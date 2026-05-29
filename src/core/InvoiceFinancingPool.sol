// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInvoiceFinancingPool} from "../interfaces/IInvoiceFinancingPool.sol";
import {IInvoiceNFT} from "../interfaces/IInvoiceNFT.sol";
import {IRWARiskManager} from "../interfaces/IRWARiskManager.sol";
import {JuniorPool} from "../pools/JuniorPool.sol";
import {SeniorPool} from "../pools/SeniorPool.sol";

/// @title InvoiceFinancingPool
/// @notice Protocol-level coordinator for senior/junior ERC-4626 invoice financing pools.
/// @dev
/// InvoiceFinancingPool acts as the on-chain SPV coordinator.
/// It does not replace SeniorPool or JuniorPool accounting.
/// Instead, it coordinates capital entry, capital exit, and later invoice financing flows.
///
/// LP entry and exit are intentionally permissionless in v1 to keep the portfolio
/// implementation focused on tranche accounting, locked liquidity, and waterfall mechanics.
/// Production RWA deployments would typically add KYC/whitelist controls around LP access.
///
/// DAY 92 scope:
/// - deploy SeniorPool and JuniorPool
/// - expose LP deposit wrappers
/// - expose LP withdrawal wrappers
/// - expose liquidity and NAV views
/// - define protocol-level accounting metrics used by later financing/default logic
///
/// DAY 93+ scope:
/// - RWARiskManager integration
/// - financeInvoice()
/// - oracle settlement adapter
/// - paid-path settlement waterfall
/// - default-path loss waterfall
contract InvoiceFinancingPool is IInvoiceFinancingPool {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAssets();
    error InvalidFundingShares();
    error InvoiceNotEligible(uint256 invoiceId);
    error InvoiceAlreadyFinanced(uint256 invoiceId);
    error UnauthorizedFinancer(uint256 invoiceId, address caller);
    error BuyerConcentrationExceeded(uint256 invoiceId, address buyer, uint256 principal);
    error InsufficientSeniorLiquidity();
    error InsufficientJuniorLiquidity();

    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable ASSET;
    IInvoiceNFT public immutable INVOICE_NFT;
    IRWARiskManager public immutable RISK_MANAGER;

    SeniorPool public immutable SENIOR_POOL;
    JuniorPool public immutable JUNIOR_POOL;

    uint256 public immutable SENIOR_FUNDING_SHARE_BPS;
    uint256 public immutable JUNIOR_FUNDING_SHARE_BPS;

    mapping(uint256 invoiceId => FinancingPosition position) public financingPositions;

    /// @notice Aggregate assets locked across both tranches.
    /// @dev
    /// DAY 92 declares this protocol-level metric, but it is first mutated when
    /// financeInvoice(), settlement, and default flows are added in later implementation days.
    uint256 public totalLockedAssets;

    /// @notice Cumulative realized credit losses across the protocol.
    /// @dev
    /// DAY 92 declares this protocol-level metric, but it is first increased during
    /// default resolution. It is a gross cumulative loss metric and is never reset.
    uint256 public totalBadDebt;

    constructor(
        IERC20 asset_,
        IInvoiceNFT invoiceNft_,
        IRWARiskManager riskManager_,
        uint256 seniorFundingShareBps_,
        uint256 juniorFundingShareBps_
    ) {
        if (address(asset_) == address(0) || address(invoiceNft_) == address(0) || address(riskManager_) == address(0))
        {
            revert ZeroAddress();
        }

        if (seniorFundingShareBps_ + juniorFundingShareBps_ != BPS_DENOMINATOR) {
            revert InvalidFundingShares();
        }

        ASSET = asset_;
        INVOICE_NFT = invoiceNft_;
        RISK_MANAGER = riskManager_;

        SENIOR_FUNDING_SHARE_BPS = seniorFundingShareBps_;
        JUNIOR_FUNDING_SHARE_BPS = juniorFundingShareBps_;

        SENIOR_POOL = new SeniorPool(asset_, address(this));
        JUNIOR_POOL = new JuniorPool(asset_, address(this));
    }

    /// @notice Finances a verified eligible invoice by locking senior and junior liquidity and advancing capital to the supplier.
    /// @dev
    /// This function performs the core transition from verified receivable to funded financing position.
    ///
    /// v1 execution authority:
    /// - Originator creates the invoice.
    /// - Verifier verifies the invoice.
    /// - Supplier requests financing.
    /// - Pool executes accounting and funding.
    ///
    /// Reverts with UnauthorizedFinancer if anyone other than the invoice supplier attempts to finance it.
    /// Reverts with BuyerConcentrationExceeded when the invoice is otherwise eligible but the buyer exposure limit would be exceeded.
    ///
    /// It does not execute settlement, default resolution, fee distribution, or loss waterfall logic.
    function financeInvoice(uint256 invoiceId) external {
        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (msg.sender != invoice.supplier) {
            revert UnauthorizedFinancer(invoiceId, msg.sender);
        }

        if (financingPositions[invoiceId].fundedAt != 0) {
            revert InvoiceAlreadyFinanced(invoiceId);
        }

        if (!RISK_MANAGER.isEligible(invoiceId)) {
            revert InvoiceNotEligible(invoiceId);
        }

        uint256 principal = RISK_MANAGER.calculateAdvance(invoice.faceValue);

        if (!RISK_MANAGER.checkConcentration(invoice.buyer, principal)) {
            revert BuyerConcentrationExceeded(invoiceId, invoice.buyer, principal);
        }

        // Any rounding remainder is allocated to the junior tranche.
        // This keeps senior funding bounded by its configured share and preserves principal conservation.
        uint256 seniorPrincipal = principal * SENIOR_FUNDING_SHARE_BPS / BPS_DENOMINATOR;
        uint256 juniorPrincipal = principal - seniorPrincipal;

        if (SENIOR_POOL.availableLiquidity() < seniorPrincipal) {
            revert InsufficientSeniorLiquidity();
        }

        if (JUNIOR_POOL.availableLiquidity() < juniorPrincipal) {
            revert InsufficientJuniorLiquidity();
        }

        uint256 fundedAt = block.timestamp;

        financingPositions[invoiceId] = FinancingPosition({
            supplier: invoice.supplier,
            buyer: invoice.buyer,
            principal: principal,
            seniorPrincipal: seniorPrincipal,
            juniorPrincipal: juniorPrincipal,
            fundedAt: fundedAt,
            dueDate: invoice.dueDate
        });

        totalLockedAssets += principal;

        // Locking and funding are intentionally separate:
        // lockAssets() commits tranche NAV to the financing position,
        // fundInvoice() performs the external cash movement after protocol state is recorded.
        SENIOR_POOL.lockAssets(seniorPrincipal);
        JUNIOR_POOL.lockAssets(juniorPrincipal);

        RISK_MANAGER.updateBuyerExposure(invoice.buyer, principal, true);

        INVOICE_NFT.markFunded(invoiceId);

        SENIOR_POOL.fundInvoice(invoice.supplier, seniorPrincipal);
        JUNIOR_POOL.fundInvoice(invoice.supplier, juniorPrincipal);

        emit InvoiceFinanced(
            invoiceId,
            invoice.supplier,
            invoice.buyer,
            principal,
            seniorPrincipal,
            juniorPrincipal,
            fundedAt,
            invoice.dueDate
        );
    }

    /// @notice Deposits assets into the SeniorPool and mints senior ERC-4626 shares to msg.sender.
    function depositSenior(uint256 assets) external returns (uint256 shares) {
        shares = depositSeniorFor(assets, msg.sender);
    }

    /// @notice Deposits assets into the SeniorPool and mints senior ERC-4626 shares to receiver.
    /// @dev
    /// The LP approves this coordinator. The coordinator pulls assets, approves SeniorPool,
    /// then deposits into the ERC-4626 vault on behalf of receiver.
    function depositSeniorFor(uint256 assets, address receiver) public returns (uint256 shares) {
        if (assets == 0) {
            revert ZeroAssets();
        }

        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        ASSET.safeTransferFrom(msg.sender, address(this), assets);
        ASSET.forceApprove(address(SENIOR_POOL), assets);

        shares = SENIOR_POOL.deposit(assets, receiver);

        ASSET.forceApprove(address(SENIOR_POOL), 0);

        emit SeniorDeposited(msg.sender, receiver, assets, shares);
    }

    /// @notice Deposits assets into the JuniorPool and mints junior ERC-4626 shares to msg.sender.
    function depositJunior(uint256 assets) external returns (uint256 shares) {
        shares = depositJuniorFor(assets, msg.sender);
    }

    /// @notice Deposits assets into the JuniorPool and mints junior ERC-4626 shares to receiver.
    /// @dev
    /// The LP approves this coordinator. The coordinator pulls assets, approves JuniorPool,
    /// then deposits into the ERC-4626 vault on behalf of receiver.
    function depositJuniorFor(uint256 assets, address receiver) public returns (uint256 shares) {
        if (assets == 0) {
            revert ZeroAssets();
        }

        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        ASSET.safeTransferFrom(msg.sender, address(this), assets);
        ASSET.forceApprove(address(JUNIOR_POOL), assets);

        shares = JUNIOR_POOL.deposit(assets, receiver);

        ASSET.forceApprove(address(JUNIOR_POOL), 0);

        emit JuniorDeposited(msg.sender, receiver, assets, shares);
    }

    /// @notice Withdraws assets from caller's SeniorPool shares to msg.sender.
    /// @dev
    /// Because this coordinator calls the ERC-4626 vault on behalf of the LP,
    /// the LP must first approve this contract to spend enough SeniorPool shares.
    function withdrawSenior(uint256 assets) external returns (uint256 shares) {
        shares = withdrawSeniorTo(assets, msg.sender);
    }

    /// @notice Withdraws assets from caller's SeniorPool shares to receiver.
    /// @dev
    /// Withdraw constraints are enforced by SeniorPool's ERC-4626 accounting.
    /// The caller must approve this contract to spend the required amount of sINV shares,
    /// because SeniorPool sees this coordinator as the ERC-4626 caller and the LP as owner.
    function withdrawSeniorTo(uint256 assets, address receiver) public returns (uint256 shares) {
        if (assets == 0) {
            revert ZeroAssets();
        }

        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        shares = SENIOR_POOL.withdraw(assets, receiver, msg.sender);

        emit SeniorWithdrawn(msg.sender, receiver, assets, shares);
    }

    /// @notice Withdraws assets from caller's JuniorPool shares to msg.sender.
    /// @dev
    /// Because this coordinator calls the ERC-4626 vault on behalf of the LP,
    /// the LP must first approve this contract to spend enough JuniorPool shares.
    function withdrawJunior(uint256 assets) external returns (uint256 shares) {
        shares = withdrawJuniorTo(assets, msg.sender);
    }

    /// @notice Withdraws assets from caller's JuniorPool shares to receiver.
    /// @dev
    /// Withdraw constraints are enforced by JuniorPool's ERC-4626 accounting.
    /// The caller must approve this contract to spend the required amount of jINV shares,
    /// because JuniorPool sees this coordinator as the ERC-4626 caller and the LP as owner.
    function withdrawJuniorTo(uint256 assets, address receiver) public returns (uint256 shares) {
        if (assets == 0) {
            revert ZeroAssets();
        }

        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        shares = JUNIOR_POOL.withdraw(assets, receiver, msg.sender);

        emit JuniorWithdrawn(msg.sender, receiver, assets, shares);
    }

    /// @notice Returns how many sINV shares must be approved before withdrawing SeniorPool assets.
    /// @dev
    /// Withdraw wrappers call the ERC-4626 vault from this coordinator, so the LP must approve
    /// this contract to spend at least this many SeniorPool shares before calling withdrawSenior.
    function previewSeniorWithdrawShares(uint256 assets) external view returns (uint256 shares) {
        return SENIOR_POOL.previewWithdraw(assets);
    }

    /// @notice Returns how many jINV shares must be approved before withdrawing JuniorPool assets.
    /// @dev
    /// Withdraw wrappers call the ERC-4626 vault from this coordinator, so the LP must approve
    /// this contract to spend at least this many JuniorPool shares before calling withdrawJunior.
    function previewJuniorWithdrawShares(uint256 assets) external view returns (uint256 shares) {
        return JUNIOR_POOL.previewWithdraw(assets);
    }

    /// @notice Returns SeniorPool available liquidity.
    function seniorAvailableLiquidity() external view returns (uint256) {
        return SENIOR_POOL.availableLiquidity();
    }

    /// @notice Returns JuniorPool available liquidity.
    function juniorAvailableLiquidity() external view returns (uint256) {
        return JUNIOR_POOL.availableLiquidity();
    }

    /// @notice Returns aggregate available liquidity across both tranches.
    /// @dev Informational only. Future funding guards must still check each tranche independently.
    function totalAvailableLiquidity() external view returns (uint256) {
        return SENIOR_POOL.availableLiquidity() + JUNIOR_POOL.availableLiquidity();
    }

    /// @notice Returns aggregate tranche NAV across SeniorPool and JuniorPool.
    function totalPoolAssets() external view returns (uint256) {
        return SENIOR_POOL.totalAssets() + JUNIOR_POOL.totalAssets();
    }
}

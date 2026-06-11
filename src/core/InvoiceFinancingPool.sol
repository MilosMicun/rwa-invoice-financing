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
/// Instead, it coordinates capital entry, capital exit, invoice financing,
/// oracle outcome consumption, settlement accounting, and default loss recognition.
///
/// LP entry and exit are intentionally permissionless in v1 to keep the portfolio
/// implementation focused on tranche accounting, locked liquidity, and waterfall mechanics.
/// Production RWA deployments would typically add KYC/whitelist controls around LP access.
///
/// Implementation scope:
/// - deploys and coordinates SeniorPool and JuniorPool vaults
/// - exposes LP deposit and withdrawal wrappers
/// - finances eligible verified invoices
/// - records finalized oracle outcomes
/// - executes paid-path settlement accounting
/// - executes default-path recovery and loss waterfalls
contract InvoiceFinancingPool is IInvoiceFinancingPool {
    using SafeERC20 for IERC20;

    error ZeroAssets();
    error InvalidFundingShares();
    error InvoiceNotEligible(uint256 invoiceId);
    error InvoiceAlreadyFinanced(uint256 invoiceId);
    error UnauthorizedFinancer(uint256 invoiceId, address caller);
    error BuyerConcentrationExceeded(uint256 invoiceId, address buyer, uint256 principal);
    error InsufficientSeniorLiquidity();
    error InsufficientJuniorLiquidity();
    error UnauthorizedAdmin(address caller);

    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable ASSET;
    IInvoiceNFT public immutable INVOICE_NFT;
    IRWARiskManager public immutable RISK_MANAGER;

    address public immutable ADMIN;

    SeniorPool public immutable SENIOR_POOL;
    JuniorPool public immutable JUNIOR_POOL;

    /// @notice Share of financed principal funded by the senior tranche, in basis points.
    uint256 public immutable SENIOR_FUNDING_SHARE_BPS;

    /// @notice Share of financed principal funded by the junior tranche, in basis points.
    uint256 public immutable JUNIOR_FUNDING_SHARE_BPS;

    /// @notice Share of realized financing fees allocated to the senior tranche, in basis points.
    /// @dev Used only during paid-path settlement. Funding share and fee share are separate economic parameters.
    uint256 public immutable SENIOR_FEE_SHARE_BPS;

    /// @notice Share of realized financing fees allocated to the junior tranche, in basis points.
    /// @dev Used only during paid-path settlement. Junior may receive enhanced fee participation for first-loss risk.
    uint256 public immutable JUNIOR_FEE_SHARE_BPS;

    /// @notice Address authorized to deliver finalized invoice outcome callbacks.
    /// @dev Set once by the pool admin. Used to authorize onStatusFinalized().
    address public invoiceStatusOracle;

    /// @notice Finalized oracle outcome recorded for each invoice.
    /// @dev
    /// Default enum value is CREATED, but only SETTLED and DEFAULTED represent
    /// valid finalized oracle outcomes in v1.
    mapping(uint256 invoiceId => IInvoiceNFT.InvoiceStatus status) public finalizedOracleStatus;

    /// @notice Oracle-attested recovered principal recorded for each finalized invoice outcome.
    /// @dev
    /// Must be zero for SETTLED outcomes.
    /// For DEFAULTED outcomes, this value is the only recovery amount consumed
    /// by default resolution accounting.
    mapping(uint256 invoiceId => uint256 recoveredAmount) public finalizedRecoveryAmount;

    /// @notice Per-invoice financing positions created when invoices are funded.
    /// @dev A position remains stored after settlement/default for auditability.
    mapping(uint256 invoiceId => FinancingPosition position) public financingPositions;

    /// @notice Aggregate assets locked across both tranches.
    /// @dev Increased when invoices are financed and decreased exactly once during settlement or default resolution.
    uint256 public totalLockedAssets;

    /// @notice Cumulative realized credit losses across the protocol.
    /// @dev Gross cumulative principal loss metric. It is increased during default resolution and is never reset.
    uint256 public totalBadDebt;

    constructor(
        IERC20 asset_,
        IInvoiceNFT invoiceNft_,
        IRWARiskManager riskManager_,
        uint256 seniorFundingShareBps_,
        uint256 juniorFundingShareBps_,
        uint256 seniorFeeShareBps_,
        uint256 juniorFeeShareBps_
    ) {
        if (address(asset_) == address(0) || address(invoiceNft_) == address(0) || address(riskManager_) == address(0))
        {
            revert ZeroAddress();
        }

        if (seniorFundingShareBps_ + juniorFundingShareBps_ != BPS_DENOMINATOR) {
            revert InvalidFundingShares();
        }

        if (seniorFeeShareBps_ + juniorFeeShareBps_ != BPS_DENOMINATOR) {
            revert InvalidFeeShares();
        }

        ASSET = asset_;
        INVOICE_NFT = invoiceNft_;
        RISK_MANAGER = riskManager_;
        ADMIN = msg.sender;

        SENIOR_FUNDING_SHARE_BPS = seniorFundingShareBps_;
        JUNIOR_FUNDING_SHARE_BPS = juniorFundingShareBps_;

        SENIOR_FEE_SHARE_BPS = seniorFeeShareBps_;
        JUNIOR_FEE_SHARE_BPS = juniorFeeShareBps_;

        SENIOR_POOL = new SeniorPool(asset_, address(this));
        JUNIOR_POOL = new JuniorPool(asset_, address(this));
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        if (msg.sender != ADMIN) {
            revert UnauthorizedAdmin(msg.sender);
        }
    }

    /// @notice Sets the invoice status oracle used for finalized status callbacks.
    /// @dev
    /// This is intentionally set once to avoid silently changing the source of off-chain truth.
    /// The oracle reports finalized invoice outcomes, while this pool remains responsible
    /// for settlement/default accounting.
    /// @param oracle Address of the InvoiceStatusOracle contract.
    function setInvoiceStatusOracle(address oracle) external onlyAdmin {
        if (oracle == address(0)) {
            revert ZeroAddress();
        }

        if (invoiceStatusOracle != address(0)) {
            revert OracleAlreadySet();
        }

        invoiceStatusOracle = oracle;

        emit InvoiceStatusOracleSet(oracle);
    }

    /// @notice Receives a finalized invoice outcome from the configured oracle.
    /// @dev
    /// Callable only by the configured InvoiceStatusOracle.
    ///
    /// This function records both the terminal status and the oracle-attested
    /// recovered principal. It does not execute settlement/default accounting
    /// and does not mutate InvoiceNFT.
    ///
    /// A financing position must already exist. Oracle outcomes cannot be
    /// preloaded before an invoice becomes an active financed position.
    ///
    /// SETTLED outcomes must use zero recovery.
    /// DEFAULTED recovery must not exceed the stored financed principal.
    ///
    /// @param invoiceId Identifier of the financed invoice.
    /// @param status Finalized oracle outcome: SETTLED or DEFAULTED.
    /// @param recoveredAmount Oracle-attested recovered principal.
    function onStatusFinalized(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status, uint256 recoveredAmount) external {
        if (invoiceStatusOracle == address(0)) {
            revert OracleNotSet();
        }

        if (msg.sender != invoiceStatusOracle) {
            revert UnauthorizedOracle(msg.sender);
        }

        if (!_isAllowedFinalizedOracleStatus(status)) {
            revert InvalidOracleStatus(status);
        }

        FinancingPosition storage position = financingPositions[invoiceId];

        if (position.fundedAt == 0) {
            revert FinancingPositionDoesNotExist(invoiceId);
        }

        IInvoiceNFT.InvoiceStatus currentStatus = finalizedOracleStatus[invoiceId];

        if (currentStatus == IInvoiceNFT.InvoiceStatus.SETTLED || currentStatus == IInvoiceNFT.InvoiceStatus.DEFAULTED)
        {
            revert OracleStatusAlreadyFinalized(invoiceId);
        }

        if (status == IInvoiceNFT.InvoiceStatus.SETTLED) {
            if (recoveredAmount != 0) {
                revert InvalidRecoveryForStatus(status, recoveredAmount);
            }
        } else if (recoveredAmount > position.principal) {
            revert RecoveredAmountExceedsPrincipal(invoiceId, recoveredAmount, position.principal);
        }

        finalizedOracleStatus[invoiceId] = status;
        finalizedRecoveryAmount[invoiceId] = recoveredAmount;

        emit OracleStatusFinalized(invoiceId, status, recoveredAmount);
    }

    /// @notice Returns whether an invoice has a finalized oracle outcome.
    /// @dev
    /// Only SETTLED and DEFAULTED are valid finalized oracle outcomes in v1.
    /// The default enum value CREATED must not be interpreted as finalized.
    /// @param invoiceId Invoice identifier.
    /// @return finalized True if the oracle finalized SETTLED or DEFAULTED.
    function isOracleStatusFinalized(uint256 invoiceId) external view returns (bool finalized) {
        return _isAllowedFinalizedOracleStatus(finalizedOracleStatus[invoiceId]);
    }

    /// @notice Finances a verified eligible invoice by locking senior and junior liquidity and advancing capital to the supplier.
    /// @dev
    /// This function performs the core transition from verified receivable to funded financing position.
    ///
    /// Execution authority:
    /// - Originator creates the invoice.
    /// - Verifier verifies the invoice.
    /// - Supplier requests financing.
    /// - Pool executes accounting and funding.
    ///
    /// Reverts with UnauthorizedFinancer if anyone other than the invoice supplier attempts to finance it.
    /// Reverts with BuyerConcentrationExceeded when the invoice is otherwise eligible but the buyer exposure limit would be exceeded.
    ///
    /// This function does not execute settlement, default resolution, fee distribution, or loss waterfall logic.
    /// The financing fee is calculated and stored at funding time so later risk parameter changes
    /// do not affect already active financing positions.
    ///
    /// Eligibility requires dueDate > block.timestamp, so valid funded positions should not
    /// receive a zero fee due to expired invoice maturity.
    /// @param invoiceId Identifier of the verified invoice to finance.
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
        uint256 financingFee = RISK_MANAGER.calculateFee(principal, fundedAt, invoice.dueDate);

        financingPositions[invoiceId] = FinancingPosition({
            supplier: invoice.supplier,
            buyer: invoice.buyer,
            principal: principal,
            seniorPrincipal: seniorPrincipal,
            juniorPrincipal: juniorPrincipal,
            financingFee: financingFee,
            fundedAt: fundedAt,
            dueDate: invoice.dueDate,
            resolved: false
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
            financingFee,
            fundedAt,
            invoice.dueDate
        );
    }

    /// @notice Settles a financed invoice after the oracle has finalized a paid outcome.
    /// @dev
    /// Consumes a finalized oracle SETTLED status and executes the paid-path waterfall
    /// for an active financing position.
    ///
    /// The oracle only finalizes the off-chain repayment outcome. This pool performs
    /// the accounting effects and marks the InvoiceNFT as SETTLED only after successful
    /// settlement execution.
    ///
    /// The function is permissionless in v1: any caller may execute settlement
    /// after oracle finalization, provided they hold approval for `paidAmount`.
    /// This keeps settlement execution authority separate from oracle reporting authority.
    ///
    /// Requirements:
    /// - The invoice must have an active financing position.
    /// - The position must not already be resolved.
    /// - The oracle must have finalized SETTLED for the invoice.
    /// - The InvoiceNFT lifecycle status must still be FUNDED.
    /// - The invoice must not be FROZEN.
    /// - `paidAmount` must be at least principal plus stored financing fee.
    ///
    /// Accounting:
    /// - Senior and junior principal cash backing is restored to the tranche vaults.
    /// - Financing fee is split between tranches according to configured fee shares.
    /// - Surplus above principal plus financing fee is returned to the Supplier.
    /// - Locked assets and buyer exposure are reduced exactly once.
    /// - The financing position is marked resolved before external calls for CEI safety.
    ///
    /// @param invoiceId Identifier of the financed invoice.
    /// @param paidAmount Amount reported as paid and pulled through the settlement waterfall.
    function settleInvoice(uint256 invoiceId, uint256 paidAmount) external {
        FinancingPosition storage position = financingPositions[invoiceId];

        if (position.fundedAt == 0) {
            revert FinancingPositionDoesNotExist(invoiceId);
        }

        if (position.resolved) {
            revert FinancingPositionAlreadyResolved(invoiceId);
        }

        IInvoiceNFT.InvoiceStatus oracleStatus = finalizedOracleStatus[invoiceId];

        if (!_isAllowedFinalizedOracleStatus(oracleStatus)) {
            revert OracleStatusNotFinalized(invoiceId);
        }

        if (oracleStatus != IInvoiceNFT.InvoiceStatus.SETTLED) {
            revert UnexpectedOracleStatus(invoiceId, oracleStatus, IInvoiceNFT.InvoiceStatus.SETTLED);
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status == IInvoiceNFT.InvoiceStatus.FROZEN) {
            revert InvoiceFrozen(invoiceId);
        }

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            revert InvoiceNotFunded(invoiceId, invoice.status);
        }

        uint256 expectedRepayment = position.principal + position.financingFee;

        if (paidAmount < expectedRepayment) {
            revert PaidAmountBelowExpected(paidAmount, expectedRepayment);
        }

        uint256 juniorFee = position.financingFee * JUNIOR_FEE_SHARE_BPS / BPS_DENOMINATOR;
        uint256 seniorFee = position.financingFee - juniorFee;
        uint256 surplus = paidAmount - expectedRepayment;
        uint256 settledAt = block.timestamp;

        uint256 seniorRepayment = position.seniorPrincipal + seniorFee;
        uint256 juniorRepayment = position.juniorPrincipal + juniorFee;

        // Close local accounting before external calls.
        // If any later operation reverts, the whole transaction reverts atomically.
        position.resolved = true;
        totalLockedAssets -= position.principal;

        if (seniorRepayment > 0) {
            ASSET.safeTransferFrom(msg.sender, address(SENIOR_POOL), seniorRepayment);
        }

        if (juniorRepayment > 0) {
            ASSET.safeTransferFrom(msg.sender, address(JUNIOR_POOL), juniorRepayment);
        }

        if (surplus > 0) {
            ASSET.safeTransferFrom(msg.sender, position.supplier, surplus);
        }

        SENIOR_POOL.unlockAssets(position.seniorPrincipal);
        JUNIOR_POOL.unlockAssets(position.juniorPrincipal);

        if (seniorFee > 0) {
            SENIOR_POOL.creditAssets(seniorFee);
        }

        if (juniorFee > 0) {
            JUNIOR_POOL.creditAssets(juniorFee);
        }

        RISK_MANAGER.updateBuyerExposure(position.buyer, position.principal, false);

        INVOICE_NFT.markSettled(invoiceId);

        emit InvoiceSettled(
            invoiceId,
            msg.sender,
            position.buyer,
            paidAmount,
            position.principal,
            position.financingFee,
            juniorFee,
            seniorFee,
            surplus,
            settledAt
        );
    }

    /// @notice Resolves a defaulted financed invoice after the oracle has finalized a default outcome.
    /// @dev
    /// Consumes a finalized oracle DEFAULTED status and executes the default-path recovery
    /// and loss waterfall for an active financing position.
    ///
    /// The oracle finalizes both the off-chain default status and the recovered principal.
    /// This pool performs recovery allocation, NAV writedowns, bad debt accounting,
    /// and marks the InvoiceNFT as DEFAULTED only after successful default execution.
    ///
    /// The function is permissionless in v1: any caller may execute default resolution
    /// after oracle finalization, provided they hold enough assets and approval to supply
    /// the oracle-finalized recovered principal.
    ///
    /// The caller cannot select or modify the recovered amount.
    /// Default accounting consumes only the value previously finalized by the oracle.
    ///
    /// Requirements:
    /// - The invoice must have an active financing position.
    /// - The position must not already be resolved.
    /// - The oracle must have finalized DEFAULTED for the invoice.
    /// - The InvoiceNFT lifecycle status must still be FUNDED.
    /// - The invoice must not be FROZEN.
    /// - The oracle-finalized recovered amount must not exceed financed principal.
    ///
    /// Accounting:
    /// - Recovered principal is allocated to SeniorPool first, then JuniorPool.
    /// - JuniorPool absorbs first-loss exposure through NAV writedown.
    /// - SeniorPool absorbs only residual loss after junior recovery is depleted.
    /// - `totalBadDebt` increases by realized principal credit loss.
    /// - Unpaid financing fee is not counted as bad debt because it was never realized NAV.
    /// - Locked assets and buyer exposure are reduced exactly once.
    /// - The financing position is marked resolved before external calls for CEI safety.
    ///
    /// @param invoiceId Identifier of the financed invoice.
    function resolveDefault(uint256 invoiceId) external {
        FinancingPosition storage position = financingPositions[invoiceId];

        if (position.fundedAt == 0) {
            revert FinancingPositionDoesNotExist(invoiceId);
        }

        if (position.resolved) {
            revert FinancingPositionAlreadyResolved(invoiceId);
        }

        IInvoiceNFT.InvoiceStatus oracleStatus = finalizedOracleStatus[invoiceId];

        if (!_isAllowedFinalizedOracleStatus(oracleStatus)) {
            revert OracleStatusNotFinalized(invoiceId);
        }

        if (oracleStatus != IInvoiceNFT.InvoiceStatus.DEFAULTED) {
            revert UnexpectedOracleStatus(invoiceId, oracleStatus, IInvoiceNFT.InvoiceStatus.DEFAULTED);
        }

        uint256 recoveredAmount = finalizedRecoveryAmount[invoiceId];

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status == IInvoiceNFT.InvoiceStatus.FROZEN) {
            revert InvoiceFrozen(invoiceId);
        }

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            revert InvoiceNotFunded(invoiceId, invoice.status);
        }

        if (recoveredAmount > position.principal) {
            revert RecoveredAmountExceedsPrincipal(invoiceId, recoveredAmount, position.principal);
        }

        uint256 seniorRecovery = recoveredAmount > position.seniorPrincipal ? position.seniorPrincipal : recoveredAmount;

        uint256 juniorRecovery = recoveredAmount - seniorRecovery;

        uint256 seniorLoss = position.seniorPrincipal - seniorRecovery;
        uint256 juniorLoss = position.juniorPrincipal - juniorRecovery;

        uint256 loss = position.principal - recoveredAmount;

        // Close local accounting before external calls.
        // If any later operation reverts, the whole transaction reverts atomically.
        position.resolved = true;
        totalLockedAssets -= position.principal;
        totalBadDebt += loss;

        if (seniorRecovery > 0) {
            ASSET.safeTransferFrom(msg.sender, address(SENIOR_POOL), seniorRecovery);
        }

        if (juniorRecovery > 0) {
            ASSET.safeTransferFrom(msg.sender, address(JUNIOR_POOL), juniorRecovery);
        }

        SENIOR_POOL.unlockAssets(position.seniorPrincipal);
        JUNIOR_POOL.unlockAssets(position.juniorPrincipal);

        if (juniorLoss > 0) {
            JUNIOR_POOL.writeDown(juniorLoss);
        }

        if (seniorLoss > 0) {
            SENIOR_POOL.writeDown(seniorLoss);
        }

        RISK_MANAGER.updateBuyerExposure(position.buyer, position.principal, false);

        INVOICE_NFT.markDefaulted(invoiceId);

        emit InvoiceDefaultResolved(
            invoiceId,
            msg.sender,
            position.buyer,
            position.principal,
            recoveredAmount,
            seniorRecovery,
            juniorRecovery,
            loss,
            juniorLoss,
            seniorLoss
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

    /// @dev Returns true only for finalized oracle outcomes accepted by the pool.
    function _isAllowedFinalizedOracleStatus(IInvoiceNFT.InvoiceStatus status) internal pure returns (bool) {
        return status == IInvoiceNFT.InvoiceStatus.SETTLED || status == IInvoiceNFT.InvoiceStatus.DEFAULTED;
    }
}


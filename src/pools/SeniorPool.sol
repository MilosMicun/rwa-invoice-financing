// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title SeniorPool
/// @notice ERC-4626 vault representing the senior liquidity tranche.
/// @dev
/// SeniorPool tracks pool-accounted NAV separately from raw token balance.
/// This is required because invoice financing sends tokens out to suppliers,
/// while the pool still owns an economic claim against the financed receivable.
///
/// `accountedAssets` is the ERC-4626 NAV source.
/// `lockedAssets` is the portion of NAV committed to active invoice financings.
///
/// Losses are later recognized through `writeDown()`, which decreases NAV
/// without burning LP shares. This causes ERC-4626 share price to fall naturally.
///
/// SeniorPool is protected by JuniorPool first-loss capital, but is not risk-free.
/// Residual losses after JuniorPool depletion are written down here.
contract SeniorPool is ERC4626 {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAssets();
    error InsufficientAvailableLiquidity();
    error InsufficientAccountedAssets();
    error NotInvoiceFinancingPool();

    event AssetsLocked(uint256 assets);
    event AssetsUnlocked(uint256 assets);
    event AssetsCredited(uint256 assets);
    event AssetsWrittenDown(uint256 assets);
    event InvoiceFunded(address indexed receiver, uint256 assets);

    address public immutable INVOICE_FINANCING_POOL;

    uint256 private accountedAssets;
    uint256 public lockedAssets;

    constructor(IERC20 asset_, address invoiceFinancingPool_)
        ERC20("Senior Invoice Pool Share", "sINV")
        ERC4626(asset_)
    {
        if (address(asset_) == address(0) || invoiceFinancingPool_ == address(0)) {
            revert ZeroAddress();
        }

        INVOICE_FINANCING_POOL = invoiceFinancingPool_;
    }

    modifier onlyInvoiceFinancingPool() {
        _onlyInvoiceFinancingPool();
        _;
    }

    function _onlyInvoiceFinancingPool() internal view {
        if (msg.sender != INVOICE_FINANCING_POOL) {
            revert NotInvoiceFinancingPool();
        }
    }

    /// @notice Returns pool-accounted NAV used by ERC-4626 share pricing.
    /// @dev This intentionally does not equal raw token balance during active financing.
    function totalAssets() public view override returns (uint256) {
        return accountedAssets;
    }

    /// @notice Returns liquidity not locked in active invoice financings.
    function availableLiquidity() public view returns (uint256) {
        return accountedAssets - lockedAssets;
    }

    /// @notice Returns the maximum amount `owner` can withdraw without touching locked liquidity.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        uint256 available = availableLiquidity();
        uint256 cash = IERC20(asset()).balanceOf(address(this));

        uint256 liquid = available < cash ? available : cash;

        return ownerAssets < liquid ? ownerAssets : liquid;
    }

    /// @notice Returns the maximum shares `owner` can redeem without touching locked liquidity.
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        return convertToShares(maxAssets);
    }

    /// @notice Locks NAV into an active invoice financing position.
    /// @dev Locking does not reduce NAV. It only reduces withdrawable liquidity.
    function lockAssets(uint256 assets) external onlyInvoiceFinancingPool {
        if (assets == 0) {
            revert ZeroAssets();
        }

        if (assets > availableLiquidity()) {
            revert InsufficientAvailableLiquidity();
        }

        lockedAssets += assets;

        emit AssetsLocked(assets);
    }

    /// @notice Releases locked NAV after settlement/default resolution.
    function unlockAssets(uint256 assets) external onlyInvoiceFinancingPool {
        if (assets == 0) {
            revert ZeroAssets();
        }

        if (assets > lockedAssets) {
            revert InsufficientAccountedAssets();
        }

        lockedAssets -= assets;

        emit AssetsUnlocked(assets);
    }

    /// @notice Sends liquidity to a supplier as part of invoice financing.
    /// @dev
    /// This function does not decrease NAV because the pool receives invoice exposure
    /// in exchange for the transferred liquidity.
    function fundInvoice(address receiver, uint256 assets) external onlyInvoiceFinancingPool {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        if (assets == 0) {
            revert ZeroAssets();
        }

        if (assets > lockedAssets) {
            revert InsufficientAccountedAssets();
        }

        if (assets > IERC20(asset()).balanceOf(address(this))) {
            revert InsufficientAvailableLiquidity();
        }

        IERC20(asset()).safeTransfer(receiver, assets);

        emit InvoiceFunded(receiver, assets);
    }

    /// @notice Credits realized yield to the pool NAV after invoice settlement.
    /// @dev
    /// Calling convention during settlement:
    /// 1. InvoiceFinancingPool transfers repayment tokens to this vault.
    /// 2. unlockAssets(principal) is called to release the financed principal from locked NAV.
    /// 3. creditAssets(yield) is called to account for incremental realized yield.
    ///
    /// `assets` must be the yield component only.
    /// Principal is already part of accountedAssets while the invoice is active,
    /// so passing principal + yield would incorrectly attempt to credit principal twice.
    ///
    /// The requiredCash check enforces that unlocked NAV plus new yield is backed
    /// by real token balance before accountedAssets increases.
    function creditAssets(uint256 assets) external onlyInvoiceFinancingPool {
        if (assets == 0) {
            revert ZeroAssets();
        }

        // Solvency assertion: after crediting yield, every unlocked NAV unit
        // must be backed by real cash. This prevents accountedAssets from growing
        // without corresponding token balance.
        uint256 requiredCash = availableLiquidity() + assets;

        if (IERC20(asset()).balanceOf(address(this)) < requiredCash) {
            revert InsufficientAvailableLiquidity();
        }

        accountedAssets += assets;

        emit AssetsCredited(assets);
    }

    /// @notice Recognizes realized loss by reducing pool NAV without burning LP shares.
    /// @dev
    /// InvoiceFinancingPool must release the relevant locked position before calling this function.
    /// This keeps locked liquidity accounting explicit and prevents silent accounting repair.
    function writeDown(uint256 assets) external onlyInvoiceFinancingPool {
        if (assets == 0) {
            revert ZeroAssets();
        }

        if (assets > accountedAssets) {
            revert InsufficientAccountedAssets();
        }

        if (assets > availableLiquidity()) {
            revert InsufficientAvailableLiquidity();
        }

        accountedAssets -= assets;

        emit AssetsWrittenDown(assets);
    }

    /// @dev Updates internal NAV after a successful ERC-4626 deposit/mint.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);

        accountedAssets += assets;
    }

    /// @dev Updates internal NAV after a successful ERC-4626 withdraw/redeem.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets > availableLiquidity()) {
            revert InsufficientAvailableLiquidity();
        }

        super._withdraw(caller, receiver, owner, assets, shares);

        accountedAssets -= assets;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInvoiceNFT} from "./IInvoiceNFT.sol";

/// @title IInvoiceFinancingPool
/// @notice Interface for the protocol coordinator that funds invoices through senior and junior ERC-4626 tranches.
/// @dev
/// InvoiceFinancingPool acts as the on-chain SPV coordinator.
/// It does not custody capital directly as a single pool.
/// Instead, it coordinates SeniorPool and JuniorPool accounting, locks tranche liquidity,
/// records financing positions, updates risk exposure, advances funds to suppliers,
/// records finalized oracle outcomes, and executes settlement/default waterfalls.
interface IInvoiceFinancingPool {
    /// @notice Per-invoice accounting record created when an invoice is financed.
    /// @dev
    /// The senior/junior principal split and financing fee are stored at funding time
    /// and must be reused during settlement/default resolution. Future funding share,
    /// fee share, or risk parameter changes must not affect already active financing positions.
    ///
    /// `resolved` prevents settlement and default execution from both being applied
    /// to the same financed invoice.
    struct FinancingPosition {
        address supplier;
        address buyer;
        uint256 principal;
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 financingFee;
        uint256 fundedAt;
        uint256 dueDate;
        bool resolved;
    }

    error ZeroAddress();
    error OracleAlreadySet();
    error OracleNotSet();
    error InvalidFeeShares();
    error UnauthorizedOracle(address caller);
    error InvalidOracleStatus(IInvoiceNFT.InvoiceStatus status);
    error InvalidRecoveryForStatus(IInvoiceNFT.InvoiceStatus status, uint256 recoveredAmount);
    error OracleStatusAlreadyFinalized(uint256 invoiceId);
    error OracleStatusNotFinalized(uint256 invoiceId);
    error UnexpectedOracleStatus(
        uint256 invoiceId, IInvoiceNFT.InvoiceStatus actual, IInvoiceNFT.InvoiceStatus expected
    );
    error PaidAmountBelowExpected(uint256 paidAmount, uint256 expectedRepayment);
    error FinancingPositionDoesNotExist(uint256 invoiceId);
    error FinancingPositionAlreadyResolved(uint256 invoiceId);
    error InvoiceFrozen(uint256 invoiceId);
    error InvoiceNotFunded(uint256 invoiceId, IInvoiceNFT.InvoiceStatus currentStatus);
    error RecoveredAmountExceedsPrincipal(uint256 invoiceId, uint256 recoveredAmount, uint256 principal);

    event SeniorDeposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    event JuniorDeposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    event SeniorWithdrawn(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    event JuniorWithdrawn(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted after a funded invoice is successfully settled through the paid-path waterfall.
    /// @dev
    /// `paidAmount` is the total amount reported and pulled through the settlement flow.
    /// `principal + financingFee` is the expected repayment.
    /// `surplus` is any amount above expected repayment returned to the Supplier.
    event InvoiceSettled(
        uint256 indexed invoiceId,
        address indexed payer,
        address indexed buyer,
        uint256 paidAmount,
        uint256 principal,
        uint256 financingFee,
        uint256 juniorFee,
        uint256 seniorFee,
        uint256 surplus,
        uint256 settledAt
    );

    /// @notice Emitted after a funded invoice is resolved through the default-path waterfall.
    /// @dev
    /// Recoveries are allocated to SeniorPool first, then JuniorPool.
    /// Losses are attributed after recovery allocation and recognized through tranche NAV writedowns.
    event InvoiceDefaultResolved(
        uint256 indexed invoiceId,
        address indexed resolver,
        address indexed buyer,
        uint256 principal,
        uint256 recoveredAmount,
        uint256 seniorRecovery,
        uint256 juniorRecovery,
        uint256 loss,
        uint256 juniorLoss,
        uint256 seniorLoss
    );

    event InvoiceFinanced(
        uint256 indexed invoiceId,
        address indexed supplier,
        address indexed buyer,
        uint256 principal,
        uint256 seniorPrincipal,
        uint256 juniorPrincipal,
        uint256 financingFee,
        uint256 fundedAt,
        uint256 dueDate
    );

    event InvoiceStatusOracleSet(address indexed oracle);

    /// @notice Emitted when the authorized oracle finalizes an outcome for a financed invoice.
    /// @dev
    /// `recoveredAmount` must be zero for SETTLED outcomes.
    /// For DEFAULTED outcomes, it represents oracle-attested recovered principal.
    event OracleStatusFinalized(
        uint256 indexed invoiceId, IInvoiceNFT.InvoiceStatus indexed status, uint256 recoveredAmount
    );

    function financeInvoice(uint256 invoiceId) external;

    function setInvoiceStatusOracle(address oracle) external;

    /// @notice Records an oracle-finalized outcome for an existing financed position.
    /// @dev
    /// Callable only by the configured oracle.
    /// The implementation must reject outcomes for invoices without an existing
    /// financing position and must validate recovery against the stored principal.
    /// @param invoiceId Identifier of the financed invoice.
    /// @param status Finalized terminal outcome: SETTLED or DEFAULTED.
    /// @param recoveredAmount Oracle-attested recovered principal for a default.
    function onStatusFinalized(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status, uint256 recoveredAmount) external;

    /// @notice Executes paid-path settlement for a financed invoice.
    /// @dev Requires a finalized oracle SETTLED status.
    /// @param invoiceId Identifier of the financed invoice.
    /// @param paidAmount Amount reported as paid and pulled through the settlement waterfall.
    function settleInvoice(uint256 invoiceId, uint256 paidAmount) external;

    /// @notice Executes default-path recovery and loss recognition for a financed invoice.
    /// @dev
    /// Requires a finalized oracle DEFAULTED status.
    /// The recovery amount is read from the oracle-finalized outcome stored by the pool.
    /// The caller cannot select or modify the recovery amount during execution.
    /// @param invoiceId Identifier of the financed invoice.
    function resolveDefault(uint256 invoiceId) external;

    function isOracleStatusFinalized(uint256 invoiceId) external view returns (bool finalized);

    function finalizedOracleStatus(uint256 invoiceId) external view returns (IInvoiceNFT.InvoiceStatus status);

    function finalizedRecoveryAmount(uint256 invoiceId) external view returns (uint256 recoveredAmount);

    function invoiceStatusOracle() external view returns (address oracle);

    function depositSenior(uint256 assets) external returns (uint256 shares);

    function depositSeniorFor(uint256 assets, address receiver) external returns (uint256 shares);

    function depositJunior(uint256 assets) external returns (uint256 shares);

    function depositJuniorFor(uint256 assets, address receiver) external returns (uint256 shares);

    function withdrawSenior(uint256 assets) external returns (uint256 shares);

    function withdrawSeniorTo(uint256 assets, address receiver) external returns (uint256 shares);

    function withdrawJunior(uint256 assets) external returns (uint256 shares);

    function withdrawJuniorTo(uint256 assets, address receiver) external returns (uint256 shares);

    function previewSeniorWithdrawShares(uint256 assets) external view returns (uint256 shares);

    function previewJuniorWithdrawShares(uint256 assets) external view returns (uint256 shares);

    function seniorAvailableLiquidity() external view returns (uint256);

    function juniorAvailableLiquidity() external view returns (uint256);

    function totalAvailableLiquidity() external view returns (uint256);

    function totalPoolAssets() external view returns (uint256);

    function totalLockedAssets() external view returns (uint256);

    function totalBadDebt() external view returns (uint256);

    function financingPositions(uint256 invoiceId)
        external
        view
        returns (
            address supplier,
            address buyer,
            uint256 principal,
            uint256 seniorPrincipal,
            uint256 juniorPrincipal,
            uint256 financingFee,
            uint256 fundedAt,
            uint256 dueDate,
            bool resolved
        );
}


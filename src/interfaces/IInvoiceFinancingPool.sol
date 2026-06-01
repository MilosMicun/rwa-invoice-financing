// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInvoiceNFT} from "./IInvoiceNFT.sol";

/// @title IInvoiceFinancingPool
/// @notice Interface for the protocol coordinator that funds invoices through senior and junior ERC-4626 tranches.
/// @dev
/// InvoiceFinancingPool acts as the on-chain SPV coordinator.
/// It does not custody capital directly as a single pool.
/// Instead, it coordinates SeniorPool and JuniorPool accounting, locks tranche liquidity,
/// records financing positions, updates risk exposure, and advances funds to suppliers.
interface IInvoiceFinancingPool {
    /// @notice Per-invoice accounting record created when an invoice is financed.
    /// @dev
    /// The senior/junior principal split and financing fee are stored at funding time
    /// and must be reused during settlement/default resolution. Future funding share
    /// or risk parameter changes must not affect already active financing positions.
    struct FinancingPosition {
        address supplier;
        address buyer;
        uint256 principal;
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 financingFee;
        uint256 fundedAt;
        uint256 dueDate;
    }

    error ZeroAddress();
    error OracleAlreadySet();
    error OracleNotSet();
    error UnauthorizedOracle(address caller);
    error InvalidOracleStatus(IInvoiceNFT.InvoiceStatus status);
    error OracleStatusAlreadyFinalized(uint256 invoiceId);

    event SeniorDeposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event JuniorDeposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event SeniorWithdrawn(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event JuniorWithdrawn(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

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

    event OracleStatusFinalized(uint256 indexed invoiceId, IInvoiceNFT.InvoiceStatus indexed status);

    function financeInvoice(uint256 invoiceId) external;

    function setInvoiceStatusOracle(address oracle) external;

    function onStatusFinalized(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status) external;

    function isOracleStatusFinalized(uint256 invoiceId) external view returns (bool finalized);

    function finalizedOracleStatus(uint256 invoiceId) external view returns (IInvoiceNFT.InvoiceStatus status);

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
            uint256 dueDate
        );
}

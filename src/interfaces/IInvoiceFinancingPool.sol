// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
    /// The senior/junior principal split is stored at funding time and must be reused
    /// during settlement and default resolution. Future funding share changes must not
    /// affect already active financing positions.
    struct FinancingPosition {
        address supplier;
        address buyer;
        uint256 principal;
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 fundedAt;
        uint256 dueDate;
    }

    /// @notice Emitted when liquidity is deposited into the senior tranche.
    event SeniorDeposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when liquidity is deposited into the junior tranche.
    event JuniorDeposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when assets are withdrawn from the senior tranche.
    event SeniorWithdrawn(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when assets are withdrawn from the junior tranche.
    event JuniorWithdrawn(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a verified invoice is financed and liquidity is advanced to the supplier.
    /// @dev
    /// This event records the immutable funding split used for future settlement/default accounting.
    event InvoiceFinanced(
        uint256 indexed invoiceId,
        address indexed supplier,
        address indexed buyer,
        uint256 principal,
        uint256 seniorPrincipal,
        uint256 juniorPrincipal,
        uint256 fundedAt,
        uint256 dueDate
    );

    /// @notice Finances an eligible verified invoice.
    /// @dev
    /// This function performs the core transition from verified receivable to funded position.
    ///
    /// v1 execution authority:
    /// - Originator creates the invoice.
    /// - Verifier verifies the invoice.
    /// - Supplier requests financing.
    /// - Pool executes accounting and funding.
    ///
    /// It must atomically:
    /// - validate that caller is the invoice supplier
    /// - validate risk eligibility
    /// - check buyer concentration
    /// - check senior and junior liquidity independently
    /// - record the financing position
    /// - lock tranche assets
    /// - update buyer exposure
    /// - mark the invoice as funded
    /// - transfer liquidity to the supplier
    ///
    /// It does not execute settlement, default resolution, fee distribution, or loss waterfall logic.
    /// @param invoiceId Invoice identifier in the InvoiceNFT registry.
    function financeInvoice(uint256 invoiceId) external;

    /// @notice Deposits assets into the SeniorPool and mints senior shares to the caller.
    /// @param assets Amount of underlying asset to deposit.
    /// @return shares Amount of senior shares minted.
    function depositSenior(uint256 assets) external returns (uint256 shares);

    /// @notice Deposits assets into the SeniorPool and mints senior shares to a receiver.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Address receiving the senior shares.
    /// @return shares Amount of senior shares minted.
    function depositSeniorFor(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Deposits assets into the JuniorPool and mints junior shares to the caller.
    /// @param assets Amount of underlying asset to deposit.
    /// @return shares Amount of junior shares minted.
    function depositJunior(uint256 assets) external returns (uint256 shares);

    /// @notice Deposits assets into the JuniorPool and mints junior shares to a receiver.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Address receiving the junior shares.
    /// @return shares Amount of junior shares minted.
    function depositJuniorFor(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraws assets from the caller's SeniorPool shares to the caller.
    /// @dev Caller must approve this coordinator to spend the required senior shares.
    /// @param assets Amount of underlying asset to withdraw.
    /// @return shares Amount of senior shares burned.
    function withdrawSenior(uint256 assets) external returns (uint256 shares);

    /// @notice Withdraws assets from the caller's SeniorPool shares to a receiver.
    /// @dev Caller must approve this coordinator to spend the required senior shares.
    /// @param assets Amount of underlying asset to withdraw.
    /// @param receiver Address receiving the withdrawn assets.
    /// @return shares Amount of senior shares burned.
    function withdrawSeniorTo(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraws assets from the caller's JuniorPool shares to the caller.
    /// @dev Caller must approve this coordinator to spend the required junior shares.
    /// @param assets Amount of underlying asset to withdraw.
    /// @return shares Amount of junior shares burned.
    function withdrawJunior(uint256 assets) external returns (uint256 shares);

    /// @notice Withdraws assets from the caller's JuniorPool shares to a receiver.
    /// @dev Caller must approve this coordinator to spend the required junior shares.
    /// @param assets Amount of underlying asset to withdraw.
    /// @param receiver Address receiving the withdrawn assets.
    /// @return shares Amount of junior shares burned.
    function withdrawJuniorTo(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Previews how many senior shares must be approved before withdrawing assets.
    /// @param assets Amount of underlying asset to withdraw.
    /// @return shares Required senior shares.
    function previewSeniorWithdrawShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Previews how many junior shares must be approved before withdrawing assets.
    /// @param assets Amount of underlying asset to withdraw.
    /// @return shares Required junior shares.
    function previewJuniorWithdrawShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Returns available liquidity in the senior tranche.
    /// @return Available senior liquidity not locked in active financings.
    function seniorAvailableLiquidity() external view returns (uint256);

    /// @notice Returns available liquidity in the junior tranche.
    /// @return Available junior liquidity not locked in active financings.
    function juniorAvailableLiquidity() external view returns (uint256);

    /// @notice Returns aggregate available liquidity across both tranches.
    /// @dev Informational only. Funding execution must still check each tranche independently.
    /// @return Aggregate available liquidity.
    function totalAvailableLiquidity() external view returns (uint256);

    /// @notice Returns aggregate accounted NAV across SeniorPool and JuniorPool.
    /// @return Aggregate pool-accounted assets.
    function totalPoolAssets() external view returns (uint256);

    /// @notice Returns aggregate principal locked in active invoice financing positions.
    /// @return Total locked principal across both tranches.
    function totalLockedAssets() external view returns (uint256);

    /// @notice Returns cumulative realized protocol credit losses.
    /// @dev This value must not decrease during normal protocol operation.
    /// @return Cumulative bad debt recognized by the protocol.
    function totalBadDebt() external view returns (uint256);

    /// @notice Returns the financing position recorded for an invoice.
    /// @param invoiceId Invoice identifier.
    /// @return supplier Original invoice creditor receiving financing liquidity.
    /// @return buyer Off-chain payment obligor associated with the invoice.
    /// @return principal Total financed principal advanced to the supplier.
    /// @return seniorPrincipal Principal funded by the senior tranche.
    /// @return juniorPrincipal Principal funded by the junior tranche.
    /// @return fundedAt Timestamp recorded by the pool when the financing position was created.
    /// @return dueDate Invoice maturity timestamp.
    function financingPositions(uint256 invoiceId)
        external
        view
        returns (
            address supplier,
            address buyer,
            uint256 principal,
            uint256 seniorPrincipal,
            uint256 juniorPrincipal,
            uint256 fundedAt,
            uint256 dueDate
        );
}

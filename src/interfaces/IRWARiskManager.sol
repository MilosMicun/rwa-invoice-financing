// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRWARiskManager
/// @notice Interface for invoice eligibility, concentration limits, advance calculation, and fee calculation.
/// @dev
/// The risk manager is a read/permissioned risk boundary used by InvoiceFinancingPool.
/// It must not move funds, mutate invoice lifecycle state, or execute settlement/default accounting.
interface IRWARiskManager {
    /// @notice Global underwriting parameters used for invoice financing eligibility.
    /// @dev
    /// All monetary values are expressed in the underlying asset's smallest unit.
    /// `advanceRate` and `financingFeeApr` are expressed in basis points.
    /// `maxInvoiceTenor` is expressed in seconds.
    struct RiskParams {
        /// @notice Maximum active financed principal exposure allowed per buyer.
        uint256 maxExposurePerBuyer;
        /// @notice Percentage of invoice face value advanced to the supplier, in basis points.
        uint256 advanceRate;
        /// @notice Maximum allowed invoice tenor from financing time to due date, in seconds.
        uint256 maxInvoiceTenor;
        /// @notice Minimum invoice face value required for financing eligibility.
        uint256 minInvoiceAmount;
        /// @notice Annualized financing fee rate, in basis points.
        uint256 financingFeeApr;
    }

    /// @notice Emitted when global risk parameters are updated.
    event RiskParamsUpdated(
        uint256 maxExposurePerBuyer,
        uint256 advanceRate,
        uint256 maxInvoiceTenor,
        uint256 minInvoiceAmount,
        uint256 financingFeeApr
    );

    /// @notice Emitted when a buyer is added to or removed from the denylist.
    event BuyerDenylistUpdated(address indexed buyer, bool denied);

    /// @notice Emitted when active buyer exposure changes.
    event BuyerExposureUpdated(address indexed buyer, uint256 oldExposure, uint256 newExposure);

    /// @notice Returns the current global risk parameter configuration.
    function riskParams()
        external
        view
        returns (
            uint256 maxExposurePerBuyer,
            uint256 advanceRate,
            uint256 maxInvoiceTenor,
            uint256 minInvoiceAmount,
            uint256 financingFeeApr
        );

    /// @notice Returns whether a buyer is currently denied from new invoice financing.
    /// @param buyer Buyer address to check.
    function isBuyerDenied(address buyer) external view returns (bool);

    /// @notice Returns whether an invoice is currently eligible for financing.
    /// @dev
    /// Implementations should treat this as a boolean risk query.
    /// A non-existent invoice should return false rather than bubbling up a registry revert.
    /// @param invoiceId Invoice identifier in the InvoiceNFT registry.
    function isEligible(uint256 invoiceId) external view returns (bool);

    /// @notice Returns active financed principal exposure for a buyer.
    /// @dev Exposure is active principal exposure, not lifetime volume and not invoice face value.
    /// @param buyer Buyer address whose active exposure is queried.
    function getBuyerExposure(address buyer) external view returns (uint256);

    /// @notice Checks whether adding a new financing amount would remain within buyer concentration limits.
    /// @param buyer Buyer address whose concentration limit is checked.
    /// @param newAmount New financed principal amount to test.
    function checkConcentration(address buyer, uint256 newAmount) external view returns (bool);

    /// @notice Calculates the financed principal advanced against an invoice face value.
    /// @param faceValue Nominal invoice amount.
    /// @return advance Financed principal amount advanced to the supplier.
    function calculateAdvance(uint256 faceValue) external view returns (uint256 advance);

    /// @notice Calculates the financing fee for a funded invoice position.
    /// @dev Uses simple linear APR over the full tenor from fundedAt to dueDate.
    /// @param principal Financed principal amount.
    /// @param fundedAt Timestamp when the invoice was funded.
    /// @param dueDate Invoice maturity timestamp.
    /// @return fee Financing fee owed at settlement.
    function calculateFee(uint256 principal, uint256 fundedAt, uint256 dueDate) external view returns (uint256 fee);

    /// @notice Updates active buyer exposure after financing, settlement, or default resolution.
    /// @dev Intended to be callable only by InvoiceFinancingPool in the implementation.
    /// @param buyer Buyer whose exposure is updated.
    /// @param delta Amount by which exposure changes.
    /// @param increase True to increase exposure, false to decrease exposure.
    function updateBuyerExposure(address buyer, uint256 delta, bool increase) external;

    /// @notice Updates global risk parameters.
    /// @dev Intended to be callable only by the risk admin role in the implementation.
    /// @param newRiskParams New underwriting configuration.
    function setRiskParams(RiskParams calldata newRiskParams) external;

    /// @notice Adds or removes a buyer from the denylist.
    /// @dev Denylisting blocks new financing but does not mutate already funded invoice accounting.
    /// @param buyer Buyer address to update.
    /// @param denied True to deny new financing, false to allow eligibility checks again.
    function setBuyerDenied(address buyer, bool denied) external;
}

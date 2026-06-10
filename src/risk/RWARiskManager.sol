// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IInvoiceNFT} from "../interfaces/IInvoiceNFT.sol";
import {IRWARiskManager} from "../interfaces/IRWARiskManager.sol";

/// @title RWARiskManager
/// @notice Risk and eligibility module for RWA invoice financing.
/// @dev
/// RWARiskManager is an underwriting boundary, not an accounting or execution contract.
///
/// It does not:
/// - move funds
/// - mutate invoice lifecycle state
/// - lock or unlock liquidity
/// - execute settlement/default waterfalls
///
/// It does:
/// - evaluate invoice eligibility
/// - calculate advance principal
/// - calculate financing fees
/// - enforce buyer concentration limits
/// - track active buyer exposure
/// - maintain buyer denylist controls
contract RWARiskManager is AccessControl, IRWARiskManager {
    /// @notice Role allowed to configure underwriting parameters and buyer denylist status.
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");

    /// @notice Role allowed to update active buyer exposure after pool accounting execution.
    bytes32 public constant POOL_ROLE = keccak256("POOL_ROLE");

    /// @notice Basis point denominator used for percentage calculations.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum advance rate allowed in v1, expressed in basis points.
    /// @dev 9,000 bps = 90%. This enforces a minimum haircut against invoice face value.
    uint256 public constant MAX_ADVANCE_RATE_BPS = 9_000;

    /// @notice Maximum financing fee APR allowed in v1, expressed in basis points.
    /// @dev 5,000 bps = 50% APR. This is a bounded governance guardrail.
    uint256 public constant MAX_FINANCING_FEE_APR_BPS = 5_000;

    error ZeroAddress();
    error InvalidRiskParams();
    error AdvanceRateTooHigh();
    error FinancingFeeAprTooHigh();
    error ExposureUnderflow();

    /// @notice Canonical invoice lifecycle registry used for eligibility checks.
    /// @dev RiskManager reads invoice data from InvoiceNFT but never mutates invoice state.
    IInvoiceNFT public immutable INVOICE_NFT;

    /// @notice Current global underwriting configuration.
    RiskParams public riskParams;

    /// @notice Buyer denylist used to block new financing against risky or disputed buyers.
    /// @dev Denylisting does not affect already funded invoices.
    mapping(address buyer => bool denied) public isBuyerDenied;

    /// @dev Active financed principal exposure per buyer.
    /// Exposure is reduced only after settlement/default accounting is executed by the pool.
    mapping(address buyer => uint256 exposure) private buyerExposure;

    /// @notice Initializes the risk manager.
    /// @dev
    /// The deployer-provided admin receives DEFAULT_ADMIN_ROLE and RISK_ADMIN_ROLE.
    /// POOL_ROLE is intentionally not granted in the constructor because InvoiceFinancingPool
    /// may be deployed later and granted explicitly by the admin.
    ///
    /// @param admin Address that receives default admin and risk admin authority.
    /// @param invoiceNft_ InvoiceNFT registry used as the lifecycle source of truth.
    /// @param initialRiskParams Initial underwriting configuration.
    constructor(address admin, IInvoiceNFT invoiceNft_, RiskParams memory initialRiskParams) {
        if (admin == address(0) || address(invoiceNft_) == address(0)) {
            revert ZeroAddress();
        }

        INVOICE_NFT = invoiceNft_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN_ROLE, admin);

        _setRiskParams(initialRiskParams);
    }

    /// @notice Returns whether an invoice is currently eligible for financing.
    /// @dev
    /// This function is intentionally a boolean risk query.
    /// If the invoice does not exist, InvoiceNFT.getInvoice() reverts and this function returns false.
    ///
    /// Eligibility requires:
    /// - invoice exists
    /// - invoice status is VERIFIED
    /// - buyer is not denylisted
    /// - face value is at least minInvoiceAmount
    /// - due date is in the future
    /// - remaining tenor is within maxInvoiceTenor
    /// - calculated advance is non-zero
    ///
    /// @param invoiceId Invoice identifier in the InvoiceNFT registry.
    /// @return eligible True if the invoice passes all v1 eligibility checks.
    function isEligible(uint256 invoiceId) external view returns (bool eligible) {
        try INVOICE_NFT.getInvoice(invoiceId) returns (IInvoiceNFT.Invoice memory invoice) {
            if (invoice.status != IInvoiceNFT.InvoiceStatus.VERIFIED) {
                return false;
            }

            if (isBuyerDenied[invoice.buyer]) {
                return false;
            }

            if (invoice.faceValue < riskParams.minInvoiceAmount) {
                return false;
            }

            if (invoice.dueDate <= block.timestamp) {
                return false;
            }

            uint256 tenor = invoice.dueDate - block.timestamp;

            if (tenor > riskParams.maxInvoiceTenor) {
                return false;
            }

            uint256 advance = calculateAdvance(invoice.faceValue);

            if (advance == 0) {
                return false;
            }

            return true;
        } catch {
            return false;
        }
    }

    /// @notice Returns active financed principal exposure for a buyer.
    /// @dev
    /// Exposure represents currently active financed principal.
    /// It is not lifetime volume and does not use invoice face value.
    /// @param buyer Buyer address whose active exposure is queried.
    /// @return exposure Active financed principal exposure.
    function getBuyerExposure(address buyer) external view returns (uint256 exposure) {
        return buyerExposure[buyer];
    }

    /// @notice Checks whether adding new financed principal would stay within buyer concentration limits.
    /// @dev
    /// This function is public so it can be reused internally by isEligible().
    /// @param buyer Buyer address whose concentration limit is checked.
    /// @param newAmount New financed principal amount to test.
    /// @return allowed True if buyerExposure[buyer] + newAmount does not exceed maxExposurePerBuyer.
    function checkConcentration(address buyer, uint256 newAmount) public view returns (bool allowed) {
        return buyerExposure[buyer] + newAmount <= riskParams.maxExposurePerBuyer;
    }

    /// @notice Calculates the financed principal advanced against invoice face value.
    /// @dev
    /// The advance is calculated from the configured advanceRate in basis points.
    /// The resulting amount is the principal that InvoiceFinancingPool will lock and send to the supplier.
    /// @param faceValue Nominal invoice amount.
    /// @return advance Financed principal amount.
    function calculateAdvance(uint256 faceValue) public view returns (uint256 advance) {
        return faceValue * riskParams.advanceRate / BPS_DENOMINATOR;
    }

    /// @notice Calculates the financing fee for a funded invoice.
    /// @dev
    /// Uses simple linear APR:
    /// fee = principal * financingFeeApr * (dueDate - fundedAt) / (365 days * 10_000)
    ///
    /// Early repayment does not reduce the fee in v1. The fee is based on full invoice tenor.
    /// Returns zero for zero principal or invalid/non-positive duration.
    ///
    /// @param principal Financed principal amount.
    /// @param fundedAt Timestamp when the invoice was funded.
    /// @param dueDate Invoice maturity timestamp.
    /// @return fee Financing fee amount.
    function calculateFee(uint256 principal, uint256 fundedAt, uint256 dueDate) public view returns (uint256 fee) {
        if (principal == 0 || dueDate <= fundedAt) {
            return 0;
        }

        uint256 duration = dueDate - fundedAt;

        return principal * riskParams.financingFeeApr * duration / (365 days * BPS_DENOMINATOR);
    }

    /// @notice Updates global risk parameters.
    /// @dev Callable only by RISK_ADMIN_ROLE.
    /// @param newRiskParams New underwriting configuration.
    function setRiskParams(RiskParams calldata newRiskParams) external onlyRole(RISK_ADMIN_ROLE) {
        _setRiskParams(newRiskParams);
    }

    /// @notice Adds or removes a buyer from the denylist.
    /// @dev
    /// Denylisting blocks new financing eligibility for invoices associated with the buyer.
    /// It does not mutate already funded invoice state, buyer exposure, locked liquidity, or pool accounting.
    /// @param buyer Buyer address to update.
    /// @param denied True to block new financing, false to remove the denylist restriction.
    function setBuyerDenied(address buyer, bool denied) external onlyRole(RISK_ADMIN_ROLE) {
        if (buyer == address(0)) {
            revert ZeroAddress();
        }

        isBuyerDenied[buyer] = denied;

        emit BuyerDenylistUpdated(buyer, denied);
    }

    /// @notice Updates active buyer exposure after financing, settlement, or default accounting.
    /// @dev
    /// Callable only by POOL_ROLE.
    ///
    /// Intended calling convention:
    /// - financeInvoice(): increase = true, delta = financed principal
    /// - settleInvoice(): increase = false, delta = financed principal
    /// - defaultInvoice(): increase = false, delta = financed principal
    ///
    /// This function does not check concentration limits when increasing exposure.
    /// Concentration must be checked before funding through isEligible() / checkConcentration().
    /// Concentration must be checked atomically within the same transaction as financing execution.
    /// A prior isEligible() call in a separate transaction does not guarantee concentration still holds at execution time.
    ///
    /// @param buyer Buyer whose exposure is updated.
    /// @param delta Amount by which exposure changes.
    /// @param increase True to increase exposure, false to decrease exposure.
    function updateBuyerExposure(address buyer, uint256 delta, bool increase) external onlyRole(POOL_ROLE) {
        if (buyer == address(0)) {
            revert ZeroAddress();
        }

        uint256 oldExposure = buyerExposure[buyer];
        uint256 newExposure;

        if (increase) {
            newExposure = oldExposure + delta;
        } else {
            if (delta > oldExposure) {
                revert ExposureUnderflow();
            }

            newExposure = oldExposure - delta;
        }

        buyerExposure[buyer] = newExposure;

        emit BuyerExposureUpdated(buyer, oldExposure, newExposure);
    }

    /// @dev Validates and stores global underwriting parameters.
    /// @param newRiskParams New risk parameter configuration.
    function _setRiskParams(RiskParams memory newRiskParams) internal {
        if (
            newRiskParams.maxExposurePerBuyer == 0 || newRiskParams.advanceRate == 0
                || newRiskParams.maxInvoiceTenor == 0 || newRiskParams.minInvoiceAmount == 0
        ) {
            revert InvalidRiskParams();
        }

        if (newRiskParams.advanceRate > MAX_ADVANCE_RATE_BPS) {
            revert AdvanceRateTooHigh();
        }

        if (newRiskParams.financingFeeApr > MAX_FINANCING_FEE_APR_BPS) {
            revert FinancingFeeAprTooHigh();
        }

        riskParams = newRiskParams;

        emit RiskParamsUpdated(
            newRiskParams.maxExposurePerBuyer,
            newRiskParams.advanceRate,
            newRiskParams.maxInvoiceTenor,
            newRiskParams.minInvoiceAmount,
            newRiskParams.financingFeeApr
        );
    }
}

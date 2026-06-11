// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IInvoiceNFT} from "../interfaces/IInvoiceNFT.sol";
import {IInvoiceFinancingPool} from "../interfaces/IInvoiceFinancingPool.sol";
import {IInvoiceStatusOracle} from "../interfaces/IInvoiceStatusOracle.sol";

/// @title InvoiceStatusOracle
/// @notice Permissioned oracle adapter for finalizing off-chain invoice outcomes.
/// @dev
/// This contract reports off-chain truth into the protocol through a simple
/// submitter + dispute window pattern.
///
/// It does not execute settlement/default accounting.
/// It does not mutate InvoiceNFT directly.
/// It finalizes a terminal status together with any recovered principal
/// and forwards that outcome to InvoiceFinancingPool.onStatusFinalized().
///
/// In v1, the deployer admin receives submitter and dispute roles for operational simplicity.
/// Production deployments should separate these roles, preferably through a multisig or
/// independent submitter/dispute process.
contract InvoiceStatusOracle is AccessControl, IInvoiceStatusOracle {
    bytes32 public constant ORACLE_SUBMITTER_ROLE = keccak256("ORACLE_SUBMITTER_ROLE");
    bytes32 public constant DISPUTE_ADMIN_ROLE = keccak256("DISPUTE_ADMIN_ROLE");

    IInvoiceNFT public immutable INVOICE_NFT;
    IInvoiceFinancingPool public immutable POOL;

    uint256 private immutable DISPUTE_WINDOW;
    uint256 private immutable MAX_STALENESS;

    mapping(uint256 invoiceId => StatusUpdate update) private statusUpdates;

    constructor(
        address admin,
        IInvoiceNFT invoiceNft_,
        IInvoiceFinancingPool pool_,
        uint256 disputeWindow_,
        uint256 maxStaleness_
    ) {
        if (admin == address(0) || address(invoiceNft_) == address(0) || address(pool_) == address(0)) {
            revert ZeroAddress();
        }

        if (disputeWindow_ == 0) {
            revert InvalidDisputeWindow();
        }

        if (maxStaleness_ <= disputeWindow_) {
            revert InvalidMaxStaleness();
        }

        INVOICE_NFT = invoiceNft_;
        POOL = pool_;
        DISPUTE_WINDOW = disputeWindow_;
        MAX_STALENESS = maxStaleness_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_SUBMITTER_ROLE, admin);
        _grantRole(DISPUTE_ADMIN_ROLE, admin);
    }

    /// @notice Returns the current status update for an invoice.
    /// @param invoiceId Invoice identifier.
    /// @return update Stored oracle status update.
    function getStatusUpdate(uint256 invoiceId) external view returns (StatusUpdate memory update) {
        return statusUpdates[invoiceId];
    }

    /// @notice Returns the dispute window duration.
    /// @return window Duration during which a submitted status can be disputed.
    function disputeWindow() external view returns (uint256 window) {
        return DISPUTE_WINDOW;
    }

    /// @notice Returns the maximum age after which a submitted update becomes stale.
    /// @return staleness Maximum allowed age of a submitted status update.
    function maxStaleness() external view returns (uint256 staleness) {
        return MAX_STALENESS;
    }

    /// @notice Submits an off-chain terminal outcome for a funded invoice.
    /// @dev
    /// Callable only by ORACLE_SUBMITTER_ROLE.
    ///
    /// The submitted outcome is not immediately actionable. It must pass the dispute
    /// window and be finalized before the pool can consume it during settlement/default
    /// resolution.
    ///
    /// SETTLED outcomes must use a zero recovered amount because paid-path cash flow
    /// is supplied and validated separately during settleInvoice().
    ///
    /// DEFAULTED outcomes may report zero or non-zero recovered principal. The pool
    /// validates the reported amount against the stored financed principal during
    /// finalization.
    ///
    /// Resubmission is allowed only when the previous update was disputed or stale.
    /// Active non-disputed updates cannot be overwritten, and finalized updates are immutable.
    ///
    /// @param invoiceId Invoice identifier.
    /// @param newStatus Proposed terminal outcome: SETTLED or DEFAULTED.
    /// @param recoveredAmount Recovered principal reported for a DEFAULTED outcome.
    function submitStatus(uint256 invoiceId, IInvoiceNFT.InvoiceStatus newStatus, uint256 recoveredAmount)
        external
        onlyRole(ORACLE_SUBMITTER_ROLE)
    {
        if (!_isAllowedOracleStatus(newStatus)) {
            revert InvalidOracleStatus(newStatus);
        }

        if (newStatus == IInvoiceNFT.InvoiceStatus.SETTLED && recoveredAmount != 0) {
            revert InvalidRecoveryForStatus(newStatus, recoveredAmount);
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            revert InvoiceNotFunded(invoiceId, invoice.status);
        }

        StatusUpdate memory existingUpdate = statusUpdates[invoiceId];

        if (existingUpdate.finalized) {
            revert StatusUpdateAlreadyFinalized(invoiceId);
        }

        bool activeUpdate = existingUpdate.submittedAt != 0 && !existingUpdate.disputed
            && block.timestamp <= existingUpdate.submittedAt + MAX_STALENESS;

        if (activeUpdate) {
            revert StatusUpdateAlreadyActive(invoiceId);
        }

        statusUpdates[invoiceId] = StatusUpdate({
            invoiceId: invoiceId,
            newStatus: newStatus,
            recoveredAmount: recoveredAmount,
            submittedAt: block.timestamp,
            disputed: false,
            finalized: false
        });

        emit StatusSubmitted(invoiceId, newStatus, msg.sender, recoveredAmount, block.timestamp);
    }

    /// @notice Disputes a submitted status update during the dispute window.
    /// @dev
    /// Callable only by DISPUTE_ADMIN_ROLE.
    /// A disputed update cannot be finalized, but a new outcome can be submitted later.
    /// The replacement update may use a different status and recovered amount.
    /// @param invoiceId Invoice identifier.
    function disputeStatus(uint256 invoiceId) external onlyRole(DISPUTE_ADMIN_ROLE) {
        StatusUpdate storage update = statusUpdates[invoiceId];

        if (update.submittedAt == 0) {
            revert StatusUpdateDoesNotExist(invoiceId);
        }

        if (update.finalized) {
            revert StatusUpdateAlreadyFinalized(invoiceId);
        }

        if (update.disputed) {
            revert StatusUpdateDisputed(invoiceId);
        }

        if (block.timestamp > update.submittedAt + DISPUTE_WINDOW) {
            revert DisputeWindowElapsed(invoiceId);
        }

        update.disputed = true;

        emit StatusDisputed(invoiceId, update.newStatus, msg.sender);
    }

    /// @notice Finalizes a submitted status update after the dispute window has elapsed.
    /// @dev
    /// Callable by anyone once timing and dispute checks pass.
    ///
    /// Finalization propagates the complete oracle-attested outcome to the pool:
    /// terminal status plus recovered principal.
    ///
    /// It does not execute settlement/default accounting and does not mutate InvoiceNFT
    /// directly. InvoiceFinancingPool validates that a financing position exists and
    /// that default recovery does not exceed its stored principal.
    ///
    /// If an invoice becomes FROZEN after submission, this function may still finalize
    /// the oracle outcome because it does not execute waterfall accounting or mutate
    /// InvoiceNFT. Settlement/default execution must separately reject FROZEN invoices.
    ///
    /// If the pool callback reverts, the entire finalization transaction reverts,
    /// including the local `finalized` state update.
    ///
    /// @param invoiceId Invoice identifier.
    function finalize(uint256 invoiceId) external {
        StatusUpdate storage update = statusUpdates[invoiceId];

        if (update.submittedAt == 0) {
            revert StatusUpdateDoesNotExist(invoiceId);
        }

        if (update.disputed) {
            revert StatusUpdateDisputed(invoiceId);
        }

        if (update.finalized) {
            revert StatusUpdateAlreadyFinalized(invoiceId);
        }

        uint256 earliestFinalizeAt = update.submittedAt + DISPUTE_WINDOW;

        if (block.timestamp < earliestFinalizeAt) {
            revert DisputeWindowNotElapsed(invoiceId, earliestFinalizeAt);
        }

        uint256 staleAfter = update.submittedAt + MAX_STALENESS;

        if (block.timestamp > staleAfter) {
            revert StatusUpdateStale(invoiceId, staleAfter);
        }

        if (!_isAllowedOracleStatus(update.newStatus)) {
            revert InvalidOracleStatus(update.newStatus);
        }

        update.finalized = true;

        POOL.onStatusFinalized(invoiceId, update.newStatus, update.recoveredAmount);

        emit StatusFinalized(invoiceId, update.newStatus, msg.sender, update.recoveredAmount, block.timestamp);
    }

    /// @dev Returns true only for terminal off-chain outcome statuses accepted by this oracle.
    function _isAllowedOracleStatus(IInvoiceNFT.InvoiceStatus status) internal pure returns (bool) {
        return status == IInvoiceNFT.InvoiceStatus.SETTLED || status == IInvoiceNFT.InvoiceStatus.DEFAULTED;
    }
}


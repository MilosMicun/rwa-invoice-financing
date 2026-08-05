// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {InvoiceFinancingPool} from "../../../src/core/InvoiceFinancingPool.sol";
import {InvoiceNFT} from "../../../src/core/InvoiceNFT.sol";
import {InvoiceStatusOracle} from "../../../src/oracle/InvoiceStatusOracle.sol";
import {RWARiskManager} from "../../../src/risk/RWARiskManager.sol";
import {SeniorPool} from "../../../src/pools/SeniorPool.sol";
import {JuniorPool} from "../../../src/pools/JuniorPool.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceStatusOracle} from "../../../src/interfaces/IInvoiceStatusOracle.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title InvoiceFinancingPoolHandler
/// @notice Stateful fuzzing handler for the RWA Invoice Financing protocol.
/// @dev
/// Phase 1 focuses on creating valid financed positions.
/// Oracle, resolution, freeze, and LP actions are added incrementally.
contract InvoiceFinancingPoolHandler is Test {
    struct Actors {
        address admin;
        address originator;
        address verifier;
        address riskAdmin;
        address supplier;
        address buyer;
        address resolver;
    }

    struct AccountingSnapshot {
        uint256 totalLockedAssets;
        uint256 seniorLockedAssets;
        uint256 juniorLockedAssets;
        uint256 totalBadDebt;
        uint256 buyerExposure;
        uint256 seniorTotalAssets;
        uint256 juniorTotalAssets;
    }

    MockERC20 public immutable ASSET;
    InvoiceNFT public immutable INVOICE_NFT;
    RWARiskManager public immutable RISK_MANAGER;
    InvoiceFinancingPool public immutable POOL;
    InvoiceStatusOracle public immutable ORACLE;
    SeniorPool public immutable SENIOR_POOL;
    JuniorPool public immutable JUNIOR_POOL;

    address public immutable ADMIN;
    address public immutable ORIGINATOR;
    address public immutable VERIFIER;
    address public immutable RISK_ADMIN;
    address public immutable SUPPLIER;
    address public immutable BUYER;
    address public immutable RESOLVER;

    /// @dev Test-domain bound only. This is not a protocol limit.
    uint256 internal constant MAX_HANDLER_FACE_VALUE = 100_000e18;

    /// @dev Test-domain bound for optional settlement surplus.
    ///
    /// This is not a protocol limit.
    /// It allows the invariant fuzzer to exercise both exact repayment and
    /// repayment-above-expected paths without generating unrealistic balances.
    uint256 internal constant MAX_HANDLER_SETTLEMENT_SURPLUS = 10_000e18;

    /// @notice Number of successful settled-outcome submissions.
    uint256 public callsSubmitSettledOutcome;

    /// @notice Number of successful defaulted-outcome submissions.
    uint256 public callsSubmitDefaultedOutcome;

    /// @dev Successfully financed invoice identifiers tracked by the handler.
    uint256[] internal financedInvoiceIds;

    /// @notice Number of successful create-and-finance handler calls.
    uint256 public callsCreateAndFinance;

    /// @notice Number of successfully finalized oracle outcomes.
    uint256 public callsFinalizeOutcome;

    /// @notice Number of successful settlement executions.
    uint256 public callsSettleInvoice;

    /// @notice Number of successful default resolutions.
    uint256 public callsResolveDefault;

    /// @notice Number of successful invoice freeze actions.
    uint256 public callsFreezeInvoice;

    /// @notice Number of successful invoice unfreeze actions.
    uint256 public callsUnfreezeInvoice;

    constructor(InvoiceFinancingPool pool_, InvoiceStatusOracle oracle_, Actors memory actors_) {
        POOL = pool_;
        ORACLE = oracle_;

        ASSET = MockERC20(address(pool_.ASSET()));
        INVOICE_NFT = InvoiceNFT(address(pool_.INVOICE_NFT()));
        RISK_MANAGER = RWARiskManager(address(pool_.RISK_MANAGER()));

        SENIOR_POOL = pool_.SENIOR_POOL();
        JUNIOR_POOL = pool_.JUNIOR_POOL();

        ADMIN = actors_.admin;
        ORIGINATOR = actors_.originator;
        VERIFIER = actors_.verifier;
        RISK_ADMIN = actors_.riskAdmin;
        SUPPLIER = actors_.supplier;
        BUYER = actors_.buyer;
        RESOLVER = actors_.resolver;
    }

    /// @notice Returns number of successfully financed invoices.
    function financedInvoiceCount() external view returns (uint256 count) {
        return financedInvoiceIds.length;
    }

    /// @notice Returns a financed invoice identifier by registry index.
    function financedInvoiceIdAt(uint256 index) external view returns (uint256 invoiceId) {
        return financedInvoiceIds[index];
    }

    /// @notice Creates, verifies, and finances a valid invoice.
    /// @dev
    /// Preconditions are checked before invoice creation so the handler does not
    /// accumulate unusable VERIFIED invoices.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function createAndFinanceInvoice(uint256 faceValueSeed, uint256 tenorSeed) external {
        (,, uint256 maxInvoiceTenor, uint256 minInvoiceAmount,) = RISK_MANAGER.riskParams();

        if (minInvoiceAmount > MAX_HANDLER_FACE_VALUE) {
            return;
        }

        if (RISK_MANAGER.isBuyerDenied(BUYER)) {
            return;
        }

        uint256 faceValue = bound(faceValueSeed, minInvoiceAmount, MAX_HANDLER_FACE_VALUE);

        uint256 tenor = bound(tenorSeed, 1, maxInvoiceTenor);

        uint256 principal = RISK_MANAGER.calculateAdvance(faceValue);

        if (principal == 0) {
            return;
        }

        if (!RISK_MANAGER.checkConcentration(BUYER, principal)) {
            return;
        }

        uint256 seniorPrincipal = principal * POOL.SENIOR_FUNDING_SHARE_BPS() / POOL.BPS_DENOMINATOR();

        uint256 juniorPrincipal = principal - seniorPrincipal;

        if (SENIOR_POOL.availableLiquidity() < seniorPrincipal) {
            return;
        }

        if (JUNIOR_POOL.availableLiquidity() < juniorPrincipal) {
            return;
        }

        uint256 dueDate = block.timestamp + tenor;

        vm.prank(ORIGINATOR);
        uint256 invoiceId = INVOICE_NFT.createInvoice(SUPPLIER, BUYER, faceValue, dueDate);

        vm.prank(VERIFIER);
        INVOICE_NFT.verify(invoiceId);

        vm.prank(SUPPLIER);
        POOL.financeInvoice(invoiceId);

        financedInvoiceIds.push(invoiceId);

        callsCreateAndFinance++;
    }

    /// @notice Submits a SETTLED oracle outcome for an eligible financed invoice.
    /// @dev
    /// Submission and finalization are intentionally separate handler actions.
    ///
    /// This allows invariant runs to explore intermediate states where:
    /// - the invoice remains FUNDED;
    /// - the oracle update exists but is not finalized;
    /// - accounting has not yet executed.
    ///
    /// SETTLED outcomes always use zero recovered principal.
    function submitSettledOutcome(uint256 invoiceSeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        if (!_canSubmitOracleUpdate(invoiceId)) {
            return;
        }

        vm.prank(ADMIN);
        ORACLE.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        callsSubmitSettledOutcome++;
    }

    /// @notice Submits a DEFAULTED oracle outcome for an eligible financed invoice.
    /// @dev
    /// The recovery amount is derived from the immutable principal stored in the
    /// financing position and is always bounded to:
    ///
    ///     0 <= recoveredAmount <= principal
    ///
    /// Submission and finalization remain separate actions so invariant runs can
    /// explore disputed, stale, replaced, and finalized oracle states.
    ///
    /// @param invoiceSeed Fuzzer-provided seed used to select a financed invoice.
    /// @param recoverySeed Fuzzer-provided seed used to derive recovered principal.
    function submitDefaultedOutcome(uint256 invoiceSeed, uint256 recoverySeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        if (!_canSubmitOracleUpdate(invoiceId)) {
            return;
        }

        uint256 principal = _getPositionPrincipal(invoiceId);

        uint256 recoveredAmount = bound(recoverySeed, 0, principal);

        vm.prank(ADMIN);
        ORACLE.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, recoveredAmount);

        callsSubmitDefaultedOutcome++;
    }

    /// @notice Finalizes an eligible oracle update for a financed invoice.
    /// @dev
    /// Finalization is permissionless, so the handler contract itself acts as
    /// the finalizer.
    ///
    /// If the dispute window has not yet elapsed, the handler advances time to
    /// the exact earliest valid finalization boundary.
    ///
    /// The action returns without reverting when:
    /// - no financed invoice exists;
    /// - no oracle update exists;
    /// - the update is disputed;
    /// - the update is already finalized;
    /// - the update is stale.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function finalizeOutcome(uint256 invoiceSeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        IInvoiceStatusOracle.StatusUpdate memory update = ORACLE.getStatusUpdate(invoiceId);

        if (update.submittedAt == 0) {
            return;
        }

        if (update.disputed || update.finalized) {
            return;
        }

        uint256 staleAfter = update.submittedAt + ORACLE.maxStaleness();

        if (block.timestamp > staleAfter) {
            return;
        }

        uint256 earliestFinalizeAt = update.submittedAt + ORACLE.disputeWindow();

        if (block.timestamp < earliestFinalizeAt) {
            vm.warp(earliestFinalizeAt);
        }

        ORACLE.finalize(invoiceId);

        callsFinalizeOutcome++;
    }

    /// @notice Executes paid-path settlement for a finalized SETTLED invoice.
    /// @dev
    /// The handler contract acts as the permissionless settlement payer.
    ///
    /// The action uses the immutable principal and financing fee stored when the
    /// invoice was funded. It mints exactly the required repayment plus an optional
    /// bounded surplus, approves the coordinator, and executes settlement.
    ///
    /// The action returns without reverting when:
    /// - no financed invoice exists;
    /// - the position is already resolved;
    /// - the pool has not finalized SETTLED;
    /// - the InvoiceNFT lifecycle is not currently FUNDED.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function settleInvoice(uint256 invoiceSeed, uint256 surplusSeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        (uint256 principal, uint256 financingFee, bool resolved) = _getPositionSettlementTerms(invoiceId);

        if (resolved) {
            return;
        }

        if (POOL.finalizedOracleStatus(invoiceId) != IInvoiceNFT.InvoiceStatus.SETTLED) {
            return;
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return;
        }

        uint256 expectedRepayment = principal + financingFee;

        uint256 surplus = bound(surplusSeed, 0, MAX_HANDLER_SETTLEMENT_SURPLUS);

        uint256 paidAmount = expectedRepayment + surplus;

        ASSET.mint(address(this), paidAmount);

        ASSET.approve(address(POOL), paidAmount);

        POOL.settleInvoice(invoiceId, paidAmount);

        callsSettleInvoice++;
    }

    /// @notice Executes default accounting for a finalized DEFAULTED invoice.
    /// @dev
    /// The handler contract acts as the permissionless default executor.
    ///
    /// The executor does not choose recovery.
    /// It reads the recovery amount already finalized by the oracle,
    /// mints exactly that amount, approves the coordinator, and calls
    /// the production default-resolution path.
    ///
    /// The action returns without reverting when:
    /// - no financed invoice exists;
    /// - the position is already resolved;
    /// - the pool has not finalized DEFAULTED;
    /// - the InvoiceNFT lifecycle is not currently FUNDED.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function resolveDefault(uint256 invoiceSeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        (,, bool resolved) = _getPositionSettlementTerms(invoiceId);

        if (resolved) {
            return;
        }

        if (POOL.finalizedOracleStatus(invoiceId) != IInvoiceNFT.InvoiceStatus.DEFAULTED) {
            return;
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return;
        }

        uint256 recoveredAmount = POOL.finalizedRecoveryAmount(invoiceId);

        if (recoveredAmount > 0) {
            ASSET.mint(address(this), recoveredAmount);
            ASSET.approve(address(POOL), recoveredAmount);
        }

        POOL.resolveDefault(invoiceId);

        callsResolveDefault++;
    }

    /// @notice Freezes an active financed invoice.
    /// @dev
    /// Only invoices currently in FUNDED state are eligible.
    ///
    /// Freeze is an operational/legal overlay and must not mutate:
    /// - aggregate locked assets;
    /// - tranche locked assets;
    /// - tranche NAV;
    /// - buyer exposure;
    /// - cumulative bad debt.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function freezeInvoice(uint256 invoiceSeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return;
        }

        AccountingSnapshot memory beforeSnapshot = _snapshotAccounting();

        vm.prank(RISK_ADMIN);
        INVOICE_NFT.freezeInvoice(invoiceId);

        IInvoiceNFT.Invoice memory frozenInvoice = INVOICE_NFT.getInvoice(invoiceId);

        assertEq(uint256(frozenInvoice.status), uint256(IInvoiceNFT.InvoiceStatus.FROZEN));

        assertEq(uint256(frozenInvoice.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));

        _assertAccountingUnchanged(beforeSnapshot);

        callsFreezeInvoice++;
    }

    /// @notice Restores a frozen financed invoice to FUNDED state.
    /// @dev
    /// Only invoices frozen from FUNDED state are handled here.
    ///
    /// Unfreeze must restore lifecycle state without mutating any accounting field.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function unfreezeInvoice(uint256 invoiceSeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FROZEN) {
            return;
        }

        if (invoice.previousStatus != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return;
        }

        AccountingSnapshot memory beforeSnapshot = _snapshotAccounting();

        vm.prank(RISK_ADMIN);
        INVOICE_NFT.unfreezeInvoice(invoiceId);

        IInvoiceNFT.Invoice memory restoredInvoice = INVOICE_NFT.getInvoice(invoiceId);

        assertEq(uint256(restoredInvoice.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));

        assertEq(uint256(restoredInvoice.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));

        _assertAccountingUnchanged(beforeSnapshot);

        callsUnfreezeInvoice++;
    }

    /// @dev Returns core immutable and lifecycle terms for a financing position.
    function _getPositionSettlementTerms(uint256 invoiceId)
        internal
        view
        returns (uint256 principal, uint256 financingFee, bool resolved)
    {
        (,, principal,,, financingFee,,, resolved) = POOL.financingPositions(invoiceId);
    }

    /// @dev Captures protocol accounting that freeze/unfreeze must not change.
    function _snapshotAccounting() internal view returns (AccountingSnapshot memory snapshot) {
        snapshot = AccountingSnapshot({
            totalLockedAssets: POOL.totalLockedAssets(),
            seniorLockedAssets: SENIOR_POOL.lockedAssets(),
            juniorLockedAssets: JUNIOR_POOL.lockedAssets(),
            totalBadDebt: POOL.totalBadDebt(),
            buyerExposure: RISK_MANAGER.getBuyerExposure(BUYER),
            seniorTotalAssets: SENIOR_POOL.totalAssets(),
            juniorTotalAssets: JUNIOR_POOL.totalAssets()
        });
    }

    /// @dev Asserts that an operational lifecycle action changed no accounting state.
    function _assertAccountingUnchanged(AccountingSnapshot memory beforeSnapshot) internal view {
        assertEq(POOL.totalLockedAssets(), beforeSnapshot.totalLockedAssets);

        assertEq(SENIOR_POOL.lockedAssets(), beforeSnapshot.seniorLockedAssets);

        assertEq(JUNIOR_POOL.lockedAssets(), beforeSnapshot.juniorLockedAssets);

        assertEq(POOL.totalBadDebt(), beforeSnapshot.totalBadDebt);

        assertEq(RISK_MANAGER.getBuyerExposure(BUYER), beforeSnapshot.buyerExposure);

        assertEq(SENIOR_POOL.totalAssets(), beforeSnapshot.seniorTotalAssets);

        assertEq(JUNIOR_POOL.totalAssets(), beforeSnapshot.juniorTotalAssets);
    }

    /// @dev Returns the immutable financed principal stored for an invoice position.
    function _getPositionPrincipal(uint256 invoiceId) internal view returns (uint256 principal) {
        (,, principal,,,,,,) = POOL.financingPositions(invoiceId);
    }

    /// @dev Returns whether a new oracle update may currently be submitted.
    ///
    /// A new update is allowed when:
    /// - the invoice still has lifecycle status FUNDED;
    /// - the pool has not already recorded a finalized outcome;
    /// - no oracle update exists; or
    /// - the previous update was disputed; or
    /// - the previous update became stale.
    ///
    /// Exact max-staleness boundary remains active.
    /// Resubmission becomes valid only after that boundary.
    function _canSubmitOracleUpdate(uint256 invoiceId) internal view returns (bool) {
        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return false;
        }

        if (POOL.isOracleStatusFinalized(invoiceId)) {
            return false;
        }

        IInvoiceStatusOracle.StatusUpdate memory update = ORACLE.getStatusUpdate(invoiceId);

        if (update.submittedAt == 0) {
            return true;
        }

        if (update.finalized) {
            return false;
        }

        if (update.disputed) {
            return true;
        }

        uint256 staleAfter = update.submittedAt + ORACLE.maxStaleness();

        return block.timestamp > staleAfter;
    }

    /// @dev Selects a financed invoice deterministically from a fuzz seed.
    function _pickFinancedInvoice(uint256 seed) internal view returns (uint256 invoiceId, bool exists) {
        uint256 length = financedInvoiceIds.length;

        if (length == 0) {
            return (0, false);
        }

        invoiceId = financedInvoiceIds[seed % length];

        exists = true;
    }
}

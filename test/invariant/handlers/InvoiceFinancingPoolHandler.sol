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

import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title InvoiceFinancingPoolHandler
/// @notice Stateful fuzzing handler for the RWA Invoice Financing protocol.
/// @dev
/// The targeted state space covers financing, oracle outcome submission and
/// finalization, settlement/default execution, and freeze/unfreeze.
/// Disputes, deliberate stale-replacement actions, LP actions, direct donations,
/// and risk-parameter changes are excluded.
contract InvoiceFinancingPoolHandler is Test {
    error InvalidActorConfiguration();
    error InvalidModelConfiguration();
    error BuyerIndexOutOfBounds(uint256 index);

    struct Actors {
        address admin;
        address originator;
        address verifier;
        address riskAdmin;
        address supplier;
        address buyerOne;
        address buyerTwo;
        address resolver;
    }

    struct ModelConfig {
        uint256 maxExposurePerBuyer;
        uint256 advanceRateBps;
        uint256 seniorFundingShareBps;
        uint256 bpsDenominator;
        uint256 maxInvoiceTenor;
        uint256 minInvoiceAmount;
        uint256 financingFeeAprBps;
        uint256 disputeWindow;
        uint256 maxStaleness;
    }

    struct GhostPosition {
        bool exists;
        address supplier;
        address buyer;
        uint256 principal;
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 fundedAt;
        uint256 dueDate;
        bool pendingOutcomeExists;
        IInvoiceNFT.InvoiceStatus pendingStatus;
        uint256 pendingRecovery;
        uint256 pendingSubmittedAt;
        bool finalized;
        IInvoiceNFT.InvoiceStatus finalizedStatus;
        uint256 finalizedRecovery;
        bool resolved;
    }

    struct AccountingSnapshot {
        uint256 totalLockedAssets;
        uint256 seniorLockedAssets;
        uint256 juniorLockedAssets;
        uint256 totalBadDebt;
        uint256 buyerOneExposure;
        uint256 buyerTwoExposure;
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
    address public immutable BUYER_ONE;
    address public immutable BUYER_TWO;
    address public immutable RESOLVER;

    uint256 public immutable MODEL_MAX_EXPOSURE_PER_BUYER;
    uint256 public immutable MODEL_ADVANCE_RATE_BPS;
    uint256 public immutable MODEL_SENIOR_FUNDING_SHARE_BPS;
    uint256 public immutable MODEL_BPS_DENOMINATOR;
    uint256 public immutable MODEL_MAX_INVOICE_TENOR;
    uint256 public immutable MODEL_MIN_INVOICE_AMOUNT;
    uint256 public immutable MODEL_FINANCING_FEE_APR_BPS;
    uint256 public immutable MODEL_DISPUTE_WINDOW;
    uint256 public immutable MODEL_MAX_STALENESS;

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

    /// @dev Expected position state derived only from successful handler actions.
    mapping(uint256 invoiceId => GhostPosition position) internal ghostPositions;

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

    constructor(
        InvoiceFinancingPool pool_,
        InvoiceStatusOracle oracle_,
        Actors memory actors_,
        ModelConfig memory modelConfig_
    ) {
        _validateActorConfiguration(actors_);
        _validateModelConfig(modelConfig_);

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
        BUYER_ONE = actors_.buyerOne;
        BUYER_TWO = actors_.buyerTwo;
        RESOLVER = actors_.resolver;

        MODEL_MAX_EXPOSURE_PER_BUYER = modelConfig_.maxExposurePerBuyer;
        MODEL_ADVANCE_RATE_BPS = modelConfig_.advanceRateBps;
        MODEL_SENIOR_FUNDING_SHARE_BPS = modelConfig_.seniorFundingShareBps;
        MODEL_BPS_DENOMINATOR = modelConfig_.bpsDenominator;
        MODEL_MAX_INVOICE_TENOR = modelConfig_.maxInvoiceTenor;
        MODEL_MIN_INVOICE_AMOUNT = modelConfig_.minInvoiceAmount;
        MODEL_FINANCING_FEE_APR_BPS = modelConfig_.financingFeeAprBps;
        MODEL_DISPUTE_WINDOW = modelConfig_.disputeWindow;
        MODEL_MAX_STALENESS = modelConfig_.maxStaleness;
    }

    /// @notice Returns number of successfully financed invoices.
    function financedInvoiceCount() external view returns (uint256 count) {
        return financedInvoiceIds.length;
    }

    /// @notice Returns a financed invoice identifier by registry index.
    function financedInvoiceIdAt(uint256 index) external view returns (uint256 invoiceId) {
        return financedInvoiceIds[index];
    }

    /// @notice Returns independently reconstructed state for a financed invoice.
    function getGhostPosition(uint256 invoiceId) external view returns (GhostPosition memory position) {
        return ghostPositions[invoiceId];
    }

    /// @notice Returns the number of Buyers exercised by the handler.
    function buyerCount() external pure returns (uint256 count) {
        return 2;
    }

    /// @notice Returns a Buyer actor by enumeration index.
    function buyerAt(uint256 index) external view returns (address buyer) {
        if (index == 0) {
            return BUYER_ONE;
        }

        if (index == 1) {
            return BUYER_TWO;
        }

        revert BuyerIndexOutOfBounds(index);
    }

    /// @notice Creates, verifies, and finances a valid invoice.
    /// @dev
    /// Preconditions are checked before invoice creation so the handler does not
    /// accumulate unusable VERIFIED invoices.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function createAndFinanceInvoice(uint256 faceValueSeed, uint256 tenorSeed, uint256 buyerSeed) external {
        address selectedBuyer = buyerSeed % 2 == 0 ? BUYER_ONE : BUYER_TWO;

        uint256 faceValue = bound(faceValueSeed, MODEL_MIN_INVOICE_AMOUNT, MAX_HANDLER_FACE_VALUE);
        uint256 tenor = bound(tenorSeed, 1, MODEL_MAX_INVOICE_TENOR);

        uint256 principal = faceValue * MODEL_ADVANCE_RATE_BPS / MODEL_BPS_DENOMINATOR;
        uint256 seniorPrincipal = principal * MODEL_SENIOR_FUNDING_SHARE_BPS / MODEL_BPS_DENOMINATOR;
        uint256 juniorPrincipal = principal - seniorPrincipal;

        uint256 ghostExposure = _ghostBuyerExposure(selectedBuyer);

        if (principal > MODEL_MAX_EXPOSURE_PER_BUYER) {
            return;
        }

        if (ghostExposure > MODEL_MAX_EXPOSURE_PER_BUYER - principal) {
            return;
        }

        if (seniorPrincipal == 0 || juniorPrincipal == 0) {
            return;
        }

        if (RISK_MANAGER.isBuyerDenied(selectedBuyer)) {
            return;
        }

        if (!RISK_MANAGER.checkConcentration(selectedBuyer, principal)) {
            return;
        }

        if (SENIOR_POOL.availableLiquidity() < seniorPrincipal) {
            return;
        }

        if (JUNIOR_POOL.availableLiquidity() < juniorPrincipal) {
            return;
        }

        if (tenor > type(uint256).max - block.timestamp) {
            return;
        }

        uint256 dueDate = block.timestamp + tenor;

        vm.prank(ORIGINATOR);
        uint256 invoiceId = INVOICE_NFT.createInvoice(SUPPLIER, selectedBuyer, faceValue, dueDate);

        vm.prank(VERIFIER);
        INVOICE_NFT.verify(invoiceId);

        assertTrue(RISK_MANAGER.isEligible(invoiceId));

        uint256 expectedFundedAt = block.timestamp;

        vm.prank(SUPPLIER);
        POOL.financeInvoice(invoiceId);

        financedInvoiceIds.push(invoiceId);

        _recordFinancedGhost(
            invoiceId, selectedBuyer, principal, seniorPrincipal, juniorPrincipal, expectedFundedAt, dueDate
        );

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

        GhostPosition storage ghost = ghostPositions[invoiceId];

        ghost.pendingOutcomeExists = true;
        ghost.pendingStatus = IInvoiceNFT.InvoiceStatus.SETTLED;
        ghost.pendingRecovery = 0;
        ghost.pendingSubmittedAt = block.timestamp;

        callsSubmitSettledOutcome++;
    }

    /// @notice Submits a DEFAULTED oracle outcome for an eligible financed invoice.
    /// @dev
    /// The recovery amount is derived from the immutable principal stored in the
    /// handler ghost position and is always bounded to:
    ///
    ///     0 <= recoveredAmount <= principal
    ///
    /// Submission and finalization remain separate actions so invariant runs can
    /// explore active, passively stale, replaced, and finalized oracle states.
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

        GhostPosition storage ghost = ghostPositions[invoiceId];

        uint256 recoveredAmount = bound(recoverySeed, 0, ghost.principal);

        vm.prank(ADMIN);
        ORACLE.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, recoveredAmount);

        ghost.pendingOutcomeExists = true;
        ghost.pendingStatus = IInvoiceNFT.InvoiceStatus.DEFAULTED;
        ghost.pendingRecovery = recoveredAmount;
        ghost.pendingSubmittedAt = block.timestamp;

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
    /// - the update is already finalized;
    /// - the update is stale.
    ///
    /// Unexpected reverts are intentionally not swallowed.
    function finalizeOutcome(uint256 invoiceSeed) external {
        (uint256 invoiceId, bool exists) = _pickFinancedInvoice(invoiceSeed);

        if (!exists) {
            return;
        }

        GhostPosition storage ghost = ghostPositions[invoiceId];

        if (!ghost.pendingOutcomeExists || ghost.finalized) {
            return;
        }

        if (
            block.timestamp > ghost.pendingSubmittedAt
                && block.timestamp - ghost.pendingSubmittedAt > MODEL_MAX_STALENESS
        ) {
            return;
        }

        if (MODEL_DISPUTE_WINDOW > type(uint256).max - ghost.pendingSubmittedAt) {
            return;
        }

        uint256 earliestFinalizeAt = ghost.pendingSubmittedAt + MODEL_DISPUTE_WINDOW;

        if (block.timestamp < earliestFinalizeAt) {
            vm.warp(earliestFinalizeAt);
        }

        ORACLE.finalize(invoiceId);

        ghost.finalized = true;
        ghost.finalizedStatus = ghost.pendingStatus;
        ghost.finalizedRecovery = ghost.pendingRecovery;

        callsFinalizeOutcome++;
    }

    /// @notice Executes paid-path settlement for a finalized SETTLED invoice.
    /// @dev
    /// The handler contract acts as the permissionless settlement payer.
    ///
    /// The action independently reconstructs principal and financing fee from the
    /// handler model. It mints the required repayment plus an optional
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

        GhostPosition storage ghost = ghostPositions[invoiceId];

        if (ghost.resolved) {
            return;
        }

        if (!ghost.finalized || ghost.finalizedStatus != IInvoiceNFT.InvoiceStatus.SETTLED) {
            return;
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return;
        }

        uint256 duration = ghost.dueDate - ghost.fundedAt;

        uint256 aprDuration = MODEL_FINANCING_FEE_APR_BPS * duration;

        uint256 financingFee = ghost.principal * aprDuration / (365 days * MODEL_BPS_DENOMINATOR);

        uint256 expectedRepayment = ghost.principal + financingFee;

        uint256 surplus = bound(surplusSeed, 0, MAX_HANDLER_SETTLEMENT_SURPLUS);

        uint256 paidAmount = expectedRepayment + surplus;

        ASSET.mint(address(this), paidAmount);

        ASSET.approve(address(POOL), paidAmount);

        POOL.settleInvoice(invoiceId, paidAmount);

        ghost.resolved = true;

        callsSettleInvoice++;
    }

    /// @notice Executes default accounting for a finalized DEFAULTED invoice.
    /// @dev
    /// RESOLVER acts as the permissionless default executor.
    ///
    /// The executor does not choose recovery.
    /// It uses the independently tracked finalized recovery,
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

        GhostPosition storage ghost = ghostPositions[invoiceId];

        if (ghost.resolved) {
            return;
        }

        if (!ghost.finalized || ghost.finalizedStatus != IInvoiceNFT.InvoiceStatus.DEFAULTED) {
            return;
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return;
        }

        uint256 recoveredAmount = ghost.finalizedRecovery;

        if (recoveredAmount > 0) {
            ASSET.mint(RESOLVER, recoveredAmount);
        }

        vm.startPrank(RESOLVER);

        if (recoveredAmount > 0) {
            ASSET.approve(address(POOL), recoveredAmount);
        }

        POOL.resolveDefault(invoiceId);

        vm.stopPrank();

        ghost.resolved = true;

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

    /// @dev Captures protocol accounting that freeze/unfreeze must not change.
    function _snapshotAccounting() internal view returns (AccountingSnapshot memory snapshot) {
        snapshot = AccountingSnapshot({
            totalLockedAssets: POOL.totalLockedAssets(),
            seniorLockedAssets: SENIOR_POOL.lockedAssets(),
            juniorLockedAssets: JUNIOR_POOL.lockedAssets(),
            totalBadDebt: POOL.totalBadDebt(),
            buyerOneExposure: RISK_MANAGER.getBuyerExposure(BUYER_ONE),
            buyerTwoExposure: RISK_MANAGER.getBuyerExposure(BUYER_TWO),
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

        assertEq(RISK_MANAGER.getBuyerExposure(BUYER_ONE), beforeSnapshot.buyerOneExposure);

        assertEq(RISK_MANAGER.getBuyerExposure(BUYER_TWO), beforeSnapshot.buyerTwoExposure);

        assertEq(SENIOR_POOL.totalAssets(), beforeSnapshot.seniorTotalAssets);

        assertEq(JUNIOR_POOL.totalAssets(), beforeSnapshot.juniorTotalAssets);
    }

    /// @dev Returns whether a new oracle update may currently be submitted.
    ///
    /// A new update is allowed when:
    /// - the invoice still has lifecycle status FUNDED;
    /// - the ghost position is unresolved and not finalized;
    /// - no pending ghost outcome exists; or
    /// - the pending ghost outcome became stale through elapsed handler time.
    ///
    /// Exact max-staleness boundary remains active.
    /// Resubmission becomes valid only after that boundary.
    function _canSubmitOracleUpdate(uint256 invoiceId) internal view returns (bool) {
        GhostPosition storage ghost = ghostPositions[invoiceId];

        if (!ghost.exists || ghost.resolved || ghost.finalized) {
            return false;
        }

        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);

        if (invoice.status != IInvoiceNFT.InvoiceStatus.FUNDED) {
            return false;
        }

        if (!ghost.pendingOutcomeExists) {
            return true;
        }

        if (block.timestamp <= ghost.pendingSubmittedAt) {
            return false;
        }

        return block.timestamp - ghost.pendingSubmittedAt > MODEL_MAX_STALENESS;
    }

    /// @dev Reconstructs unresolved exposure without reading RiskManager exposure.
    function _ghostBuyerExposure(address buyer) internal view returns (uint256 exposure) {
        uint256 length = financedInvoiceIds.length;

        for (uint256 i; i < length; i++) {
            GhostPosition storage ghost = ghostPositions[financedInvoiceIds[i]];

            if (!ghost.resolved && ghost.buyer == buyer) {
                exposure += ghost.principal;
            }
        }
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

    /// @dev Records model-derived terms only after successful production financing.
    function _recordFinancedGhost(
        uint256 invoiceId,
        address buyer,
        uint256 principal,
        uint256 seniorPrincipal,
        uint256 juniorPrincipal,
        uint256 fundedAt,
        uint256 dueDate
    ) internal {
        GhostPosition storage ghost = ghostPositions[invoiceId];

        ghost.exists = true;
        ghost.supplier = SUPPLIER;
        ghost.buyer = buyer;
        ghost.principal = principal;
        ghost.seniorPrincipal = seniorPrincipal;
        ghost.juniorPrincipal = juniorPrincipal;
        ghost.fundedAt = fundedAt;
        ghost.dueDate = dueDate;
    }

    function _validateActorConfiguration(Actors memory actors_) internal pure {
        if (
            actors_.supplier == address(0) || actors_.buyerOne == address(0) || actors_.buyerTwo == address(0)
                || actors_.resolver == address(0) || actors_.buyerOne == actors_.buyerTwo
                || actors_.supplier == actors_.buyerOne || actors_.supplier == actors_.buyerTwo
                || actors_.resolver == actors_.supplier || actors_.resolver == actors_.buyerOne
                || actors_.resolver == actors_.buyerTwo
        ) {
            revert InvalidActorConfiguration();
        }
    }

    /// @dev Rejects configurations that invalidate model assumptions or bounded arithmetic.
    function _validateModelConfig(ModelConfig memory modelConfig_) internal pure {
        if (
            modelConfig_.maxExposurePerBuyer == 0 || modelConfig_.advanceRateBps == 0
                || modelConfig_.bpsDenominator == 0 || modelConfig_.advanceRateBps > modelConfig_.bpsDenominator
                || modelConfig_.seniorFundingShareBps == 0
                || modelConfig_.seniorFundingShareBps >= modelConfig_.bpsDenominator
                || modelConfig_.maxInvoiceTenor == 0 || modelConfig_.minInvoiceAmount == 0
                || modelConfig_.minInvoiceAmount > MAX_HANDLER_FACE_VALUE || modelConfig_.disputeWindow == 0
                || modelConfig_.maxStaleness <= modelConfig_.disputeWindow
        ) {
            revert InvalidModelConfiguration();
        }

        uint256 maxUint = type(uint256).max;

        if (modelConfig_.advanceRateBps > maxUint / MAX_HANDLER_FACE_VALUE) {
            revert InvalidModelConfiguration();
        }

        uint256 maxPrincipal = MAX_HANDLER_FACE_VALUE * modelConfig_.advanceRateBps / modelConfig_.bpsDenominator;

        if (maxPrincipal == 0 || modelConfig_.seniorFundingShareBps > maxUint / maxPrincipal) {
            revert InvalidModelConfiguration();
        }

        uint256 minPrincipal = modelConfig_.minInvoiceAmount * modelConfig_.advanceRateBps / modelConfig_.bpsDenominator;

        uint256 minSeniorPrincipal = minPrincipal * modelConfig_.seniorFundingShareBps / modelConfig_.bpsDenominator;

        uint256 minJuniorPrincipal = minPrincipal - minSeniorPrincipal;

        if (
            minPrincipal == 0 || minSeniorPrincipal == 0 || minJuniorPrincipal == 0
                || minPrincipal > modelConfig_.maxExposurePerBuyer
        ) {
            revert InvalidModelConfiguration();
        }

        if (
            modelConfig_.financingFeeAprBps != 0
                && modelConfig_.maxInvoiceTenor > maxUint / modelConfig_.financingFeeAprBps
        ) {
            revert InvalidModelConfiguration();
        }

        uint256 maxAprDuration = modelConfig_.financingFeeAprBps * modelConfig_.maxInvoiceTenor;

        if (maxAprDuration != 0 && maxPrincipal > maxUint / maxAprDuration) {
            revert InvalidModelConfiguration();
        }

        if (modelConfig_.bpsDenominator > maxUint / (365 days)) {
            revert InvalidModelConfiguration();
        }

        uint256 feeDenominator = 365 days * modelConfig_.bpsDenominator;
        uint256 maxFee = maxPrincipal * maxAprDuration / feeDenominator;

        if (maxPrincipal > maxUint - maxFee) {
            revert InvalidModelConfiguration();
        }

        uint256 maxExpectedRepayment = maxPrincipal + maxFee;

        if (maxExpectedRepayment > maxUint - MAX_HANDLER_SETTLEMENT_SURPLUS) {
            revert InvalidModelConfiguration();
        }
    }
}

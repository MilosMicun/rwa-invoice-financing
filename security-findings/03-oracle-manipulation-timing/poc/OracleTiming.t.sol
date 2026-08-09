// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceStatusOracle} from "../../../src/interfaces/IInvoiceStatusOracle.sol";
import {IInvoiceFinancingPool} from "../../../src/interfaces/IInvoiceFinancingPool.sol";
import {InvoiceStatusOracle} from "../../../src/oracle/InvoiceStatusOracle.sol";
import {InvoiceFinancingPool} from "../../../src/core/InvoiceFinancingPool.sol";

/// @title Vector 03 — Oracle manipulation, timing & trust boundaries
/// @notice Probes the permissioned-oracle + dispute-window + permissionless-finalize design.
///         Each test encodes its verdict in assertions. SAFE = defense holds; FINDING = harm proven.
contract OracleTimingTest is Harness {
    // Convenience enum aliases
    IInvoiceNFT.InvoiceStatus internal constant SETTLED = IInvoiceNFT.InvoiceStatus.SETTLED;
    IInvoiceNFT.InvoiceStatus internal constant DEFAULTED = IInvoiceNFT.InvoiceStatus.DEFAULTED;
    IInvoiceNFT.InvoiceStatus internal constant FUNDED = IInvoiceNFT.InvoiceStatus.FUNDED;
    IInvoiceNFT.InvoiceStatus internal constant VERIFIED = IInvoiceNFT.InvoiceStatus.VERIFIED;

    // ---------------------------------------------------------------------
    // H1 — Unauthorized outcome injection
    // ---------------------------------------------------------------------
    // Hypothesis: an EOA can inject a finalized outcome by calling the pool callback directly.
    // Attack: attacker calls pool.onStatusFinalized(id, SETTLED, 0) with no oracle role.
    // Result: reverts UnauthorizedOracle; only the configured oracle may inject an outcome.
    // Verdict: SAFE.
    function test_SAFE_onStatusFinalized_rejects_direct_eoa_call() public {
        uint256 id = _bootstrapFundedInvoice();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.UnauthorizedOracle.selector, attacker));
        pool.onStatusFinalized(id, SETTLED, 0);

        // Nothing was recorded.
        assertFalse(pool.isOracleStatusFinalized(id), "no outcome should be recorded");
    }

    // ---------------------------------------------------------------------
    // H2 — Permissionless finalize propagates the submitted payload verbatim
    // ---------------------------------------------------------------------
    // Hypothesis: the (permissionless) finalizer can alter the status/recovery it pushes.
    // Attack: attacker (no roles) finalizes an admin-submitted DEFAULTED(recovery) outcome.
    // Result: the pool stores EXACTLY what was submitted; finalizer has zero payload control.
    // Verdict: SAFE.
    function test_SAFE_finalize_is_permissionless_but_payload_is_immutable() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 submittedRecovery = principal / 2;

        vm.prank(admin);
        oracle.submitStatus(id, DEFAULTED, submittedRecovery);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        // A random actor finalizes — cannot pass any payload of its own.
        vm.prank(attacker);
        oracle.finalize(id);

        assertEq(uint256(pool.finalizedOracleStatus(id)), uint256(DEFAULTED), "status must equal submitted");
        assertEq(pool.finalizedRecoveryAmount(id), submittedRecovery, "recovery must equal submitted");
    }

    // ---------------------------------------------------------------------
    // H3 — Timing boundaries (dispute window / staleness)
    // ---------------------------------------------------------------------
    // Hypothesis: finalize can run before the dispute window or after staleness.
    // Attack: finalize at t < submittedAt+window, at the boundary, and at t > submittedAt+staleness.
    // Result: too-early reverts DisputeWindowNotElapsed; == earliest works; too-late reverts stale.
    // Verdict: SAFE.
    function test_SAFE_finalize_timing_boundaries() public {
        // ---- too early ----
        uint256 id = _bootstrapFundedInvoice();
        uint256 submittedAt = block.timestamp;
        vm.prank(admin);
        oracle.submitStatus(id, SETTLED, 0);

        // one second before the window elapses -> revert
        vm.warp(submittedAt + DISPUTE_WINDOW - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceStatusOracle.DisputeWindowNotElapsed.selector, id, submittedAt + DISPUTE_WINDOW
            )
        );
        oracle.finalize(id);

        // exactly at earliestFinalizeAt -> succeeds
        vm.warp(submittedAt + DISPUTE_WINDOW);
        oracle.finalize(id);
        assertEq(uint256(pool.finalizedOracleStatus(id)), uint256(SETTLED), "boundary finalize should succeed");

        // ---- too late (new invoice) ----
        uint256 id2 = _createVerifiedInvoiceFor(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(id2);
        uint256 submittedAt2 = block.timestamp;
        vm.prank(admin);
        oracle.submitStatus(id2, SETTLED, 0);

        // one second past staleness -> revert
        vm.warp(submittedAt2 + MAX_STALENESS + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateStale.selector, id2, submittedAt2 + MAX_STALENESS)
        );
        oracle.finalize(id2);
    }

    // ---------------------------------------------------------------------
    // H4 — Active, non-disputed, non-stale outcome cannot be overwritten
    // ---------------------------------------------------------------------
    // Hypothesis: a submitter can overwrite a correct active SETTLED with a malicious DEFAULTED.
    // Attack: submit SETTLED, then (still active) resubmit DEFAULTED(recovery) to poison the outcome.
    // Result: resubmission reverts StatusUpdateAlreadyActive while the update is live.
    // Verdict: SAFE.
    function test_SAFE_active_outcome_cannot_be_overwritten() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 maliciousRecovery = _positionPrincipal(id) / 2;

        vm.prank(admin);
        oracle.submitStatus(id, SETTLED, 0);

        // Immediately (active, not disputed, not stale) try to replace it with a malicious default.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyActive.selector, id));
        oracle.submitStatus(id, DEFAULTED, maliciousRecovery);

        // The original SETTLED still finalizes and drives the settlement path.
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);
        assertEq(uint256(pool.finalizedOracleStatus(id)), uint256(SETTLED), "original outcome must survive");
    }

    // ---------------------------------------------------------------------
    // H5 — Recovery-bound BRICK / liveness DoS  (FINDING)
    // ---------------------------------------------------------------------
    // Hypothesis: a DEFAULTED submission with recovery > principal permanently bricks
    //             finalize() while the update stays active (not disputed / not stale),
    //             freezing resolution — and the locked LP capital — for the staleness window.
    // Attack: submitter (or an honest fat-finger) submits DEFAULTED, recovery = principal+1.
    //         After the dispute window, finalize() reverts inside onStatusFinalized
    //         (RecoveredAmountExceedsPrincipal), so update.finalized is never set. Because the
    //         bad update is still "active", a corrective resubmit ALSO reverts. Neither settle
    //         nor default resolution can complete; capital stays locked.
    // Result: resolution is bricked; recovery only via (a) waiting out staleness, or
    //         (b) a DISPUTE_ADMIN dispute; both prolong locked LP capital / require privilege.
    // Verdict: FINDING (Medium/High liveness — see findings/V03-01).
    function test_FINDING_recovery_bound_bricks_resolution() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);

        // Bad submission: recovery strictly greater than principal.
        vm.prank(admin);
        oracle.submitStatus(id, DEFAULTED, principal + 1);

        uint256 submittedAt = block.timestamp;

        // Dispute window elapses; finalize() now permanently reverts because the pool callback rejects it.
        vm.warp(submittedAt + DISPUTE_WINDOW + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.RecoveredAmountExceedsPrincipal.selector, id, principal + 1, principal
            )
        );
        oracle.finalize(id);

        // The update is still active (not disputed, not stale) so a corrective resubmit is BLOCKED.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyActive.selector, id));
        oracle.submitStatus(id, DEFAULTED, principal / 2);

        // Neither settlement nor default resolution can run (no finalized outcome recorded).
        assertFalse(pool.isOracleStatusFinalized(id), "no finalized outcome -> execution paths blocked");
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.OracleStatusNotFinalized.selector, id));
        pool.resolveDefault(id);

        // The capital is demonstrably still locked (invariant: position unresolved, assets locked).
        assertFalse(_positionResolved(id), "position stuck unresolved");
        assertEq(pool.totalLockedAssets(), principal, "LP capital remains locked during the brick");

        // ---- Escape path #1: wait out the staleness window, then resubmit a valid outcome. ----
        vm.warp(submittedAt + MAX_STALENESS + 1);
        vm.prank(admin);
        oracle.submitStatus(id, DEFAULTED, principal / 2); // now the stale update can be replaced
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);
        assertTrue(pool.isOracleStatusFinalized(id), "recovery finally possible after staleness");
        assertEq(pool.finalizedRecoveryAmount(id), principal / 2, "valid recovery recorded");
    }

    // ---------------------------------------------------------------------
    // H5b — The dispute path is a faster escape from the brick
    // ---------------------------------------------------------------------
    // Hypothesis: a DISPUTE_ADMIN can unstick the brick before staleness by disputing then resubmitting.
    // Attack path (mitigation demonstration): dispute the bad update inside the dispute window,
    //             then immediately resubmit a valid DEFAULTED and finalize.
    // Result: dispute -> resubmit valid -> finalize succeeds well before staleness.
    // Verdict: SAFE (documents the intended, privileged recovery lever).
    function test_SAFE_dispute_unsticks_recovery_brick() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);

        vm.prank(admin);
        oracle.submitStatus(id, DEFAULTED, principal + 1); // bad submission

        // Dispute inside the window (DISPUTE_ADMIN_ROLE is admin in fixture).
        vm.prank(admin);
        oracle.disputeStatus(id);

        // A disputed update can be replaced immediately with a correct one.
        vm.prank(admin);
        oracle.submitStatus(id, DEFAULTED, principal / 2);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);

        assertTrue(pool.isOracleStatusFinalized(id), "dispute path unsticks the brick");
        assertEq(pool.finalizedRecoveryAmount(id), principal / 2, "corrected recovery recorded");
    }

    // ---------------------------------------------------------------------
    // H6 — SETTLED-with-recovery is rejected (no fake NAV gain on paid invoices)
    // ---------------------------------------------------------------------
    // Hypothesis: a submitter attaches a nonzero recovery to a SETTLED outcome to mint fake NAV.
    // Attack: submitStatus(SETTLED, >0); and (defense-in-depth) the pool callback with SETTLED+recovery.
    // Result: oracle rejects at submit (InvalidRecoveryForStatus); pool independently rejects too.
    // Verdict: SAFE.
    function test_SAFE_settled_with_recovery_rejected_both_layers() public {
        uint256 id = _bootstrapFundedInvoice();

        // Oracle-layer rejection at submit.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvalidRecoveryForStatus.selector, SETTLED, 1));
        oracle.submitStatus(id, SETTLED, 1);

        // Pool-layer rejection (defense-in-depth): call the callback as the configured oracle.
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvalidRecoveryForStatus.selector, SETTLED, 1));
        pool.onStatusFinalized(id, SETTLED, 1);
    }

    // ---------------------------------------------------------------------
    // H7 — FROZEN overlay: oracle may finalize; execution rejects until unfreeze
    // ---------------------------------------------------------------------
    // Hypothesis: finalizing on a FROZEN invoice corrupts state or lets settlement run.
    // Attack: freeze funded invoice, finalize SETTLED, then settle -> expect InvoiceFrozen;
    //         verify no state corruption; unfreeze and settle succeeds.
    // Result: settlement blocked while frozen with clean state; proceeds after unfreeze.
    // Verdict: SAFE.
    function test_SAFE_frozen_finalize_then_blocked_then_unfreeze() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);

        // Submit while FUNDED (submit requires FUNDED NFT status).
        vm.prank(admin);
        oracle.submitStatus(id, SETTLED, 0);

        // Now freeze the invoice during the dispute window.
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(id);

        // Oracle can still finalize the attestation over a FROZEN invoice (by design):
        // finalize() does not read/mutate NFT status.
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);
        assertTrue(pool.isOracleStatusFinalized(id), "oracle finalizes over FROZEN by design");

        // Settlement execution is blocked while frozen.
        uint256 expectedRepay = principal + _positionFee(id);
        asset.mint(buyer, expectedRepay);
        vm.startPrank(buyer);
        asset.approve(address(pool), expectedRepay);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvoiceFrozen.selector, id));
        pool.settleInvoice(id, expectedRepay);
        vm.stopPrank();

        // No state corruption during the blocked attempt.
        assertFalse(_positionResolved(id), "position must remain unresolved");
        assertEq(pool.totalLockedAssets(), principal, "locked assets unchanged");

        // Unfreeze -> settlement proceeds normally.
        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(id);
        _settleAsBuyer(id, expectedRepay);
        assertTrue(_positionResolved(id), "settlement completes after unfreeze");
        assertEq(pool.totalLockedAssets(), 0, "locked assets released");
    }

    // ---------------------------------------------------------------------
    // H8 — Immutability: no double-finalize, no dispute-after-finalize, no double-apply
    // ---------------------------------------------------------------------
    // Hypothesis: a finalized outcome can be finalized again, disputed, or re-applied to the pool.
    // Attack: finalize once, then finalize again / dispute / re-call the pool callback.
    // Result: second finalize + dispute revert StatusUpdateAlreadyFinalized; pool re-apply reverts
    //         OracleStatusAlreadyFinalized.
    // Verdict: SAFE.
    function test_SAFE_finalized_outcome_is_immutable() public {
        uint256 id = _bootstrapFundedInvoice();

        vm.prank(admin);
        oracle.submitStatus(id, SETTLED, 0);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);

        // double finalize
        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyFinalized.selector, id));
        oracle.finalize(id);

        // dispute after finalize
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyFinalized.selector, id));
        oracle.disputeStatus(id);

        // pool-layer: re-applying an outcome is blocked even from the configured oracle
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.OracleStatusAlreadyFinalized.selector, id));
        pool.onStatusFinalized(id, DEFAULTED, 0);
    }

    // ---------------------------------------------------------------------
    // H9 — No outcome preload before a financing position exists
    // ---------------------------------------------------------------------
    // Hypothesis: an outcome can be staged before the invoice is financed (fundedAt == 0).
    // Attack: submit against a VERIFIED (not FUNDED) invoice -> oracle rejects.
    //         Defense-in-depth: call pool.onStatusFinalized for an id with no position.
    // Result: oracle rejects InvoiceNotFunded; pool rejects FinancingPositionDoesNotExist.
    // Verdict: SAFE.
    function test_SAFE_cannot_preload_outcome_before_position() public {
        // Verified but not financed.
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        uint256 id = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.InvoiceNotFunded.selector, id, VERIFIED));
        oracle.submitStatus(id, SETTLED, 0);

        // Pool-layer: no financing position exists for this id.
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.FinancingPositionDoesNotExist.selector, id));
        pool.onStatusFinalized(id, SETTLED, 0);
    }

    // ---------------------------------------------------------------------
    // H10 — Status/ordering: submit only against FUNDED NFTs
    // ---------------------------------------------------------------------
    // Hypothesis: outcomes can be submitted against CREATED / already-terminal invoices.
    // Attack: submit against CREATED and against an already-SETTLED invoice.
    // Result: both revert InvoiceNotFunded (submit gate ties to NFT FUNDED state).
    // Verdict: SAFE.
    function test_SAFE_submit_requires_funded_nft_status() public {
        // CREATED (not yet verified).
        vm.prank(originator);
        uint256 createdId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceStatusOracle.InvoiceNotFunded.selector, createdId, IInvoiceNFT.InvoiceStatus.CREATED
            )
        );
        oracle.submitStatus(createdId, SETTLED, 0);

        // Already SETTLED: run a full happy path, then try to submit again.
        uint256 id = _bootstrapFundedInvoice();
        uint256 repay = _positionPrincipal(id) + _positionFee(id);
        _submitAndFinalizeOracleStatus(id, SETTLED, 0);
        _settleAsBuyer(id, repay);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.InvoiceNotFunded.selector, id, SETTLED));
        oracle.submitStatus(id, SETTLED, 0);
    }

    // ---------------------------------------------------------------------
    // H11 — One-shot oracle rotation (centralization / liveness)
    // ---------------------------------------------------------------------
    // Hypothesis: a compromised oracle can be rotated, or a non-admin can set it.
    // Attack: admin tries to set a second oracle; non-admin tries to set one.
    // Result: second set reverts OracleAlreadySet; non-admin reverts UnauthorizedAdmin.
    // Verdict: SAFE (INFO-level centralization: no rotation, but no theft enabled either).
    function test_SAFE_oracle_is_one_shot_and_admin_only() public {
        // deploy a fresh oracle candidate
        InvoiceStatusOracle newOracle =
            new InvoiceStatusOracle(admin, invoiceNft, pool, DISPUTE_WINDOW, MAX_STALENESS);

        // admin cannot rotate (already set in _deployProtocol)
        vm.prank(admin);
        vm.expectRevert(IInvoiceFinancingPool.OracleAlreadySet.selector);
        pool.setInvoiceStatusOracle(address(newOracle));

        // non-admin cannot set
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.UnauthorizedAdmin.selector, attacker));
        pool.setInvoiceStatusOracle(address(newOracle));

        // configured oracle unchanged
        assertEq(pool.invoiceStatusOracle(), address(oracle), "oracle must remain the original");
    }

    // ---------------------------------------------------------------------
    // H12 — Rogue authorized submitter: process integrity vs truth
    // ---------------------------------------------------------------------
    // Hypothesis: a holder of ORACLE_SUBMITTER_ROLE can push a false DEFAULTED to harm LPs,
    //             and can manufacture value beyond principal.
    // Attack: submit false DEFAULTED(recovery=0) on an invoice the buyer actually paid; finalize;
    //         resolveDefault -> junior/senior NAV is written down (LPs lose). Then confirm the ONE
    //         hard code guarantee still holds: recovery is bounded by principal (no gain manufacture)
    //         and SETTLED cannot carry recovery.
    // Result: false default DOES harm LPs (intended trust assumption; NOT a code bug) BUT the code
    //         still bounds recovery <= principal and forbids SETTLED-recovery, so no extra value can
    //         be minted for seniors beyond principal.
    // Verdict: INFO/centralization (documented), with the value-bound guarantee asserted SAFE.
    function test_SAFE_rogue_submitter_bounded_by_principal_guarantee() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);

        // (1) Rogue submitter cannot inflate recovery beyond principal: bounded at both layers.
        vm.prank(admin);
        oracle.submitStatus(id, DEFAULTED, principal + 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.RecoveredAmountExceedsPrincipal.selector, id, principal + 1, principal
            )
        );
        oracle.finalize(id);

        // (2) The false-default harm itself IS possible (trust assumption). Wait out staleness,
        //     submit a truthful-shaped-but-false DEFAULTED with zero recovery, finalize, resolve.
        uint256 juniorNavBefore = juniorPool.totalAssets();
        uint256 seniorNavBefore = seniorPool.totalAssets();

        vm.warp(block.timestamp + MAX_STALENESS + 1); // let the bad update go stale
        vm.prank(admin);
        oracle.submitStatus(id, DEFAULTED, 0); // false default, no recovery
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);
        _resolveDefaultAsResolver(id);

        // LPs lost NAV: junior absorbs first, senior residual. This is the accepted trust assumption.
        uint256 juniorNavAfter = juniorPool.totalAssets();
        uint256 seniorNavAfter = seniorPool.totalAssets();
        assertLt(juniorNavAfter, juniorNavBefore, "junior NAV written down by false default (trust assumption)");
        // With recovery 0 and junior principal < total loss, senior also takes residual writedown.
        assertLt(seniorNavAfter, seniorNavBefore, "senior residual writedown once junior depleted");

        // (3) Hard code guarantee that STILL held: bad debt equals principal, not more.
        //     The rogue submitter could not manufacture loss/gain beyond the actual principal.
        assertEq(pool.totalBadDebt(), principal, "loss bounded exactly by principal, no over/under-count");
    }
}

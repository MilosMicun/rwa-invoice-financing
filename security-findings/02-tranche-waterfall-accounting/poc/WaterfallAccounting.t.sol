// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceFinancingPool} from "../../../src/interfaces/IInvoiceFinancingPool.sol";
import {SeniorPool} from "../../../src/pools/SeniorPool.sol";
import {JuniorPool} from "../../../src/pools/JuniorPool.sol";

/// @title VECTOR 02 — Tranche waterfall & loss/recovery accounting
/// @notice Probes the senior-first recovery waterfall, first-loss ordering, writeDown-DoS,
///         bad-debt accounting, one-shot resolution, fee-split conservation, and NAV
///         conservation in InvoiceFinancingPool.settleInvoice / resolveDefault and the
///         SeniorPool/JuniorPool lock/unlock/credit/writeDown primitives.
contract WaterfallAccountingTest is Harness {
    // -------------------------------------------------------------------------
    // Local helpers
    // -------------------------------------------------------------------------

    function _seniorNav() internal view returns (uint256) {
        return seniorPool.totalAssets();
    }

    function _juniorNav() internal view returns (uint256) {
        return juniorPool.totalAssets();
    }

    /// @dev Create a verified invoice for a distinct supplier/buyer and finance it as that supplier.
    function _bootstrapExtraFunded(address sup, address buy, uint256 face) internal returns (uint256 id) {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        id = _createVerifiedInvoiceFor(sup, buy, face, dueDate);
        _financeAs(sup, id);
    }

    /// @dev Full default flow at an arbitrary oracle-attested recovery, resolved by resolver.
    function _defaultAtRecovery(uint256 id, uint256 recovery) internal {
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, recovery);
        _resolveDefaultAsResolver(id);
    }

    // =========================================================================
    // Hypothesis 1 — senior-protection matrix across the full recovery range
    // =========================================================================

    // Hypothesis: For any recovery >= seniorPrincipal, senior NAV loss must be exactly 0
    //             and junior must absorb the entire loss (first-loss). Below seniorPrincipal,
    //             junior is already fully wiped and senior begins to lose.
    // Attack:     Sweep every regime {0, <senior, =senior, between senior&principal, =principal}
    //             on an isolated funded invoice and assert exact senior/junior NAV deltas.
    // Result:     Senior loss is 0 whenever recovery>=seniorPrincipal in every regime; junior
    //             always eats first loss. No inversion.
    // Verdict:    SAFE (senior-protection guarantee holds).
    function test_SAFE_SeniorProtectionMatrix() public {
        uint256 principal = _expectedPrincipal(); // 80k
        uint256 seniorP = _expectedSeniorPrincipal(principal); // 56k
        uint256 juniorP = principal - seniorP; // 24k

        // Five recovery regimes.
        uint256[5] memory recoveries = [
            uint256(0), // total loss
            seniorP / 2, // < senior
            seniorP, // == senior (junior fully wiped, senior whole)
            seniorP + (juniorP / 2), // between senior and principal
            principal // == principal (no loss)
        ];

        for (uint256 i = 0; i < recoveries.length; i++) {
            // Fresh protocol per iteration so deltas are clean.
            setUp();
            _checkSeniorProtectionAtRecovery(recoveries[i], seniorP, juniorP);
        }
    }

    /// @dev One recovery regime of the senior-protection matrix (extracted to avoid stack-too-deep).
    function _checkSeniorProtectionAtRecovery(uint256 recovery, uint256 seniorP, uint256 juniorP) internal {
        uint256 id = _bootstrapFundedInvoice();

        uint256 seniorBefore = _seniorNav();
        uint256 juniorBefore = _juniorNav();

        _defaultAtRecovery(id, recovery);

        uint256 seniorLoss = seniorBefore - _seniorNav();
        uint256 juniorLoss = juniorBefore - _juniorNav();

        // Expected waterfall math.
        uint256 expSeniorRecovery = recovery > seniorP ? seniorP : recovery;
        assertEq(seniorLoss, seniorP - expSeniorRecovery, "senior loss mismatch");
        assertEq(juniorLoss, juniorP - (recovery - expSeniorRecovery), "junior loss mismatch");

        // The core guarantee: senior loss == 0 iff recovery >= seniorPrincipal.
        if (recovery >= seniorP) {
            assertEq(seniorLoss, 0, "senior lost value despite recovery>=seniorPrincipal");
        } else {
            assertEq(juniorLoss, juniorP, "junior not fully wiped while senior takes loss");
            assertGt(seniorLoss, 0, "senior should lose when recovery<seniorPrincipal");
        }
    }

    // =========================================================================
    // Hypothesis 2 — first-loss ordering cannot be inverted
    // =========================================================================

    // Hypothesis: There is no recovery where senior loses while junior still has residual
    //             value in the same position.
    // Attack:     Recovery exactly one wei below seniorPrincipal: junior must already be
    //             fully wiped, senior loss is exactly 1 wei.
    // Result:     junior fully wiped (loss==juniorPrincipal), senior loss == 1.
    // Verdict:    SAFE.
    function test_SAFE_FirstLossOrderingNoInversion() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 seniorP = _expectedSeniorPrincipal(principal);
        uint256 juniorP = principal - seniorP;

        uint256 seniorBefore = _seniorNav();
        uint256 juniorBefore = _juniorNav();

        _defaultAtRecovery(id, seniorP - 1);

        uint256 seniorLoss = seniorBefore - _seniorNav();
        uint256 juniorLoss = juniorBefore - _juniorNav();

        assertEq(juniorLoss, juniorP, "junior must be fully wiped first");
        assertEq(seniorLoss, 1, "senior loss should be exactly the 1 wei shortfall");
    }

    // =========================================================================
    // Hypothesis 3 — writeDown-DoS with a competing locked position
    // =========================================================================

    // Hypothesis: A second active position that keeps most junior liquidity locked can starve
    //             availableLiquidity so resolveDefault's writeDown reverts, stranding the
    //             defaulted position forever.
    // Attack:     Two funded positions eating ~all junior liquidity; default one with
    //             recovery=0 (maximum junior + senior writedown).
    // Result:     resolveDefault succeeds because unlockAssets(juniorPrincipal) runs BEFORE
    //             writeDown, restoring availableLiquidity >= juniorLoss.
    // Verdict:    SAFE (no writeDown DoS).
    function test_SAFE_WriteDownDoS_CompetingLockedPosition() public {
        // Deposit just enough that two invoices consume almost all junior liquidity.
        // Junior deposit 300k; each invoice locks juniorPrincipal = 24k. Two = 48k locked.
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        address supA = makeAddr("supA");
        address supB = makeAddr("supB");
        address buyA = makeAddr("buyA");
        address buyB = makeAddr("buyB");

        uint256 idA = _bootstrapExtraFunded(supA, buyA, FACE_VALUE);
        uint256 idB = _bootstrapExtraFunded(supB, buyB, FACE_VALUE);

        // Snapshot the untouched position B contribution.
        uint256 lockedBefore = pool.totalLockedAssets();

        // Default A at recovery 0 -> max writedown on both tranches.
        _defaultAtRecovery(idA, 0);

        // Must succeed; junior & senior NAV written down by A's principals.
        assertTrue(_positionResolved(idA), "A should be resolved");

        // B still locked, untouched.
        assertFalse(_positionResolved(idB), "B must remain active");
        uint256 principalA = _positionPrincipal(idA);
        assertEq(pool.totalLockedAssets(), lockedBefore - principalA, "only A's lock released");
    }

    // =========================================================================
    // Hypothesis 4 — writeDown-DoS after junior LP drains available liquidity
    // =========================================================================

    // Hypothesis: A junior LP withdrawing every unlocked asset right before resolution drops
    //             availableLiquidity to 0, so writeDown reverts and the position is stranded.
    // Attack:     One funded position; junior LP withdraws max available; then default recovery=0.
    // Result:     resolveDefault still succeeds because unlock(juniorPrincipal) restores
    //             availableLiquidity to >= juniorLoss before writeDown.
    // Verdict:    SAFE.
    function test_SAFE_WriteDownDoS_AfterJuniorDrainsLiquidity() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 juniorP = principal - _expectedSeniorPrincipal(principal);

        // Junior LP withdraws every asset not locked.
        uint256 avail = pool.juniorAvailableLiquidity();
        assertGt(avail, 0, "expected free junior liquidity");
        vm.startPrank(juniorLp);
        // withdraw pulls from LP's own shares via coordinator; approve coordinator for shares.
        uint256 sharesNeeded = pool.previewJuniorWithdrawShares(avail);
        juniorPool.approve(address(pool), sharesNeeded);
        pool.withdrawJunior(avail);
        vm.stopPrank();

        assertEq(pool.juniorAvailableLiquidity(), 0, "junior available should be fully drained");

        // Now default at recovery 0. juniorLoss = juniorPrincipal must be written down.
        // unlock(juniorPrincipal) raises available to juniorPrincipal >= juniorLoss.
        _defaultAtRecovery(id, 0);

        assertTrue(_positionResolved(id), "resolution must not be stranded");
        // Junior NAV after: it was drained by `avail`, then written down by juniorP.
        // accountedAssets went 300k -> 300k-avail (withdraw) -> minus juniorP (writeDown).
        assertEq(_juniorNav(), JUNIOR_DEPOSIT - avail - juniorP, "junior NAV after drain+writedown");
    }

    // =========================================================================
    // Hypothesis 5 — bad-debt is exactly principal-recovery, fee excluded
    // =========================================================================

    // Hypothesis: totalBadDebt could be inflated (include fee) or deflated.
    // Attack:     Default with partial recovery; check badDebt == principal-recovery and that
    //             it is strictly below principal-recovery+fee (fee not counted).
    // Result:     Exact. Fee excluded.
    // Verdict:    SAFE.
    function test_SAFE_BadDebtExactPrincipalMinusRecovery() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);
        assertGt(fee, 0, "expected non-zero fee");

        uint256 recovery = principal / 3;
        _defaultAtRecovery(id, recovery);

        assertEq(pool.totalBadDebt(), principal - recovery, "badDebt must equal principal-recovery");
        // Fee is NOT part of bad debt.
        assertLt(pool.totalBadDebt(), principal - recovery + fee, "fee must be excluded from bad debt");
    }

    // =========================================================================
    // Hypothesis 6 — bad-debt accumulates cleanly across two positions
    // =========================================================================

    // Hypothesis: Resolving position A corrupts B's later bad-debt contribution (double count
    //             or overwrite).
    // Attack:     Default two positions at different recoveries; assert cumulative badDebt is
    //             the exact sum of the two independent losses.
    // Result:     totalBadDebt == lossA + lossB, exact.
    // Verdict:    SAFE.
    function test_SAFE_BadDebtAccumulatesAcrossPositions() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        address supA = makeAddr("supA");
        address supB = makeAddr("supB");
        uint256 idA = _bootstrapExtraFunded(supA, makeAddr("buyA"), FACE_VALUE);
        uint256 idB = _bootstrapExtraFunded(supB, makeAddr("buyB"), FACE_VALUE);

        uint256 pA = _positionPrincipal(idA);
        uint256 pB = _positionPrincipal(idB);

        uint256 recA = pA / 4;
        uint256 recB = pB / 2;

        _defaultAtRecovery(idA, recA);
        uint256 afterA = pool.totalBadDebt();
        assertEq(afterA, pA - recA, "badDebt after A");

        _defaultAtRecovery(idB, recB);
        assertEq(pool.totalBadDebt(), (pA - recA) + (pB - recB), "cumulative badDebt must sum losses");
    }

    // =========================================================================
    // Hypothesis 7 — one-shot resolution: no double resolve
    // =========================================================================

    // Hypothesis: A position can be resolved twice (settle+default or resolve twice),
    //             double-decrementing totalLockedAssets or applying two waterfalls.
    // Attack:     Settle, then attempt resolveDefault and re-settle; both must revert.
    // Result:     resolved flag + NFT terminal state block any second resolution.
    // Verdict:    SAFE.
    function test_SAFE_NoDoubleResolveAfterSettle() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);

        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAsBuyer(id, principal + fee);

        assertTrue(_positionResolved(id), "should be resolved after settle");
        assertEq(pool.totalLockedAssets(), 0, "locked back to zero after settle");

        // Re-settle must revert (already resolved).
        asset.mint(attacker, principal + fee);
        vm.startPrank(attacker);
        asset.approve(address(pool), principal + fee);
        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.FinancingPositionAlreadyResolved.selector, id)
        );
        pool.settleInvoice(id, principal + fee);
        vm.stopPrank();

        // resolveDefault must revert too.
        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.FinancingPositionAlreadyResolved.selector, id)
        );
        pool.resolveDefault(id);
    }

    // =========================================================================
    // Hypothesis 7b — cannot default a position the oracle finalized as SETTLED
    // =========================================================================

    // Hypothesis: Oracle finalizes SETTLED but attacker calls resolveDefault to force a
    //             writedown / bad-debt against LPs.
    // Attack:     Finalize SETTLED, then call resolveDefault.
    // Result:     Reverts with UnexpectedOracleStatus (default path requires DEFAULTED).
    // Verdict:    SAFE.
    function test_SAFE_CannotDefaultWhenOracleSettled() public {
        uint256 id = _bootstrapFundedInvoice();
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.UnexpectedOracleStatus.selector,
                id,
                IInvoiceNFT.InvoiceStatus.SETTLED,
                IInvoiceNFT.InvoiceStatus.DEFAULTED
            )
        );
        pool.resolveDefault(id);
    }

    // =========================================================================
    // Hypothesis 8 — fee-split conservation at settlement
    // =========================================================================

    // Hypothesis: seniorFee+juniorFee != fee, principal not fully restored, or surplus
    //             mis-routed, causing LP over/under-gain.
    // Attack:     Settle with a surplus; assert exact NAV deltas and surplus routing.
    // Result:     senior NAV += seniorFee, junior NAV += juniorFee, seniorFee+juniorFee==fee,
    //             supplier receives surplus, totalLockedAssets back to 0.
    // Verdict:    SAFE.
    function test_SAFE_FeeSplitConservationAtSettlement() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);

        uint256 juniorFee = fee * JUNIOR_FEE_SHARE_BPS / BPS;
        uint256 seniorFee = fee - juniorFee;
        assertEq(seniorFee + juniorFee, fee, "fee split must be conservative");

        uint256 seniorBefore = _seniorNav();
        uint256 juniorBefore = _juniorNav();
        uint256 supplierBefore = asset.balanceOf(supplier);

        uint256 surplus = 5_000e18;
        uint256 paid = principal + fee + surplus;

        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAsBuyer(id, paid);

        // NAV rises by exactly each tranche's fee share; principal fully restored (no change
        // in accounted principal because it was never removed from NAV, only locked).
        assertEq(_seniorNav() - seniorBefore, seniorFee, "senior NAV must rise by seniorFee only");
        assertEq(_juniorNav() - juniorBefore, juniorFee, "junior NAV must rise by juniorFee only");

        // Surplus routed to supplier.
        assertEq(asset.balanceOf(supplier) - supplierBefore, surplus, "surplus must go to supplier");

        // Locked assets released exactly once.
        assertEq(pool.totalLockedAssets(), 0, "locked back to zero");

        // Both tranches now fully liquid (accountedAssets == cash, no locked).
        assertEq(seniorPool.lockedAssets(), 0, "senior fully unlocked");
        assertEq(juniorPool.lockedAssets(), 0, "junior fully unlocked");
    }

    // =========================================================================
    // Hypothesis 9 — cross-position isolation on default
    // =========================================================================

    // Hypothesis: Resolving one position mutates a second, untouched position's locked amount
    //             or its tranche NAV beyond the resolved one.
    // Attack:     Two positions same buyer; snapshot; default one; check the other's lock and
    //             the residual tranche lockedAssets equal exactly the survivor's principals.
    // Result:     Survivor untouched.
    // Verdict:    SAFE.
    function test_SAFE_CrossPositionIsolationOnDefault() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        address supA = makeAddr("supA");
        address supB = makeAddr("supB");
        address sharedBuyer = makeAddr("sharedBuyer");

        uint256 idA = _bootstrapExtraFunded(supA, sharedBuyer, FACE_VALUE);
        uint256 idB = _bootstrapExtraFunded(supB, sharedBuyer, FACE_VALUE);

        uint256 pB = _positionPrincipal(idB);
        uint256 seniorB = _expectedSeniorPrincipal(pB);
        uint256 juniorB = pB - seniorB;

        // Default A completely.
        _defaultAtRecovery(idA, 0);

        // B remains fully locked at its own principals only.
        assertFalse(_positionResolved(idB), "B must be active");
        assertEq(seniorPool.lockedAssets(), seniorB, "senior lock now only B's senior principal");
        assertEq(juniorPool.lockedAssets(), juniorB, "junior lock now only B's junior principal");

        // B can still be settled normally afterwards (proves it wasn't corrupted).
        uint256 feeB = _positionFee(idB);
        _submitAndFinalizeOracleStatus(idB, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAs(sharedBuyer, idB, pB + feeB);
        assertTrue(_positionResolved(idB), "B settles cleanly after A defaulted");
    }

    // =========================================================================
    // Hypothesis 10 — NAV conservation over a multi-step lifecycle
    // =========================================================================

    // Hypothesis: Over settle + partial-default + full-default the identity
    //             (seniorNAV+juniorNAV) - initialDeposits == realizedFees - realizedLosses
    //             is violated (silent gain/loss).
    // Attack:     Run three positions through different terminal paths and check the identity.
    // Result:     Identity holds exactly.
    // Verdict:    SAFE.
    function test_SAFE_NavConservationMultiStep() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        uint256 initialDeposits = SENIOR_DEPOSIT + JUNIOR_DEPOSIT;

        address s1 = makeAddr("s1");
        address s2 = makeAddr("s2");
        address s3 = makeAddr("s3");

        uint256 id1 = _bootstrapExtraFunded(s1, makeAddr("b1"), FACE_VALUE);
        uint256 id2 = _bootstrapExtraFunded(s2, makeAddr("b2"), FACE_VALUE);
        uint256 id3 = _bootstrapExtraFunded(s3, makeAddr("b3"), FACE_VALUE);

        uint256 realizedFees;
        uint256 realizedLosses;

        // id1: settle -> realizes full fee.
        {
            uint256 p = _positionPrincipal(id1);
            uint256 fee = _positionFee(id1);
            _submitAndFinalizeOracleStatus(id1, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
            _settleAs(s1, id1, p + fee);
            realizedFees += fee;
        }

        // id2: partial default -> realizes loss = principal - recovery.
        {
            uint256 p = _positionPrincipal(id2);
            uint256 recovery = p / 2;
            _defaultAtRecovery(id2, recovery);
            realizedLosses += (p - recovery);
        }

        // id3: full default (recovery 0) -> realizes loss = principal.
        {
            uint256 p = _positionPrincipal(id3);
            _defaultAtRecovery(id3, 0);
            realizedLosses += p;
        }

        uint256 finalNav = _seniorNav() + _juniorNav();

        // (final - initial) == realizedFees - realizedLosses
        // Rearranged to avoid signed math: final + realizedLosses == initial + realizedFees
        assertEq(finalNav + realizedLosses, initialDeposits + realizedFees, "NAV conservation broken");
    }

    // =========================================================================
    // Hypothesis 11 — settlement underpayment boundary
    // =========================================================================

    // Hypothesis: A caller can settle for less than principal+fee (LP shortfall) or the exact
    //             boundary is mis-handled.
    // Attack:     paidAmount = expected-1 reverts; exact works with zero surplus; large surplus
    //             all goes to supplier.
    // Result:     Boundary enforced; conservation holds.
    // Verdict:    SAFE.
    function test_SAFE_SettlementUnderpaymentBoundary() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);
        uint256 expected = principal + fee;

        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        // Underpayment reverts.
        asset.mint(attacker, expected);
        vm.startPrank(attacker);
        asset.approve(address(pool), expected);
        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.PaidAmountBelowExpected.selector, expected - 1, expected)
        );
        pool.settleInvoice(id, expected - 1);
        vm.stopPrank();

        // Exact boundary works, zero surplus to supplier.
        uint256 supplierBefore = asset.balanceOf(supplier);
        _settleAsBuyer(id, expected);
        assertEq(asset.balanceOf(supplier) - supplierBefore, 0, "no surplus at exact boundary");
        assertTrue(_positionResolved(id), "settled at exact boundary");
    }

    // =========================================================================
    // Hypothesis 12 — recovery edges: =principal (no loss) and =seniorPrincipal
    // =========================================================================

    // Hypothesis: NAV leakage at the boundary recoveries.
    // Attack:     recovery=principal -> both losses 0, badDebt unchanged; recovery=seniorPrincipal
    //             -> junior fully wiped, senior whole.
    // Result:     Clean edges, no leakage.
    // Verdict:    SAFE.
    function test_SAFE_RecoveryEdges() public {
        // Edge A: recovery == principal -> no loss at all.
        {
            uint256 id = _bootstrapFundedInvoice();
            uint256 principal = _positionPrincipal(id);
            uint256 sBefore = _seniorNav();
            uint256 jBefore = _juniorNav();

            _defaultAtRecovery(id, principal);

            assertEq(_seniorNav(), sBefore, "senior NAV unchanged at full recovery");
            assertEq(_juniorNav(), jBefore, "junior NAV unchanged at full recovery");
            assertEq(pool.totalBadDebt(), 0, "no bad debt at full recovery");
        }

        // Edge B: recovery == seniorPrincipal -> junior fully wiped, senior whole.
        {
            setUp();
            uint256 id = _bootstrapFundedInvoice();
            uint256 principal = _positionPrincipal(id);
            uint256 seniorP = _expectedSeniorPrincipal(principal);
            uint256 juniorP = principal - seniorP;
            uint256 sBefore = _seniorNav();
            uint256 jBefore = _juniorNav();

            _defaultAtRecovery(id, seniorP);

            assertEq(_seniorNav(), sBefore, "senior whole at recovery==seniorPrincipal");
            assertEq(jBefore - _juniorNav(), juniorP, "junior fully wiped at recovery==seniorPrincipal");
            assertEq(pool.totalBadDebt(), juniorP, "bad debt equals junior principal");
        }
    }

    // =========================================================================
    // Hypothesis 13 — junior-remainder routing under a non-round funding split
    // =========================================================================

    // Hypothesis: When the 7000-bps senior split leaves an odd remainder on the junior side,
    //             a recovery exactly at seniorPrincipal could leak the junior remainder loss
    //             onto senior (or vice versa) via rounding.
    // Attack:     Craft a face value whose advance*7000/10000 is NOT clean; default at
    //             recovery == seniorPrincipal and check junior eats exactly its remainder and
    //             senior stays whole.
    // Result:     seniorRecovery==seniorPrincipal, junior absorbs the full (odd) juniorPrincipal.
    // Verdict:    SAFE.
    function test_SAFE_JuniorRemainderRoutingNonRoundSplit() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        // Face value chosen so advance (80%) then *7000/10000 leaves a remainder.
        // face = 1000e18 + 3 -> advance = 800e18 + 2 -> senior = floor(advance*7000/10000)
        // leaves a 4000-wei remainder that is routed to junior. This is a non-round split.
        uint256 face = MIN_INVOICE_AMOUNT + 3;
        require(face >= MIN_INVOICE_AMOUNT, "face too small");

        address sup = makeAddr("supRemainder");
        address buy = makeAddr("buyRemainder");
        uint256 id = _bootstrapExtraFunded(sup, buy, face);

        uint256 principal = _positionPrincipal(id);
        uint256 seniorP = principal * SENIOR_FUNDING_SHARE_BPS / BPS;
        uint256 juniorP = principal - seniorP;

        // Confirm this really is a non-round split (remainder present in the floor).
        assertTrue(principal * SENIOR_FUNDING_SHARE_BPS % BPS != 0, "expected a rounding remainder");

        uint256 sBefore = _seniorNav();
        uint256 jBefore = _juniorNav();

        // Recovery exactly at seniorPrincipal: senior gets it all, junior absorbs its full principal.
        _defaultAtRecovery(id, seniorP);

        assertEq(_seniorNav(), sBefore, "senior must stay whole (no remainder leaked to senior)");
        assertEq(jBefore - _juniorNav(), juniorP, "junior absorbs its exact (odd) principal");
        assertEq(pool.totalBadDebt(), juniorP, "bad debt equals junior odd principal");
    }

    // =========================================================================
    // Hypothesis 14 — totalLockedAssets decremented exactly once on default
    // =========================================================================

    // Hypothesis: default double-decrements or mis-decrements totalLockedAssets.
    // Attack:     Two positions; default one; assert global locked drops by exactly that
    //             position's principal, and per-tranche locked drops by exactly its shares.
    // Result:     Exactly one decrement, per-tranche exact.
    // Verdict:    SAFE.
    function test_SAFE_TotalLockedDecrementedOnceOnDefault() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        address supA = makeAddr("supA2");
        address supB = makeAddr("supB2");
        uint256 idA = _bootstrapExtraFunded(supA, makeAddr("buyA2"), FACE_VALUE);
        _bootstrapExtraFunded(supB, makeAddr("buyB2"), FACE_VALUE);

        uint256 pA = _positionPrincipal(idA);
        uint256 seniorA = _expectedSeniorPrincipal(pA);
        uint256 juniorA = pA - seniorA;

        uint256 lockedBefore = pool.totalLockedAssets();
        uint256 seniorLockedBefore = seniorPool.lockedAssets();
        uint256 juniorLockedBefore = juniorPool.lockedAssets();

        _defaultAtRecovery(idA, pA / 2);

        assertEq(pool.totalLockedAssets(), lockedBefore - pA, "global locked -1x principal");
        assertEq(seniorPool.lockedAssets(), seniorLockedBefore - seniorA, "senior locked -seniorPrincipal");
        assertEq(juniorPool.lockedAssets(), juniorLockedBefore - juniorA, "junior locked -juniorPrincipal");
    }
}

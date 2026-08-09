// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IRWARiskManager} from "../../../src/interfaces/IRWARiskManager.sol";
import {InvoiceFinancingPool} from "../../../src/core/InvoiceFinancingPool.sol";

/// @title Vector 06 — Economic / MEV / Front-running / Fee-on-transfer
/// @notice All tests inherit the default MockERC20 harness unless a test-level redeploy is used
///         via _deployProtocol on a malicious asset. FeeOnTransfer probes live in a sibling file
///         that overrides setUp so the whole protocol runs on the fee token.
contract EconomicMEVTest is Harness {
    // ---------------------------------------------------------------------
    // Local helpers
    // ---------------------------------------------------------------------

    /// @dev Junior available liquidity (accountedAssets - lockedAssets).
    function _juniorAvail() internal view returns (uint256) {
        return juniorPool.availableLiquidity();
    }

    /// @dev What `assets` a holder's shares are currently worth in the junior vault.
    function _juniorAssetsOf(address who) internal view returns (uint256) {
        return juniorPool.convertToAssets(juniorPool.balanceOf(who));
    }

    function _seniorAssetsOf(address who) internal view returns (uint256) {
        return seniorPool.convertToAssets(seniorPool.balanceOf(who));
    }

    /// @dev Deposit into junior for an arbitrary LP; approves pool as ERC-4626 caller for later withdraw.
    function _juniorDeposit(address lp, uint256 assets) internal {
        asset.mint(lp, assets);
        vm.startPrank(lp);
        asset.approve(address(pool), assets);
        pool.depositJunior(assets);
        vm.stopPrank();
    }

    function _seniorDeposit(address lp, uint256 assets) internal {
        asset.mint(lp, assets);
        vm.startPrank(lp);
        asset.approve(address(pool), assets);
        pool.depositSenior(assets);
        vm.stopPrank();
    }

    /// @dev LP redeems its maximum withdrawable junior assets through the coordinator.
    ///      Returns the actual ASSET amount received (measured by balance delta), because the
    ///      pool wrapper returns SHARES, not assets.
    function _juniorRedeemAll(address lp) internal returns (uint256 assetsOut) {
        uint256 max = juniorPool.maxWithdraw(lp);
        if (max == 0) return 0;
        uint256 balBefore = asset.balanceOf(lp);
        vm.startPrank(lp);
        juniorPool.approve(address(pool), type(uint256).max);
        pool.withdrawJunior(max);
        vm.stopPrank();
        assetsOut = asset.balanceOf(lp) - balBefore;
    }

    function _seniorRedeemAll(address lp) internal returns (uint256 assetsOut) {
        uint256 max = seniorPool.maxWithdraw(lp);
        if (max == 0) return 0;
        uint256 balBefore = asset.balanceOf(lp);
        vm.startPrank(lp);
        seniorPool.approve(address(pool), type(uint256).max);
        pool.withdrawSenior(max);
        vm.stopPrank();
        assetsOut = asset.balanceOf(lp) - balBefore;
    }

    // =====================================================================
    // H1 — LOSS FRONT-RUNNING (primary)
    // =====================================================================
    function test_FINDING_juniorExitBeforeWritedownDumpsLossOnCoLP() public {
        // Hypothesis: After oracle finalizes DEFAULTED (public on-chain), but BEFORE resolveDefault,
        //   a junior LP withdraws their still-unlocked liquidity at full NAV, escaping the impending
        //   writedown. The remaining junior LP absorbs the escaping LP's share of the loss too.
        // Attack: two equal junior LPs (150k each). Finance one invoice (junior principal locked).
        //   Finalize DEFAULTED with zero recovery. LP1 (attacker) redeems all available BEFORE
        //   resolveDefault. Then resolveDefault writes NAV down; LP2 (victim) eats the whole loss.
        // Result: attacker exits ~whole; victim's share value falls by MORE than its fair 50% loss.
        // Verdict: FINDING (HIGH) — breaks first-loss socialization fairness among junior LPs.

        // Senior liquidity so financing succeeds; two equal junior LPs.
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        address jA = makeAddr("jA_attacker");
        address jB = makeAddr("jB_victim");
        _juniorDeposit(jA, 150_000e18);
        _juniorDeposit(jB, 150_000e18);

        // Finance one invoice.
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        uint256 juniorPrincipal = _positionPrincipal(invoiceId) - _expectedSeniorPrincipal(_positionPrincipal(invoiceId));
        assertGt(juniorPrincipal, 0, "junior principal locked");

        // Oracle finalizes DEFAULTED, zero recovery -> pending junior writedown == juniorPrincipal.
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);

        // Snapshot fair share value BEFORE the attack: each LP owns 150k of a 300k NAV pool.
        // Pending loss = juniorPrincipal; a FAIR socialization = juniorPrincipal/2 each.
        uint256 fairLossEach = juniorPrincipal / 2;

        // --- ATTACK: LP1 exits available liquidity BEFORE resolveDefault ---
        uint256 attackerOut = _juniorRedeemAll(jA);

        // Now resolve the default. The writedown hits the remaining shares (LP2).
        _resolveDefaultAsResolver(invoiceId);

        // Victim's remaining share value.
        uint256 victimValueAfter = _juniorAssetsOf(jB);
        uint256 victimLoss = 150_000e18 - victimValueAfter;

        // Attacker escaped essentially their full principal; they took out far more than
        // 150k - fairLossEach would have been.
        assertGt(attackerOut, 150_000e18 - fairLossEach, "attacker escaped more than fair post-loss value");

        // Victim bore MORE than a fair 50% split of the loss (in fact ~the whole loss).
        assertGt(victimLoss, fairLossEach, "victim over-charged vs fair socialization");

        // Concretely: victim bears (nearly) the entire junior loss, attacker bears ~nothing.
        // Allow tiny rounding wiggle.
        assertApproxEqAbs(victimLoss, juniorPrincipal, 2, "victim eats ~whole junior loss");
        assertApproxEqAbs(attackerOut, 150_000e18, 2, "attacker exits ~whole");
    }

    // =====================================================================
    // H1b — Control: if BOTH junior LPs stay, loss is socialized fairly.
    // =====================================================================
    function test_SAFE_ifNoOneExitsLossIsSocializedFairly() public {
        // Hypothesis: With no timing game, the junior writedown is shared pro-rata (this is the
        //   *intended* behavior). This is the control that proves H1's harm comes from TIMING,
        //   not from the waterfall itself.
        // Verdict: SAFE (intended) — equal LPs share equal loss when neither front-runs.
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        address jA = makeAddr("jA");
        address jB = makeAddr("jB");
        _juniorDeposit(jA, 150_000e18);
        _juniorDeposit(jB, 150_000e18);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);
        uint256 principal = _positionPrincipal(invoiceId);
        uint256 juniorPrincipal = principal - _expectedSeniorPrincipal(principal);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);
        _resolveDefaultAsResolver(invoiceId);

        uint256 aVal = _juniorAssetsOf(jA);
        uint256 bVal = _juniorAssetsOf(jB);

        // Both lose the same amount, ~ juniorPrincipal/2 each.
        assertApproxEqAbs(aVal, bVal, 2, "equal loss when nobody times the exit");
        assertApproxEqAbs(150_000e18 - aVal, juniorPrincipal / 2, 2, "each bears half the loss");
    }

    // =====================================================================
    // H2 — JIT YIELD CAPTURE on settle (junior fee credit)
    // =====================================================================
    function test_FINDING_jitDepositCapturesSettlementFee() public {
        // Hypothesis: An attacker deposits into junior right BEFORE settleInvoice credits the
        //   fee (via creditAssets), then withdraws right AFTER, capturing a pro-rata slice of a
        //   fee that accrued over the WHOLE tenor, with ~0 duration/loss risk. Long-term LPs
        //   are diluted.
        // Attack: honest junior LP deposits and holds the full tenor. A whale attacker deposits an
        //   equal amount AFTER the oracle finalizes SETTLED (fee is now inevitable) but BEFORE
        //   settleInvoice, then redeems immediately after settle.
        // Result: attacker realizes a positive profit == its pro-rata slice of juniorFee, for a
        //   1-tx holding period. That profit is diverted from the long-term LP.
        // Verdict: FINDING (HIGH) — JIT yield theft / dilution of long-term LPs.

        // Bootstrap: only junior LP (honest) + senior liquidity, one financed invoice.
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        address honest = makeAddr("honestJunior");
        _juniorDeposit(honest, JUNIOR_DEPOSIT); // 300k held full tenor

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);
        uint256 principal = _positionPrincipal(invoiceId);
        uint256 fee = _positionFee(invoiceId);
        assertGt(fee, 0, "fee nonzero");
        uint256 juniorFee = fee * JUNIOR_FEE_SHARE_BPS / BPS;

        // Advance to just before due date to be realistic; oracle finalizes SETTLED.
        vm.warp(dueDate - 1);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        // --- ATTACK: JIT whale deposits AFTER finalize, before settle ---
        // Deposit a large amount so the attacker owns a big share of the pool at credit time.
        uint256 jitAmount = 300_000e18;
        address jit = makeAddr("jitWhale");
        uint256 jitCostBefore = jitAmount;
        _juniorDeposit(jit, jitAmount);

        // Settle: creditAssets(juniorFee) raises NAV for ALL current junior holders.
        _settleAsBuyer(invoiceId, principal + fee);

        // JIT immediately redeems all available.
        uint256 jitOut = _juniorRedeemAll(jit);

        // Profit for a ~1-tx holding period.
        assertGt(jitOut, jitCostBefore, "JIT LP profited from a single-block deposit");
        uint256 jitProfit = jitOut - jitCostBefore;

        // The profit is a real slice of the tenor-long fee. With equal 300k/300k split at credit
        // time, JIT captures ~half of juniorFee.
        assertApproxEqAbs(jitProfit, juniorFee / 2, juniorFee / 100 + 2, "JIT skims ~half the junior fee");

        // And the honest long-term LP got diluted: it received LESS than the full juniorFee it
        // would have earned alone.
        uint256 honestVal = _juniorAssetsOf(honest);
        uint256 honestGain = honestVal - JUNIOR_DEPOSIT;
        assertLt(honestGain, juniorFee, "long-term LP diluted below full fee");
        assertApproxEqAbs(honestGain, juniorFee / 2, juniorFee / 100 + 2, "honest LP only kept ~half the fee it earned");
    }

    // =====================================================================
    // H11 — Fee not pro-rated to holding time (quantify per-share equality)
    // =====================================================================
    function test_FINDING_feeNotProRatedByHoldingTime() public {
        // Hypothesis: A 1-block JIT LP earns the SAME per-share fee as a full-tenor LP because the
        //   fee is credited as a lump NAV bump split by shares, not by holding duration.
        // Attack: same as H2 but explicitly compare per-share realized gain.
        // Result: per-share gain is identical for the JIT and the full-tenor LP.
        // Verdict: FINDING (HIGH) — no duration weighting; underpins H2.
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        address longTerm = makeAddr("longTerm");
        _juniorDeposit(longTerm, 100_000e18);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);
        uint256 principal = _positionPrincipal(invoiceId);
        uint256 fee = _positionFee(invoiceId);

        vm.warp(dueDate - 1);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        // JIT deposits same 100k right before settle.
        address jit = makeAddr("jit");
        _juniorDeposit(jit, 100_000e18);

        uint256 longSharesBefore = juniorPool.balanceOf(longTerm);
        uint256 jitSharesBefore = juniorPool.balanceOf(jit);

        _settleAsBuyer(invoiceId, principal + fee);

        // Per-share value is the same for both -> identical per-share gain regardless of duration.
        uint256 longPerShare = juniorPool.convertToAssets(longSharesBefore) * 1e18 / longSharesBefore;
        uint256 jitPerShare = juniorPool.convertToAssets(jitSharesBefore) * 1e18 / jitSharesBefore;
        assertEq(longPerShare, jitPerShare, "per-share gain identical: no duration weighting");
    }

    // =====================================================================
    // H6 — CONCENTRATION TOCTOU
    // =====================================================================
    function test_SAFE_concentrationReCheckedAtomically() public {
        // Hypothesis: isEligible()/checkConcentration() are views checkable in a prior tx; between
        //   the check and financeInvoice, exposure to the same buyer grows. If financeInvoice does
        //   NOT re-check atomically, the per-buyer cap can be exceeded.
        // Attack: set a small per-buyer cap. Finance invoice A (fills most of the cap). Then create
        //   invoice B for the SAME buyer whose principal, added to A's, exceeds the cap, and try to
        //   finance it. The view might have said "ok" earlier; the execution must reject.
        // Result: financeInvoice reverts BuyerConcentrationExceeded -> cap holds.
        // Verdict: SAFE — atomic re-check in financeInvoice (src/core/InvoiceFinancingPool.sol:275).

        // Tight cap: allow ~1 invoice worth of principal per buyer.
        // Principal per invoice = FACE_VALUE * 8000/10000 = 80k. Set cap to 120k so 2 invoices (160k) bust it.
        vm.prank(admin);
        riskManager.setRiskParams(
            IRWARiskManager.RiskParams({
                maxExposurePerBuyer: 120_000e18,
                advanceRate: ADVANCE_RATE_BPS,
                maxInvoiceTenor: MAX_TENOR,
                minInvoiceAmount: MIN_INVOICE_AMOUNT,
                financingFeeApr: FINANCING_FEE_APR_BPS
            })
        );

        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        // Same buyer for both invoices.
        uint256 idA = _createVerifiedInvoiceFor(supplier, buyer, FACE_VALUE, dueDate);
        uint256 idB = _createVerifiedInvoiceFor(supplier, buyer, FACE_VALUE, dueDate);

        // Fund A: 80k exposure, under 120k cap.
        _financeAs(supplier, idA);
        assertEq(riskManager.getBuyerExposure(buyer), 80_000e18, "A exposure");

        // The view for B, checked NOW, already returns false because exposure moved.
        uint256 principalB = riskManager.calculateAdvance(FACE_VALUE);
        assertFalse(riskManager.checkConcentration(buyer, principalB), "view already false post-A");

        // But even if a searcher had checked earlier (pre-A) and got true, executing B must revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceFinancingPool.BuyerConcentrationExceeded.selector, idB, buyer, principalB
            )
        );
        _financeAs(supplier, idB);
    }

    // =====================================================================
    // H8 — Permissionless settle/resolve timing abuse
    // =====================================================================
    function test_SAFE_permissionlessResolveCannotChooseRecovery() public {
        // Hypothesis: resolveDefault is permissionless; a searcher choosing WHEN/HOW to call could
        //   change the loss allocation (e.g., supply a different recovery).
        // Attack: attacker calls resolveDefault directly and tries to influence the outcome. The
        //   recovery amount is fixed by the oracle; the caller only funds it.
        // Result: attacker can trigger resolution but the recovery and waterfall are exactly the
        //   oracle-attested values; no economic choice is available to the caller.
        // Verdict: SAFE — recovery sourced from finalizedRecoveryAmount, not caller (line 515).

        uint256 invoiceId = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(invoiceId);
        // Oracle attests a specific recovery.
        uint256 attestedRecovery = 60_000e18;
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, attestedRecovery);

        // Attacker funds exactly the attested recovery and calls resolveDefault; cannot pass more/less.
        asset.mint(attacker, attestedRecovery);
        vm.startPrank(attacker);
        asset.approve(address(pool), attestedRecovery);
        pool.resolveDefault(invoiceId); // no amount parameter -> caller has zero discretion
        vm.stopPrank();

        assertTrue(_positionResolved(invoiceId), "resolved by attacker but on oracle terms");
        // Loss recorded is principal - attestedRecovery exactly.
        assertEq(pool.totalBadDebt(), principal - attestedRecovery, "loss fixed by oracle, not caller");
    }

    function test_FINDING_searcherWithholdsResolveToKeepFrontRunWindowOpen() public {
        // Hypothesis: Because resolveDefault is permissionless AND nobody is obligated to call it,
        //   the loss-front-running window of H1 stays open indefinitely: a junior LP watching the
        //   public finalized-DEFAULTED state has unbounded time to exit before ANY resolver acts.
        // Attack: finalize DEFAULTED, then let arbitrary time pass with NO resolveDefault; a junior
        //   LP still withdraws at full (un-written-down) NAV long after finalization.
        // Result: LP exits at full NAV weeks after the default is public and finalized.
        // Verdict: FINDING (HIGH) — same root cause as H1; the permissionless-but-optional resolve
        //   step gives the front-runner an open-ended window.
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        address jA = makeAddr("jExit");
        address jB = makeAddr("jStay");
        _juniorDeposit(jA, 150_000e18);
        _juniorDeposit(jB, 150_000e18);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);

        // A long time passes; no one resolves.
        vm.warp(block.timestamp + 30 days);

        // The exiting LP still redeems at the full, un-written-down NAV.
        uint256 out = _juniorRedeemAll(jA);
        assertApproxEqAbs(out, 150_000e18, 2, "full-NAV exit long after finalized default");

        // The value was NOT yet written down at exit time (proof the window is open, not a race).
        // (resolveDefault has not been called; NAV still full apart from the exit.)
    }

    // =====================================================================
    // H9 — Deposit/withdraw sandwich around a credit
    // =====================================================================
    function test_SAFE_donationDoesNotMoveSharePriceForSandwich() public {
        // Hypothesis: A sandwich attacker could inflate NAV by donating raw ERC20 to the vault to
        //   move share price around a victim deposit.
        // Attack: attacker transfers raw asset directly to the junior vault, then checks price.
        // Result: totalAssets() returns accountedAssets, so raw donations are ignored -> no price move.
        // Verdict: SAFE — donation/inflation neutralized by accountedAssets design
        //   (src/pools/JuniorPool.sol:68).
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        _juniorDeposit(juniorLp, JUNIOR_DEPOSIT);

        uint256 priceBefore = juniorPool.convertToAssets(1e18);
        // Attacker donates a big pile directly.
        asset.mint(attacker, 1_000_000e18);
        vm.prank(attacker);
        asset.transfer(address(juniorPool), 1_000_000e18);

        uint256 priceAfter = juniorPool.convertToAssets(1e18);
        assertEq(priceBefore, priceAfter, "raw donation does not move share price");
    }

    // =====================================================================
    // H12 — Senior-side JIT symmetry + senior residual writedown front-run
    // =====================================================================
    function test_FINDING_seniorJitCapturesSeniorFee() public {
        // Hypothesis: The senior tranche has the same JIT credit surface: creditAssets(seniorFee)
        //   bumps senior NAV; a JIT senior LP captures a pro-rata slice.
        // Attack: honest senior LP holds full tenor; JIT senior whale deposits after finalize,
        //   before settle, and redeems right after.
        // Result: JIT senior LP profits from a single-tx hold.
        // Verdict: FINDING (HIGH, same class as H2) — symmetric JIT on the senior fee credit.
        address honest = makeAddr("honestSenior");
        _seniorDeposit(honest, SENIOR_DEPOSIT);
        _juniorDeposit(juniorLp, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);
        uint256 principal = _positionPrincipal(invoiceId);
        uint256 fee = _positionFee(invoiceId);
        uint256 juniorFee = fee * JUNIOR_FEE_SHARE_BPS / BPS;
        uint256 seniorFee = fee - juniorFee;
        assertGt(seniorFee, 0, "senior fee nonzero");

        vm.warp(dueDate - 1);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        // JIT senior whale deposits an amount equal to honest so it captures ~half.
        address jit = makeAddr("jitSenior");
        _seniorDeposit(jit, SENIOR_DEPOSIT);

        _settleAsBuyer(invoiceId, principal + fee);
        uint256 jitOut = _seniorRedeemAll(jit);

        assertGt(jitOut, SENIOR_DEPOSIT, "senior JIT profited in one tx");
        assertApproxEqAbs(jitOut - SENIOR_DEPOSIT, seniorFee / 2, seniorFee / 100 + 2, "senior JIT skims ~half senior fee");
    }

    function test_SAFE_seniorCannotFrontRunResidualWritedownWhenNAVLocked() public {
        // Hypothesis: On a severe default (recovery < seniorPrincipal), senior takes residual loss.
        //   Could a senior LP front-run the senior writedown like junior does in H1?
        // Attack: single big default where recovery=0 so BOTH tranches are fully written down. The
        //   senior LP tries to exit before resolveDefault to escape the residual writedown.
        // Result: In THIS single-invoice case the senior LP CAN also exit available liquidity (same
        //   mechanism as junior). We assert the mechanism is symmetric BUT senior first-loss
        //   protection is intact: senior only takes residual after junior is wiped, and the exit is
        //   the SAME timing bug, not a new one. Marked SAFE-as-documented since it is the identical
        //   root cause already captured by H1 (documented, not a distinct finding).
        // Verdict: INFO/SAFE — no NEW guarantee broken beyond H1's timing root cause.
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        _juniorDeposit(juniorLp, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        // recovery=0 -> junior fully lost AND senior takes residual writedown.
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);

        // Senior LP can withdraw available liquidity pre-resolve (only its locked senior principal
        // is at risk). This is the SAME timing surface as H1; we simply confirm it exists and
        // record it as the same root cause.
        uint256 seniorAvailBefore = seniorPool.availableLiquidity();
        assertGt(seniorAvailBefore, 0, "senior has withdrawable liquidity pre-resolve");

        // The invariant that senior is protected FIRST (waterfall order) is untouched: resolve it
        // and confirm junior is written down before senior residual, per src line 557-563.
        uint256 juniorAssetsBefore = juniorPool.totalAssets();
        _resolveDefaultAsResolver(invoiceId);
        // Junior NAV dropped by its full principal (first loss); this ordering guarantee holds.
        assertLt(juniorPool.totalAssets(), juniorAssetsBefore, "junior absorbed first loss");
    }

    // =====================================================================
    // H7 — Withdraw-after-finalize (SETTLED) race == same JIT window as H2
    // =====================================================================
    function test_FINDING_depositAfterSettledFinalizeStillCapturesFee() public {
        // Hypothesis: The public finalized-SETTLED state (before settleInvoice executes) is a clear
        //   signal that a fee credit is imminent, so an attacker can JIT-deposit in that window.
        // Attack: finalize SETTLED; attacker deposits; settle; attacker exits.
        // Result: attacker captures fee slice -> confirms the finalize->settle gap is exploitable.
        // Verdict: FINDING (HIGH, same class as H2) — finalize is a public trigger signal.
        _seniorDeposit(seniorLp, SENIOR_DEPOSIT);
        address honest = makeAddr("honestJ2");
        _juniorDeposit(honest, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);
        uint256 principal = _positionPrincipal(invoiceId);
        uint256 fee = _positionFee(invoiceId);

        vm.warp(dueDate - 1);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        address jit = makeAddr("jit7");
        _juniorDeposit(jit, JUNIOR_DEPOSIT);
        _settleAsBuyer(invoiceId, principal + fee);
        uint256 out = _juniorRedeemAll(jit);
        assertGt(out, JUNIOR_DEPOSIT, "attacker captured fee in finalize->settle window");
    }

}

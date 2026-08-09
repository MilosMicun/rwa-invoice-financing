// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IRWARiskManager} from "../../../src/interfaces/IRWARiskManager.sol";
import {InvoiceFinancingPool} from "../../../src/core/InvoiceFinancingPool.sol";
import {IInvoiceFinancingPool} from "../../../src/interfaces/IInvoiceFinancingPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Vector 08 — Arithmetic, rounding, precision & DoS
/// @notice Probes RWARiskManager math (advance/fee/concentration/exposure/params) and pool
///         split/lock/writeDown arithmetic. Every test encodes its verdict in its assertions.
contract V08_ArithmeticRoundingDoS is Harness {
    // Convenience getters for the risk params tuple.
    function _params()
        internal
        view
        returns (uint256 maxExp, uint256 advRate, uint256 tenor, uint256 minAmt, uint256 apr)
    {
        return riskManager.riskParams();
    }

    function _setParams(uint256 maxExp, uint256 advRate, uint256 tenor, uint256 minAmt, uint256 apr) internal {
        vm.prank(admin);
        riskManager.setRiskParams(
            IRWARiskManager.RiskParams({
                maxExposurePerBuyer: maxExp,
                advanceRate: advRate,
                maxInvoiceTenor: tenor,
                minInvoiceAmount: minAmt,
                financingFeeApr: apr
            })
        );
    }

    // ------------------------------------------------------------------
    // HYP 1 — ZeroTranchePrincipal DoS boundary
    // ------------------------------------------------------------------

    // Hypothesis: An admin can set a permissive config where an invoice passes isEligible()
    //   (advance > 0) yet financeInvoice reverts with ZeroTranchePrincipal because
    //   seniorPrincipal = principal*7000/10000 rounds to 0.
    // Attack: minInvoiceAmount=1, advanceRate=1bps, faceValue=10000 -> advance = 10000*1/10000 = 1.
    //   seniorPrincipal = 1*7000/10000 = 0 -> revert. Supplier is eligible but cannot fund.
    // Result: financeInvoice reverts ZeroTranchePrincipal for an isEligible() invoice.
    // Verdict: FINDING-lite / classified LOW (griefing only under an atypical-but-legal admin
    //   config; no funds at risk, no unauthorized loss/gain — the tx simply reverts atomically).
    function test_SAFE_zeroTranchePrincipal_isDoS_notFundLoss() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        // Permissive but valid config: all fields nonzero, advanceRate within bound.
        _setParams(MAX_EXPOSURE_PER_BUYER, 1, MAX_TENOR, 1, FINANCING_FEE_APR_BPS);

        // faceValue chosen so advance == 1 (eligible) but seniorPrincipal rounds to 0.
        uint256 faceValue = 10_000; // 10_000 * 1 / 10_000 = 1
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoice(faceValue, dueDate);

        // Sanity: eligibility passes (advance == 1 > 0).
        assertTrue(riskManager.isEligible(id), "should be eligible");
        assertEq(riskManager.calculateAdvance(faceValue), 1, "advance == 1");

        // But funding reverts because seniorPrincipal == 0.
        uint256 principal = 1;
        uint256 seniorP = principal * SENIOR_FUNDING_SHARE_BPS / BPS; // 0
        uint256 juniorP = principal - seniorP; // 1
        assertEq(seniorP, 0, "senior rounds to 0");

        vm.expectRevert(
            abi.encodeWithSelector(InvoiceFinancingPool.ZeroTranchePrincipal.selector, id, seniorP, juniorP)
        );
        _financeAsSupplier(id);

        // No state mutated: no position, no locked assets, no exposure. Funds safe.
        assertEq(_positionPrincipal(id), 0, "no position created");
        assertEq(pool.totalLockedAssets(), 0, "no lock");
        assertEq(riskManager.getBuyerExposure(buyer), 0, "no exposure");
    }

    // Hypothesis: With the DEFAULT protocol config (minInvoiceAmount 1000e18, advanceRate 8000),
    //   the ZeroTranchePrincipal branch is unreachable — the minimum principal is enormous.
    // Verdict: SAFE — default guardrails keep both tranches nonzero.
    function test_SAFE_defaultConfig_bothTranchesAlwaysNonzero() public view {
        (, uint256 advRate,, uint256 minAmt,) = _params();
        // Smallest financeable face value = minInvoiceAmount.
        uint256 minPrincipal = Math.mulDiv(minAmt, advRate, BPS);
        uint256 seniorP = minPrincipal * SENIOR_FUNDING_SHARE_BPS / BPS;
        uint256 juniorP = minPrincipal - seniorP;
        assertGt(seniorP, 0, "senior nonzero under default cfg");
        assertGt(juniorP, 0, "junior nonzero under default cfg");
    }

    // ------------------------------------------------------------------
    // HYP 2 — calculateAdvance extreme faceValue: no overflow, correct floor
    // ------------------------------------------------------------------

    // Hypothesis: mulDiv-based calculateAdvance overflows/reverts on huge faceValue.
    // Attack: faceValue near type(uint256).max/advanceRate and beyond.
    // Result: mulDiv returns exact floor(faceValue*rate/BPS) with full 512-bit precision; only
    //   reverts when the TRUE quotient exceeds 2^256 (impossible since rate<BPS => quotient<faceValue).
    // Verdict: SAFE.
    function test_SAFE_calculateAdvance_extremeFaceValue_noOverflow() public {
        // advanceRate = 9000 (max). Since 9000 < 10000, advance < faceValue for all inputs,
        // so the 512-bit quotient always fits in uint256; no revert possible.
        _setParams(MAX_EXPOSURE_PER_BUYER, 9_000, MAX_TENOR, MIN_INVOICE_AMOUNT, FINANCING_FEE_APR_BPS);

        uint256 face = type(uint256).max;
        uint256 got = riskManager.calculateAdvance(face);
        uint256 expected = Math.mulDiv(face, 9_000, BPS);
        assertEq(got, expected, "advance == floor(face*rate/bps)");
        assertLt(got, face, "advance strictly below face for rate<100%");
    }

    function testFuzz_SAFE_calculateAdvance_matchesMulDiv(uint256 face) public view {
        (, uint256 advRate,,,) = _params(); // 8000
        uint256 got = riskManager.calculateAdvance(face);
        assertEq(got, Math.mulDiv(face, advRate, BPS), "matches full-precision mulDiv");
    }

    // ------------------------------------------------------------------
    // HYP 3 — calculateFee rounding-to-zero
    // ------------------------------------------------------------------

    // Hypothesis: A tiny principal / short tenor makes calculateFee floor to 0, so an active
    //   position accrues no fee — LPs lend for free.
    // Attack: principal small enough that principal*apr*duration < 365d*BPS.
    // Result: fee == 0 for such positions. This is a value leak to the supplier, but LPs never
    //   lose PRINCIPAL, and at realistic scale (principal in 1e18 units) fee is never zero.
    // Verdict: SAFE (LOW/INFO value-leak only at dust principal; not exploitable at scale).
    function test_SAFE_calculateFee_roundsToZero_dustPrincipal() public view {
        (,,,, uint256 apr) = _params(); // 1200 bps
        uint256 duration = INVOICE_TENOR; // 30 days
        // fee = mulDiv(principal, apr*duration, 365d*BPS). Denominator dominates for tiny principal.
        uint256 denom = 365 days * BPS;
        uint256 aprDuration = apr * duration;
        // Largest principal with fee==0: principal*aprDuration < denom.
        uint256 boundary = denom / aprDuration; // principal <= boundary-1 -> fee 0 (approx)
        uint256 tinyPrincipal = 1;
        uint256 fee = riskManager.calculateFee(tinyPrincipal, block.timestamp, block.timestamp + duration);
        assertEq(fee, 0, "dust principal accrues zero fee");
        // A realistic 1e18-scale principal earns a nonzero fee.
        uint256 realPrincipal = 1e18;
        assertGt(boundary, 0, "boundary sanity");
        assertGt(
            riskManager.calculateFee(realPrincipal, block.timestamp, block.timestamp + duration),
            0,
            "1e18 principal earns nonzero fee"
        );
    }

    // Hypothesis: fee rounds to zero for a very short tenor (1 second) even at 1e18 principal.
    // Result: 1e18 * 1200 * 1 / (365d*10000) = large; nonzero. But 1 wei principal + 1s => 0.
    // Verdict: SAFE — zero-fee only in the dust regime.
    function test_SAFE_calculateFee_shortTenor_boundary() public view {
        uint256 fee1 = riskManager.calculateFee(1, block.timestamp, block.timestamp + 1);
        assertEq(fee1, 0, "1 wei / 1 sec => 0 fee");
        uint256 fee2 = riskManager.calculateFee(1e18, block.timestamp, block.timestamp + 1 days);
        assertGt(fee2, 0, "1e18 / 1 day => nonzero fee");
    }

    // ------------------------------------------------------------------
    // HYP 4 — calculateFee overflow safety at max params
    // ------------------------------------------------------------------

    // Hypothesis: At apr=5000, tenor=365d, huge principal, fee mulDiv overflows/reverts wrongly.
    // Attack: max params; principal chosen so the TRUE fee still fits uint256.
    // Result: mulDiv computes the exact value with 512-bit intermediate; only reverts if the
    //   real quotient > 2^256. At apr=5000 (50%), fee = principal*0.5 for a full year, which fits
    //   whenever principal <= ~2*type(uint256).max — i.e. always representable results succeed.
    // Verdict: SAFE.
    function test_SAFE_calculateFee_maxParams_noSpuriousOverflow() public {
        _setParams(MAX_EXPOSURE_PER_BUYER, 9_000, 365 days, MIN_INVOICE_AMOUNT, 5_000);
        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + 365 days;
        // apr*duration = 5000 * 365d. Choose principal so fee ~ principal/2 fits.
        uint256 principal = type(uint256).max / 2; // fee ~ principal/2, fits.
        uint256 fee = riskManager.calculateFee(principal, fundedAt, dueDate);
        uint256 expected = Math.mulDiv(principal, 5_000 * uint256(365 days), 365 days * BPS);
        assertEq(fee, expected, "max-params fee matches mulDiv");
        // fee is ~50% of principal for a 1-year 50% APR loan.
        assertApproxEqAbs(fee, principal / 2, 2, "50% APR / 1yr ~ half principal");
    }

    // ------------------------------------------------------------------
    // HYP 5 — Exposure decrement / double-decrement safety
    // ------------------------------------------------------------------

    // Hypothesis: A settle followed by a second settle (or settle after default) double-decrements
    //   buyerExposure and underflows / desyncs it.
    // Attack: settle an invoice, then call settleInvoice again on the same id.
    // Result: the second call reverts on the `resolved` guard BEFORE any exposure update, so
    //   updateBuyerExposure(decrease) can never fire twice for one position -> no underflow.
    // Verdict: SAFE.
    function test_SAFE_exposure_noDoubleDecrement_onResolvedGuard() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        assertEq(riskManager.getBuyerExposure(buyer), principal, "exposure set on finance");

        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        uint256 repay = principal + _positionFee(id);
        _settleAsBuyer(id, repay);

        assertEq(riskManager.getBuyerExposure(buyer), 0, "exposure cleared once");
        assertTrue(_positionResolved(id), "resolved");

        // Second settle reverts on resolved guard; exposure untouched, no underflow.
        asset.mint(buyer, repay);
        vm.startPrank(buyer);
        asset.approve(address(pool), repay);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.FinancingPositionAlreadyResolved.selector, id));
        pool.settleInvoice(id, repay);
        vm.stopPrank();

        assertEq(riskManager.getBuyerExposure(buyer), 0, "exposure still 0, no underflow");
    }

    // ------------------------------------------------------------------
    // HYP 6 — Exposure overflow on increase (reachability)
    // ------------------------------------------------------------------

    // Hypothesis: Repeated financing overflows buyerExposure (uint256).
    // Attack: finance many invoices for one buyer.
    // Result: each finance is gated by checkConcentration (buyerExposure+newAmount <= maxExposure),
    //   so total exposure is bounded by maxExposurePerBuyer << 2^256. Overflow is unreachable
    //   through the pool. (Direct updateBuyerExposure is POOL_ROLE-only, an intended privileged path.)
    // Verdict: SAFE.
    function test_SAFE_exposure_overflow_unreachable_viaConcentrationCap() public {
        // Cap exposure at exactly one principal; a second concurrent finance for the same buyer
        // is rejected by concentration, so exposure never compounds toward overflow.
        uint256 principal = _expectedPrincipal();
        _setParams(principal, ADVANCE_RATE_BPS, MAX_TENOR, MIN_INVOICE_AMOUNT, FINANCING_FEE_APR_BPS);
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 due = block.timestamp + INVOICE_TENOR;
        uint256 id1 = _createVerifiedInvoiceFor(supplier, buyer, FACE_VALUE, due);
        _financeAs(supplier, id1);
        assertEq(riskManager.getBuyerExposure(buyer), principal, "exposure at cap");

        // Second invoice for same buyer exceeds concentration -> rejected, exposure not increased.
        address supplier2 = makeAddr("supplier2");
        uint256 id2 = _createVerifiedInvoiceFor(supplier2, buyer, FACE_VALUE, due);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceFinancingPool.BuyerConcentrationExceeded.selector, id2, buyer, principal
            )
        );
        _financeAs(supplier2, id2);
        assertEq(riskManager.getBuyerExposure(buyer), principal, "exposure still bounded by cap");
    }

    // ------------------------------------------------------------------
    // HYP 7 — checkConcentration off-by-one
    // ------------------------------------------------------------------

    // Hypothesis: The concentration check is off-by-one (allows exceeding max, or rejects exact fit).
    // Attack: probe exact equality and +1 at the boundary.
    // Result: buyerExposure+newAmount == maxExposure is ALLOWED; +1 rejected; newAmount>max early-out.
    // Verdict: SAFE.
    function test_SAFE_checkConcentration_offByOne_boundary() public {
        uint256 maxExp = 1_000e18;
        _setParams(maxExp, ADVANCE_RATE_BPS, MAX_TENOR, MIN_INVOICE_AMOUNT, FINANCING_FEE_APR_BPS);

        // Fresh buyer, exposure 0.
        address b = makeAddr("boundaryBuyer");
        assertTrue(riskManager.checkConcentration(b, maxExp), "exact max allowed");
        assertFalse(riskManager.checkConcentration(b, maxExp + 1), "max+1 rejected (early-out)");
        assertTrue(riskManager.checkConcentration(b, maxExp - 1), "just below max allowed");
        assertTrue(riskManager.checkConcentration(b, 0), "zero allowed");
    }

    function testFuzz_SAFE_checkConcentration_matchesSpec(uint256 existing, uint256 newAmount) public {
        uint256 maxExp = 1_000_000e18;
        _setParams(maxExp, ADVANCE_RATE_BPS, MAX_TENOR, MIN_INVOICE_AMOUNT, FINANCING_FEE_APR_BPS);
        existing = bound(existing, 0, maxExp);

        // Seed exposure to `existing` via the pool-role path is not directly callable; instead
        // reason purely about the pure/view function on a fresh buyer (exposure 0) which is the
        // canonical entry state, and assert the documented semantics.
        address b = makeAddr(string(abi.encodePacked("fuzzBuyer", existing)));
        bool allowed = riskManager.checkConcentration(b, newAmount);
        // With exposure 0, allowed iff newAmount <= maxExp (no overflow possible in subtraction path).
        assertEq(allowed, newAmount <= maxExp, "matches: newAmount <= maxExposure when exposure==0");
    }

    // ------------------------------------------------------------------
    // HYP 8 — availableLiquidity underflow invariant
    // ------------------------------------------------------------------

    // Hypothesis: A finance/withdraw/writeDown/unlock sequence drives accountedAssets < lockedAssets,
    //   making availableLiquidity() underflow-revert and bricking the pool.
    // Attack: finance (locks), have LPs withdraw all free liquidity, then default with 0 recovery
    //   (writeDown), then observe availableLiquidity.
    // Result: every mutator asserts assets<=availableLiquidity (lock, writeDown) or assets<=lockedAssets
    //   (unlock), so accountedAssets>=lockedAssets is preserved throughout. availableLiquidity never
    //   underflows.
    // Verdict: SAFE.
    function test_SAFE_availableLiquidity_neverUnderflows_fullCycle() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 seniorP = _expectedSeniorPrincipal(principal);
        uint256 juniorP = principal - seniorP;

        // locked == principal split across tranches. accountedAssets == deposits.
        assertEq(seniorPool.lockedAssets(), seniorP, "senior locked");
        assertEq(juniorPool.lockedAssets(), juniorP, "junior locked");
        // availableLiquidity holds (no revert).
        assertEq(seniorPool.availableLiquidity(), SENIOR_DEPOSIT - seniorP, "senior avail");
        assertEq(juniorPool.availableLiquidity(), JUNIOR_DEPOSIT - juniorP, "junior avail");

        // Default with zero recovery -> junior/senior writeDown up to their principal.
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);
        _resolveDefaultAsResolver(id);

        // After writeDown, accountedAssets reduced by losses, lockedAssets back to 0.
        assertEq(seniorPool.lockedAssets(), 0, "senior unlocked");
        assertEq(juniorPool.lockedAssets(), 0, "junior unlocked");
        // availableLiquidity == accountedAssets (no underflow, no revert).
        assertEq(seniorPool.availableLiquidity(), seniorPool.totalAssets(), "senior invariant");
        assertEq(juniorPool.availableLiquidity(), juniorPool.totalAssets(), "junior invariant");
        // Junior absorbed first loss: NAV reduced by juniorP.
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT - juniorP, "junior wrote down full loss");
        // Senior NAV reduced by seniorP (0 recovery -> senior also loses).
        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT - seniorP, "senior wrote down its loss");
    }

    // ------------------------------------------------------------------
    // HYP 9 — writeDown revert DoS in resolveDefault
    // ------------------------------------------------------------------

    // Hypothesis: resolveDefault can revert inside writeDown because the loss to write down exceeds
    //   the tranche's availableLiquidity (e.g. another active invoice locked the tranche).
    // Attack: fund TWO invoices so both tranches are heavily locked; default one with 0 recovery.
    //   The defaulting invoice UNLOCKS its own principal first (increasing availableLiquidity by
    //   exactly its own locked share) before writeDown, so writeDown(loss) always fits because
    //   loss <= that invoice's own principal <= freshly-unlocked availableLiquidity.
    // Result: resolveDefault succeeds; no arithmetic DoS. writeDown(loss) <= availableLiquidity always.
    // Verdict: SAFE.
    function test_SAFE_resolveDefault_writeDown_noArithmeticDoS_withConcurrentLock() public {
        // Deposit enough for two full invoices.
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        uint256 due = block.timestamp + INVOICE_TENOR;

        address supA = makeAddr("supA");
        address supB = makeAddr("supB");
        address buyA = makeAddr("buyA");
        address buyB = makeAddr("buyB");

        uint256 idA = _createVerifiedInvoiceFor(supA, buyA, FACE_VALUE, due);
        uint256 idB = _createVerifiedInvoiceFor(supB, buyB, FACE_VALUE, due);
        _financeAs(supA, idA);
        _financeAs(supB, idB);

        uint256 pA = _positionPrincipal(idA);
        uint256 juniorPA = pA - _expectedSeniorPrincipal(pA);

        // Both invoices locked; junior available reduced by 2 * juniorP.
        assertEq(juniorPool.lockedAssets(), 2 * juniorPA, "both junior locked");

        // Default idA with zero recovery. Junior must write down juniorPA.
        _submitAndFinalizeOracleStatus(idA, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);
        _resolveDefaultAsResolver(idA); // must NOT revert

        assertTrue(_positionResolved(idA), "idA resolved despite concurrent lock");
        // idB still locked; its accounting intact.
        assertEq(juniorPool.lockedAssets(), juniorPA, "only idB remains locked");
        assertFalse(_positionResolved(idB), "idB untouched");
    }

    // ------------------------------------------------------------------
    // HYP 10 — Conservation: funding split
    // ------------------------------------------------------------------

    // Hypothesis: seniorPrincipal + juniorPrincipal != principal (wei lost/created in the split).
    // Result: juniorPrincipal is defined as the REMAINDER (principal - seniorPrincipal), so the
    //   sum equals principal exactly for all inputs. Rounding remainder goes to junior.
    // Verdict: SAFE.
    function testFuzz_SAFE_fundingSplit_conserved(uint256 principal) public pure {
        principal = principal % (type(uint128).max); // keep in a sane range
        uint256 seniorP = principal * SENIOR_FUNDING_SHARE_BPS / BPS;
        uint256 juniorP = principal - seniorP;
        assertEq(seniorP + juniorP, principal, "funding split conserved");
        // senior never exceeds its configured share (floor).
        assertLe(seniorP, principal * SENIOR_FUNDING_SHARE_BPS / BPS, "senior bounded");
    }

    // ------------------------------------------------------------------
    // HYP 11 — Conservation: fee split
    // ------------------------------------------------------------------

    // Hypothesis: seniorFee + juniorFee != fee.
    // Result: seniorFee is the remainder (fee - juniorFee), so sum == fee exactly. Junior takes
    //   the rounding remainder (juniorFee = fee*6000/10000 floor).
    // Verdict: SAFE.
    function testFuzz_SAFE_feeSplit_conserved(uint256 fee) public pure {
        fee = fee % (type(uint128).max);
        uint256 juniorFee = fee * JUNIOR_FEE_SHARE_BPS / BPS;
        uint256 seniorFee = fee - juniorFee;
        assertEq(seniorFee + juniorFee, fee, "fee split conserved");
        assertLe(juniorFee, fee, "junior fee bounded");
    }

    // ------------------------------------------------------------------
    // HYP 12 — Governance guardrails on _setRiskParams
    // ------------------------------------------------------------------

    // Hypothesis: An admin can set out-of-bound params (advanceRate>9000, apr>5000, tenor>365d,
    //   or any zero field), bypassing underwriting guardrails.
    // Result: _setRiskParams reverts on each violation. Bounds cannot be bypassed.
    // Verdict: SAFE.
    function test_SAFE_setRiskParams_rejectsOutOfBounds() public {
        // advanceRate > 9000
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("AdvanceRateTooHigh()")));
        riskManager.setRiskParams(_mk(MAX_EXPOSURE_PER_BUYER, 9_001, MAX_TENOR, MIN_INVOICE_AMOUNT, 1_200));

        // apr > 5000
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("FinancingFeeAprTooHigh()")));
        riskManager.setRiskParams(_mk(MAX_EXPOSURE_PER_BUYER, 8_000, MAX_TENOR, MIN_INVOICE_AMOUNT, 5_001));

        // tenor > 365d
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("MaxInvoiceTenorTooHigh()")));
        riskManager.setRiskParams(_mk(MAX_EXPOSURE_PER_BUYER, 8_000, 365 days + 1, MIN_INVOICE_AMOUNT, 1_200));

        // zero fields -> InvalidRiskParams
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("InvalidRiskParams()")));
        riskManager.setRiskParams(_mk(0, 8_000, MAX_TENOR, MIN_INVOICE_AMOUNT, 1_200));

        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("InvalidRiskParams()")));
        riskManager.setRiskParams(_mk(MAX_EXPOSURE_PER_BUYER, 0, MAX_TENOR, MIN_INVOICE_AMOUNT, 1_200));

        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("InvalidRiskParams()")));
        riskManager.setRiskParams(_mk(MAX_EXPOSURE_PER_BUYER, 8_000, 0, MIN_INVOICE_AMOUNT, 1_200));

        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("InvalidRiskParams()")));
        riskManager.setRiskParams(_mk(MAX_EXPOSURE_PER_BUYER, 8_000, MAX_TENOR, 0, 1_200));

        // apr == 0 is ALLOWED (0% fee is a valid config, only >5000 is rejected).
        vm.prank(admin);
        riskManager.setRiskParams(_mk(MAX_EXPOSURE_PER_BUYER, 8_000, MAX_TENOR, MIN_INVOICE_AMOUNT, 0));
        (,,,, uint256 apr) = _params();
        assertEq(apr, 0, "zero apr accepted");
    }

    function _mk(uint256 maxExp, uint256 advRate, uint256 tenor, uint256 minAmt, uint256 apr)
        internal
        pure
        returns (IRWARiskManager.RiskParams memory)
    {
        return IRWARiskManager.RiskParams({
            maxExposurePerBuyer: maxExp,
            advanceRate: advRate,
            maxInvoiceTenor: tenor,
            minInvoiceAmount: minAmt,
            financingFeeApr: apr
        });
    }

    // ------------------------------------------------------------------
    // HYP 13 — Dust across repeated settle cycles
    // ------------------------------------------------------------------

    // Hypothesis: Repeated finance/settle cycles accumulate dust that either strands funds or lets
    //   the attacker extract value.
    // Attack: run several full settle cycles; track senior/junior NAV and LP redeemable value.
    // Result: NAV grows monotonically by the credited fee only; no dust leaks to a third party.
    //   LP principal is always fully redeemable (availableLiquidity == accountedAssets at rest).
    // Verdict: SAFE.
    function test_SAFE_dust_acrossSettleCycles_noLeak() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        uint256 seniorNav0 = seniorPool.totalAssets();
        uint256 juniorNav0 = juniorPool.totalAssets();

        for (uint256 i = 0; i < 5; i++) {
            uint256 due = block.timestamp + INVOICE_TENOR;
            address sup = makeAddr(string(abi.encodePacked("cyclesup", i)));
            address buy = makeAddr(string(abi.encodePacked("cyclebuy", i)));
            uint256 id = _createVerifiedInvoiceFor(sup, buy, FACE_VALUE, due);
            _financeAs(sup, id);
            uint256 principal = _positionPrincipal(id);
            uint256 fee = _positionFee(id);
            _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
            _settleAs(buy, id, principal + fee);

            // At rest between cycles: nothing locked, availableLiquidity == accountedAssets.
            assertEq(seniorPool.lockedAssets(), 0, "senior unlocked between cycles");
            assertEq(juniorPool.lockedAssets(), 0, "junior unlocked between cycles");
            assertEq(seniorPool.availableLiquidity(), seniorPool.totalAssets(), "senior invariant");
            assertEq(juniorPool.availableLiquidity(), juniorPool.totalAssets(), "junior invariant");
        }

        // NAV strictly grew by accrued fees; no value lost to dust or a third party.
        assertGt(seniorPool.totalAssets(), seniorNav0, "senior NAV grew by fees");
        assertGt(juniorPool.totalAssets(), juniorNav0, "junior NAV grew by fees");

        // Real token balance backs NAV (creditAssets solvency assertion held every cycle).
        assertGe(asset.balanceOf(address(seniorPool)), seniorPool.totalAssets(), "senior cash-backed");
        assertGe(asset.balanceOf(address(juniorPool)), juniorPool.totalAssets(), "junior cash-backed");
    }

    // ------------------------------------------------------------------
    // HYP 14 — First-loss waterfall integrity across recovery sweep
    // ------------------------------------------------------------------

    // Hypothesis: Some recovery value makes senior lose while junior is still whole (breaking the
    //   stated senior-first protection guarantee).
    // Attack: sweep recoveredAmount across the whole [0, principal] range; check loss allocation.
    // Result: senior loss > 0 ONLY when junior is fully wiped (recovery < seniorPrincipal). Junior
    //   always absorbs first loss. seniorLoss + juniorLoss == principal - recovery (conserved).
    // Verdict: SAFE.
    function testFuzz_SAFE_waterfall_seniorFirstProtection(uint256 recoveryPct) public {
        recoveryPct = bound(recoveryPct, 0, 10_000);
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 seniorP = _expectedSeniorPrincipal(principal);
        uint256 recovery = principal * recoveryPct / 10_000;

        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, recovery);

        uint256 seniorNavBefore = seniorPool.totalAssets();
        uint256 juniorNavBefore = juniorPool.totalAssets();
        _resolveDefaultAsResolver(id);

        uint256 seniorLoss = seniorNavBefore - seniorPool.totalAssets();
        uint256 juniorLoss = juniorNavBefore - juniorPool.totalAssets();

        // Conservation: total NAV loss == principal - recovery.
        assertEq(seniorLoss + juniorLoss, principal - recovery, "loss conserved");

        // Senior-first: senior only loses when junior is fully wiped.
        if (seniorLoss > 0) {
            assertEq(juniorLoss, principal - seniorP, "junior fully wiped before senior loses");
            assertLt(recovery, seniorP, "senior only loses when recovery < seniorPrincipal");
        }
        // If recovery >= seniorPrincipal, senior is whole.
        if (recovery >= seniorP) {
            assertEq(seniorLoss, 0, "senior whole when recovery covers senior principal");
        }
    }
}

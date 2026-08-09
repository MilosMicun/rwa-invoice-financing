// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {SeniorPool} from "../../../src/pools/SeniorPool.sol";
import {JuniorPool} from "../../../src/pools/JuniorPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Vector 01 — ERC-4626 vault accounting & share-price manipulation
/// @notice Probes SeniorPool/JuniorPool ERC-4626 vaults + InvoiceFinancingPool wrappers.
/// @dev All tests inherit the shared Harness (default MockERC20 asset). Each test encodes
///      its verdict in assertions. SAFE = the defense holds; FINDING = exploit succeeds.
contract VaultAccounting is Harness {
    // ---------------------------------------------------------------------
    // H1 — First-depositor donation inflation attack
    // ---------------------------------------------------------------------
    // Hypothesis: attacker deposits 1 wei, donates a large raw token amount to the
    //   vault, victim deposits and is rounded to ~0 shares; attacker redeems and steals.
    // Attack: 1-wei deposit + direct ERC20 transfer of 1e24 to the vault, then a
    //   1_000e18 victim deposit.
    // Result: donation does NOT move totalAssets()/convertToShares; victim gets fair
    //   shares. Attacker cannot steal.
    // Verdict: SAFE (totalAssets()=accountedAssets; SeniorPool.sol:68-70).
    function test_SAFE_H1_donationInflationDoesNotMovePrice() public {
        // Attacker seeds 1 wei of shares.
        _depositSenior(attacker, 1);
        assertEq(seniorPool.totalAssets(), 1, "NAV should be exactly the 1 wei deposit");

        // Attacker donates a huge amount directly to the vault (raw ERC20 push).
        uint256 donation = 1_000_000e18;
        asset.mint(attacker, donation);
        vm.prank(attacker);
        asset.transfer(address(seniorPool), donation);

        // NAV is untouched by the donation.
        assertEq(seniorPool.totalAssets(), 1, "donation must NOT change accountedAssets/NAV");

        // Victim deposits 1000e18. Because NAV=1 and supply=1, victim gets ~1000e18 shares.
        uint256 victimAssets = 1_000e18;
        _depositSenior(seniorLp, victimAssets);
        uint256 victimShares = seniorPool.balanceOf(seniorLp);

        // Victim must retain essentially all of their value (fair mint), not lose it to attacker.
        uint256 victimRedeemable = seniorPool.convertToAssets(victimShares);
        assertApproxEqAbs(victimRedeemable, victimAssets, 2, "victim keeps their deposit value");

        // Attacker's 1 wei share is still worth ~1 wei of NAV (they did NOT capture victim funds).
        uint256 attackerRedeemable = seniorPool.convertToAssets(seniorPool.balanceOf(attacker));
        assertLe(attackerRedeemable, 2, "attacker gains nothing from the donation");
    }

    // ---------------------------------------------------------------------
    // H2 — NAV moves ONLY through creditAssets (onlyPool), never raw pushes
    // ---------------------------------------------------------------------
    // Hypothesis: a raw ERC20 push cannot inflate NAV; only settlement yield (creditAssets) can.
    // Attack: push tokens, compare price; then run a genuine settlement and check NAV delta == fee.
    // Result: price flat after push; NAV increases by exactly the credited fee after settlement.
    // Verdict: SAFE (creditAssets onlyPool, SeniorPool.sol:164; totalAssets uses accountedAssets).
    function test_SAFE_H2_navMovesOnlyViaCreditAssets() public {
        uint256 id = _bootstrapFundedInvoice();

        uint256 seniorNavBefore = seniorPool.totalAssets();
        uint256 juniorNavBefore = juniorPool.totalAssets();

        // Raw push to both vaults changes nothing about NAV.
        asset.mint(address(this), 500_000e18);
        asset.transfer(address(seniorPool), 250_000e18);
        asset.transfer(address(juniorPool), 250_000e18);
        assertEq(seniorPool.totalAssets(), seniorNavBefore, "raw push must not move senior NAV");
        assertEq(juniorPool.totalAssets(), juniorNavBefore, "raw push must not move junior NAV");

        // Now genuine settlement: NAV grows by exactly the split fee.
        uint256 fee = _positionFee(id);
        uint256 principal = _positionPrincipal(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAsBuyer(id, principal + fee);

        uint256 juniorFee = fee * JUNIOR_FEE_SHARE_BPS / BPS;
        uint256 seniorFee = fee - juniorFee;

        assertEq(seniorPool.totalAssets(), seniorNavBefore + seniorFee, "senior NAV grew by exactly seniorFee");
        assertEq(juniorPool.totalAssets(), juniorNavBefore + juniorFee, "junior NAV grew by exactly juniorFee");
    }

    // ---------------------------------------------------------------------
    // H3 — NAV-to-(near)-zero share explosion after full writeDown
    // ---------------------------------------------------------------------
    // Hypothesis: drive junior NAV toward zero via a default writeDown, then a fresh
    //   depositor over-mints and steals from... someone.
    // Attack: default with 0 recovery on a large invoice, then a new junior LP deposits.
    // Result: junior NAV drops by the junior loss (legit first-loss). The +1 virtual
    //   asset prevents divide-by-zero. New depositor mints against the reduced price;
    //   existing junior holder is NOT further harmed by the new deposit.
    // Verdict: SAFE (writeDown reduces NAV = intended first-loss; OZ +1 offset).
    function test_SAFE_H3_navToZeroNoShareExplosionTheft() public {
        uint256 id = _bootstrapFundedInvoice();

        // Existing junior LP holds shares; capture pre-default redeemable value.
        uint256 juniorShares = juniorPool.balanceOf(juniorLp);

        // Full default, zero recovery: junior absorbs first loss (writeDown).
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);
        _resolveDefaultAsResolver(id);

        uint256 juniorNavAfterDefault = juniorPool.totalAssets();
        assertGt(juniorNavAfterDefault, 0, "NAV still positive (only one invoice defaulted)");

        // Redeemable value of the existing junior holder immediately after default.
        uint256 existingRedeemableBefore = juniorPool.convertToAssets(juniorShares);

        // A fresh junior LP now deposits into the reduced-price vault.
        address newLp = makeAddr("newJuniorLp");
        _depositJunior(newLp, 100_000e18);

        // The new deposit must NOT reduce the existing holder's redeemable value.
        uint256 existingRedeemableAfter = juniorPool.convertToAssets(juniorShares);
        assertGe(
            existingRedeemableAfter,
            existingRedeemableBefore,
            "new depositor cannot dilute existing junior holder"
        );

        // The new LP gets a fair claim: their redeemable value approx equals what they put in.
        uint256 newLpRedeemable = juniorPool.convertToAssets(juniorPool.balanceOf(newLp));
        assertApproxEqRel(newLpRedeemable, 100_000e18, 1e14, "new LP mint is fair"); // 0.01%
    }

    // ---------------------------------------------------------------------
    // H4 — Deposit/withdraw round-trip rounding extraction
    // ---------------------------------------------------------------------
    // Hypothesis: repeated deposit-then-withdraw lets an attacker extract value or
    //   grief NAV via floor/ceil rounding.
    // Attack: seed a productive vault (existing LP + credited yield), then loop
    //   attacker deposit(x)+withdraw(x) 20 times; measure attacker net and LP value.
    // Result: attacker never ends up richer than they started; existing LP value never drops.
    // Verdict: SAFE (rounding always favors the vault via OZ virtual shares).
    function test_SAFE_H4_roundTripRoundingNoExtraction() public {
        // Establish a vault with a non-trivial, non-1:1 price via real yield.
        uint256 id = _bootstrapFundedInvoice();
        uint256 fee = _positionFee(id);
        uint256 principal = _positionPrincipal(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAsBuyer(id, principal + fee);

        uint256 seniorLpValueBefore = seniorPool.convertToAssets(seniorPool.balanceOf(seniorLp));

        // Fund the attacker generously and let them thrash the vault. Deposit the
        // attacker's *current* balance each round so a per-round rounding loss (proof of
        // the defense) does not cause a spurious InsufficientBalance revert.
        uint256 seed = 10_000e18;
        asset.mint(attacker, seed);
        uint256 attackerBalBefore = asset.balanceOf(attacker);

        for (uint256 i = 0; i < 20; i++) {
            vm.startPrank(attacker);
            uint256 depositAmt = asset.balanceOf(attacker);
            if (depositAmt == 0) {
                vm.stopPrank();
                break;
            }
            asset.approve(address(pool), depositAmt);
            uint256 shares = pool.depositSenior(depositAmt);
            // Withdraw everything the attacker can (bounded by their own shares' value).
            uint256 redeemable = seniorPool.convertToAssets(shares);
            seniorPool.approve(address(pool), shares);
            if (redeemable > 0) {
                pool.withdrawSenior(redeemable);
            }
            vm.stopPrank();
        }

        // Clean up any residual shares to realize final position.
        vm.startPrank(attacker);
        uint256 residual = seniorPool.balanceOf(attacker);
        if (residual > 0) {
            uint256 red = seniorPool.convertToAssets(residual);
            seniorPool.approve(address(pool), residual);
            if (red > 0) pool.withdrawSenior(red);
        }
        vm.stopPrank();

        uint256 attackerBalAfter = asset.balanceOf(attacker);

        // Attacker cannot profit from round-trip rounding.
        assertLe(attackerBalAfter, attackerBalBefore, "attacker must not profit from round trips");

        // Existing LP is not griefed downward.
        uint256 seniorLpValueAfter = seniorPool.convertToAssets(seniorPool.balanceOf(seniorLp));
        assertGe(seniorLpValueAfter, seniorLpValueBefore, "existing LP value not reduced by attacker thrash");
    }

    // ---------------------------------------------------------------------
    // H5 — maxWithdraw / locked-liquidity bypass
    // ---------------------------------------------------------------------
    // Hypothesis: an LP can withdraw more than availableLiquidity (touching locked capital).
    // Attack: finance an invoice to lock NAV, then try to withdraw availableLiquidity+1.
    // Result: both direct-vault and coordinator paths revert; maxWithdraw is bounded.
    // Verdict: SAFE (_withdraw guard SeniorPool.sol:217; maxWithdraw:78-86).
    function test_SAFE_H5_maxWithdrawLockedLiquidityBypass() public {
        _bootstrapFundedInvoice();

        uint256 avail = seniorPool.availableLiquidity();
        uint256 seniorMax = seniorPool.maxWithdraw(seniorLp);
        assertLe(seniorMax, avail, "maxWithdraw cannot exceed availableLiquidity");

        // Direct vault withdraw of avail+1 must revert (ExceededMaxWithdraw).
        vm.prank(seniorLp);
        vm.expectRevert();
        seniorPool.withdraw(avail + 1, seniorLp, seniorLp);

        // Coordinator path: LP approves shares, tries to over-withdraw -> revert.
        vm.startPrank(seniorLp);
        seniorPool.approve(address(pool), type(uint256).max);
        vm.expectRevert();
        pool.withdrawSenior(avail + 1);
        vm.stopPrank();

        // Sanity: withdrawing exactly availableLiquidity succeeds.
        vm.startPrank(seniorLp);
        pool.withdrawSenior(avail);
        vm.stopPrank();
        assertEq(seniorPool.availableLiquidity(), 0, "available fully drained, locked untouched");
    }

    // ---------------------------------------------------------------------
    // H6 — Withdrawing donated / extra cash that is not the LP's NAV
    // ---------------------------------------------------------------------
    // Hypothesis: after a raw donation increases cash, an LP can withdraw more than
    //   their NAV entitlement (i.e. steal the donation).
    // Attack: single senior LP, donate 1e24 to vault, attempt withdraw > convertToAssets(shares).
    // Result: withdraw is bounded by the LP's share-implied assets; donation is unclaimable.
    // Verdict: SAFE (donation not in accountedAssets; convertToAssets caps entitlement).
    function test_SAFE_H6_cannotWithdrawDonatedCash() public {
        _depositSenior(seniorLp, 100_000e18);
        uint256 shares = seniorPool.balanceOf(seniorLp);
        uint256 entitlement = seniorPool.convertToAssets(shares);

        // Big donation to the vault (cash balance now far exceeds NAV).
        asset.mint(address(this), 1_000_000e18);
        asset.transfer(address(seniorPool), 1_000_000e18);

        // Entitlement (NAV-based) is unchanged by the donation.
        assertEq(seniorPool.convertToAssets(shares), entitlement, "donation not reflected in NAV entitlement");

        // Try to withdraw more than entitlement -> revert.
        vm.startPrank(seniorLp);
        seniorPool.approve(address(pool), type(uint256).max);
        vm.expectRevert();
        pool.withdrawSenior(entitlement + 1);
        vm.stopPrank();

        // Withdraw exactly entitlement succeeds and returns only entitlement.
        uint256 balBefore = asset.balanceOf(seniorLp);
        vm.startPrank(seniorLp);
        pool.withdrawSenior(entitlement);
        vm.stopPrank();
        assertEq(asset.balanceOf(seniorLp) - balBefore, entitlement, "LP got exactly their NAV, not the donation");

        // The donation remains stranded in the vault (not stealable by this LP), NAV now 0.
        assertEq(seniorPool.totalAssets(), 0, "NAV drained to zero; donation still sitting as raw balance");
        assertGe(asset.balanceOf(address(seniorPool)), 1_000_000e18, "donation stays as raw balance");
    }

    // ---------------------------------------------------------------------
    // H7 — Dust minting: sub-price deposit into a price>1 vault mints 0 shares
    // ---------------------------------------------------------------------
    // Hypothesis: when share price > 1 (NAV grew via yield), a dust deposit smaller than
    //   the price mints 0 shares and the depositor's dust is stolen by existing holders,
    //   or lets an attacker grief.
    // Attack: raise price above 1 via real yield, then deposit a dust amount (< price)
    //   that rounds to 0 shares; check shares==0 and who benefits.
    // Result: attacker self-griefs the dust (donates it to the pool); existing holders gain
    //   at most the dust amount total. Only the attacker is harmed — not a theft vector.
    // Verdict: SAFE / INFO (self-grief dust; economically irrational).
    function test_SAFE_H7_dustMintSelfGriefOnly() public {
        // Build a vault with price > 1 by realizing yield through a full settlement.
        uint256 id = _bootstrapFundedInvoice();
        uint256 fee = _positionFee(id);
        uint256 principal = _positionPrincipal(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAsBuyer(id, principal + fee);

        // Sanity: senior share price is now strictly above 1 (NAV > supply).
        assertGt(seniorPool.totalAssets(), seniorPool.totalSupply(), "price must exceed 1:1 for dust test");

        uint256 lpValueBefore = seniorPool.convertToAssets(seniorPool.balanceOf(seniorLp));

        // Dust deposit strictly below the marginal cost of 1 share => rounds to 0 shares.
        // convertToShares(dust) with dust=1 wei and NAV>>1 floors to 0.
        uint256 dust = 1;
        asset.mint(attacker, dust);
        vm.startPrank(attacker);
        asset.approve(address(pool), dust);
        uint256 shares = pool.depositSenior(dust);
        vm.stopPrank();

        assertEq(shares, 0, "sub-price dust mints 0 shares");
        assertEq(seniorPool.balanceOf(attacker), 0, "attacker owns no shares");

        // Attacker's dust is unrecoverable but only benefits existing LP by <= dust of NAV.
        uint256 lpValueAfter = seniorPool.convertToAssets(seniorPool.balanceOf(seniorLp));
        assertGe(lpValueAfter, lpValueBefore, "existing LP value did not decrease");
        assertLe(lpValueAfter - lpValueBefore, dust, "existing LP gains at most the dust (attacker self-grief)");
    }

    // ---------------------------------------------------------------------
    // H8 — Later depositor after a writeDown-reduced price
    // ---------------------------------------------------------------------
    // Hypothesis: after a partial default lowers junior price, the next depositor is
    //   diluted beyond legitimate first-loss OR can dilute existing holders.
    // Attack: partial default (junior partly written down), new LP deposits.
    // Result: new LP buys at the reduced price and receives fair value; existing holders
    //   are not harmed. First-loss was already realized before the new deposit.
    // Verdict: SAFE.
    function test_SAFE_H8_depositAfterWriteDownIsFair() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);

        // Partial recovery: recovery = seniorPrincipal exactly, so junior takes full loss,
        // senior takes none (senior-first waterfall).
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, seniorPrincipal);
        _resolveDefaultAsResolver(id);

        // Senior NAV should be intact (protected); junior NAV reduced by junior principal.
        // Existing junior holder redeemable value at the new (reduced) price.
        uint256 existingShares = juniorPool.balanceOf(juniorLp);
        uint256 existingBefore = juniorPool.convertToAssets(existingShares);

        address newLp = makeAddr("lateJuniorLp");
        _depositJunior(newLp, 50_000e18);

        // Existing holder not diluted by the new deposit.
        uint256 existingAfter = juniorPool.convertToAssets(existingShares);
        assertGe(existingAfter, existingBefore, "existing junior holder not diluted by later depositor");

        // New LP gets fair value for what they deposited.
        uint256 newVal = juniorPool.convertToAssets(juniorPool.balanceOf(newLp));
        assertApproxEqRel(newVal, 50_000e18, 1e14, "late depositor buys in fairly at reduced price");
    }

    // ---------------------------------------------------------------------
    // H9 — Privileged NAV mutators are not externally reachable
    // ---------------------------------------------------------------------
    // Hypothesis: a non-pool caller can call creditAssets/writeDown/lock/unlock/fundInvoice
    //   directly to inflate/deflate NAV or drain cash.
    // Attack: attacker calls each privileged function directly on both vaults.
    // Result: every call reverts NotInvoiceFinancingPool.
    // Verdict: SAFE (onlyInvoiceFinancingPool, SeniorPool.sol:96/111/129/164/187).
    function test_SAFE_H9_privilegedMutatorsNotExternallyReachable() public {
        _depositSenior(seniorLp, 100_000e18);

        vm.startPrank(attacker);
        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.creditAssets(1e18);

        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.writeDown(1e18);

        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.lockAssets(1e18);

        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.unlockAssets(1e18);

        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.fundInvoice(attacker, 1e18);
        vm.stopPrank();

        // Junior vault too.
        vm.startPrank(attacker);
        vm.expectRevert(JuniorPool.NotInvoiceFinancingPool.selector);
        juniorPool.creditAssets(1e18);
        vm.stopPrank();

        // NAV unchanged.
        assertEq(seniorPool.totalAssets(), 100_000e18, "NAV untouched by failed privileged calls");
    }

    // ---------------------------------------------------------------------
    // H10 — Direct ERC-4626 entry/exit bypassing the coordinator
    // ---------------------------------------------------------------------
    // Hypothesis: calling seniorPool.deposit/withdraw directly (no coordinator) breaks
    //   a coordinator invariant or lets the caller escape locked-liquidity limits.
    // Attack: attacker deposits directly, then withdraws directly; also try over-withdraw.
    // Result: direct entry/exit is ERC-4626 self-consistent; NAV correct; locked liquidity
    //   still protected by the vault's own _withdraw guard.
    // Verdict: SAFE (coordinator is convenience; vault enforces its own accounting).
    function test_SAFE_H10_directEntryExitConsistent() public {
        // Direct deposit (bypass coordinator).
        uint256 amt = 100_000e18;
        asset.mint(attacker, amt);
        vm.startPrank(attacker);
        asset.approve(address(seniorPool), amt);
        uint256 shares = seniorPool.deposit(amt, attacker);
        vm.stopPrank();

        assertEq(seniorPool.totalAssets(), amt, "NAV reflects direct deposit");
        assertEq(seniorPool.convertToAssets(shares), amt, "shares worth the deposit");

        // Lock most of it via a real financing so availableLiquidity < NAV.
        // Need a second LP for junior side; use harness bootstrap-style manual wiring.
        _depositJunior(juniorLp, JUNIOR_DEPOSIT);
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(id);

        uint256 avail = seniorPool.availableLiquidity();

        // Direct over-withdraw is still blocked.
        vm.prank(attacker);
        vm.expectRevert();
        seniorPool.withdraw(avail + 1, attacker, attacker);

        // Direct withdraw of available amount works and reduces NAV correctly.
        uint256 navBefore = seniorPool.totalAssets();
        vm.prank(attacker);
        seniorPool.withdraw(avail, attacker, attacker);
        assertEq(seniorPool.totalAssets(), navBefore - avail, "NAV reduced by exactly withdrawn amount");
    }

    // ---------------------------------------------------------------------
    // H11 — availableLiquidity never underflows / lockedAssets <= accountedAssets
    // ---------------------------------------------------------------------
    // Hypothesis: sequence of lock + writeDown makes lockedAssets > accountedAssets,
    //   underflowing availableLiquidity (which would let deposits/withdraws misprice).
    // Attack: lock most senior NAV, then default writeDown; assert invariant holds throughout.
    // Result: writeDown requires amount <= availableLiquidity, so accountedAssets stays
    //   >= lockedAssets. Invariant never violated.
    // Verdict: SAFE (SeniorPool.sol:196-200; unlock happens before writeDown in resolveDefault).
    function test_SAFE_H11_availableLiquidityNeverUnderflows() public {
        uint256 id = _bootstrapFundedInvoice();

        // Mid-financing: locked > 0, availableLiquidity computed without underflow.
        assertGe(seniorPool.totalAssets(), seniorPool.lockedAssets(), "senior: accounted >= locked");
        assertGe(juniorPool.totalAssets(), juniorPool.lockedAssets(), "junior: accounted >= locked");
        // Does not revert.
        seniorPool.availableLiquidity();
        juniorPool.availableLiquidity();

        // Full default -> junior writeDown to (near) full loss.
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);
        _resolveDefaultAsResolver(id);

        // Post-default invariant holds and lockedAssets is back to 0.
        assertEq(seniorPool.lockedAssets(), 0, "senior locked cleared");
        assertEq(juniorPool.lockedAssets(), 0, "junior locked cleared");
        assertGe(seniorPool.totalAssets(), seniorPool.lockedAssets(), "senior invariant holds post-default");
        assertGe(juniorPool.totalAssets(), juniorPool.lockedAssets(), "junior invariant holds post-default");
        // Still computable without revert.
        assertEq(seniorPool.availableLiquidity(), seniorPool.totalAssets(), "no locked => avail == nav");
    }

    // ---------------------------------------------------------------------
    // H12 — mint() vs deposit() path rounding symmetry (no free shares)
    // ---------------------------------------------------------------------
    // Hypothesis: mint (rounds assets up) vs deposit (rounds shares down) creates an
    //   arbitrage where one path gives free shares/assets.
    // Attack: from an identical non-1:1 NAV state, exercise both paths and compare cost/value.
    // Result: mint costs >= deposit for equal shares; no path yields free value; entrant
    //   never redeems for more than they paid.
    // Verdict: SAFE (OZ rounding always favors the vault).
    function test_SAFE_H12_mintVsDepositNoFreeValue() public {
        // Build a non-1:1 price via real yield.
        uint256 id = _bootstrapFundedInvoice();
        uint256 fee = _positionFee(id);
        uint256 principal = _positionPrincipal(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAsBuyer(id, principal + fee);

        // deposit() path: attacker deposits assets directly on the vault.
        uint256 depositAssets = 10_000e18;
        asset.mint(attacker, depositAssets);
        vm.startPrank(attacker);
        asset.approve(address(seniorPool), depositAssets);
        uint256 sharesFromDeposit = seniorPool.deposit(depositAssets, attacker);
        vm.stopPrank();
        // Redeemable value must not exceed what was paid.
        assertLe(
            seniorPool.convertToAssets(sharesFromDeposit),
            depositAssets,
            "deposit(): cannot redeem more than deposited"
        );

        // mint() path: a different entrant mints an exact share amount and pays previewMint assets.
        address minter = makeAddr("minter");
        uint256 sharesToMint = 1_000e18;
        uint256 cost = seniorPool.previewMint(sharesToMint);
        asset.mint(minter, cost);
        vm.startPrank(minter);
        asset.approve(address(seniorPool), cost);
        uint256 paid = seniorPool.mint(sharesToMint, minter);
        vm.stopPrank();
        assertEq(paid, cost, "mint pays exactly previewMint");
        // Redeemable value of minted shares must not exceed cost paid.
        assertLe(
            seniorPool.convertToAssets(seniorPool.balanceOf(minter)),
            paid,
            "mint(): cannot redeem more than paid"
        );
    }
}

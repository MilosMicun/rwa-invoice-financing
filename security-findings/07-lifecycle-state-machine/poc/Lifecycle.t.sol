// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceFinancingPool} from "../../../src/interfaces/IInvoiceFinancingPool.sol";
import {IInvoiceStatusOracle} from "../../../src/interfaces/IInvoiceStatusOracle.sol";
import {InvoiceNFT} from "../../../src/core/InvoiceNFT.sol";
import {InvoiceFinancingPool} from "../../../src/core/InvoiceFinancingPool.sol";

/// @title VECTOR 07 — Invoice lifecycle state machine & freeze griefing
/// @notice All probes encode their verdict in the assertions. SAFE probes prove the defense
///         holds; FINDING probes prove the harmful outcome actually occurs.
contract LifecycleStateMachineTest is Harness {
    IInvoiceNFT.InvoiceStatus constant CREATED = IInvoiceNFT.InvoiceStatus.CREATED;
    IInvoiceNFT.InvoiceStatus constant VERIFIED = IInvoiceNFT.InvoiceStatus.VERIFIED;
    IInvoiceNFT.InvoiceStatus constant FUNDED = IInvoiceNFT.InvoiceStatus.FUNDED;
    IInvoiceNFT.InvoiceStatus constant SETTLED = IInvoiceNFT.InvoiceStatus.SETTLED;
    IInvoiceNFT.InvoiceStatus constant DEFAULTED = IInvoiceNFT.InvoiceStatus.DEFAULTED;
    IInvoiceNFT.InvoiceStatus constant FROZEN = IInvoiceNFT.InvoiceStatus.FROZEN;

    function _status(uint256 id) internal view returns (IInvoiceNFT.InvoiceStatus) {
        return invoiceNft.getInvoice(id).status;
    }

    // ------------------------------------------------------------------
    // 1. Double-finance
    // ------------------------------------------------------------------
    // Hypothesis: financing an already-FUNDED invoice can drain both tranches twice.
    // Attack: bootstrap a FUNDED invoice, call financeInvoice again as supplier.
    // Result: reverts InvoiceAlreadyFinanced (pool fundedAt!=0 guard); independently,
    //         markFunded requires VERIFIED so even the NFT layer blocks re-funding.
    // Verdict: SAFE.
    function test_SAFE_doubleFinanceBlockedByPoolAndNft() public {
        uint256 id = _bootstrapFundedInvoice();

        // Pool-level guard: position already exists.
        vm.prank(supplier);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceAlreadyFinanced.selector, id));
        pool.financeInvoice(id);

        // NFT-level guard: markFunded requires VERIFIED, invoice is FUNDED.
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, id, FUNDED, VERIFIED));
        invoiceNft.markFunded(id);

        assertEq(uint256(_status(id)), uint256(FUNDED), "still funded, not double-funded");
    }

    // ------------------------------------------------------------------
    // 2. Settle then default (mutual exclusion)
    // ------------------------------------------------------------------
    // Hypothesis: after a SETTLED path, the DEFAULTED path can also be run (double loss/payout).
    // Attack: settle, then submit+finalize DEFAULTED and call resolveDefault.
    // Result: the oracle rejects re-finalization (OracleStatusAlreadyFinalized), so the
    //         default path is unreachable. Even if it were reached, resolved flag + NFT!=FUNDED block it.
    // Verdict: SAFE.
    function test_SAFE_settleThenDefaultMutualExclusion() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);

        _submitAndFinalizeOracleStatus(id, SETTLED, 0);
        _settleAsBuyer(id, principal + fee);

        assertEq(uint256(_status(id)), uint256(SETTLED), "settled");
        assertTrue(_positionResolved(id), "resolved");

        // Try to finalize a DEFAULTED outcome on the same invoice.
        // Oracle submit requires NFT == FUNDED; it is SETTLED now, so submit reverts with the
        // oracle's own InvoiceNotFunded error.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.InvoiceNotFunded.selector, id, SETTLED));
        oracle.submitStatus(id, DEFAULTED, 0);

        // Even bypassing the oracle, the pool's resolveDefault would revert: the position is
        // already resolved.
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.FinancingPositionAlreadyResolved.selector, id));
        pool.resolveDefault(id);
    }

    // ------------------------------------------------------------------
    // 3. Default then settle (mutual exclusion, mirror)
    // ------------------------------------------------------------------
    // Hypothesis: after a DEFAULTED path, the SETTLED path can also be run.
    // Attack: resolveDefault, then try settleInvoice.
    // Result: position.resolved is true → settle reverts FinancingPositionAlreadyResolved.
    // Verdict: SAFE.
    function test_SAFE_defaultThenSettleMutualExclusion() public {
        uint256 id = _bootstrapFundedInvoice();
        _submitAndFinalizeOracleStatus(id, DEFAULTED, 0);
        _resolveDefaultAsResolver(id);

        assertEq(uint256(_status(id)), uint256(DEFAULTED), "defaulted");
        assertTrue(_positionResolved(id), "resolved");

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.FinancingPositionAlreadyResolved.selector, id));
        pool.settleInvoice(id, 999_999e18);
    }

    // ------------------------------------------------------------------
    // 4. FREEZE STRAND
    // ------------------------------------------------------------------
    // Hypothesis: RISK_ROLE freezing a FUNDED invoice that already has a finalized oracle
    //             outcome permanently strands locked tranche liquidity: settle & resolve both
    //             revert InvoiceFrozen, so totalLockedAssets never releases and LPs cannot
    //             withdraw that capital while it stays frozen.
    // Attack: bootstrap+finalize(SETTLED), freeze, prove settle & resolve revert, quantify
    //         the locked capital that senior+junior LPs cannot withdraw.
    // Result: strand demonstrated *while frozen*, but it is fully reversible by RISK_ROLE
    //         (unfreeze → settle succeeds). A NON-privileged actor CANNOT freeze. So this is a
    //         privileged-role liveness lever, not an exploitable strand. Documented as SAFE/INFO.
    // Verdict: SAFE (privileged, reversible; no non-risk actor can trigger; LOW/liveness note).
    function test_SAFE_freezeStrandIsReversibleAndPrivilegedOnly() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);

        _submitAndFinalizeOracleStatus(id, SETTLED, 0);

        // Non-privileged actor cannot freeze (this is what would make it a finding).
        vm.prank(attacker);
        vm.expectRevert();
        invoiceNft.freezeInvoice(id);

        // RISK_ROLE freezes the FUNDED invoice.
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(id);
        assertEq(uint256(_status(id)), uint256(FROZEN), "frozen");

        // While frozen: settle reverts InvoiceFrozen, so locked capital is stuck.
        asset.mint(buyer, principal + fee);
        vm.startPrank(buyer);
        asset.approve(address(pool), principal + fee);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvoiceFrozen.selector, id));
        pool.settleInvoice(id, principal + fee);
        vm.stopPrank();

        // resolve also reverts (both terminal paths blocked while frozen).
        // Oracle finalized SETTLED, so resolveDefault reverts on UnexpectedOracleStatus BEFORE
        // the frozen check; assert it simply cannot succeed regardless.
        vm.prank(resolver);
        vm.expectRevert();
        pool.resolveDefault(id);

        // Quantify the stranded LP capital while frozen: full principal is locked and
        // unwithdrawable beyond available liquidity.
        uint256 locked = pool.totalLockedAssets();
        assertEq(locked, principal, "full principal locked while frozen");

        // Senior LP cannot withdraw beyond available liquidity (locked portion is stuck).
        uint256 seniorMax = seniorPool.maxWithdraw(seniorLp);
        assertEq(seniorMax, SENIOR_DEPOSIT - _expectedSeniorPrincipal(principal), "senior locked portion stuck");

        // BUT the strand is reversible by the same trusted role: unfreeze → settle succeeds.
        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(id);
        assertEq(uint256(_status(id)), uint256(FUNDED), "restored to FUNDED exactly");

        _settleAsBuyer(id, principal + fee);
        assertTrue(_positionResolved(id), "settled after unfreeze");
        assertEq(pool.totalLockedAssets(), 0, "locked fully released after unfreeze");
    }

    // ------------------------------------------------------------------
    // 5. markFunded state gating (cannot fund from non-VERIFIED)
    // ------------------------------------------------------------------
    // Hypothesis: an invoice can be funded from CREATED / SETTLED / DEFAULTED / FROZEN.
    // Attack: drive markFunded directly (as pool) from each illegal state.
    // Result: every non-VERIFIED source reverts InvalidStatus.
    // Verdict: SAFE.
    function test_SAFE_markFundedRequiresVerified() public {
        // CREATED
        vm.prank(originator);
        uint256 created = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, created, CREATED, VERIFIED));
        invoiceNft.markFunded(created);

        // FROZEN (freeze a VERIFIED one)
        uint256 frozen = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(frozen);
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, frozen, FROZEN, VERIFIED));
        invoiceNft.markFunded(frozen);

        // SETTLED
        uint256 settled = _bootstrapFundedInvoice();
        _submitAndFinalizeOracleStatus(settled, SETTLED, 0);
        _settleAsBuyer(settled, _positionPrincipal(settled) + _positionFee(settled));
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, settled, SETTLED, VERIFIED));
        invoiceNft.markFunded(settled);

        // DEFAULTED
        uint256 defaulted = _createVerifiedInvoiceFor(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(defaulted);
        _submitAndFinalizeOracleStatus(defaulted, DEFAULTED, 0);
        _resolveDefaultAsResolver(defaulted);
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, defaulted, DEFAULTED, VERIFIED));
        invoiceNft.markFunded(defaulted);
    }

    // ------------------------------------------------------------------
    // 6. Non-transferability (no move, no burn)
    // ------------------------------------------------------------------
    // Hypothesis: the claim NFT can be transferred or burned, breaking non-transferability.
    // Attack: owner (supplier) calls transferFrom/safeTransferFrom/approve/setApprovalForAll.
    // Result: all revert TransfersDisabled; _update blocks any from!=0 move so no burn path exists.
    // Verdict: SAFE.
    function test_SAFE_nonTransferabilityAndNoBurn() public {
        uint256 id = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        assertEq(invoiceNft.ownerOf(id), supplier, "minted to supplier");

        vm.startPrank(supplier);
        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        invoiceNft.transferFrom(supplier, attacker, id);

        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        invoiceNft.safeTransferFrom(supplier, attacker, id);

        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        invoiceNft.approve(attacker, id);

        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        invoiceNft.setApprovalForAll(attacker, true);
        vm.stopPrank();

        // No burn path: the contract exposes no burn function, and _update reverts for any
        // existing token (from != 0). A transfer to address(0) is caught even earlier by OZ's
        // ERC721InvalidReceiver guard, so it also cannot burn. Either way it reverts.
        vm.prank(supplier);
        vm.expectRevert(); // OZ ERC721InvalidReceiver(0) fires before _update's TransfersDisabled
        invoiceNft.transferFrom(supplier, address(0), id);

        assertEq(invoiceNft.ownerOf(id), supplier, "still owned, not moved/burned");
    }

    // ------------------------------------------------------------------
    // 7. Re-verify after funding blocked
    // ------------------------------------------------------------------
    // Hypothesis: a FUNDED/SETTLED invoice can be pushed back to VERIFIED to re-finance.
    // Attack: call verify() on FUNDED and on SETTLED invoices.
    // Result: verify requires CREATED → both revert InvalidStatus.
    // Verdict: SAFE.
    function test_SAFE_reVerifyAfterFundingBlocked() public {
        uint256 funded = _bootstrapFundedInvoice();
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, funded, FUNDED, CREATED));
        invoiceNft.verify(funded);

        _submitAndFinalizeOracleStatus(funded, SETTLED, 0);
        _settleAsBuyer(funded, _positionPrincipal(funded) + _positionFee(funded));
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, funded, SETTLED, CREATED));
        invoiceNft.verify(funded);
    }

    // ------------------------------------------------------------------
    // 8. Freeze a VERIFIED invoice blocks financing
    // ------------------------------------------------------------------
    // Hypothesis: a frozen VERIFIED invoice can still be financed.
    // Attack: freeze a VERIFIED invoice, then financeInvoice.
    // Result: isEligible returns false (status FROZEN != VERIFIED) → InvoiceNotEligible.
    //         No funds are locked because financing never runs; unfreeze restores fundability.
    // Verdict: SAFE (pre-funding griefing by RISK_ROLE only; no capital at risk).
    function test_SAFE_freezeVerifiedBlocksFinancing() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        uint256 id = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(id);
        assertFalse(riskManager.isEligible(id), "frozen invoice not eligible");

        vm.prank(supplier);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceNotEligible.selector, id));
        pool.financeInvoice(id);

        // No liquidity was ever locked.
        assertEq(pool.totalLockedAssets(), 0, "nothing locked");

        // Reversible: unfreeze → eligible → finance succeeds.
        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(id);
        assertTrue(riskManager.isEligible(id), "eligible again");
        _financeAsSupplier(id);
        assertEq(uint256(_status(id)), uint256(FUNDED), "financed after unfreeze");
    }

    // ------------------------------------------------------------------
    // 9. Freeze after submit, before finalize: no stale-outcome corruption
    // ------------------------------------------------------------------
    // Hypothesis: freezing between oracle submit and finalize can lock in a stale outcome that
    //             later mis-resolves (e.g. finalize a SETTLED that no longer reflects reality).
    // Attack: submit SETTLED, freeze, finalize (succeeds by design), unfreeze, then settle.
    // Result: finalize succeeds (design: it does not touch NFT/waterfall). The frozen check on
    //         settle/resolve prevents acting while frozen. After unfreeze, the SETTLED outcome
    //         resolves cleanly with correct accounting and no double-count. No corruption.
    // Verdict: SAFE (matches documented design in InvoiceStatusOracle.finalize NatSpec).
    function test_SAFE_freezeBetweenSubmitAndFinalizeNoCorruption() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);

        // Submit SETTLED.
        vm.prank(admin);
        oracle.submitStatus(id, SETTLED, 0);

        // Freeze during the dispute window.
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(id);

        // Advance past dispute window and finalize — succeeds by design (no NFT mutation).
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);
        assertTrue(pool.isOracleStatusFinalized(id), "oracle finalized while frozen");

        // Settle while frozen must revert.
        asset.mint(buyer, principal + fee);
        vm.startPrank(buyer);
        asset.approve(address(pool), principal + fee);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvoiceFrozen.selector, id));
        pool.settleInvoice(id, principal + fee);
        vm.stopPrank();

        // Unfreeze restores FUNDED and settle now resolves correctly.
        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(id);
        uint256 seniorNavBefore = seniorPool.totalAssets();
        uint256 juniorNavBefore = juniorPool.totalAssets();

        _settleAsBuyer(id, principal + fee);

        assertTrue(_positionResolved(id), "resolved once");
        assertEq(uint256(_status(id)), uint256(SETTLED), "settled");
        assertEq(pool.totalLockedAssets(), 0, "no strand, no double-count");
        // NAV grew by exactly the fee (no principal double-credit).
        assertEq(
            (seniorPool.totalAssets() - seniorNavBefore) + (juniorPool.totalAssets() - juniorNavBefore),
            fee,
            "NAV increased by exactly the fee"
        );
    }

    // ------------------------------------------------------------------
    // 10. Terminal immutability (SETTLED / DEFAULTED cannot re-transition or re-freeze)
    // ------------------------------------------------------------------
    // Hypothesis: a terminal invoice can be re-verified/funded/settled/defaulted/frozen.
    // Attack: hit every transition on a SETTLED and on a DEFAULTED invoice.
    // Result: all revert. Terminal states are absorbing.
    // Verdict: SAFE.
    function test_SAFE_terminalStatesAreImmutable() public {
        // SETTLED
        uint256 s = _bootstrapFundedInvoice();
        _submitAndFinalizeOracleStatus(s, SETTLED, 0);
        _settleAsBuyer(s, _positionPrincipal(s) + _positionFee(s));

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, s, SETTLED, CREATED));
        invoiceNft.verify(s);

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, s, SETTLED, VERIFIED));
        invoiceNft.markFunded(s);

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, s, SETTLED, FUNDED));
        invoiceNft.markSettled(s);

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, s, SETTLED, FUNDED));
        invoiceNft.markDefaulted(s);

        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidFreezeStatus.selector, s, SETTLED));
        invoiceNft.freezeInvoice(s);

        // DEFAULTED
        uint256 d = _createVerifiedInvoiceFor(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(d);
        _submitAndFinalizeOracleStatus(d, DEFAULTED, 0);
        _resolveDefaultAsResolver(d);

        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidFreezeStatus.selector, d, DEFAULTED));
        invoiceNft.freezeInvoice(d);

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidStatus.selector, d, DEFAULTED, FUNDED));
        invoiceNft.markSettled(d);
    }

    // ------------------------------------------------------------------
    // 11. previousStatus integrity (unfreeze gating + exact restore)
    // ------------------------------------------------------------------
    // Hypothesis: the CREATED placeholder previousStatus, or unfreezing a non-frozen invoice,
    //             can land the invoice in a bogus state enabling an illegal action.
    // Attack: (a) unfreeze a VERIFIED (never-frozen) invoice; (b) round-trip VERIFIED and FUNDED.
    // Result: (a) reverts InvoiceNotFrozen — the placeholder is never consulted for non-frozen.
    //         (b) restore is exact for both source states; fundedAt is preserved on FUNDED.
    // Verdict: SAFE.
    function test_SAFE_previousStatusIntegrity() public {
        // (a) unfreeze on a never-frozen invoice reverts (placeholder CREATED never applied).
        uint256 v = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceNotFrozen.selector, v));
        invoiceNft.unfreezeInvoice(v);
        assertEq(uint256(_status(v)), uint256(VERIFIED), "unchanged");

        // (b1) VERIFIED -> FROZEN -> VERIFIED exact restore.
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(v);
        assertEq(uint256(invoiceNft.getInvoice(v).previousStatus), uint256(VERIFIED), "prev=VERIFIED");
        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(v);
        assertEq(uint256(_status(v)), uint256(VERIFIED), "restored VERIFIED exactly");

        // (b2) FUNDED -> FROZEN -> FUNDED exact restore, fundedAt preserved, still resolvable.
        uint256 f = _bootstrapFundedInvoice();
        uint256 fundedAtBefore = invoiceNft.getInvoice(f).fundedAt;
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(f);
        assertEq(uint256(invoiceNft.getInvoice(f).previousStatus), uint256(FUNDED), "prev=FUNDED");
        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(f);
        assertEq(uint256(_status(f)), uint256(FUNDED), "restored FUNDED exactly");
        assertEq(invoiceNft.getInvoice(f).fundedAt, fundedAtBefore, "fundedAt preserved across freeze");

        // Normal terminal path still completes.
        _submitAndFinalizeOracleStatus(f, SETTLED, 0);
        _settleAsBuyer(f, _positionPrincipal(f) + _positionFee(f));
        assertEq(uint256(_status(f)), uint256(SETTLED), "settles normally after round-trip");
    }

    // ------------------------------------------------------------------
    // 12. Freeze cannot be applied from CREATED (only VERIFIED/FUNDED)
    // ------------------------------------------------------------------
    // Hypothesis: freezing a CREATED invoice sets previousStatus=CREATED, and unfreeze then
    //             lands in CREATED (an unexpected regression that could be re-verified/funded oddly).
    // Attack: create (not verify), freeze.
    // Result: freeze reverts InvalidFreezeStatus for CREATED — the only freezable states are
    //         VERIFIED and FUNDED, so the CREATED-restore corner case is unreachable.
    // Verdict: SAFE.
    function test_SAFE_freezeFromCreatedBlocked() public {
        vm.prank(originator);
        uint256 id = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidFreezeStatus.selector, id, CREATED));
        invoiceNft.freezeInvoice(id);

        assertEq(uint256(_status(id)), uint256(CREATED), "unchanged");
    }

    // ------------------------------------------------------------------
    // 13. Double-freeze blocked (cannot re-freeze a FROZEN invoice)
    // ------------------------------------------------------------------
    // Hypothesis: re-freezing a FROZEN invoice overwrites previousStatus with FROZEN, so a
    //             later unfreeze restores FROZEN (a permanent limbo / self-referential state).
    // Attack: freeze a FUNDED invoice, then freeze again.
    // Result: second freeze reverts InvalidFreezeStatus (current status FROZEN not in {VERIFIED,FUNDED}).
    //         previousStatus can never be corrupted to FROZEN.
    // Verdict: SAFE.
    function test_SAFE_doubleFreezeBlocked() public {
        uint256 id = _bootstrapFundedInvoice();
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(id);

        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvalidFreezeStatus.selector, id, FROZEN));
        invoiceNft.freezeInvoice(id);

        assertEq(uint256(invoiceNft.getInvoice(id).previousStatus), uint256(FUNDED), "prev still FUNDED, not FROZEN");
    }

    // ------------------------------------------------------------------
    // 14. NFT<->position desync strand (no permanent non-frozen strand reachable)
    // ------------------------------------------------------------------
    // Hypothesis: a state exists where the pool holds a FUNDED position with locked assets but
    //             the NFT is neither FUNDED nor FROZEN (so settle/resolve fail InvoiceNotFunded
    //             forever) — permanently stranding funds without any privileged reversibility.
    // Attack: enumerate reachable NFT states for an active (unresolved) position. The only
    //         transitions out of FUNDED are: markSettled/markDefaulted (POOL_ROLE, both resolve
    //         the position) and freeze (RISK_ROLE, reversible). There is no role that can move a
    //         FUNDED invoice to a non-FROZEN, non-terminal state while leaving the position open.
    // Result: after any FROZEN detour the invoice returns to FUNDED and resolves; there is NO
    //         reachable permanent non-frozen desync. Prove by exhaustively resolving after a
    //         freeze detour and confirming locked assets clear.
    // Verdict: SAFE.
    function test_SAFE_noPermanentNonFrozenDesyncStrand() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);

        // Detour through FROZEN then back; the position stays open and resolvable.
        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(id);
        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(id);

        // The active position is still resolvable via the default path (no privileged NFT
        // mutation could have moved it to a stuck non-frozen state).
        assertEq(uint256(_status(id)), uint256(FUNDED), "back to FUNDED, resolvable");
        assertEq(pool.totalLockedAssets(), principal, "still locked, awaiting resolution");

        _submitAndFinalizeOracleStatus(id, DEFAULTED, principal); // full recovery
        _resolveDefaultAsResolver(id);

        assertTrue(_positionResolved(id), "resolved");
        assertEq(pool.totalLockedAssets(), 0, "locked cleared - funds not stranded");
        assertEq(uint256(_status(id)), uint256(DEFAULTED), "terminal");
    }
}

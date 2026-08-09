// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";
import {ReentrantToken} from "../../_base/MaliciousTokens.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title Vector 05 — Reentrancy & external-call safety PoCs
/// @notice Every test starts from the malicious ReentrantToken asset (ERC777-style
///         callback fired mid-transfer). The whole protocol is redeployed on it via the
///         overridden setUp -> _deployProtocol. Verdicts are encoded in assertions.
contract ReentrancyTest is Harness {
    ReentrantToken internal rtoken;

    /// @dev Redeploy the whole protocol on top of the callback asset.
    function setUp() public override {
        vm.warp(1_700_000_000);
        rtoken = new ReentrantToken();
        _deployProtocol(address(rtoken));
    }

    // -------------------------------------------------------------------------
    // Small helpers (asset is ReentrantToken; mint via its public mint)
    // -------------------------------------------------------------------------

    function _seedTranches() internal {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
    }

    /// @dev Full happy-path funding + SETTLED oracle finalization, ready to settle.
    function _fundedAndSettledOracle() internal returns (uint256 id) {
        id = _bootstrapFundedInvoice();
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
    }

    /// @dev Full happy-path funding + DEFAULTED oracle finalization with a recovery.
    function _fundedAndDefaultedOracle(uint256 recovery) internal returns (uint256 id) {
        id = _bootstrapFundedInvoice();
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, recovery);
    }

    /// @dev Pre-fund + approve a settle payer WITHOUT triggering an armed hook (mint/approve
    ///      happen before arming). Returns nothing; caller then arms and pranks settle.
    function _preparePayer(address payer, uint256 pay) internal {
        rtoken.mint(payer, pay);
        vm.prank(payer);
        rtoken.approve(address(pool), pay);
    }

    // =========================================================================
    // 1. Settle same-invoice reentrancy
    // =========================================================================
    // Hypothesis: settleInvoice's repayment transfer fires the token hook; re-entering
    //   settleInvoice(sameId) could double-credit fees / double-unlock.
    // Attack: arm the token to call pool.settleInvoice(id, x) again during transfer.
    // Result: position.resolved is set BEFORE the transfer (L416), so re-entry reverts.
    // Verdict: SAFE (CEI holds).
    function test_SAFE_SettleSameInvoiceReentrancyReverts() public {
        uint256 id = _fundedAndSettledOracle();
        uint256 pay = _positionPrincipal(id) + _positionFee(id);

        ReReenterHelper_Settle atk = new ReReenterHelper_Settle(address(pool), id);
        // Fund the attacker as the settlement payer.
        rtoken.mint(address(atk), pay * 2);
        atk.approvePool(pay * 2);

        // Arm: during the first repayment safeTransferFrom, the attacker re-enters settle.
        rtoken.armHook(address(atk), abi.encodeWithSelector(atk.reenter.selector, pay));

        // The whole outer settle must revert because the reentrant settle reverts
        // (FinancingPositionAlreadyResolved) and the ReentrantToken bubbles it up.
        vm.expectRevert(
            abi.encodeWithSignature("FinancingPositionAlreadyResolved(uint256)", id)
        );
        atk.settle(pay);

        // Nothing changed: still unresolved, still funded.
        assertFalse(_positionResolved(id), "position must remain unresolved after reverted settle");
        IInvoiceNFT.Invoice memory inv = invoiceNft.getInvoice(id);
        assertEq(uint256(inv.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED), "invoice must stay FUNDED");
    }

    // =========================================================================
    // 2. Settle -> withdraw cross-function over-withdraw
    // =========================================================================
    // Hypothesis: at the settle transfer hook, unlock has NOT run, so lockedAssets is
    //   still elevated. A senior LP re-enters withdrawSenior hoping to withdraw against
    //   the (soon to be) restored NAV before locked liquidity is released.
    // Attack: seniorLp is a contract; on the senior repayment transfer hook it tries to
    //   withdraw more than the mid-tx availableLiquidity.
    // Result: availableLiquidity is still low mid-hook; over-withdraw reverts. Even a
    //   legitimate-size withdraw is bounded by ERC-4626 _withdraw's availableLiquidity check.
    // Verdict: SAFE.
    function test_SAFE_SettleThenWithdrawCannotOverWithdraw() public {
        // Senior LP is a contract that will attempt a reentrant over-withdraw.
        WithdrawAttacker lp = new WithdrawAttacker(address(pool), address(seniorPool), true);

        // Deposit senior via the attacker LP contract.
        rtoken.mint(address(lp), SENIOR_DEPOSIT);
        lp.approveAssetToPool(SENIOR_DEPOSIT);
        lp.depositSenior(SENIOR_DEPOSIT);
        // Junior liquidity from the normal junior LP.
        _depositJunior(juniorLp, JUNIOR_DEPOSIT);

        // Approve the coordinator to move the LP's shares for the reentrant withdraw.
        lp.approveSharesToPool(type(uint256).max);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        uint256 pay = _positionPrincipal(id) + _positionFee(id);

        // Pre-fund the payer BEFORE arming so the mint/approve don't trip the hook.
        _preparePayer(buyer, pay);

        // Arm the LP to re-enter withdrawSenior for a LARGE amount during the senior
        // repayment transfer (which goes to the SeniorPool, but the hook fires regardless).
        // Ask to withdraw the full senior deposit, which exceeds mid-tx availableLiquidity.
        lp.armReentrantWithdraw(SENIOR_DEPOSIT);
        rtoken.armHook(address(lp), abi.encodeWithSelector(lp.doReentrantWithdraw.selector));

        // Settle is executed by an independent payer.
        // The reentrant over-withdraw must revert; OZ ERC4626.withdraw enforces the
        // overridden maxWithdraw (capped by mid-tx availableLiquidity) -> ERC4626ExceededMaxWithdraw.
        vm.expectPartialRevert(bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)")));
        vm.prank(buyer);
        pool.settleInvoice(id, pay);

        // Sanity: nothing settled.
        assertFalse(_positionResolved(id), "settle must have fully reverted");
    }

    // =========================================================================
    // 3. resolveDefault same-invoice reentrancy
    // =========================================================================
    // Hypothesis: recovery transfer hook re-enters resolveDefault(sameId) → double
    //   write-down / double bad debt.
    // Attack: arm the token to re-enter resolveDefault during the senior recovery transfer.
    // Result: resolved set before transfer (L542) -> revert FinancingPositionAlreadyResolved.
    // Verdict: SAFE.
    function test_SAFE_ResolveDefaultSameInvoiceReentrancyReverts() public {
        uint256 recovery = 60_000e18;
        uint256 id = _fundedAndDefaultedOracle(recovery);

        ResolveAttacker atk = new ResolveAttacker(address(pool), id);
        rtoken.mint(address(atk), recovery * 2);
        atk.approvePool(recovery * 2);

        rtoken.armHook(address(atk), abi.encodeWithSelector(atk.reenter.selector));

        vm.expectRevert(
            abi.encodeWithSignature("FinancingPositionAlreadyResolved(uint256)", id)
        );
        atk.resolve();

        assertFalse(_positionResolved(id), "position must remain unresolved after reverted resolve");
        assertEq(pool.totalBadDebt(), 0, "no bad debt should be recorded on reverted resolve");
    }

    // =========================================================================
    // 4. Deposit reentrancy
    // =========================================================================
    // Hypothesis: transferFrom(LP->coordinator) hook re-enters depositSenior, minting
    //   shares twice for one economic intent / mispricing shares.
    // Attack: LP contract deposits X; on the transferFrom hook it deposits X again.
    // Result: each deposit pulls its own X assets and mints proportional shares. The
    //   second deposit is a full, honest deposit (its own transferFrom). No free shares,
    //   share price stays 1:1. Conservation holds.
    // Verdict: SAFE.
    function test_SAFE_DepositReentrancyNoMispricing() public {
        // Seed a normal senior deposit first so a share price exists.
        _depositSenior(seniorLp, SENIOR_DEPOSIT);

        DepositAttacker lp = new DepositAttacker(address(pool));
        uint256 each = 100_000e18;
        rtoken.mint(address(lp), each * 2);
        lp.approveAssetToPool(each * 2);

        // Arm: during the first deposit's transferFrom, re-enter depositSenior(each).
        lp.armReentrantDeposit(each);
        rtoken.armHook(address(lp), abi.encodeWithSelector(lp.doReentrantDeposit.selector));

        uint256 sharesBefore = seniorPool.balanceOf(address(lp));
        lp.depositSenior(each);
        uint256 sharesAfter = seniorPool.balanceOf(address(lp));

        // The LP paid 2*each and got shares worth ~2*each. Conversion is fair (>= within 1 wei).
        uint256 gotShares = sharesAfter - sharesBefore;
        uint256 gotAssets = seniorPool.convertToAssets(gotShares);
        assertApproxEqAbs(gotAssets, each * 2, 2, "LP shares must be worth what LP paid (no free mint)");
        // Attacker holds no leftover asset windfall.
        assertEq(rtoken.balanceOf(address(lp)), 0, "LP must have spent exactly 2*each");
    }

    // =========================================================================
    // 5. financeInvoice same-invoice reentrancy
    // =========================================================================
    // Hypothesis: supplier is a contract; on the senior fundInvoice transfer hook it
    //   re-enters financeInvoice(sameId) to double-fund.
    // Attack: supplier contract calls financeInvoice; the senior fundInvoice transfer to
    //   it fires the hook, which re-enters financeInvoice(id).
    // Result: position stored + markFunded already done -> revert InvoiceAlreadyFinanced
    //   (also invoice no longer VERIFIED). CEI holds; funding external calls are LAST.
    // Verdict: SAFE.
    function test_SAFE_FinanceInvoiceSameIdReentrancyReverts() public {
        _seedTranches();

        FinanceAttacker sup = new FinanceAttacker(address(pool));
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        // Create + verify an invoice whose supplier is the attacker contract.
        uint256 id = _createVerifiedInvoiceFor(address(sup), buyer, FACE_VALUE, dueDate);

        sup.armReentrantFinance(id);
        rtoken.armHook(address(sup), abi.encodeWithSelector(sup.doReentrantFinance.selector));

        vm.expectRevert(
            abi.encodeWithSignature("InvoiceAlreadyFinanced(uint256)", id)
        );
        sup.finance(id);

        // Position must not exist (finance fully reverted).
        assertEq(_positionPrincipal(id), 0, "no position should be created on reverted finance");
        assertEq(pool.totalLockedAssets(), 0, "no assets locked on reverted finance");
    }

    // =========================================================================
    // 6. financeInvoice -> withdraw mid-financing
    // =========================================================================
    // Hypothesis: at the senior fundInvoice transfer hook, both tranche locks are already
    //   set (lockAssets ran before fundInvoice), so a colluding LP re-entering withdraw
    //   cannot pull the committed liquidity.
    // Attack: supplier contract, on its fundInvoice receive hook, re-enters withdrawSenior
    //   for the full pre-finance senior available liquidity.
    // Result: availableLiquidity already reduced by the senior lock -> over-withdraw reverts.
    // Verdict: SAFE.
    function test_SAFE_FinanceThenWithdrawCannotDrainLockedLiquidity() public {
        // Senior LP is the same contract that supplies and also owns senior shares,
        // to make the reentrant withdraw authorized.
        FinanceWithdrawAttacker actor = new FinanceWithdrawAttacker(address(pool), address(seniorPool));

        rtoken.mint(address(actor), SENIOR_DEPOSIT);
        actor.approveAssetToPool(SENIOR_DEPOSIT);
        actor.depositSenior(SENIOR_DEPOSIT);
        actor.approveSharesToPool(type(uint256).max);
        _depositJunior(juniorLp, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoiceFor(address(actor), buyer, FACE_VALUE, dueDate);

        // Try to withdraw the FULL senior deposit during the fund hook (exceeds available
        // liquidity because the senior principal is now locked).
        actor.armReentrantWithdraw(SENIOR_DEPOSIT);
        rtoken.armHook(address(actor), abi.encodeWithSelector(actor.doReentrantWithdraw.selector));

        // Over-withdraw during the fund hook reverts: senior principal is already locked,
        // so the overridden maxWithdraw caps the withdrawable amount -> ERC4626ExceededMaxWithdraw.
        vm.expectPartialRevert(bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)")));
        actor.finance(id);

        assertEq(_positionPrincipal(id), 0, "finance must have fully reverted");
    }

    // =========================================================================
    // 7. Surplus transfer -> supplier reentrancy
    // =========================================================================
    // Hypothesis: settle sends surplus to the supplier; if supplier is a contract it can
    //   re-enter settle/withdraw in the surplus transfer hook.
    // Attack: supplier contract; overpay so surplus > 0; on the surplus transfer hook the
    //   supplier re-enters settleInvoice(id).
    // Result: resolved already true -> revert. (Surplus transfer is after senior+junior
    //   repayment but resolved was set at the very start.)
    // Verdict: SAFE.
    function test_SAFE_SettleSurplusReentrancyReverts() public {
        _seedTranches();

        SurplusAttacker sup = new SurplusAttacker(address(pool));
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoiceFor(address(sup), buyer, FACE_VALUE, dueDate);
        _financeAs(address(sup), id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        uint256 principal = _positionPrincipal(id);
        uint256 fee = _positionFee(id);
        uint256 surplus = 5_000e18;
        uint256 pay = principal + fee + surplus;

        // Pre-fund payer before arming so the mint/approve don't trip the hook; the hook
        // then fires on the first in-settle transfer, by which point resolved==true.
        _preparePayer(buyer, pay);
        // Give the reentrant supplier its own allowance so it truly reaches the resolved
        // guard (and not a spurious allowance revert) when it re-enters settle.
        rtoken.mint(address(sup), pay);
        sup.approvePool(pay);

        sup.armReenter(id, principal + fee);
        rtoken.armHook(address(sup), abi.encodeWithSelector(sup.doReenter.selector));

        // Independent payer settles; the supplier's reentry into settle must revert because
        // position.resolved is set BEFORE any external transfer (CEI).
        vm.expectRevert(
            abi.encodeWithSignature("FinancingPositionAlreadyResolved(uint256)", id)
        );
        vm.prank(buyer);
        pool.settleInvoice(id, pay);

        assertFalse(_positionResolved(id), "settle must have fully reverted");
    }

    // =========================================================================
    // 8. ERC721 onReceived on createInvoice
    // =========================================================================
    // Hypothesis: createInvoice _safeMints the NFT to the supplier; a contract supplier's
    //   onERC721Received can re-enter to advance the lifecycle (verify/finance) at CREATED.
    // Attack: supplier contract re-enters verify(id) and financeInvoice(id) from the mint hook.
    // Result: verify requires VERIFIER_ROLE (missing) and finance requires eligibility
    //   (invoice still CREATED, not VERIFIED) -> both revert. Lifecycle cannot be advanced
    //   illegally through the mint callback.
    // Verdict: SAFE.
    function test_SAFE_ERC721OnReceivedCannotAdvanceLifecycle() public {
        _seedTranches();

        NftReenterSupplier sup = new NftReenterSupplier(address(pool), address(invoiceNft));
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        // originator creates the invoice; _safeMint fires sup.onERC721Received which tries
        // to re-enter verify + finance. Both must fail internally; sup swallows the reverts
        // and records whether either succeeded.
        vm.prank(originator);
        uint256 id = invoiceNft.createInvoice(address(sup), buyer, FACE_VALUE, dueDate);

        assertFalse(sup.verifySucceeded(), "verify must not succeed from mint hook (no role)");
        assertFalse(sup.financeSucceeded(), "finance must not succeed from mint hook (not eligible)");

        // Invoice is still CREATED, no position, nothing locked.
        IInvoiceNFT.Invoice memory inv = invoiceNft.getInvoice(id);
        assertEq(uint256(inv.status), uint256(IInvoiceNFT.InvoiceStatus.CREATED), "invoice must stay CREATED");
        assertEq(_positionPrincipal(id), 0, "no position from mint-hook reentry");
    }

    // =========================================================================
    // 9. Read-only reentrancy during withdraw
    // =========================================================================
    // Hypothesis: SeniorPool._withdraw burns shares + safeTransfer(receiver) BEFORE the
    //   accountedAssets -= assets line runs. During the receiver transfer hook, shares are
    //   already burned but accountedAssets is still the pre-withdraw (inflated) value, so an
    //   external integrator reading convertToAssets / totalAssets sees a STALE, inflated
    //   share price. This is a genuine read-only-reentrancy window.
    // Attack: LP is a contract; on the withdraw transfer hook it records
    //   totalAssets/pricePerShare and compares to the correct post-withdraw values.
    // Result: an INCONSISTENT (stale-high) NAV is observable mid-withdraw. But it cannot be
    //   turned into value extraction against THIS protocol: the pools never call an external
    //   contract that reads their own price during a state-changing op, and every internal
    //   guard (availableLiquidity, creditAssets requiredCash) uses freshly-consistent values.
    // Verdict: INFO / read-only-reentrancy window (no HIGH/CRITICAL in-protocol impact).
    function test_INFO_ReadOnlyReentrancyStaleNavDuringWithdraw() public {
        ReadOnlyObserver lp = new ReadOnlyObserver(address(pool), address(seniorPool));

        rtoken.mint(address(lp), SENIOR_DEPOSIT);
        lp.approveAssetToPool(SENIOR_DEPOSIT);
        lp.depositSenior(SENIOR_DEPOSIT);
        lp.approveSharesToPool(type(uint256).max);

        // Credit some yield so price-per-share != 1 and staleness is observable in assets.
        // Do this by settling a small financed invoice.
        _depositJunior(juniorLp, JUNIOR_DEPOSIT);
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        uint256 pay = _positionPrincipal(id) + _positionFee(id);
        _settleAs(buyer, id, pay);

        uint256 totalAssetsBefore = seniorPool.totalAssets();

        // Withdraw a chunk; observe totalAssets mid-transfer.
        uint256 wd = 50_000e18;
        lp.armObserve();
        rtoken.armHook(address(lp), abi.encodeWithSelector(lp.doObserve.selector));
        lp.withdrawSenior(wd);

        uint256 observedMid = lp.observedTotalAssets();
        uint256 totalAssetsAfter = seniorPool.totalAssets();

        // The mid-withdraw observed NAV equals the PRE-withdraw NAV (stale/inflated),
        // NOT the correct post-withdraw NAV. This documents the read-only window.
        assertEq(observedMid, totalAssetsBefore, "mid-withdraw NAV is the stale pre-withdraw value");
        assertEq(totalAssetsAfter, totalAssetsBefore - wd, "final NAV correctly reduced by withdrawn assets");
        assertGt(observedMid, totalAssetsAfter, "stale NAV is strictly higher than the correct post-withdraw NAV");
    }

    // =========================================================================
    // 10. Cross-pool isolation during a senior transfer hook
    // =========================================================================
    // Hypothesis: during a senior-pool-bound transfer hook (settle), acting on the junior
    //   pool could exploit a shared/inconsistent state.
    // Attack: on the senior repayment transfer hook, re-enter withdrawJunior for the FULL
    //   junior deposit (junior principal is still locked mid-settle).
    // Result: junior availableLiquidity is still low (junior unlock hasn't run) -> reverts.
    //   Pools are fully independent; senior tx cannot manipulate junior accounting.
    // Verdict: SAFE.
    function test_SAFE_CrossPoolIsolationJuniorUntouchedDuringSeniorHook() public {
        // Junior LP is a contract able to reenter withdrawJunior.
        WithdrawAttacker jlp = new WithdrawAttacker(address(pool), address(juniorPool), false);

        _depositSenior(seniorLp, SENIOR_DEPOSIT);
        rtoken.mint(address(jlp), JUNIOR_DEPOSIT);
        jlp.approveAssetToPool(JUNIOR_DEPOSIT);
        jlp.depositJunior(JUNIOR_DEPOSIT);
        jlp.approveSharesToPool(type(uint256).max);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        uint256 pay = _positionPrincipal(id) + _positionFee(id);

        // Pre-fund payer before arming so the mint/approve don't trip the hook.
        _preparePayer(buyer, pay);

        // On the senior repayment transfer hook, try to drain the whole junior deposit.
        jlp.armReentrantWithdraw(JUNIOR_DEPOSIT);
        rtoken.armHook(address(jlp), abi.encodeWithSelector(jlp.doReentrantWithdraw.selector));

        // Junior principal is still locked mid-settle (junior unlock has not run yet), so the
        // reentrant junior withdraw is capped by maxWithdraw -> ERC4626ExceededMaxWithdraw.
        vm.expectPartialRevert(bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)")));
        vm.prank(buyer);
        pool.settleInvoice(id, pay);

        assertFalse(_positionResolved(id), "settle must have fully reverted");
    }

    // =========================================================================
    // 11. Value extraction attempt — conservation after a benign reentrant probe
    // =========================================================================
    // Hypothesis (the real goal): find ANY callback sequence that leaves the attacker with
    //   more assets than owed, or a pool with less NAV than cash.
    // Attack: LP re-enters withdrawSenior for the LARGEST amount that will NOT revert
    //   (i.e. within mid-tx availableLiquidity) during a settle transfer hook, banking a
    //   double action in one tx. Then measure attacker profit + pool NAV-vs-cash.
    // Result: the reentrant withdraw only ever moves assets the LP is genuinely entitled to
    //   (shares burned 1:1 against NAV); no surplus is created. Post-tx the senior pool's
    //   NAV is fully cash-backed and the attacker gained nothing beyond fair value.
    // Verdict: SAFE (no value extraction possible).
    function test_SAFE_NoValueExtractionViaReentrantWithdrawDuringSettle() public {
        WithdrawAttacker lp = new WithdrawAttacker(address(pool), address(seniorPool), true);

        rtoken.mint(address(lp), SENIOR_DEPOSIT);
        lp.approveAssetToPool(SENIOR_DEPOSIT);
        lp.depositSenior(SENIOR_DEPOSIT);
        _depositJunior(juniorLp, JUNIOR_DEPOSIT);
        lp.approveSharesToPool(type(uint256).max);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 id = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(id);
        _submitAndFinalizeOracleStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        uint256 pay = _positionPrincipal(id) + _positionFee(id);

        // Mid-settle available liquidity in senior = accountedAssets - lockedAssets - cash.
        // Pick a small, definitely-safe reentrant withdraw amount.
        uint256 safeWithdraw = 1_000e18;
        lp.armReentrantWithdraw(safeWithdraw);
        rtoken.armHook(address(lp), abi.encodeWithSelector(lp.doReentrantWithdraw.selector));

        uint256 lpAssetBefore = rtoken.balanceOf(address(lp));
        uint256 lpSharesBefore = seniorPool.balanceOf(address(lp));

        // This settle SUCCEEDS: the reentrant withdraw of 1_000e18 is within mid-tx liquidity.
        _settleAs(buyer, id, pay);

        assertTrue(_positionResolved(id), "settle should succeed with an in-budget reentrant withdraw");

        uint256 lpAssetAfter = rtoken.balanceOf(address(lp));
        uint256 lpSharesAfter = seniorPool.balanceOf(address(lp));

        // The LP received exactly `safeWithdraw` assets and burned shares worth ~that.
        uint256 assetsGained = lpAssetAfter - lpAssetBefore;
        uint256 sharesBurned = lpSharesBefore - lpSharesAfter;
        uint256 sharesBurnedValue = seniorPool.convertToAssets(sharesBurned);
        assertEq(assetsGained, safeWithdraw, "LP received exactly the withdrawn assets (no windfall)");
        // Value of burned shares must be >= assets withdrawn (LP did not extract more than fair).
        assertGe(sharesBurnedValue + 2, assetsGained, "no free value: shares burned back the assets");

        // CONSERVATION: SeniorPool NAV must be fully backed by cash now (nothing locked left
        // for this invoice, no phantom NAV). Cash >= accounted available liquidity.
        uint256 seniorCash = rtoken.balanceOf(address(seniorPool));
        uint256 seniorAvail = seniorPool.availableLiquidity();
        assertGe(seniorCash, seniorAvail, "senior pool must hold cash >= its available NAV (solvent)");
    }

    // =========================================================================
    // 12. Confirm absence of ReentrancyGuard (documentation assertion)
    // =========================================================================
    // Hypothesis: there is no nonReentrant guard; a benign single re-entry of a *view* or a
    //   fully-CEI'd path is possible but harmless. We prove reentrancy is *reachable* (hook
    //   fires) yet the fired-count is exactly what CEI predicts and no guard blocks it.
    // Verdict: SAFE (CEI is the sole and sufficient defense).
    function test_SAFE_HookActuallyFiresProvingNoGuardButCEIHolds() public {
        uint256 id = _fundedAndSettledOracle();
        uint256 pay = _positionPrincipal(id) + _positionFee(id);

        // A benign hook that just reads state (does not re-enter a state-changing fn).
        BenignReader reader = new BenignReader(address(pool), address(seniorPool));
        rtoken.armHook(address(reader), abi.encodeWithSelector(reader.peek.selector));

        uint256 fireBefore = rtoken.hookFireCount();
        _settleAs(buyer, id, pay);
        uint256 fireAfter = rtoken.hookFireCount();

        // The hook fired (reentrancy surface is real / no guard), yet settle completed
        // correctly because CEI protects it.
        assertEq(fireAfter - fireBefore, 1, "callback fired exactly once during settle (no guard)");
        assertTrue(_positionResolved(id), "settle completed correctly despite the callback");
        assertTrue(reader.peeked(), "external read happened mid-transfer");
    }
}

// =============================================================================
// Attacker / helper contracts
// =============================================================================

interface IPool {
    function settleInvoice(uint256 invoiceId, uint256 paidAmount) external;
    function resolveDefault(uint256 invoiceId) external;
    function financeInvoice(uint256 invoiceId) external;
    function depositSenior(uint256 assets) external returns (uint256);
    function depositJunior(uint256 assets) external returns (uint256);
    function withdrawSenior(uint256 assets) external returns (uint256);
    function withdrawJunior(uint256 assets) external returns (uint256);
    function ASSET() external view returns (address);
    function SENIOR_POOL() external view returns (address);
    function JUNIOR_POOL() external view returns (address);
    function totalLockedAssets() external view returns (uint256);
}

contract ReReenterHelper_Settle {
    IPool internal immutable POOL;
    uint256 internal immutable ID;

    constructor(address pool_, uint256 id_) {
        POOL = IPool(pool_);
        ID = id_;
    }

    function approvePool(uint256 amt) external {
        IERC20(POOL.ASSET()).approve(address(POOL), amt);
    }

    function settle(uint256 pay) external {
        POOL.settleInvoice(ID, pay);
    }

    // Re-enter settle for the same invoice; must revert AlreadyResolved.
    function reenter(uint256 pay) external {
        POOL.settleInvoice(ID, pay);
    }
}

contract ResolveAttacker {
    IPool internal immutable POOL;
    uint256 internal immutable ID;

    constructor(address pool_, uint256 id_) {
        POOL = IPool(pool_);
        ID = id_;
    }

    function approvePool(uint256 amt) external {
        IERC20(POOL.ASSET()).approve(address(POOL), amt);
    }

    function resolve() external {
        POOL.resolveDefault(ID);
    }

    function reenter() external {
        POOL.resolveDefault(ID);
    }
}

contract DepositAttacker {
    IPool internal immutable POOL;
    uint256 internal reentrantAmount;
    bool internal armed;

    constructor(address pool_) {
        POOL = IPool(pool_);
    }

    function approveAssetToPool(uint256 amt) external {
        IERC20(POOL.ASSET()).approve(address(POOL), amt);
    }

    function armReentrantDeposit(uint256 amt) external {
        reentrantAmount = amt;
        armed = true;
    }

    function depositSenior(uint256 amt) external {
        POOL.depositSenior(amt);
    }

    function doReentrantDeposit() external {
        if (!armed) return;
        armed = false;
        POOL.depositSenior(reentrantAmount);
    }
}

contract FinanceAttacker {
    IPool internal immutable POOL;
    uint256 internal reentrantId;
    bool internal armed;

    constructor(address pool_) {
        POOL = IPool(pool_);
    }

    function armReentrantFinance(uint256 id) external {
        reentrantId = id;
        armed = true;
    }

    function finance(uint256 id) external {
        POOL.financeInvoice(id);
    }

    function doReentrantFinance() external {
        if (!armed) return;
        armed = false;
        POOL.financeInvoice(reentrantId);
    }

    // Accept ERC721 mint (supplier receives the invoice NFT).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Combined supplier + senior LP for finance->withdraw probe.
contract FinanceWithdrawAttacker {
    IPool internal immutable POOL;
    ERC4626Like internal immutable SENIOR;
    uint256 internal reentrantWithdraw;
    bool internal armed;

    constructor(address pool_, address senior_) {
        POOL = IPool(pool_);
        SENIOR = ERC4626Like(senior_);
    }

    function approveAssetToPool(uint256 amt) external {
        IERC20(POOL.ASSET()).approve(address(POOL), amt);
    }

    function approveSharesToPool(uint256 amt) external {
        SENIOR.approve(address(POOL), amt);
    }

    function depositSenior(uint256 amt) external {
        POOL.depositSenior(amt);
    }

    function armReentrantWithdraw(uint256 amt) external {
        reentrantWithdraw = amt;
        armed = true;
    }

    function finance(uint256 id) external {
        POOL.financeInvoice(id);
    }

    function doReentrantWithdraw() external {
        if (!armed) return;
        armed = false;
        POOL.withdrawSenior(reentrantWithdraw);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Generic senior/junior LP that re-enters withdraw during a token hook.
contract WithdrawAttacker {
    IPool internal immutable POOL;
    ERC4626Like internal immutable VAULT;
    bool internal immutable IS_SENIOR;
    uint256 internal reentrantWithdraw;
    bool internal armed;

    constructor(address pool_, address vault_, bool isSenior_) {
        POOL = IPool(pool_);
        VAULT = ERC4626Like(vault_);
        IS_SENIOR = isSenior_;
    }

    function approveAssetToPool(uint256 amt) external {
        IERC20(POOL.ASSET()).approve(address(POOL), amt);
    }

    function approveSharesToPool(uint256 amt) external {
        VAULT.approve(address(POOL), amt);
    }

    function depositSenior(uint256 amt) external {
        POOL.depositSenior(amt);
    }

    function depositJunior(uint256 amt) external {
        POOL.depositJunior(amt);
    }

    function armReentrantWithdraw(uint256 amt) external {
        reentrantWithdraw = amt;
        armed = true;
    }

    function doReentrantWithdraw() external {
        if (!armed) return;
        armed = false;
        if (IS_SENIOR) {
            POOL.withdrawSenior(reentrantWithdraw);
        } else {
            POOL.withdrawJunior(reentrantWithdraw);
        }
    }
}

contract SurplusAttacker {
    IPool internal immutable POOL;
    uint256 internal reentrantId;
    uint256 internal reentrantPay;
    bool internal armed;

    constructor(address pool_) {
        POOL = IPool(pool_);
    }

    function approvePool(uint256 amt) external {
        IERC20(POOL.ASSET()).approve(address(POOL), amt);
    }

    function armReenter(uint256 id, uint256 pay) external {
        reentrantId = id;
        reentrantPay = pay;
        armed = true;
    }

    function doReenter() external {
        if (!armed) return;
        armed = false;
        POOL.settleInvoice(reentrantId, reentrantPay);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract NftReenterSupplier {
    IPool internal immutable POOL;
    InvoiceNftLike internal immutable NFT;
    bool public verifySucceeded;
    bool public financeSucceeded;

    constructor(address pool_, address nft_) {
        POOL = IPool(pool_);
        NFT = InvoiceNftLike(nft_);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        // Try to advance lifecycle from within the mint callback.
        try NFT.verify(tokenId) {
            verifySucceeded = true;
        } catch {}
        try POOL.financeInvoice(tokenId) {
            financeSucceeded = true;
        } catch {}
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ReadOnlyObserver {
    IPool internal immutable POOL;
    ERC4626Like internal immutable SENIOR;
    uint256 public observedTotalAssets;
    bool internal armed;

    constructor(address pool_, address senior_) {
        POOL = IPool(pool_);
        SENIOR = ERC4626Like(senior_);
    }

    function approveAssetToPool(uint256 amt) external {
        IERC20(POOL.ASSET()).approve(address(POOL), amt);
    }

    function approveSharesToPool(uint256 amt) external {
        SENIOR.approve(address(POOL), amt);
    }

    function depositSenior(uint256 amt) external {
        POOL.depositSenior(amt);
    }

    function withdrawSenior(uint256 amt) external {
        POOL.withdrawSenior(amt);
    }

    function armObserve() external {
        armed = true;
    }

    function doObserve() external {
        if (!armed) return;
        armed = false;
        observedTotalAssets = SENIOR.totalAssets();
    }
}

contract BenignReader {
    IPool internal immutable POOL;
    ERC4626Like internal immutable SENIOR;
    bool public peeked;

    constructor(address pool_, address senior_) {
        POOL = IPool(pool_);
        SENIOR = ERC4626Like(senior_);
    }

    function peek() external {
        // Read-only, does not re-enter any state-changing function.
        SENIOR.totalAssets();
        peeked = true;
    }
}

interface ERC4626Like {
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function convertToAssets(uint256) external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
}

interface InvoiceNftLike {
    function verify(uint256) external;
}

# Vector 06 — Economic / MEV / Front-running / Fee-on-transfer

## Scope
Cross-cutting economic timing attacks against the InvoiceFinancingPool + Senior/Junior
ERC-4626 tranches:
- LP deposit/withdraw timing vs `settleInvoice` (fee credit via `creditAssets`)
- LP deposit/withdraw timing vs `resolveDefault` (NAV loss via `writeDown`)
- Concentration TOCTOU (`checkConcentration` view vs atomic re-check in `financeInvoice`)
- Fee-on-transfer asset compatibility on deposit / settle / fund / recovery paths
- Permissionless `settleInvoice` / `resolveDefault` / `finalize` timing abuse

## Known-attack classes for this vector
1. JIT liquidity / yield theft — deposit right before a NAV credit, withdraw right after.
2. Loss-socialization front-running — exit an unlocked position before a pending writedown.
3. Sandwich around a victim LP deposit/withdraw to skim value.
4. TOCTOU on protocol limits (concentration cap checked in one tx, exceeded in another).
5. Fee-on-transfer accounting break (credited/received != transferred amount).
6. Permissionless-function timing abuse (choosing WHEN to call settle/resolve/finalize).
7. First-loss inversion via timing (junior LP escapes first-loss, keeps junior-tier fee).

## Numbered hypotheses (attacker goal + method) — >=10

1. **LOSS FRONT-RUNNING (primary).** Goal: a junior LP escapes an impending writedown and
   dumps the loss onto co-LPs. Method: two junior LPs; oracle finalizes DEFAULTED (public);
   *before* `resolveDefault`, LP1 withdraws their available (unlocked) liquidity at full NAV;
   `resolveDefault` then writes NAV down, and the remaining LP2 absorbs LP1's share of the loss.
   Quantify escaped value vs a control LP.

2. **JIT YIELD CAPTURE (settle).** Goal: capture fee earned over a full tenor with ~0 duration
   risk. Method: attacker deposits into junior right before `settleInvoice` credits `juniorFee`,
   withdraws right after; measures pro-rata fee slice stolen from the long-term LP.

3. **FEE-ON-TRANSFER deposit break.** Deploy on FeeOnTransferToken; `depositSenior/Junior`
   pulls assets to the coordinator (receives less), then deposits the *full* amount into the
   vault. Determine: DoS revert, or shares minted not backed by cash. Show exact outcome.

4. **FEE-ON-TRANSFER settle break.** On FeeOnTransferToken, `settleInvoice` transfers
   senior/juniorRepayment to the vaults; vault receives less; `creditAssets` requiredCash
   solvency check either reverts (settlement DoS) or, if it passes, NAV is credited unbacked.
   Show which.

5. **FEE-ON-TRANSFER fund/recovery paths.** Check `financeInvoice`→`fundInvoice` and
   `resolveDefault` recovery transfer under fee-on-transfer; do they revert or mis-account?

6. **CONCENTRATION TOCTOU.** Goal: exceed `maxExposurePerBuyer`. Method: pre-check
   `checkConcentration` view true; between check and `financeInvoice`, add other exposure to
   the same buyer; confirm `financeInvoice` re-checks atomically and reverts. Try to exceed.

7. **WITHDRAW-AFTER-FINALIZE (SETTLED) race.** Goal: time entry/exit around the fee credit
   using the public finalized-SETTLED state before `settleInvoice` executes. Method: deposit
   after finalize but before settle, withdraw after settle; compare to #2.

8. **PERMISSIONLESS SETTLE/RESOLVE TIMING.** Goal: griefer/searcher gains by choosing WHEN to
   call. Method: show `settleInvoice`/`resolveDefault` are permissionless and that a searcher
   deliberately NOT calling resolveDefault keeps the loss-front-running window (#1) open; and
   that anyone can trigger the credit to bootstrap a JIT (#2).

9. **DEPOSIT/WITHDRAW SANDWICH around a credit.** Goal: skim value from a victim LP's deposit
   that lands right before a credit. Method: attacker front-runs with a large deposit to dilute,
   or back-runs; quantify whether victim is measurably harmed vs no-sandwich control.

10. **FIRST-LOSS INVERSION via timing.** Goal: junior LP collects junior-tier fee on invoice A,
    then on the *next* invoice B's default exits before its writedown → de-facto senior. Method:
    settle A (junior earns enhanced fee), then default B, junior LP exits available liquidity
    before resolveDefault; assert they kept fee + escaped loss.

11. **FEE NOT PRO-RATED TO HOLDING TIME.** Goal: quantify that a 1-block JIT LP earns the same
    per-share fee as a full-tenor LP. Method: equal deposits, one held full tenor, one JIT at
    settle; compare realized per-share gain.

12. **SENIOR-SIDE JIT / loss front-run symmetry check.** Confirm whether the senior tranche has
    the same JIT surface on its `seniorFee` credit and whether senior can front-run its residual
    writedown (only bites when recovery < seniorPrincipal).

## Verdict encoding
- SAFE probe: `vm.expectRevert` on the malicious action OR assert the guarantee still holds.
- FINDING probe: construct exploit + assert the harmful outcome (attacker gain / victim loss /
  invariant broken) actually occurs. Severity assessed adversarially (HIGH/CRITICAL only get a
  finding folder).

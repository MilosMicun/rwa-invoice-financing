# VECTOR 02 — Tranche waterfall & loss/recovery accounting — PLAN

## Scope
- `src/core/InvoiceFinancingPool.sol`: `settleInvoice`, `resolveDefault`.
- `src/pools/SeniorPool.sol`, `src/pools/JuniorPool.sol`: `lockAssets`, `unlockAssets`,
  `fundInvoice`, `creditAssets`, `writeDown`, `availableLiquidity`, `totalAssets`.

## Stated guarantees under test
1. **Senior protection / first-loss ordering** — junior (first-loss) tranche is wiped
   before senior takes any principal loss. Whenever `recovery >= seniorPrincipal`, senior
   NAV loss must be exactly zero.
2. **LP accounting conservation** — no unauthorized loss/gain; NAV moves only by realized
   fee (settle) or realized loss (default).
3. **One-shot resolution** — `totalLockedAssets` decremented exactly once; a position cannot
   be both settled and defaulted, nor resolved twice (`resolved` flag).
4. **Bad-debt correctness** — `totalBadDebt += principal - recovery`; unpaid fee excluded.
5. **Funds not stranded** — `writeDown` cannot be forced to revert and permanently strand a
   defaulted position.

## Known-attack classes for this vector
- Waterfall inversion (recovery routed to wrong tranche).
- First-loss violation (senior takes loss while junior still has value).
- writeDown-DoS (`assets > availableLiquidity` revert strands the position).
- Bad-debt over/under counting (double count, or counting the fee).
- Split-rounding misallocation (funding split floor / fee split floor).
- NAV conservation break / double-decrement of locked assets.

## Waterfall math (from source)
- Funding: `seniorPrincipal = floor(principal * 7000/10000)`, `juniorPrincipal = principal - seniorPrincipal`.
- Recovery (default): `seniorRecovery = min(recovery, seniorPrincipal)`, `juniorRecovery = recovery - seniorRecovery`.
- Loss: `seniorLoss = seniorPrincipal - seniorRecovery`, `juniorLoss = juniorPrincipal - juniorRecovery`, `loss = principal - recovery`.
- Fee split (settle): `juniorFee = floor(fee * 6000/10000)`, `seniorFee = fee - juniorFee`.
- Order in resolveDefault: transfers (senior then junior) -> unlock senior -> unlock junior
  -> writeDown junior -> writeDown senior. CEI: `resolved`, `totalLockedAssets`, `totalBadDebt`
  all set BEFORE external calls.

## Hypotheses (attacker goal + method) — >=10

1. **Senior-protection matrix.** Goal: find a recovery where senior loses NAV although
   `recovery >= seniorPrincipal`. Method: sweep recovery in {0, <senior, =senior, between
   senior and principal, =principal}; assert exact senior/junior NAV deltas each time.
   Expected SAFE.

2. **First-loss ordering.** Goal: senior takes loss while junior still has residual value in
   the SAME position. Method: at recovery = seniorPrincipal, assert junior fully wiped
   (juniorLoss==juniorPrincipal) AND senior loss==0; at recovery just below seniorPrincipal
   assert junior fully wiped and senior begins to lose. Expected SAFE (impossible to invert).

3. **writeDown-DoS with a competing locked position.** Goal: make `resolveDefault`'s junior
   `writeDown` revert (`assets>availableLiquidity`) so the defaulted position is stranded.
   Method: two active positions locking most junior liquidity; default one with recovery=0
   (max writedown). Assert it does NOT revert and NAV is written down. Expected SAFE.

4. **writeDown-DoS after junior LP drains all available liquidity.** Goal: same DoS via a
   junior LP withdrawing every unlocked asset just before resolution, leaving
   availableLiquidity==0. Method: one active position, junior LP withdraws max, then default
   with recovery=0. Assert resolveDefault still succeeds (unlock precedes writeDown). SAFE.

5. **Bad-debt exact accounting.** Goal: make `totalBadDebt` != principal-recovery, or make it
   include the fee. Method: default with partial recovery; assert `totalBadDebt ==
   principal - recovery` exactly and strictly less than principal - recovery + fee. SAFE.

6. **Bad-debt across two positions (no cross-contamination / double count).** Goal: resolving
   position A corrupts position B's contribution to totalBadDebt. Method: default two
   positions with different recoveries; assert cumulative badDebt == sum of the two losses.
   SAFE.

7. **Double-resolve blocked (settle-then-default, default-then-settle, resolve-twice).** Goal:
   decrement `totalLockedAssets` twice or apply two waterfalls. Method: settle, then attempt
   resolveDefault (expect revert) and re-settle (expect revert). Symmetric for default first.
   SAFE.

8. **Fee-split conservation at settlement.** Goal: seniorFee+juniorFee != fee, or principal
   not fully restored, or surplus mis-sent. Method: settle with surplus; assert
   seniorFee+juniorFee==fee, senior NAV delta==seniorFee, junior NAV delta==juniorFee,
   supplier receives surplus, totalLockedAssets back to 0. SAFE.

9. **Cross-position isolation on default.** Goal: resolving one position mutates the other's
   locked/NAV. Method: two positions same buyer; snapshot NAV/locked; default one; assert the
   untouched position's principal still locked and its tranche NAV unaffected beyond the
   resolved one. SAFE.

10. **NAV conservation invariant over a multi-step sequence.** Goal: break
    `(seniorNAV+juniorNAV) - initialDeposits == realizedFees - realizedLosses`. Method: run
    settle + partial-default + full-default sequence, then assert the identity holds exactly.
    SAFE.

11. **Settlement underpayment boundary.** Goal: settle for less than principal+fee (LP loss)
    or break the exact boundary. Method: paidAmount = expected-1 reverts; paidAmount = exact
    works (zero surplus); huge surplus routes fully to supplier. SAFE.

12. **Recovery edge = principal (no loss) and = seniorPrincipal (junior fully wiped, senior
    whole).** Goal: any NAV leakage at the edges. Method: recovery=principal => both losses 0,
    badDebt unchanged; recovery=seniorPrincipal => juniorLoss==juniorPrincipal, seniorLoss==0.
    SAFE.

13. **Junior-recovery misrouting via funding remainder.** Goal: with a principal whose
    7000-bps split leaves a remainder on the junior side, check recovery just at seniorPrincipal
    still leaves junior with the exact remainder loss and senior whole (no rounding leaks the
    junior remainder to senior). Method: craft face value giving a non-round split. SAFE.

## Verdict expectation
The waterfall is a clean, well-ordered senior-first design with CEI and monotone
lock/unlock/writeDown invariants. Expectation is that all probes are SAFE and the vector
yields negative documentation (no HIGH/CRITICAL). Any surprise (writeDown revert, double
decrement, badDebt drift) would be a HIGH finding and written up under findings/.

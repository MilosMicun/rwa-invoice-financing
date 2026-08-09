# Vector 08 — Arithmetic, Rounding, Precision & DoS

## Scope
- `src/risk/RWARiskManager.sol` — `calculateAdvance` (mulDiv), `calculateFee` (linear APR mulDiv),
  `checkConcentration`, `updateBuyerExposure`, `_setRiskParams`.
- `src/core/InvoiceFinancingPool.sol` — funding split (senior/junior principal), fee split
  (senior/junior fee), `totalLockedAssets` / `totalBadDebt` arithmetic, waterfall.
- `src/pools/SeniorPool.sol` / `JuniorPool.sol` — `availableLiquidity` (accountedAssets - lockedAssets),
  `lockAssets` / `unlockAssets` / `writeDown` / `creditAssets` guards.

## Known-attack classes for this vector
1. mulDiv overflow / precision loss.
2. Rounding-to-zero (fee, tranche split) → value leak or DoS revert.
3. Off-by-one on concentration / exposure limits.
4. Under/overflow (exposure decrement, availableLiquidity subtraction, writeDown).
5. Division edge cases (zero principal, zero duration).
6. Conservation violations (senior+junior != principal / fee).
7. DoS via revert (a legitimately eligible invoice cannot be financed).
8. Governance guardrail bypass (advanceRate/apr/tenor bounds).
9. Dust accumulation across repeated cycles.

## Numbered hypotheses (attacker goal + method)

1. **ZeroTranchePrincipal DoS boundary** — Goal: make an isEligible() invoice revert on
   `financeInvoice` with ZeroTranchePrincipal, stranding the supplier. Method: admin sets a
   permissive config (tiny minInvoiceAmount, low advanceRate) so a small face value passes
   eligibility (advance>0) but `seniorPrincipal = principal*7000/10000 == 0` or
   `juniorPrincipal == 0`. Map exact boundary; classify griefing/DoS severity.

2. **calculateAdvance extreme faceValue** — Goal: overflow/revert calculateAdvance with faceValue
   near type(uint256).max. Method: fuzz/boundary faceValue up to max/advanceRate; assert mulDiv
   returns correct floor value, no revert. SAFE expected.

3. **calculateFee rounding-to-zero** — Goal: active position with fee==0 (LP earns nothing).
   Method: small principal + short tenor so mulDiv floors to 0. Map boundary; assess value leak.

4. **calculateFee overflow safety at max params** — Goal: overflow fee at apr=5000, tenor=365d,
   huge principal. Method: set max params, principal near uint256 max/(apr*duration); assert
   correctness / graceful revert only on genuine >2^256 product. SAFE expected.

5. **Exposure underflow on decrease** — Goal: force ExposureUnderflow or a stuck buyer. Method:
   attempt double-decrement via full settle then a second settle; confirm second reverts earlier
   (resolved guard) so exposure cannot underflow. Also unit-test updateBuyerExposure directly via
   POOL_ROLE granted to a test contract? (POOL_ROLE is pool-only; test the invariant via lifecycle.)

6. **Exposure overflow on increase** — Goal: overflow buyerExposure via repeated increases.
   Method: assess reachability — concentration cap (maxExposurePerBuyer <= uint256) bounds each
   increase; show overflow is unreachable through the pool. SAFE/INFO.

7. **checkConcentration off-by-one** — Goal: exceed maxExposure by 1, or wrongly reject exact
   equality. Method: exposure+newAmount == maxExposure must be allowed; +1 rejected;
   newAmount>maxExposure early-out. Boundary test. SAFE expected.

8. **availableLiquidity underflow** — Goal: make accountedAssets < lockedAssets so
   availableLiquidity() reverts. Method: sequence finance/withdraw/writeDown/unlock; prove the
   guards (lock<=available, writeDown<=available) keep accountedAssets>=lockedAssets. SAFE.

9. **writeDown revert DoS in resolveDefault** — Goal: make resolveDefault revert on
   writeDown (assets>availableLiquidity or >accountedAssets), stranding a defaulted invoice.
   Method: construct a state (e.g. junior fully locked by another invoice) so junior writeDown
   would exceed junior availableLiquidity. Assess reachability.

10. **Conservation fuzz — funding split** — For random valid principal, assert
    seniorPrincipal+juniorPrincipal == principal (no wei lost/created). Fuzz.

11. **Conservation fuzz — fee split** — For random fee, assert seniorFee+juniorFee == fee. Fuzz.

12. **Governance guardrails** — _setRiskParams rejects advanceRate>9000, apr>5000, tenor>365d,
    and any zero field. Confirm bounds hold; cannot be bypassed. SAFE expected.

13. **Dust across cycles** — Goal: extract value or strand dust via repeated deposit/withdraw and
    settle cycles. Method: run N settle cycles; assert NAV conservation, no attacker profit, LP
    principal preserved. SAFE expected.

14. **First-loss waterfall integrity under recovery** — Goal: a recovery value that makes senior
    lose while junior is whole (violating senior-first). Method: sweep recoveredAmount across
    [0, principal]; assert senior loss > 0 only when junior fully wiped. SAFE expected.

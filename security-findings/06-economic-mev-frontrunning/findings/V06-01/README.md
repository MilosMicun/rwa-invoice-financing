# V06-01 — Junior LP front-runs the default writedown, socializing its loss onto co-LPs

## Severity
HIGH

## Location
- `src/core/InvoiceFinancingPool.sol:494-581` (`resolveDefault`; writedown executed at 557-563)
- `src/oracle/InvoiceStatusOracle.sol:197-233` (`finalize` — publishes DEFAULTED outcome before resolution)
- `src/pools/JuniorPool.sol:73-86` (`availableLiquidity`, `maxWithdraw`) and `:187-203` (`writeDown`)

## Description
The default loss waterfall is a two-step, non-atomic public process:

1. Anyone calls `InvoiceStatusOracle.finalize(invoiceId)` once the dispute window has elapsed.
   This calls `pool.onStatusFinalized(...)` and records `finalizedOracleStatus = DEFAULTED` and
   the recovery amount. It emits `StatusFinalized`/`OracleStatusFinalized`. The pending loss is now
   **public and inevitable**, but no NAV has been written down yet.
2. Separately, and at an unbounded later time, someone calls `resolveDefault(invoiceId)`, which
   finally calls `JuniorPool.writeDown(juniorLoss)` (and, on severe defaults, `SeniorPool.writeDown`),
   dropping the tranche NAV / share price.

Between step 1 and step 2, a junior LP's *unlocked* liquidity is still redeemable at the **full,
un-written-down** share price. `JuniorPool.maxWithdraw` only restricts withdrawals to
`min(ownerAssets, availableLiquidity, cash)` — it has no awareness that a writedown is finalized and
pending. A junior LP who watches the finalize event can therefore redeem their available liquidity
at the old NAV and escape the loss entirely. Because `writeDown` reduces `accountedAssets` for the
**remaining** shares only, the escaping LP's share of the loss is transferred to the LPs who stayed.

This breaks the protocol's stated first-loss socialization: the junior tranche is supposed to absorb
first loss *pro-rata across junior shareholders*. Timing lets one junior LP convert into a de-facto
loss-free position at the direct expense of passive co-LPs.

The `resolveDefault` step being permissionless-but-optional makes the window **open-ended** — nobody
is obligated to call it, so the escaping LP is not even racing a specific transaction; they have as
long as they want (demonstrated 30 days later in
`test_FINDING_searcherWithholdsResolveToKeepFrontRunWindowOpen`).

## Root cause
Loss recognition (`writeDown`) is decoupled in time from the moment the loss becomes known/finalized,
and withdrawals are priced off `accountedAssets` which is not adjusted until `resolveDefault` runs.
There is no share lockup, no "pending loss" haircut on `maxWithdraw`/`convertToAssets`, and no
mechanism that forces loss recognition atomically with (or before) finalization for the affected
invoice's tranche.

## Attack scenario (step by step)
Precondition: junior tranche has ≥2 LPs and some unlocked liquidity (the normal state — only a
fraction of tranche NAV is locked per invoice).

1. LP_A and LP_B each deposit 150,000 into the junior tranche (total NAV 300,000).
2. One invoice is financed; junior principal (24,000) is locked. Junior `availableLiquidity` and cash
   are 276,000.
3. The invoice defaults. A submitter reports DEFAULTED (recovery 0); after the dispute window anyone
   calls `finalize` → the DEFAULTED outcome is public on-chain.
4. LP_A (attacker) immediately redeems its maximum (150,000) at the still-full NAV via
   `withdrawJunior`. It exits whole.
5. `resolveDefault` is later called. `writeDown(24,000)` now hits only the remaining shares, i.e.
   LP_B. LP_B's 150,000 position is marked down to ~126,000.

Result: LP_A escaped its 12,000 fair share of the loss; LP_B absorbed the full 24,000 instead of
12,000 — a 100% overcharge relative to fair socialization.

## Impact
- Direct, quantifiable loss transfer between junior LPs (first-loss fairness violated).
- Passive / slower LPs systematically subsidize sophisticated LPs on every default.
- Erodes the economic meaning of the first-loss tranche: an informed junior LP is never truly
  first-loss, defeating the senior-protection design's assumption that junior capital is committed.
- No privileged role required; any junior LP can do it; the window is open-ended.

## Proof of Concept
Test functions (file `security-findings/06-economic-mev-frontrunning/poc/EconomicMEV.t.sol`):
- `test_FINDING_juniorExitBeforeWritedownDumpsLossOnCoLP` — attacker exits ~whole (≈150,000), victim
  bears ≈the entire 24,000 junior loss (asserts `victimLoss ≈ juniorPrincipal`).
- `test_FINDING_searcherWithholdsResolveToKeepFrontRunWindowOpen` — full-NAV exit still works 30
  days after finalization (window is open-ended, not a tight race).
- Control: `test_SAFE_ifNoOneExitsLossIsSocializedFairly` — if nobody times the exit, the loss is
  split equally (proves the harm is caused by TIMING, not the waterfall itself).

Run:
```
FOUNDRY_TEST=security-findings/06-economic-mev-frontrunning FOUNDRY_OUT=out-v06 FOUNDRY_CACHE_PATH=cache-v06 \
  forge test --match-path 'security-findings/06-economic-mev-frontrunning/poc/EconomicMEV.t.sol' \
  --match-test 'test_FINDING_juniorExitBeforeWritedownDumpsLossOnCoLP|test_FINDING_searcherWithholdsResolveToKeepFrontRunWindowOpen|test_SAFE_ifNoOneExitsLossIsSocializedFairly' -vv
```

## Recommended fix
Any one of the following closes the timing gap:
- **Recognize the loss atomically with finalization**: have `onStatusFinalized`/`finalize` for a
  DEFAULTED outcome mark down the affected tranche NAV (or freeze withdrawals for that tranche) in
  the same transaction, rather than deferring the entire writedown to a separate optional
  `resolveDefault` call.
- **Pending-loss haircut on exits**: while an invoice tied to a tranche has a finalized-but-unresolved
  DEFAULTED status, reduce `maxWithdraw`/`convertToAssets` by the pending writedown so exiting LPs
  pre-pay their pro-rata share.
- **Withdrawal lockup / notice period** for junior LPs that spans the finalize→resolve window, so no
  one can exit at stale NAV after a default is public.
- **Auto-resolve on finalize**: make finalization of a DEFAULTED invoice trigger `resolveDefault`
  bookkeeping immediately (recovery can be pulled from a pre-funded escrow) so there is no
  exploitable gap.

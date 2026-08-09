# Vector 06 — Economic / MEV / Front-running / Fee-on-transfer

Cross-cutting economic timing attacks on LP deposit/withdraw vs settlement (fee credit) and default
(writedown), concentration TOCTOU, permissionless-function timing, and fee-on-transfer asset
compatibility.

## Results

| # | Hypothesis | Test function | Verdict | Severity | One-line result |
|---|------------|---------------|---------|----------|-----------------|
| 1 | Junior LP exits before default writedown, dumping loss on co-LPs | `test_FINDING_juniorExitBeforeWritedownDumpsLossOnCoLP` | FINDING | HIGH | Attacker exits ~whole; passive co-LP bears ~the entire junior loss (2x fair) |
| 1c | Control: no timing → loss socialized fairly | `test_SAFE_ifNoOneExitsLossIsSocializedFairly` | SAFE | INFO | Equal junior LPs each bear half the loss when nobody front-runs |
| 2 | JIT deposit captures junior settlement fee | `test_FINDING_jitDepositCapturesSettlementFee` | FINDING | HIGH | 1-tx JIT LP nets ≈juniorFee/2; honest full-tenor LP diluted to half its fee |
| 11 | Fee not pro-rated to holding time | `test_FINDING_feeNotProRatedByHoldingTime` | FINDING | HIGH | Per-share gain identical for 1-block JIT LP and full-tenor LP |
| 12 | Senior-tranche JIT symmetry (senior fee) | `test_FINDING_seniorJitCapturesSeniorFee` | FINDING | HIGH | Same JIT capture works on the senior fee credit |
| 7 | Deposit in public finalize→settle window still captures fee | `test_FINDING_depositAfterSettledFinalizeStillCapturesFee` | FINDING | HIGH | `finalize(SETTLED)` is a usable public trigger for the JIT |
| 8a | Permissionless resolve cannot choose recovery | `test_SAFE_permissionlessResolveCannotChooseRecovery` | SAFE | — | Caller funds only; recovery is fixed by the oracle, no discretion |
| 8b | Searcher withholds resolve → open-ended front-run window | `test_FINDING_searcherWithholdsResolveToKeepFrontRunWindowOpen` | FINDING | HIGH | Full-NAV junior exit still works 30 days after finalized default |
| 6 | Concentration TOCTOU (exceed per-buyer cap) | `test_SAFE_concentrationReCheckedAtomically` | SAFE | — | `financeInvoice` re-checks `checkConcentration` atomically; cap holds |
| 9 | Donation-based sandwich around a credit | `test_SAFE_donationDoesNotMoveSharePriceForSandwich` | SAFE | — | `totalAssets()==accountedAssets`; raw donations don't move share price |
| 12b | Senior residual writedown front-run (severe default) | `test_SAFE_seniorCannotFrontRunResidualWritedownWhenNAVLocked` | SAFE/INFO | — | Same root cause as #1; waterfall ordering (junior first) intact |
| 3 | Fee-on-transfer senior deposit | `test_SAFE_feeOnTransferDepositRevertsNoUnbackedShares` | SAFE | LOW | Deposit reverts; no unbacked shares/NAV (fee token unsupported) |
| 3b | Fee-on-transfer junior deposit | `test_SAFE_feeOnTransferJuniorDepositAlsoReverts` | SAFE | LOW | Same: reverts, no unbacked NAV |
| 4/5 | Fee-on-transfer full lifecycle | `test_SAFE_feeOnTransferBlocksEntireLifecycleAtDeposit` | SAFE | LOW | Fails closed at deposit; finance/settle/resolve unreachable, no corruption |
| 4b | `creditAssets` solvency guard vs unbacked NAV | `test_SAFE_creditAssetsSolvencyCheckPreventsUnbackedNAV` | SAFE | — | requiredCash check + accountedAssets design → no unbacked NAV possible |

## How to run

```
FOUNDRY_TEST=security-findings/06-economic-mev-frontrunning FOUNDRY_OUT=out-v06 FOUNDRY_CACHE_PATH=cache-v06 \
  forge test --match-path 'security-findings/06-economic-mev-frontrunning/poc/*.t.sol' -vv
```

Note: `FOUNDRY_TEST` is scoped to this vector's folder so a currently-broken sibling vector's test
file does not block compilation of this vector (the shared `_base/Harness.sol` is still pulled in via
the import graph).

## Final observed suite result

```
Ran 2 test suites in 10.99ms (13.40ms CPU time): 15 tests passed, 0 failed, 0 skipped (15 total tests)
```

Per-file:
```
Suite result: ok. 11 passed; 0 failed; 0 skipped; finished in 6.42ms (EconomicMEV.t.sol)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 1.50ms (FeeOnTransfer.t.sol)
```

## What protects this / what breaks

### What breaks (2 confirmed HIGH findings)

**V06-01 — Loss-socialization front-running (junior exit before writedown).**
Default loss recognition is a two-step, non-atomic, public process: `InvoiceStatusOracle.finalize`
publishes the DEFAULTED outcome (`src/oracle/InvoiceStatusOracle.sol:197-233`), and only a later,
separate, *optional*, permissionless `resolveDefault` actually calls
`JuniorPool.writeDown` (`src/core/InvoiceFinancingPool.sol:557-563`). In between, junior
`maxWithdraw` still prices exits off the un-written-down `accountedAssets`
(`src/pools/JuniorPool.sol:73-86`), so a junior LP redeems at stale NAV and escapes the loss; the
writedown then falls only on the remaining shares. First-loss socialization among junior LPs is
broken, and because nobody is obligated to call `resolveDefault`, the exit window is open-ended. See
`findings/V06-01/`.

**V06-02 — JIT capture of the settlement fee (both tranches).**
Fees are booked as an instantaneous NAV step (`accountedAssets += fee`) in `creditAssets`
(`src/pools/JuniorPool.sol:164-181`, `SeniorPool.sol:164-181`) called from `settleInvoice`
(`src/core/InvoiceFinancingPool.sol:434-440`), split by shares held at that single block, with no
duration weighting, no lockup, and a public trigger (`finalize`) plus a permissionless, freely-timed
`settleInvoice`. A JIT LP deposits right before the credit and withdraws right after, capturing a
pro-rata slice of a full-tenor fee risk-free and diluting long-term LPs. Per-share gain is identical
for a 1-block LP and a full-tenor LP. See `findings/V06-02/`.

### What protects this (holds up)

- **Concentration TOCTOU is closed.** `financeInvoice` re-checks `checkConcentration(buyer, principal)`
  atomically inside the funding transaction (`src/core/InvoiceFinancingPool.sol:275`), and
  `updateBuyerExposure` runs in the same tx (line 319). A stale view result cannot be used to exceed
  `maxExposurePerBuyer`.
- **Donation/inflation neutralized.** `totalAssets()` returns internal `accountedAssets`
  (`src/pools/JuniorPool.sol:68`), so raw ERC20 donations cannot move share price — a whole class of
  sandwich/first-depositor inflation attacks is defused by construction.
- **Caller of `resolveDefault` has no economic discretion.** Recovery is read from
  `finalizedRecoveryAmount` (`src/core/InvoiceFinancingPool.sol:515`), not from the caller; the
  permissionless executor can only fund the oracle-fixed amount and cannot re-shape the waterfall.
- **`creditAssets` solvency guard.** `requiredCash = availableLiquidity + assets` must be backed by
  real balance before NAV grows (`src/pools/JuniorPool.sol:172-176`), so a fee credit can never
  create unbacked NAV.
- **Fee-on-transfer tokens fail closed.** `depositSeniorFor`/`depositJuniorFor` pull `assets` to the
  coordinator then deposit the *full* `assets` into the vault
  (`src/core/InvoiceFinancingPool.sol:601-604, 629-632`); on a taxed token the coordinator is short
  and the inner transfer reverts. No unbacked shares are minted; the protocol is simply incompatible
  with such assets (INFO/LOW — a documented integration constraint, not an exploit).

### Medium/Low/Info notes (no finding folder)
- **Fee-on-transfer incompatibility (LOW/INFO):** the protocol silently DoSes on any fee-on-transfer
  asset at the deposit step. Not exploitable for gain, but should be documented / asset-allowlisted.
- **Senior residual writedown timing (INFO):** senior LPs share the same finalize→resolve exit
  surface as V06-01 on severe defaults; it is the same root cause, not an independent bug. The
  junior-first waterfall ordering itself is intact.

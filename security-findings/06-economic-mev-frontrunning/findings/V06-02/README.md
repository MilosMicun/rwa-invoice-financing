# V06-02 — JIT liquidity captures the settlement fee (both tranches), diluting long-term LPs

## Severity
HIGH

## Location
- `src/core/InvoiceFinancingPool.sol:406-440` (`settleInvoice`: fee split and `creditAssets` calls at 434-440)
- `src/pools/JuniorPool.sol:164-181` and `src/pools/SeniorPool.sol:164-181` (`creditAssets` — lump NAV bump)
- `src/oracle/InvoiceStatusOracle.sol:197-233` (`finalize` — public SETTLED signal that a fee credit is imminent)

## Description
Financing fees are realized as a single, lump NAV increase at settlement. In `settleInvoice`, after
the repayment cash is transferred to the vaults, the pool calls `SeniorPool.creditAssets(seniorFee)`
and `JuniorPool.creditAssets(juniorFee)`. `creditAssets` simply does `accountedAssets += fee`, which
raises the ERC-4626 share price for **every current shareholder pro-rata at that instant**.

The fee is calculated once at funding time over the full invoice tenor
(`RWARiskManager.calculateFee`, `src/risk/RWARiskManager.sol:194-203`) and is **not weighted by how
long each LP actually held shares**. Combined with permissionless, freely-timed settlement, this
creates a just-in-time (JIT) yield-capture:

- The SETTLED outcome becomes public when anyone calls `finalize` (before `settleInvoice` executes),
  and the actual `settleInvoice` call sits in the mempool. Either signal tells an attacker a fee
  credit is imminent.
- The attacker deposits a large amount into the tranche right before the credit, so it owns a large
  share fraction at the instant `creditAssets` runs.
- Immediately after settlement, the attacker withdraws. It captures a pro-rata slice of a fee that
  accrued over the entire tenor, having borne ~zero duration risk and ~zero default risk.

Because vault share price does not move on raw token donations (`totalAssets` returns
`accountedAssets`), the only lever is genuine deposits — but that is exactly what a JIT LP supplies,
and it works. Every unit the JIT captures is diverted from the LPs who actually funded the invoice
for its whole life.

## Root cause
Realized yield is booked as an instantaneous NAV step (`accountedAssets += fee`) shared by whoever
holds shares at that single block, with:
- no duration weighting / streaming of the fee,
- no deposit lockup or entry/exit fee,
- a public trigger (`finalize`) and a permissionless, freely-timed executor (`settleInvoice`).

## Attack scenario (step by step)
1. Honest LP holds 300,000 in the junior tranche for the full 30-day tenor of a financed invoice.
2. The buyer's SETTLED outcome is finalized (public). The settlement transaction is imminent.
3. Attacker JIT-deposits 300,000 into the junior tranche in the block(s) around settlement (e.g.
   front-runs the settle tx with a deposit).
4. `settleInvoice` runs: `creditAssets(juniorFee)` bumps junior NAV. Attacker and honest LP each now
   own ~half the pool, so each captures ~half of `juniorFee`.
5. Attacker withdraws immediately, realizing ≈`juniorFee/2` profit for a single-block hold.

The honest, full-tenor LP receives only ≈half the fee it earned. The identical attack works on the
senior tranche via `seniorFee`.

## Impact
- Risk-free, permissionless theft of realized yield from long-term LPs on every settlement.
- The per-share fee of a 1-block JIT LP equals that of a full-tenor LP (no duration weighting) —
  proven directly. This structurally disincentivizes committed liquidity and rewards mempool
  snipers.
- Applies to both tranches; scales with the attacker's deposit size relative to standing NAV, so a
  whale can capture the large majority of every fee.

## Proof of Concept
Test functions (file `security-findings/06-economic-mev-frontrunning/poc/EconomicMEV.t.sol`):
- `test_FINDING_jitDepositCapturesSettlementFee` — JIT junior LP nets ≈`juniorFee/2` in one tx; the
  honest LP is diluted to ≈half the fee it earned.
- `test_FINDING_seniorJitCapturesSeniorFee` — same attack on the senior tranche fee.
- `test_FINDING_feeNotProRatedByHoldingTime` — per-share realized gain is identical for a 1-block JIT
  LP and a full-tenor LP (asserts equality) — the root cause.
- `test_FINDING_depositAfterSettledFinalizeStillCapturesFee` — deposit in the public finalize→settle
  window still captures the fee (confirms `finalize` is a usable trigger signal).

Run:
```
FOUNDRY_TEST=security-findings/06-economic-mev-frontrunning FOUNDRY_OUT=out-v06 FOUNDRY_CACHE_PATH=cache-v06 \
  forge test --match-path 'security-findings/06-economic-mev-frontrunning/poc/EconomicMEV.t.sol' \
  --match-test 'test_FINDING_jitDepositCapturesSettlementFee|test_FINDING_seniorJitCapturesSeniorFee|test_FINDING_feeNotProRatedByHoldingTime|test_FINDING_depositAfterSettledFinalizeStillCapturesFee' -vv
```

## Recommended fix
- **Stream / accrue the fee over the tenor** instead of a lump credit at settlement, so share price
  reflects time-in-pool.
- **Deposit lockup or notice period** so a deposit cannot be redeemed in the same window as a fee
  credit (e.g. minimum hold, or block-based cooldown).
- **Entry/exit fees** proportional to imminent-credit exposure, routed to standing LPs, to make JIT
  round-trips unprofitable.
- **Snapshot fee entitlement at funding time** (record which shares/LPs financed the invoice) and
  distribute the fee only to those participants, rather than to whoever holds shares at the credit
  block.

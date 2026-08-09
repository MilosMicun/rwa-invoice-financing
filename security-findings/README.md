# RWA Invoice Financing — Consolidated Security Audit Report

## Scope & methodology

**Target:** the Foundry Solidity protocol under `src/` — an on-chain invoice-financing SPV that
finances verified invoices through Senior/Junior ERC-4626 tranches, coordinated by
`InvoiceFinancingPool`, with a non-transferable `InvoiceNFT` lifecycle
(`CREATED → VERIFIED → FUNDED → SETTLED|DEFAULTED`, `FROZEN` overlay), a permissioned
`InvoiceStatusOracle` (submitter + dispute window + permissionless finalize), and an
`RWARiskManager` underwriting boundary (eligibility, advance/fee math, buyer exposure &
concentration, denylist).

**Method.** The surface was decomposed into **eight attack vectors** (see
[`AUDIT-PLAN.md`](./AUDIT-PLAN.md)). Each vector was probed with **≥10 Foundry PoCs** that each
either *confirm a defense* (a `test_SAFE_...` that reverts the malicious action or asserts the key
invariant still holds) or *demonstrate an exploit* (a `test_FINDING_...` that asserts the harmful
outcome actually occurs). Every claimed HIGH/CRITICAL was then **independently re-verified** line-by-line
against the source and re-run before being accepted. Findings that did not survive the skeptical
re-review were downgraded and are documented as such. All PoCs inherit the shared, smoke-tested
deployment harness in [`_base/Harness.sol`](./_base/Harness.sol); malicious-asset variants
(ERC777-style callback token, fee-on-transfer token) live in
[`_base/MaliciousTokens.sol`](./_base/MaliciousTokens.sol).

## How to reproduce

PoCs live outside the default `test/` dir, so they run with the Foundry test-dir override. Each
vector uses an **isolated `out/`+`cache/` dir** so parallel vectors never collide. A sibling
vector's WIP file can block a whole-tree compile, so the reliable pattern is to scope
`FOUNDRY_TEST` to the vector's own `poc/` folder (the shared `_base/Harness.sol` is still pulled in
via the import graph). Run from repo root:

```bash
# Per vector (recommended — isolated build, no cross-vector compile coupling):
FOUNDRY_TEST=security-findings/01-erc4626-vault-accounting/poc  FOUNDRY_OUT=out-v01 FOUNDRY_CACHE_PATH=cache-v01 forge test --match-path 'security-findings/01-erc4626-vault-accounting/poc/*.t.sol' -vv
FOUNDRY_TEST=security-findings/02-tranche-waterfall-accounting/poc FOUNDRY_OUT=out-v02 FOUNDRY_CACHE_PATH=cache-v02 forge test --match-path 'security-findings/02-tranche-waterfall-accounting/poc/*.t.sol' -vv
FOUNDRY_TEST=security-findings/03-oracle-manipulation-timing/poc FOUNDRY_OUT=out-v03 FOUNDRY_CACHE_PATH=cache-v03 forge test --match-path 'security-findings/03-oracle-manipulation-timing/poc/*.t.sol' -vv
FOUNDRY_TEST=security-findings/04-access-control/poc            FOUNDRY_OUT=out-v04 FOUNDRY_CACHE_PATH=cache-v04 forge test --match-path 'security-findings/04-access-control/poc/*.t.sol' -vv
FOUNDRY_TEST=security-findings/05-reentrancy/poc                FOUNDRY_OUT=out-v05 FOUNDRY_CACHE_PATH=cache-v05 forge test --match-path 'security-findings/05-reentrancy/poc/*.t.sol' -vv
FOUNDRY_TEST=security-findings/06-economic-mev-frontrunning/poc FOUNDRY_OUT=out-v06 FOUNDRY_CACHE_PATH=cache-v06 forge test --match-path 'security-findings/06-economic-mev-frontrunning/poc/*.t.sol' -vv
FOUNDRY_TEST=security-findings/07-lifecycle-state-machine/poc   FOUNDRY_OUT=out-v07 FOUNDRY_CACHE_PATH=cache-v07 forge test --match-path 'security-findings/07-lifecycle-state-machine/poc/*.t.sol' -vv
FOUNDRY_TEST=security-findings/08-arithmetic-rounding-dos/poc   FOUNDRY_OUT=out-v08 FOUNDRY_CACHE_PATH=cache-v08 forge test --match-path 'security-findings/08-arithmetic-rounding-dos/poc/*.t.sol' -vv
```

## Executive summary

- **Total probes across all eight vectors: 115** (12 + 15 + 13 + 16 + 12 + 15 + 14 + 18), **all green**.
- **Confirmed HIGH/CRITICAL after independent verification: 1 HIGH, 0 CRITICAL.**
- Two findings were *claimed* HIGH in vector 06. One survived verification (**V06-01**, HIGH); one
  was **refuted as HIGH and downgraded to MEDIUM** (**V06-02** — a real, known ERC-4626 lump-yield
  behavior that breaks no protocol invariant and is not economically rational at scale).

**Headline conclusion.** The core accounting is robust and well-defended by construction. The
ERC-4626 vaults are donation/inflation-immune (`totalAssets()` returns internal `accountedAssets`,
not token balance), the senior-first waterfall and first-loss ordering are exact, resolution is
one-shot under strict CEI (making the guard-less design reentrancy-safe), access control is
consistently role-gated with the vault NAV mutators behind an immutable address check, and the
arithmetic is `mulDiv`-safe with remainder-to-junior conservation. Nearly all of the deliverable is
**negative documentation**: attack after attack is prevented by design.

The **one genuine HIGH** is not an accounting or reentrancy bug but an **economic timing flaw**:
default-loss recognition is a *two-step, non-atomic, permissionless* process. Between
`oracle.finalize` (which publishes the DEFAULTED outcome but writes down nothing) and the separate,
*optional* `resolveDefault` (which performs the `writeDown`), a junior LP can redeem at the stale,
un-written-down NAV and escape its first-loss share — dumping that loss onto passive co-LPs. The
window is open-ended because nobody is obligated to call `resolveDefault`. This breaks the protocol's
first-loss-socialization guarantee and is exploitable by an unprivileged actor. It is the single most
important issue to fix before any deployment.

## Vector results

| # | Vector | # probes | Forge result | Confirmed HIGH/CRITICAL |
|---|--------|----------|--------------|-------------------------|
| 01 | [ERC-4626 vault accounting & share-price manipulation](./01-erc4626-vault-accounting/README.md) | 12 | 12 passed / 0 failed | 0 |
| 02 | [Tranche waterfall & loss/recovery accounting](./02-tranche-waterfall-accounting/README.md) | 15 | 15 passed / 0 failed | 0 |
| 03 | [Oracle manipulation, timing & trust boundaries](./03-oracle-manipulation-timing/README.md) | 13 | 13 passed / 0 failed | 0 |
| 04 | [Access control & privilege escalation](./04-access-control/README.md) | 16 | 16 passed / 0 failed | 0 |
| 05 | [Reentrancy & external-call safety](./05-reentrancy/README.md) | 12 | 12 passed / 0 failed | 0 |
| 06 | [Economic / MEV / front-running / fee-on-transfer](./06-economic-mev-frontrunning/README.md) | 15 | 15 passed / 0 failed | **1 (V06-01)** |
| 07 | [Invoice lifecycle state machine & freeze griefing](./07-lifecycle-state-machine/README.md) | 14 | 14 passed / 0 failed | 0 |
| 08 | [Arithmetic, rounding, precision & DoS](./08-arithmetic-rounding-dos/README.md) | 18 | 18 passed / 0 failed | 0 |
| | **Total** | **115** | **115 passed / 0 failed** | **1 HIGH** |

## Consolidated findings

| ID | Title | Claimed sev | **Verified sev** | Confirmed? | Vector | PoC test fn |
|----|-------|-------------|------------------|------------|--------|-------------|
| V06-01 | Junior LP front-runs the default writedown, socializing its loss onto co-LPs | HIGH | **HIGH** | **Yes** | 06 | `test_FINDING_juniorExitBeforeWritedownDumpsLossOnCoLP` |
| V06-02 | JIT liquidity captures the settlement fee (both tranches), diluting long-term LPs | HIGH | **MEDIUM** (downgraded) | No — refuted as HIGH | 06 | `test_FINDING_jitDepositCapturesSettlementFee` |

**V06-02 downgrade rationale (one line):** the mechanic is real (fees are booked as an instantaneous
NAV step, front-runnable via the public `finalize` + freely-timed `settleInvoice`), but it is the
canonical, well-known ERC-4626 *deposit-just-before-yield* behavior — it breaks no stated invariant
(the fee is fully redistributed pro-rata to real deposited capital; no unauthorized gain), and the
economics are irrational (matching the pool 1:1 captures 50% of a ~sub-0.1% ROI event; capturing the
"large majority" needs 10–30× the pool NAV idle for a ~0.005–0.014% ROI). MEDIUM at most; details in
[`FINDINGS-SUMMARY.md`](./FINDINGS-SUMMARY.md) and [`06.../findings/V06-02/README.md`](./06-economic-mev-frontrunning/findings/V06-02/README.md).

See detailed, ordered write-ups in **[`FINDINGS-SUMMARY.md`](./FINDINGS-SUMMARY.md)**.

## Defenses confirmed (negative results)

These are the notable properties that the PoCs proved **safe-by-design**. Each bullet points at the
`test_SAFE_...` probe that encodes it as a passing assertion.

- **Donation / inflation immunity (V01).** `totalAssets()` returns internal `accountedAssets`, not
  the ERC20 balance (`SeniorPool.sol:68-70`, `JuniorPool.sol:68-70`), so raw token donations cannot
  move share price. The classic first-depositor / inflation attack does nothing here. NAV grows
  *only* via `creditAssets` (behind a cash-backing solvency assertion) and shrinks only via
  `writeDown` (intended first-loss). Probes: `test_SAFE_H1_donationInflationDoesNotMovePrice`,
  `test_SAFE_H2_navMovesOnlyViaCreditAssets`, `test_SAFE_H6_cannotWithdrawDonatedCash`.
- **Senior-first waterfall & first-loss ordering (V02, V08).** `seniorRecovery = min(recovery,
  seniorPrincipal)`; senior can only lose after junior is fully wiped; no arithmetic path routes
  junior's loss onto senior. Bad debt = principal − recovery (unpaid fee correctly excluded).
  Probes: `test_SAFE_SeniorProtectionMatrix`, `test_SAFE_FirstLossOrderingNoInversion`,
  `testFuzz_SAFE_waterfall_seniorFirstProtection`.
- **writeDown liveness / never strands funds (V02, V08).** `resolveDefault` unlocks the position's
  own principal *before* `writeDown`, so `loss ≤ availableLiquidity` even with concurrent locked
  positions or a junior LP that drained liquidity first. Probes:
  `test_SAFE_WriteDownDoS_CompetingLockedPosition`, `test_SAFE_WriteDownDoS_AfterJuniorDrainsLiquidity`.
- **Reentrancy safety without a guard (V05).** No `ReentrancyGuard` exists, yet strict CEI on
  `settleInvoice`/`resolveDefault`/`financeInvoice` (`resolved`/lock flags + aggregate counters
  written before every transfer) plus the `maxWithdraw`/`availableLiquidity` cap defeat classic,
  cross-function, cross-pool, and value-extraction reentrancy on an ERC777-style callback asset.
  Probes: `test_SAFE_SettleSameInvoiceReentrancyReverts`,
  `test_SAFE_NoValueExtractionViaReentrantWithdrawDuringSettle`,
  `test_SAFE_HookActuallyFiresProvingNoGuardButCEIHolds` (one INFO read-only-reentrancy window, no
  in-protocol consumer).
- **Access control / role gating (V04).** `financeInvoice` is bound to `msg.sender ==
  invoice.supplier` with no caller-supplied recipient (no fund redirection); all 10 vault NAV
  mutators revert `NotInvoiceFinancingPool` for non-pool callers via an **immutable address check**
  (not a grantable role — even DEFAULT_ADMIN cannot touch NAV); every NFT/oracle/risk transition is
  correctly role-gated. Probes: `test_SAFE_vaultMutators_onlyPool`, `test_SAFE_admin_cannotTouchVaults`,
  `test_SAFE_financeInvoice_noFundRedirection`.
- **Oracle trust boundary (V03).** Outcome injection is authenticated (`onStatusFinalized` gates on
  `msg.sender == oracle`); permissionless `finalize` is a pure propagator of the submitter's exact
  payload (WHO/WHEN separation, not WHAT); dispute window + staleness bounded; active outcomes
  immutable-until-invalidated; SETTLED cannot carry recovery and DEFAULTED recovery ≤ principal
  (value bounded). Probes: `test_SAFE_onStatusFinalized_rejects_direct_eoa_call`,
  `test_SAFE_finalize_is_permissionless_but_payload_is_immutable`,
  `test_SAFE_settled_with_recovery_rejected_both_layers`.
- **Concentration TOCTOU is atomic (V06, V08).** `financeInvoice` re-checks
  `checkConcentration(buyer, principal)` and runs `updateBuyerExposure` in the same tx, so a stale
  view cannot exceed `maxExposurePerBuyer`; exposure decrement fires exactly once (resolved guard).
  Probes: `test_SAFE_concentrationReCheckedAtomically`, `test_SAFE_exposure_noDoubleDecrement_onResolvedGuard`.
- **Lifecycle state machine (V07).** Absorbing terminals, doubly-guarded double-finance,
  settle/default mutual exclusion, non-transferable & non-burnable NFT, and a reversible freeze
  overlay that preserves financial state exactly across a round-trip. Probes:
  `test_SAFE_settleThenDefaultMutualExclusion`, `test_SAFE_nonTransferabilityAndNoBurn`,
  `test_SAFE_previousStatusIntegrity`.
- **Arithmetic robustness (V08).** `Math.mulDiv` (512-bit intermediate) for advance/fee;
  remainder-to-junior split makes funding/fee conservation exact by construction; subtraction-based
  concentration/limit checks avoid overflow and off-by-one; `accountedAssets ≥ lockedAssets`
  invariant holds throughout. Probes: `testFuzz_SAFE_fundingSplit_conserved`,
  `testFuzz_SAFE_feeSplit_conserved`, `test_SAFE_availableLiquidity_neverUnderflows_fullCycle`.

## Notable MEDIUM / LOW / INFO observations (no finding folder)

- **MEDIUM — V06-02 JIT settlement-fee capture** (downgraded from claimed HIGH; known ERC-4626
  lump-yield behavior, no invariant broken). See `FINDINGS-SUMMARY.md`.
- **MEDIUM — Oracle recovery-bound liveness brick (V03, H5).** A privileged submitter (or fat-finger)
  can submit a DEFAULTED outcome with `recovery > principal`; the oracle accepts it but the pool
  callback reverts, and the still-active bad update blocks a corrective resubmit until staleness (or a
  dispute). Fully recoverable, no loss, requires the submitter role. Fix: validate `recovery ≤
  principal` at `submitStatus`, or treat a pool-callback revert as an implicit dispute.
- **LOW / INFO — Fee-on-transfer incompatibility (V06).** Deposits of a taxed token revert (the
  coordinator is short on the inner deposit); protocol fails closed with no unbacked shares. Should be
  asset-allowlisted / documented.
- **LOW / INFO — Freeze liveness (V07) and admin blast-radius / role-revocation DoS (V04).** A
  RISK_ROLE freeze or a compromised DEFAULT_ADMIN can temporarily strand locked LP capital; all are
  reversible and gated behind the documented permissioned trust model with no unprivileged trigger.
  Recommend timelocked/two-step admin, bounded freeze SLA, and an escape hatch to resolve from the
  pool position rather than the NFT status.
- **LOW / INFO — ZeroTranchePrincipal DoS (V08)** under an atypical-but-legal admin config; and
  **read-only reentrancy** transient stale NAV (V05) relevant only to external integrators pricing off
  these vaults mid-callback.

## Links

- Audit plan & vector map: [`AUDIT-PLAN.md`](./AUDIT-PLAN.md)
- Ordered findings write-up: [`FINDINGS-SUMMARY.md`](./FINDINGS-SUMMARY.md)
- Vector folders: [01](./01-erc4626-vault-accounting/) · [02](./02-tranche-waterfall-accounting/) ·
  [03](./03-oracle-manipulation-timing/) · [04](./04-access-control/) · [05](./05-reentrancy/) ·
  [06](./06-economic-mev-frontrunning/) · [07](./07-lifecycle-state-machine/) ·
  [08](./08-arithmetic-rounding-dos/)
- Confirmed HIGH write-up: [`06.../findings/V06-01/README.md`](./06-economic-mev-frontrunning/findings/V06-01/README.md)
- Downgraded write-up: [`06.../findings/V06-02/README.md`](./06-economic-mev-frontrunning/findings/V06-02/README.md)

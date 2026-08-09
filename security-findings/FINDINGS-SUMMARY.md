# RWA Invoice Financing — Findings Summary (ordered by verified severity)

This is the authoritative, ordered list of every finding that was **claimed** at HIGH/CRITICAL and
then independently verified. Confirmed findings come first (CRITICAL then HIGH); anything refuted or
downgraded during verification is listed separately with the verifier's reasoning.

- **Confirmed CRITICAL:** 0
- **Confirmed HIGH:** 1 (V06-01)
- **Reviewed & downgraded / refuted:** 1 (V06-02, HIGH -> MEDIUM)

Full audit context and defenses-confirmed are in [`README.md`](./README.md).

---

## Confirmed findings

### V06-01 — Junior LP front-runs the default writedown, socializing its loss onto co-LPs

- **Verified severity:** HIGH (claimed HIGH; confirmed).
- **Vector:** 06 — Economic / MEV / front-running.
- **Location:**
  - `src/oracle/InvoiceStatusOracle.sol:197-233` — permissionless `finalize` publishes the DEFAULTED
    outcome and calls `pool.onStatusFinalized`, but performs **no** NAV writedown.
  - `src/core/InvoiceFinancingPool.sol:188-226` (`onStatusFinalized`) and `:494-581`
    (`resolveDefault`; the actual `writeDown` is at `:557-563`) — a **separate, permissionless,
    optional** call.
  - `src/pools/JuniorPool.sol:73-86` (`availableLiquidity`, `maxWithdraw`) and `:187-203`
    (`writeDown`) — exits are priced off the un-written-down NAV; `writeDown` reduces
    `accountedAssets` for the *remaining* shares only. (SeniorPool is symmetric.)

- **Impact.** Default-loss recognition is a two-step, non-atomic, **permissionless** process.
  `finalize` makes the loss public and inevitable but writes down nothing; the writedown happens only
  later in the optional `resolveDefault`. In between, a junior LP's unlocked liquidity is still
  redeemable at the full, stale share price (`maxWithdraw = min(ownerAssets, availableLiquidity,
  cash)` has no pending-loss awareness, no lockup, and no hook from invoice/default state into
  withdrawals). A junior LP who watches the `finalize` event redeems at the old NAV and escapes its
  first-loss share; the subsequent `writeDown` then falls entirely on the LPs who stayed. This is a
  **user-vs-user loss transfer** (unauthorized loss to a passive co-LP), requires **no privileged
  role**, and directly breaks the protocol's first-loss-socialization guarantee (junior capital is
  supposed to absorb loss pro-rata across junior shareholders). Because `resolveDefault` is optional
  and unbounded, the exit window is **open-ended** — a deterministic, riskless, repeatable exploit,
  not a fleeting mempool race.

  Verified numbers (from the PoC): junior NAV 300k split between two equal LPs; one financed invoice
  locks 24k junior principal (100k face x 8000 bps advance x 3000 bps junior share); junior available
  liquidity = cash = 276k. The escaping LP's `maxWithdraw = min(150k, 276k, 276k) = 150k`, so it exits
  whole; the 24k writedown then lands entirely on the passive co-LP — a 100% overcharge vs. the fair
  12k. The control test proves the harm is caused by **timing**, not the waterfall itself.

- **Why HIGH and not CRITICAL:** it is a real theft of value from passive LPs, deterministic and
  repeatable on every default with no privileged role — but per-event magnitude is bounded by a single
  invoice's junior loss (`loss <= juniorPrincipal`); it does not drain the protocol, break global
  solvency accounting, or defeat senior first-loss protection.

- **PoC (`security-findings/06-economic-mev-frontrunning/poc/EconomicMEV.t.sol`):**
  - `test_FINDING_juniorExitBeforeWritedownDumpsLossOnCoLP` — attacker exits ~whole; passive co-LP
    bears ~the entire junior loss (asserts `victimLoss ~= juniorPrincipal`).
  - `test_FINDING_searcherWithholdsResolveToKeepFrontRunWindowOpen` — full-NAV exit still works 30
    days after finalization (window is open-ended).
  - `test_SAFE_ifNoOneExitsLossIsSocializedFairly` — control: with no timing, the loss splits equally.
  - Detailed write-up: [`findings/V06-01/README.md`](./06-economic-mev-frontrunning/findings/V06-01/README.md).

  ```bash
  FOUNDRY_TEST=security-findings/06-economic-mev-frontrunning/poc FOUNDRY_OUT=out-v06 FOUNDRY_CACHE_PATH=cache-v06 \
    forge test --match-path 'security-findings/06-economic-mev-frontrunning/poc/EconomicMEV.t.sol' \
    --match-test 'test_FINDING_juniorExitBeforeWritedownDumpsLossOnCoLP|test_FINDING_searcherWithholdsResolveToKeepFrontRunWindowOpen|test_SAFE_ifNoOneExitsLossIsSocializedFairly' -vv
  ```

- **One-line fix.** Recognize the loss atomically with finalization (have a DEFAULTED
  `onStatusFinalized`/`finalize` mark down the affected tranche NAV or freeze that tranche's
  withdrawals in the same tx), *or* apply a pending-loss haircut to `maxWithdraw`/`convertToAssets`
  while a finalized-but-unresolved DEFAULTED invoice is outstanding, *or* impose a junior withdrawal
  lockup/notice spanning the finalize->resolve window.

---

## Reviewed & downgraded / refuted

### V06-02 — JIT liquidity captures the settlement fee (both tranches) — HIGH -> **MEDIUM**

- **Claimed severity:** HIGH. **Verified severity:** MEDIUM (arguably LOW/INFO). **Confirmed as
  HIGH:** No. **Intended-design mechanic:** Yes (documented ERC-4626 lump-credit; no invariant
  violated).
- **Vector:** 06. **PoC:** `test_FINDING_jitDepositCapturesSettlementFee` (+
  `test_FINDING_seniorJitCapturesSeniorFee`, `test_FINDING_feeNotProRatedByHoldingTime`,
  `test_FINDING_depositAfterSettledFinalizeStillCapturesFee`), all green.
- **Location:** `src/core/InvoiceFinancingPool.sol:434-440` (`settleInvoice` fee credit),
  `src/pools/{Senior,Junior}Pool.sol:164-181` (`creditAssets` lump NAV bump),
  `src/oracle/InvoiceStatusOracle.sol:197-233` (public `finalize` signal).

- **Verified mechanic (real).** Fees are booked as an instantaneous NAV step (`accountedAssets +=
  fee`) in `creditAssets`, split by shares held at that single block, with no duration weighting, no
  lockup, no entry/exit fee. `finalize` is public and `settleInvoice` is permissionless/freely-timed,
  so the credit is observable and the deposit window is front-runnable. A JIT LP owning half the
  shares at credit time captures ~half the fee for a ~1-block hold; per-share gain is identical for a
  1-block and a full-tenor LP. All four PoCs reproduce.

- **Why it is NOT HIGH (verifier reasoning).**
  1. This is the canonical, well-known ERC-4626 *deposit-just-before-yield-distribution* behavior,
     inherent to any vault that credits realized yield as a lump NAV bump rather than streaming it.
     C4/Sherlock consistently rate this MEDIUM at best (usually LOW/INFO) — a known design tradeoff,
     not a broken invariant.
  2. **No stated protocol guarantee is broken.** Senior-protection waterfall, one-shot oracle,
     funds-not-stranded, and LP-accounting conservation all hold. The fee is fully redistributed among
     shareholders (none created/destroyed); the JIT LP receives exactly the pro-rata NAV of the shares
     it legitimately deposited. It is **not** an unauthorized gain and **not** donation/inflation
     manipulation (that vector is already neutralized by `accountedAssets`).
  3. **The economics are irrational**, contradicting the "risk-free theft / whale captures the large
     majority" framing. For a junior fee of ~473 tokens on a 300k standing NAV: matching the pool 1:1
     (300k idle cash) captures 50% for a ~0.079%-per-event ROI; capturing ~91% needs 10x the pool NAV
     (3M idle) for ~0.014% ROI; ~97% needs 30x (9M) for ~0.005% ROI. There is no leverage/amplification
     — the "victim" is diluted exactly in proportion to the fresh capital that arrived. It is strictly
     cheaper to be a passive LP; no rational attacker performs this.

- **Net:** a correctly-described but low-impact, known ERC-4626 property that breaks no invariant and
  is not a profitable/realistic attack. **MEDIUM** ceiling.
- **One-line fix (defense-in-depth, optional).** Stream/accrue the fee over the tenor instead of a
  lump credit, or snapshot fee entitlement to the shares that financed the invoice, or add a short
  deposit lockup/notice so a deposit cannot be redeemed in the same window as a fee credit.
- Detailed write-up: [`findings/V06-02/README.md`](./06-economic-mev-frontrunning/findings/V06-02/README.md).

---

## Strongest non-HIGH observations (context)

These are not findings but are the most substantive MEDIUM-ish items surfaced by the vector READMEs,
included so the reader sees the full risk picture:

- **Oracle recovery-bound liveness brick (V03, H5) — MEDIUM.** A DEFAULTED submission with
  `recovery > principal` passes the oracle's local validation but reverts in the pool callback; the
  still-active bad update blocks a corrective resubmit, freezing resolution (and the position's locked
  LP capital) until staleness (<= `MAX_STALENESS`, 7d in fixture) or a `DISPUTE_ADMIN` dispute. Fully
  recoverable, no loss/unauthorized gain, requires the `ORACLE_SUBMITTER_ROLE`. Fix: validate
  `recovery <= principal` at `submitStatus`, or treat a pool-callback revert as an implicit dispute.
  (`test_FINDING_recovery_bound_bricks_resolution`, `test_SAFE_dispute_unsticks_recovery_brick`.)
- **Permissioned trust-model residuals (V04) — INFO/centralization.** Oracle role co-location
  (SUBMITTER + DISPUTE + ADMIN to one key), admin blast radius (rogue DEFAULT_ADMIN granting POOL_ROLE
  to an EOA to strand capital or DoS concentration), role-revocation DoS, and the deploy footgun
  (`ADMIN = msg.sender`, `script/Deploy.s.sol` is a placeholder). All gated behind a fully-trusted
  admin key with no unprivileged trigger — matches the documented permissioned model. Harden with a
  timelocked/two-step admin, distinct submitter/dispute keys (multisig), an explicit constructor
  `admin`, and a settle-from-position escape hatch.
- **Fee-on-transfer incompatibility (V06) — LOW/INFO.** Taxed-token deposits revert (coordinator short
  on inner deposit); fails closed with no unbacked shares. Asset-allowlist / document.
- **Freeze liveness (V07) — LOW.** RISK_ROLE can freeze a FUNDED invoice, temporarily locking LP
  capital; fully reversible, privileged-only. Bound with a freeze SLA / escape hatch.

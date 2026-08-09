# VECTOR 03 — Oracle Manipulation, Timing & Trust Boundaries — PLAN

## Scope
- `src/oracle/InvoiceStatusOracle.sol` (submitStatus / disputeStatus / finalize)
- `src/core/InvoiceFinancingPool.sol::onStatusFinalized` and `setInvoiceStatusOracle`
- Interaction with `InvoiceNFT` FROZEN overlay and lifecycle guards.

## Trust model (from src comments + audit prompt)
The oracle is *intentionally* permissioned: `ORACLE_SUBMITTER_ROLE` submits an off-chain
outcome, an optional `DISPUTE_ADMIN_ROLE` can dispute during a window, and *anyone* can
`finalize()` after the dispute window but before staleness. Finalization pushes the exact
submitted `(status, recoveredAmount)` to `pool.onStatusFinalized()`. The permissionless
`finalize()` / `settleInvoice()` / `resolveDefault()` steps are a "process integrity, not
truth" separation: they cannot alter WHAT the submitter attested; they only decouple
execution authority from reporting authority. So "a rogue authorized submitter lies" is a
centralization/off-chain concern, NOT a code bug — the code guarantees to probe are:
- one-shot / immutable finalization (no double-apply, no overwrite of an active outcome)
- authorization of the callback (only the configured oracle can inject an outcome)
- timing bounds (dispute window / staleness) enforced correctly
- recovery bound (recovery <= principal) — cannot manufacture senior/junior gain
- FROZEN overlay is respected by execution but not by the oracle attestation step
- no outcome preloading before a financing position exists / before NFT is FUNDED
- liveness: can a non-privileged actor, or an honest fat-finger, brick resolution?

## Known-attack classes for this vector
1. Unauthorized outcome injection (spoof the pool callback from an EOA).
2. Permissionless-finalize abuse (finalizer alters/forges the outcome, front-run, grief).
3. Dispute-window / staleness boundary manipulation (finalize too early / too late).
4. Resubmission overwrite of a valid, active outcome (replace SETTLED with DEFAULTED).
5. Recovery-bound brick / liveness DoS (recovery > principal makes finalize permanently revert until stale).
6. SETTLED-with-recovery injection (manufacture NAV gain via fake recovery on a paid invoice).
7. FROZEN-during-finalize interaction / state corruption.
8. Double-finalize / dispute-after-finalize (immutability of terminal outcome).
9. Outcome preload before a financing position exists (fundedAt == 0).
10. Status preload / ordering: submit against non-FUNDED NFT (CREATED/VERIFIED/SETTLED).
11. One-shot oracle rotation (compromised oracle cannot be swapped; liveness/centralization).
12. Rogue-authorized-submitter false SETTLED/DEFAULTED to harm LPs/supplier (process vs truth).

## Concrete hypotheses (attacker goal + method) — >=10

- H1 (SAFE expected): **Unauthorized outcome injection.** Attacker EOA calls
  `pool.onStatusFinalized(id, SETTLED, 0)` directly. Goal: inject a finalized outcome
  bypassing the oracle. Expect revert `UnauthorizedOracle`. Assert callback is gated to
  `invoiceStatusOracle` (InvoiceFinancingPool.sol:193).

- H2 (SAFE expected): **Permissionless finalize propagates as-is.** `attacker` (no roles)
  calls `finalize()` after dispute window. Goal: check finalizer can flip status/recovery.
  Assert the pool's stored `finalizedOracleStatus`/`finalizedRecoveryAmount` equal exactly
  what the submitter submitted — finalizer has zero influence over the payload.

- H3 (SAFE expected): **Timing boundaries.** finalize() before `submittedAt+disputeWindow`
  reverts `DisputeWindowNotElapsed`; after `submittedAt+maxStaleness` reverts
  `StatusUpdateStale`. Prove exact boundaries (== earliest OK, > stale reverts).

- H4 (SAFE expected): **Active-outcome overwrite blocked.** Submit correct SETTLED, then a
  malicious submitter tries to resubmit DEFAULTED(recovery) while the SETTLED is active
  (not disputed, not stale). Expect revert `StatusUpdateAlreadyActive`. Then finalize the
  original SETTLED and confirm settlement path is what executes.

- H5 (FINDING candidate — liveness DoS): **Recovery-bound brick.** Submitter submits
  DEFAULTED with `recoveredAmount = principal + 1`. `finalize()` reverts inside
  `onStatusFinalized` (`RecoveredAmountExceedsPrincipal`) so `update.finalized` is never
  set; the update stays active so it cannot be resubmitted; `finalize()` keeps reverting.
  Resolution of the invoice is bricked for the whole staleness window (or until a
  DISPUTE_ADMIN disputes). Prove: (a) finalize reverts, (b) resubmit reverts while active,
  (c) escape path #1 = wait for staleness then resubmit valid, (d) escape path #2 =
  dispute then resubmit valid. Classify severity honestly (griefable by an honest fat
  finger OR by a rogue-but-authorized submitter; capital stays locked meanwhile).

- H6 (SAFE expected): **SETTLED-with-recovery rejected at submit.** submitStatus(SETTLED, >0)
  reverts `InvalidRecoveryForStatus` at the oracle. Also confirm pool's onStatusFinalized
  independently rejects SETTLED with recovery (defense in depth), so a fake recovery can
  never be minted onto a settled invoice.

- H7 (SAFE expected): **FROZEN interaction.** Freeze a FUNDED invoice, finalize SETTLED
  (allowed by design at oracle), then settleInvoice reverts `InvoiceFrozen`. Assert no
  state corruption (position not resolved, locked assets unchanged, finalized outcome
  intact) and that after unfreeze settlement proceeds normally.

- H8 (SAFE expected): **Immutability.** Double finalize reverts
  `StatusUpdateAlreadyFinalized`; dispute after finalize reverts
  `StatusUpdateAlreadyFinalized`; pool `onStatusFinalized` a second time (simulate via a
  second oracle interaction) is blocked by `OracleStatusAlreadyFinalized`.

- H9 (SAFE expected): **Outcome preload before position exists.** Create+verify an invoice
  but DO NOT finance it. Because NFT is VERIFIED not FUNDED, submitStatus reverts
  `InvoiceNotFunded`. Independently, prove onStatusFinalized reverts
  `FinancingPositionDoesNotExist` when position.fundedAt==0 (defense in depth via a
  mock-oracle harness so we call the pool callback directly through the configured oracle).

- H10 (SAFE expected): **Status/ordering preload.** submitStatus against a CREATED or
  VERIFIED NFT reverts `InvoiceNotFunded`; against an already-SETTLED NFT reverts too.
  Confirms an outcome cannot be staged before/after the funded window.

- H11 (INFO expected): **One-shot oracle rotation.** setInvoiceStatusOracle a second time
  reverts `OracleAlreadySet`; a non-admin call reverts `UnauthorizedAdmin`. Document the
  liveness/centralization implication (compromised oracle cannot be rotated) but show it
  does not enable theft on its own.

- H12 (INFO expected): **Rogue authorized submitter false outcome.** A holder of
  ORACLE_SUBMITTER_ROLE submits DEFAULTED(recovery=0) on an invoice the buyer actually
  paid. After the window, anyone finalizes and resolveDefault writes down junior/senior
  NAV — LPs lose. Show the dispute window + permissionless finalize do NOT prevent this
  (they only bound WHO executes and WHEN, not truth). Frame precisely: this is the
  intended trust assumption / centralization risk, NOT a code-level escalation. The one
  hard code guarantee that still holds even here: recovery is bounded by principal, so the
  submitter cannot manufacture *gain* beyond principal (senior cannot be over-credited),
  and SETTLED cannot carry recovery — assert both.

## Deliverables
- poc/OracleTiming.t.sol — H1..H12 (>=10 tests), all green.
- README.md — results table, run cmd, real Suite result line, narrative w/ file:line refs.
- findings/<id>/README.md — only if H5 (or anything) rises to real HIGH/CRITICAL.

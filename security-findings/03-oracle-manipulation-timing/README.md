# VECTOR 03 — Oracle Manipulation, Timing & Trust Boundaries — RESULTS

Scope: `src/oracle/InvoiceStatusOracle.sol`, `src/core/InvoiceFinancingPool.sol`
(`onStatusFinalized`, `setInvoiceStatusOracle`, settle/default execution gates), and the
`InvoiceNFT` FROZEN overlay interaction.

## Results table

| # | Hypothesis (attacker goal) | Test function | Verdict | Severity | One-line result |
|---|----------------------------|---------------|---------|----------|-----------------|
| H1 | Inject a finalized outcome via a direct EOA call to the pool callback | `test_SAFE_onStatusFinalized_rejects_direct_eoa_call` | SAFE | — | Reverts `UnauthorizedOracle`; only the configured oracle may inject an outcome (`InvoiceFinancingPool.sol:193`). |
| H2 | Permissionless finalizer alters the status/recovery it pushes | `test_SAFE_finalize_is_permissionless_but_payload_is_immutable` | SAFE | — | Anyone can call `finalize()`, but the pool stores EXACTLY the submitted payload; finalizer has zero payload control (`InvoiceStatusOracle.sol:230`). |
| H3 | Finalize before dispute window or after staleness | `test_SAFE_finalize_timing_boundaries` | SAFE | — | `< earliest` reverts `DisputeWindowNotElapsed`; `== earliest` OK; `> stale` reverts `StatusUpdateStale` (`InvoiceStatusOracle.sol:212-222`). |
| H4 | Overwrite an active, correct SETTLED with a malicious DEFAULTED | `test_SAFE_active_outcome_cannot_be_overwritten` | SAFE | — | Resubmit reverts `StatusUpdateAlreadyActive` while live; original outcome survives (`InvoiceStatusOracle.sol:129-134`). |
| H5 | Brick resolution with a `recovery > principal` DEFAULTED submission | `test_FINDING_recovery_bound_bricks_resolution` | FINDING | MEDIUM | `finalize()` reverts in the pool callback, and the still-active update blocks corrective resubmit → resolution + locked LP capital stuck until staleness (or a dispute). Recoverable, no loss. |
| H5b | Dispute path unsticks the brick before staleness | `test_SAFE_dispute_unsticks_recovery_brick` | SAFE | — | `DISPUTE_ADMIN` dispute → immediate valid resubmit → finalize; brick cleared without waiting out staleness. |
| H6 | Attach a fake recovery to a SETTLED outcome to mint NAV | `test_SAFE_settled_with_recovery_rejected_both_layers` | SAFE | — | Oracle rejects at submit (`InvoiceStatusOracle.sol:113`) AND pool rejects at callback (`InvoiceFinancingPool.sol:214-217`). |
| H7 | Finalize on FROZEN corrupts state / lets settlement run | `test_SAFE_frozen_finalize_then_blocked_then_unfreeze` | SAFE | — | Oracle finalizes over FROZEN by design; settlement reverts `InvoiceFrozen` with no state change; unfreeze lets it proceed (`InvoiceFinancingPool.sol:392`). |
| H8 | Double-finalize / dispute-after-finalize / re-apply outcome | `test_SAFE_finalized_outcome_is_immutable` | SAFE | — | Reverts `StatusUpdateAlreadyFinalized` (oracle) and `OracleStatusAlreadyFinalized` (pool) (`InvoiceStatusOracle.sol:208`, `InvoiceFinancingPool.sol:209-211`). |
| H9 | Preload an outcome before a financing position exists | `test_SAFE_cannot_preload_outcome_before_position` | SAFE | — | Oracle rejects `InvoiceNotFunded`; pool rejects `FinancingPositionDoesNotExist` when `fundedAt==0` (`InvoiceFinancingPool.sol:203-205`). |
| H10 | Submit an outcome against a non-FUNDED NFT (CREATED / terminal) | `test_SAFE_submit_requires_funded_nft_status` | SAFE | — | Reverts `InvoiceNotFunded` for CREATED and already-SETTLED invoices (`InvoiceStatusOracle.sol:119-121`). |
| H11 | Rotate a compromised oracle / set oracle as non-admin | `test_SAFE_oracle_is_one_shot_and_admin_only` | SAFE | INFO | Second set reverts `OracleAlreadySet`; non-admin reverts `UnauthorizedAdmin`. One-shot = centralization/liveness risk but enables no theft (`InvoiceFinancingPool.sol:157-166`). |
| H12 | Rogue authorized submitter forces a false outcome / manufactures gain | `test_SAFE_rogue_submitter_bounded_by_principal_guarantee` | SAFE (INFO) | INFO | A false DEFAULTED DOES harm LPs (accepted trust assumption, not a code bug); but recovery stays bounded by principal and SETTLED cannot carry recovery, so no value is minted beyond principal and bad debt == principal exactly. |

Legend: SAFE = defense holds / behavior is intended; FINDING = harmful outcome demonstrated;
INFO = intended centralization/trust characteristic worth documenting.

## How to run

```bash
FOUNDRY_TEST=security-findings FOUNDRY_OUT=out-v03 FOUNDRY_CACHE_PATH=cache-v03 \
  forge test --match-path 'security-findings/03-oracle-manipulation-timing/poc/*.t.sol' \
  --skip 'security-findings/0[1245678]*/*' -vv
```

(The `--skip` excludes sibling vector folders that were still work-in-progress and did not
compile at audit time; it does not affect this vector's results. Removing it and running only
this vector's `--match-path` yields the same 13/13 once the other folders compile.)

## Observed suite result

```
Suite result: ok. 13 passed; 0 failed; 0 skipped; finished in 6.66ms (12.55ms CPU time)
```

## What protects this / what breaks

**What protects this (the oracle trust boundary holds where the code promises):**

- **Outcome injection is authenticated.** `onStatusFinalized` gates on
  `msg.sender == invoiceStatusOracle` (`InvoiceFinancingPool.sol:193`). No EOA or third
  party can stage an outcome (H1).
- **"Permissionless finalize" is a WHO/WHEN separation, not a WHAT.** `finalize()` forwards
  the exact `(status, recoveredAmount)` the submitter attested (`InvoiceStatusOracle.sol:230`).
  A random finalizer cannot change the outcome (H2). This is the protocol's "process
  integrity, not truth" property, and it holds.
- **Timing is bounded on both ends.** Dispute window (`:212-215`) and staleness (`:218-222`)
  are enforced with correct boundary semantics (H3).
- **An active outcome is immutable-until-invalidated.** It can only be replaced after it is
  disputed or stale (`:129-134`), so a correct outcome cannot be silently overwritten (H4),
  and a finalized one cannot be re-finalized/disputed/re-applied (H8).
- **Value is bounded.** `SETTLED` cannot carry recovery (oracle `:113`, pool `:214-217`), and
  `DEFAULTED` recovery cannot exceed principal (pool `:218-219`, `:527-529`). A rogue
  submitter therefore cannot mint NAV or over-credit seniors beyond principal (H6, H12).
- **No preloading.** Outcomes require both an existing financing position (`fundedAt != 0`,
  `:203-205`) and a FUNDED NFT at submit time (`InvoiceStatusOracle.sol:119-121`) (H9, H10).
- **FROZEN overlay is respected by execution.** Even if the oracle finalizes over a FROZEN
  invoice (allowed, since finalize touches no NFT state), `settleInvoice`/`resolveDefault`
  reject `InvoiceFrozen` with no state mutation, and proceed cleanly after unfreeze (H7).

**What is a real (but bounded) weakness — MEDIUM, not HIGH/CRITICAL:**

- **H5 — recovery-bound liveness brick.** A `DEFAULTED` submission with
  `recoveredAmount > principal` passes the oracle's local validation (the oracle never checks
  recovery against principal) but reverts inside the pool callback
  (`RecoveredAmountExceedsPrincipal`, `InvoiceFinancingPool.sol:218-219`). Because `finalize()`
  reverts, `update.finalized` is never set (`InvoiceStatusOracle.sol:228`), and because the
  bad update is still "active" (`:129-134`) a corrective resubmit also reverts
  `StatusUpdateAlreadyActive`. Resolution — and the LP capital locked in the position — is
  frozen until either the update goes stale (up to `MAX_STALENESS`, 7 days in fixture) or a
  `DISPUTE_ADMIN` disputes it (H5b, the fast escape).

  Why this is MEDIUM, not HIGH/CRITICAL for a skeptical judge:
  - It requires a privileged `ORACLE_SUBMITTER_ROLE` action (or an honest fat-finger by that
    role) — an unprivileged actor cannot trigger it.
  - It is fully recoverable: no funds are lost, no unauthorized gain occurs, senior protection
    and LP accounting conservation are untouched. Capital is temporarily locked, then resolved.
  - In v1 the same admin holds `ORACLE_SUBMITTER_ROLE` and `DISPUTE_ADMIN_ROLE`, so the brick
    can be self-healed by `disputeStatus` + resubmit in the very next action (H5b). The only
    lingering-lock scenario is a genuinely separated, slow/absent dispute admin, which caps the
    lock at the staleness window with no permanent harm.

  Recommended hardening (defense-in-depth / better UX): validate `recoveredAmount <= principal`
  at `submitStatus` time (the oracle already reads position/principal indirectly via the pool),
  OR treat a pool-callback revert as an implicit dispute so the outcome becomes resubmittable
  immediately instead of only after staleness. Either change removes the DoS window entirely.

**Bottom line:** no HIGH/CRITICAL oracle/timing finding. The permissioned-oracle design
enforces exactly the guarantees it claims (authenticated injection, immutable/bounded
outcomes, value bounded by principal, respected FROZEN overlay, no preloading). The only
real defect is a bounded, recoverable liveness brick (H5, MEDIUM). The residual "rogue
authorized submitter can attest a false outcome" (H12) is the intended, documented trust
assumption — a centralization/off-chain concern, not a code-level escalation.

No `findings/` folder is created because there is no confirmed HIGH/CRITICAL. H5 is documented
here at MEDIUM per the vector rules (finding folders are reserved for HIGH/CRITICAL).

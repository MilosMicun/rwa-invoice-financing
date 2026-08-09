# VECTOR 07 — Invoice Lifecycle State Machine & Freeze Griefing

Scope: `src/core/InvoiceNFT.sol` lifecycle transitions and their interplay with
`InvoiceFinancingPool.{financeInvoice,settleInvoice,resolveDefault,onStatusFinalized}` and
`InvoiceStatusOracle.{submitStatus,finalize}`.

## Results

| # | Hypothesis | Test function | Verdict | Severity | One-line result |
|---|-----------|---------------|---------|----------|-----------------|
| 1 | Double-finance an already-FUNDED invoice | `test_SAFE_doubleFinanceBlockedByPoolAndNft` | SAFE | - | Blocked by pool `fundedAt!=0` AND NFT `markFunded` requires VERIFIED |
| 2 | Settle then also default (mutual exclusion) | `test_SAFE_settleThenDefaultMutualExclusion` | SAFE | - | Oracle submit reverts `InvoiceNotFunded`; pool reverts `FinancingPositionAlreadyResolved` |
| 3 | Default then also settle (mirror) | `test_SAFE_defaultThenSettleMutualExclusion` | SAFE | - | `resolved` flag → settle reverts `FinancingPositionAlreadyResolved` |
| 4 | Freeze strands locked LP capital forever | `test_SAFE_freezeStrandIsReversibleAndPrivilegedOnly` | SAFE (INFO/liveness) | Low | Strand exists only while frozen; RISK_ROLE-only, fully reversible via unfreeze; no non-privileged trigger |
| 5 | Fund from a non-VERIFIED state | `test_SAFE_markFundedRequiresVerified` | SAFE | - | CREATED/SETTLED/DEFAULTED/FROZEN all revert `InvalidStatus` |
| 6 | Move or burn the claim NFT | `test_SAFE_nonTransferabilityAndNoBurn` | SAFE | - | transfer/safeTransfer/approve/setApprovalForAll revert; no burn path |
| 7 | Re-verify a funded/settled invoice | `test_SAFE_reVerifyAfterFundingBlocked` | SAFE | - | `verify` requires CREATED → reverts `InvalidStatus` |
| 8 | Freeze a VERIFIED invoice, then finance | `test_SAFE_freezeVerifiedBlocksFinancing` | SAFE | - | `isEligible` false (FROZEN != VERIFIED) → `InvoiceNotEligible`; nothing locked; reversible |
| 9 | Freeze between submit and finalize locks a stale outcome | `test_SAFE_freezeBetweenSubmitAndFinalizeNoCorruption` | SAFE | - | Finalize succeeds by design; settle blocked while frozen; unfreeze → clean settle, NAV += fee only |
| 10 | Mutate a terminal (SETTLED/DEFAULTED) state | `test_SAFE_terminalStatesAreImmutable` | SAFE | - | Every transition + freeze reverts on terminal states |
| 11 | previousStatus placeholder / bad restore | `test_SAFE_previousStatusIntegrity` | SAFE | - | unfreeze non-frozen reverts; VERIFIED & FUNDED restore exactly; fundedAt preserved |
| 12 | Freeze from CREATED corrupts restore | `test_SAFE_freezeFromCreatedBlocked` | SAFE | - | Freeze only from VERIFIED/FUNDED → CREATED-restore corner case unreachable |
| 13 | Double-freeze corrupts previousStatus to FROZEN | `test_SAFE_doubleFreezeBlocked` | SAFE | - | Re-freeze reverts `InvalidFreezeStatus`; previousStatus can never become FROZEN |
| 14 | Permanent non-frozen NFT↔position desync strand | `test_SAFE_noPermanentNonFrozenDesyncStrand` | SAFE | - | No role can move FUNDED to a stuck non-terminal, non-frozen state; freeze detour resolves |

Total probes: 14. Findings (HIGH/CRITICAL): 0.

## How to run

```
FOUNDRY_TEST=security-findings/07-lifecycle-state-machine/poc FOUNDRY_OUT=out-v07 FOUNDRY_CACHE_PATH=cache-v07 \
  forge test --match-path 'security-findings/07-lifecycle-state-machine/poc/*.t.sol' -vv
```

Note: `FOUNDRY_TEST` is pointed at this vector's `poc/` dir specifically so compilation is
isolated from other, in-progress vector folders under `security-findings/`. The functional run
filter is identical to the assignment's `--match-path` value.

## Observed Suite result

```
Suite result: ok. 14 passed; 0 failed; 0 skipped; finished in 2.56ms (6.35ms CPU time)
```

## What protects this / what breaks

The InvoiceNFT state machine is tight and every transition is single-source-gated:

- **Absorbing terminals.** `markSettled`/`markDefaulted` both require `status == FUNDED`
  (`InvoiceNFT.sol:157`, `:178`), so once one runs the other cannot. `verify` requires
  `CREATED` (`:112`), `markFunded` requires `VERIFIED` (`:133`), `freezeInvoice` requires
  `VERIFIED || FUNDED` (`:200`). SETTLED/DEFAULTED accept no transition and cannot be re-frozen.
- **Double-finance is doubly guarded.** The pool refuses a second finance via
  `financingPositions[id].fundedAt != 0` (`InvoiceFinancingPool.sol:265`), and even a direct
  `markFunded` fails because the NFT is FUNDED not VERIFIED (`InvoiceNFT.sol:133`).
- **Mutual exclusion of terminal paths.** `settleInvoice`/`resolveDefault` both check
  `position.resolved` (`InvoiceFinancingPool.sol:376`, `:501`), set it to true before external
  calls (CEI, `:416`, `:542`), and require the NFT still be `FUNDED` (`:396`, `:523`). The
  oracle further refuses to re-finalize (`onStatusFinalized` reverts
  `OracleStatusAlreadyFinalized`, `:209-212`) and refuses to submit against a non-FUNDED NFT
  (`InvoiceStatusOracle.sol:119`).
- **Non-transferability / no burn.** `_update` reverts `TransfersDisabled` for any `from != 0`
  (`InvoiceNFT.sol:242-250`); `approve`/`setApprovalForAll` are hard-reverting overrides
  (`:253-260`). There is no burn function, and transfer-to-zero is caught earlier by OZ's
  `ERC721InvalidReceiver`. The claim cannot move or disappear.
- **Freeze is a reversible overlay that preserves financial state.** `freezeInvoice` records
  `previousStatus = currentStatus` (`:204`) and `unfreezeInvoice` restores it exactly
  (`:225-226`), only from a FROZEN state (`:221`). Because freeze is only reachable from
  VERIFIED/FUNDED and re-freeze is blocked, `previousStatus` can never be corrupted to CREATED
  (placeholder) or FROZEN. `fundedAt` and all accounting fields are untouched across a
  freeze/unfreeze round-trip.

### The one thing worth naming (Low / liveness, not a finding)

`freezeInvoice` is a RISK_ROLE lever that, applied to a FUNDED invoice with a finalized oracle
outcome, makes both `settleInvoice` and `resolveDefault` revert `InvoiceFrozen`
(`InvoiceFinancingPool.sol:392`, `:519`). While the invoice stays frozen, the invoice's
principal remains in `totalLockedAssets` and the corresponding tranche liquidity is not
withdrawable by LPs (`SeniorPool.maxWithdraw` returns only `availableLiquidity`,
`SeniorPool.sol:78-86`). `test_SAFE_freezeStrandIsReversibleAndPrivilegedOnly` quantifies this:
the full financed principal (senior + junior split) is locked and the senior LP's withdrawable
amount drops by exactly the senior principal.

This is **not** a HIGH/CRITICAL finding because:
1. It is reachable **only** by a trusted RISK_ROLE holder — the same test proves a
   non-privileged `attacker` cannot freeze (`freezeInvoice` reverts on the role check).
2. It is **fully reversible**: `unfreezeInvoice` restores FUNDED exactly and settlement then
   completes with correct accounting and no double-count. No funds are lost or permanently
   stranded — capital availability is merely paused at the discretion of the risk operator,
   which is the documented purpose of the freeze overlay (`InvoiceNFT.sol:24`, `:187-191`).
3. No LP accounting invariant is violated: NAV, locked assets, and bad debt all remain
   consistent, and the exact-restore round-trip is proven in
   `test_SAFE_previousStatusIntegrity` and `test_SAFE_freezeBetweenSubmitAndFinalizeNoCorruption`.

Recommendation (defense-in-depth, non-blocking): document a max-freeze-duration / governance
timelock or an escape hatch that lets LPs exit locked capital if an invoice remains frozen
beyond an SLA, to bound the liveness surface of a compromised or negligent RISK_ROLE.

No HIGH/CRITICAL lifecycle findings. The negative result is the deliverable: the state machine
holds under illegal-transition, double-finance, mutual-exclusion, terminal-mutation,
non-transferability, freeze round-trip, and desync-strand probes.

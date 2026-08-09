# VECTOR 02 — Tranche waterfall & loss/recovery accounting

Scope: `InvoiceFinancingPool.settleInvoice`, `InvoiceFinancingPool.resolveDefault`, and the
`SeniorPool`/`JuniorPool` `lock/unlock/fund/credit/writeDown` primitives.

## Results table

| # | Hypothesis | Test function | Verdict | Severity | One-line result |
|---|------------|---------------|---------|----------|-----------------|
| 1 | Senior loss==0 whenever recovery>=seniorPrincipal across full recovery range | `test_SAFE_SeniorProtectionMatrix` | SAFE | — | Exact NAV deltas match; senior never loses while covered; junior eats first loss |
| 2 | First-loss ordering cannot be inverted | `test_SAFE_FirstLossOrderingNoInversion` | SAFE | — | At recovery=seniorP-1 junior fully wiped, senior loss is exactly 1 wei |
| 3 | writeDown DoS via a competing locked position | `test_SAFE_WriteDownDoS_CompetingLockedPosition` | SAFE | — | unlock precedes writeDown; resolution succeeds, sibling untouched |
| 4 | writeDown DoS after junior LP drains all available liquidity | `test_SAFE_WriteDownDoS_AfterJuniorDrainsLiquidity` | SAFE | — | unlock(juniorPrincipal) restores availableLiquidity>=loss; no strand |
| 5 | Bad-debt == principal-recovery, fee excluded | `test_SAFE_BadDebtExactPrincipalMinusRecovery` | SAFE | — | Exact; unpaid fee never counted as bad debt |
| 6 | Bad-debt accumulates cleanly across positions | `test_SAFE_BadDebtAccumulatesAcrossPositions` | SAFE | — | totalBadDebt == lossA+lossB, no double count / overwrite |
| 7 | No double-resolve (settle then default / re-settle) | `test_SAFE_NoDoubleResolveAfterSettle` | SAFE | — | `resolved` flag blocks both second resolutions |
| 7b | Cannot default a SETTLED-finalized invoice | `test_SAFE_CannotDefaultWhenOracleSettled` | SAFE | — | Reverts UnexpectedOracleStatus; path-guarded |
| 8 | Fee-split conservation + surplus routing at settlement | `test_SAFE_FeeSplitConservationAtSettlement` | SAFE | — | seniorFee+juniorFee==fee, NAV deltas exact, surplus->supplier, locked->0 |
| 9 | Cross-position isolation on default | `test_SAFE_CrossPositionIsolationOnDefault` | SAFE | — | Survivor's lock/NAV untouched; it settles cleanly afterwards |
| 10 | NAV conservation over multi-step lifecycle | `test_SAFE_NavConservationMultiStep` | SAFE | — | finalNAV+losses == initialDeposits+fees, exact |
| 11 | Settlement underpayment boundary | `test_SAFE_SettlementUnderpaymentBoundary` | SAFE | — | expected-1 reverts; exact works with zero surplus |
| 12 | Recovery edges =principal and =seniorPrincipal | `test_SAFE_RecoveryEdges` | SAFE | — | Full recovery: no loss/badDebt; =seniorP: junior wiped, senior whole |
| 13 | Junior-remainder routing under non-round funding split | `test_SAFE_JuniorRemainderRoutingNonRoundSplit` | SAFE | — | 4000-wei junior remainder absorbed by junior; senior stays whole |
| 14 | totalLockedAssets decremented exactly once on default | `test_SAFE_TotalLockedDecrementedOnceOnDefault` | SAFE | — | Global + per-tranche locked drop by exact principals |

15 probes total (hypotheses 7 and 7b are two functions). **0 HIGH/CRITICAL findings.**

## How to run

Run from repo root (isolated build/cache dir; test root scoped to this vector's `poc/` so the
unrelated, currently-broken vector 07 does not get compiled):

```bash
FOUNDRY_TEST=security-findings/02-tranche-waterfall-accounting/poc \
FOUNDRY_OUT=out-v02 FOUNDRY_CACHE_PATH=cache-v02 \
forge test --match-path 'security-findings/02-tranche-waterfall-accounting/poc/*.t.sol' -vv
```

Note: the prompt's suggested command (`FOUNDRY_TEST=security-findings`) fails to compile
because a *sibling* vector, `security-findings/07-lifecycle-state-machine/poc/Lifecycle.t.sol`,
has a unicode em-dash in a `require`/`assertEq` string and references a non-existent error
selector (`IInvoiceFinancingPool.InvoiceAlreadyFinanced`). That is not in this vector's scope
and I must not modify other folders, so I scope `FOUNDRY_TEST` to this vector's `poc/` dir,
which compiles the exact same protocol + `_base/Harness` and yields an isolated green suite.

## Observed final suite result

```
Suite result: ok. 15 passed; 0 failed; 0 skipped; finished in 6.36ms (13.47ms CPU time)
```

## What protects this / what breaks

The waterfall is a clean, correctly-ordered, senior-first design. Every probed guarantee held.

**Senior protection & first-loss (H1, H2, H12, H13).**
`resolveDefault` computes `seniorRecovery = min(recovery, seniorPrincipal)` and
`juniorRecovery = recovery - seniorRecovery`
(`src/core/InvoiceFinancingPool.sol:531-533`), then
`seniorLoss = seniorPrincipal - seniorRecovery`, `juniorLoss = juniorPrincipal - juniorRecovery`
(`:535-536`). Because senior recovery is capped at seniorPrincipal, senior can only lose once
recovery drops below seniorPrincipal — i.e. junior is already fully wiped. There is no
arithmetic path that routes junior's loss onto senior or vice-versa, including under a
non-round funding split (junior receives the floor remainder at funding time,
`src/core/InvoiceFinancingPool.sol:281-282`, and absorbs exactly that remainder as loss).

**writeDown never strands funds (H3, H4).**
This was the highest-value hypothesis. `writeDown` requires `assets <= availableLiquidity()`
(`src/pools/SeniorPool.sol:196-198`, `src/pools/JuniorPool.sol:196-198`), so a naive worry is
that a defaulting position's writedown could revert when liquidity is locked/drained. It cannot,
because `resolveDefault` calls `unlockAssets(position.juniorPrincipal)` and
`unlockAssets(position.seniorPrincipal)` **before** the writedowns
(`src/core/InvoiceFinancingPool.sol:554-563`). Unlock raises `availableLiquidity` (=
`accountedAssets - lockedAssets`) by the freed principal, and `juniorLoss <= juniorPrincipal`,
`seniorLoss <= seniorPrincipal`. So after unlock, `availableLiquidity >= loss` regardless of how
many sibling positions are locked or how much a junior LP withdrew first (withdrawals reduce
`accountedAssets` but can never touch locked liquidity — enforced by `_withdraw`'s
`assets > availableLiquidity` guard, `src/pools/JuniorPool.sol:217-219`). Both DoS constructions
were exercised and resolution succeeded.

**Bad-debt accounting (H5, H6).**
`totalBadDebt += (principal - recovery)` (`src/core/InvoiceFinancingPool.sol:538,544`). The
financing fee is never realized NAV during a default (it's only credited on the SETTLED path via
`creditAssets`), so it is correctly excluded from bad debt. Accumulation across positions is a
plain `+=` with no cross-position state, so two defaults sum exactly.

**One-shot resolution / locked-asset conservation (H7, H7b, H14).**
`position.resolved` is set true and `totalLockedAssets -= position.principal` executed once,
under CEI before any external call, on both the settle path
(`src/core/InvoiceFinancingPool.sol:416-417`) and default path (`:542-543`). The `resolved`
guard (`:376-378`, `:501-503`) plus the InvoiceNFT terminal-state guards
(`markSettled`/`markDefaulted` require FUNDED, `src/core/InvoiceNFT.sol:157-159,178-180`) make
any second resolution revert. The oracle-status path guard also prevents defaulting a
SETTLED-finalized invoice.

**Fee-split & NAV conservation (H8, H10, H11).**
`juniorFee = floor(fee * JUNIOR_FEE_SHARE_BPS/BPS)`, `seniorFee = fee - juniorFee`
(`src/core/InvoiceFinancingPool.sol:406-407`) so the split is conservative by construction
(remainder to senior). Principal is restored simply by unlocking (it was never removed from NAV,
only locked). Surplus above `principal+fee` is transferred to the supplier (`:427-429`). Across a
settle + partial-default + full-default sequence, `finalNAV + realizedLosses ==
initialDeposits + realizedFees` held exactly — no silent LP gain or loss.

### Non-findings noted (informational, not HIGH/CRITICAL)

- **Fee-split floor keeps a wei on the senior side; funding-split floor keeps a wei on the
  junior side.** Both are ≤1-wei rounding, deterministic, and documented in-source. Not a
  finding.
- **`resolveDefault`/`settleInvoice` pull assets from `msg.sender` (the keeper), not the
  buyer.** This is the intended permissionless-execution design (recovery amount is
  oracle-fixed; the keeper front-funds and is reimbursed off-chain / is the recovering party).
  Economic, not an accounting break — out of this vector's scope and covered by trust-model.
- **No `ReentrancyGuard`.** CEI ordering (resolved flag + accounting before transfers) makes the
  waterfall re-entrancy-safe on a standard ERC20; malicious-token reentrancy is vector 06's
  scope, not tranche accounting.

## Conclusion

The tranche waterfall and loss/recovery accounting are correct and robust under every probed
condition. No HIGH or CRITICAL issues. This vector's deliverable is negative documentation: the
senior-protection guarantee, first-loss ordering, one-shot resolution, bad-debt correctness,
writeDown liveness, and NAV conservation all hold with exact on-chain assertions.

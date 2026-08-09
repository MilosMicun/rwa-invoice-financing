# VECTOR 07 — Invoice Lifecycle State Machine & Freeze Griefing

## Scope
- `src/core/InvoiceNFT.sol` — the lifecycle source of truth (CREATED → VERIFIED → FUNDED →
  SETTLED|DEFAULTED, with FROZEN overlay). Role-gated transitions.
- Its interplay with `InvoiceFinancingPool.financeInvoice / settleInvoice / resolveDefault /
  onStatusFinalized` and `InvoiceStatusOracle.submitStatus / finalize`.

## Trust model (from repo)
- ORIGINATOR_ROLE creates, VERIFIER_ROLE verifies, POOL_ROLE (= the pool contract) drives
  markFunded/markSettled/markDefaulted, RISK_ROLE freezes/unfreezes.
- Privileged-role powers are INTENDED. A finding must break a stated guarantee
  (senior-protection waterfall, one-shot oracle, LP accounting conservation,
  funds-not-stranded, no-unauthorized-loss/gain) OR be triggerable by a NON-privileged actor.

## Known-attack classes for this vector
1. Illegal state transitions (skip/rewind the state graph).
2. Double-spend / double-finance of the same invoice.
3. Settle vs default mutual-exclusion break (both terminal paths on one invoice).
4. Stuck-state / stranded funds (locked tranche liquidity cannot be released).
5. Freeze griefing (RISK_ROLE freeze blocks settle/resolve → liveness/strand).
6. Non-transferability bypass (move or burn the claim NFT).
7. Terminal-state mutation (mutate SETTLED/DEFAULTED, or re-freeze them).
8. previousStatus corruption on freeze/unfreeze restoring a bogus state.
9. NFT ↔ pool position desync stranding funds.

## Numbered hypotheses (≥10; attacker goal + method)

1. **Double-finance** — Goal: finance the same invoice twice to drain both tranches for one
   receivable. Method: bootstrap a FUNDED invoice, call `financeInvoice` again as supplier.
   Expect revert (pool `fundedAt!=0` guard) AND independently prove `markFunded` requires
   VERIFIED. SAFE if both guards hold.

2. **Settle then default** — Goal: run both terminal paths on one invoice (double payout /
   loss double-count). Method: settle a FUNDED invoice, then submit+finalize DEFAULTED and
   call `resolveDefault`. Expect the second path blocked (`resolved` flag + oracle already
   finalized + NFT no longer FUNDED). SAFE.

3. **Default then settle** — mirror of #2. Method: resolveDefault, then attempt settle.
   Expect blocked. SAFE.

4. **FREEZE STRAND** — Goal: as (or via) RISK_ROLE, permanently lock tranche liquidity by
   freezing a FUNDED invoice that has a finalized oracle outcome, so settle/resolve always
   revert `InvoiceFrozen` and `totalLockedAssets` never releases; LPs cannot withdraw locked
   capital. Method: bootstrap+finalize, freeze, prove settle & resolve revert and quantify
   locked LP capital blocked from withdrawal. Assess whether a NON-risk actor can trigger it
   (default hypothesis: no) → classify.

5. **markFunded state gating** — Goal: fund from a non-VERIFIED state. Method: attempt
   `financeInvoice`/`markFunded` from CREATED, SETTLED, DEFAULTED, FROZEN. Expect all revert.
   SAFE.

6. **Non-transferability** — Goal: move or burn the claim NFT. Method: transferFrom,
   safeTransferFrom, approve, setApprovalForAll from the owner (supplier). All revert
   `TransfersDisabled`. Confirm no burn path exists (`_update` blocks to==0 as well). SAFE.

7. **Re-verify after funding** — Goal: reset a FUNDED invoice back to VERIFIED to re-finance.
   Method: verify() a FUNDED/SETTLED invoice. Expect revert (verify requires CREATED). SAFE.

8. **Freeze VERIFIED blocks financing** — Goal: freeze a VERIFIED invoice, then finance it.
   Method: freeze, then `financeInvoice`. Expect `InvoiceNotEligible` (isEligible false
   because status FROZEN != VERIFIED). SAFE. (Also a griefing note: RISK_ROLE can block
   financing pre-funding, but no funds locked yet.)

9. **Freeze after submit, before finalize** — Goal: use the freeze window to lock in a stale
   outcome that later mis-resolves. Method: submit oracle status, freeze, finalize (should
   succeed by design), unfreeze, then verify the outcome resolves correctly with no
   corruption. SAFE (design intent) — confirm no accounting corruption.

10. **Terminal immutability** — Goal: mutate a terminal state. Method: on a SETTLED and on a
    DEFAULTED invoice, attempt verify / markFunded / markSettled / markDefaulted / freeze.
    All revert. SAFE.

11. **previousStatus integrity** — Goal: exploit the CREATED placeholder previousStatus, or
    unfreeze a non-frozen invoice, to land in a bogus state. Method: (a) unfreeze a
    non-FROZEN invoice → revert; (b) VERIFIED→FROZEN→unfreeze restores VERIFIED exactly;
    (c) FUNDED→FROZEN→unfreeze restores FUNDED exactly and is still resolvable. SAFE.

12. **Freeze/unfreeze round-trip restores exact state** — combined with #11: prove no path
    yields a wrong restored status enabling an illegal action; round-trip preserves fundedAt
    and lets the normal terminal path complete. SAFE.

13. **NFT ↔ position desync strand** — Goal: leave the pool holding a FUNDED position with
    locked assets that can never be resolved (NFT desynced). Method: search for any reachable
    state where the pool position exists but the NFT is not FUNDED and not FROZEN and cannot
    be moved back to FUNDED. Because only the pool (POOL_ROLE) drives FUNDED→terminal and
    RISK_ROLE freeze is reversible, argue whether a permanent non-frozen desync is reachable.
    SAFE unless a strand independent of RISK_ROLE is found.

## Deliverables
- PLAN.md (this file)
- poc/Lifecycle.t.sol — ≥10 test functions, all compiling + passing.
- README.md — results table + run command + observed Suite result + narrative.
- findings/V07-xx/ — only for confirmed HIGH/CRITICAL.

## Run command
```
FOUNDRY_TEST=security-findings FOUNDRY_OUT=out-v07 FOUNDRY_CACHE_PATH=cache-v07 \
  forge test --match-path 'security-findings/07-lifecycle-state-machine/poc/*.t.sol' -vv
```

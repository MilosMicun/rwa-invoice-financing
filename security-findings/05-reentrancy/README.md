# Vector 05 — Reentrancy & External-Call Safety — Results

Auditor conclusion: **NO HIGH/CRITICAL reentrancy findings.** The protocol ships with
**no `ReentrancyGuard` anywhere**, yet every state-changing entry point in
`InvoiceFinancingPool` is protected by correct Checks-Effects-Interactions (CEI)
ordering, and the ERC-4626 vaults' `maxWithdraw`/`availableLiquidity` override caps every
withdrawal to un-locked, cash-backed NAV. Reentrancy via an ERC777/callback asset, the
ERC721 mint hook, cross-function and cross-pool paths were all attempted and all failed
to extract value or corrupt accounting. One INFO-level read-only-reentrancy window exists
(stale NAV observable mid-withdraw) with no in-protocol exploit path.

All PoCs run on the protocol **redeployed on the ERC777-style `ReentrantToken`** (callback
fires mid-transfer inside `_update`).

## Results table

| # | Hypothesis | Test function | Verdict | Severity | One-line result |
|---|------------|---------------|---------|----------|-----------------|
| 1 | Same-invoice reentrancy into `settleInvoice` from repayment transfer hook | `test_SAFE_SettleSameInvoiceReentrancyReverts` | SAFE | — | Reverts `FinancingPositionAlreadyResolved`; `resolved=true` set before transfers (L416). |
| 2 | Cross-fn: settle hook → `withdrawSenior` over-withdraw (unlock not yet run) | `test_SAFE_SettleThenWithdrawCannotOverWithdraw` | SAFE | — | Reverts `ERC4626ExceededMaxWithdraw`; mid-tx `availableLiquidity` still low (unlock is post-transfer). |
| 3 | Same-invoice reentrancy into `resolveDefault` from recovery transfer hook | `test_SAFE_ResolveDefaultSameInvoiceReentrancyReverts` | SAFE | — | Reverts `FinancingPositionAlreadyResolved`; no double write-down, `totalBadDebt==0`. |
| 4 | Deposit reentrancy: re-enter `depositSenior` from `transferFrom` hook | `test_SAFE_DepositReentrancyNoMispricing` | SAFE | — | Each deposit pulls its own assets; shares worth exactly what was paid (no free mint). |
| 5 | Same-invoice reentrancy into `financeInvoice` from `fundInvoice` hook | `test_SAFE_FinanceInvoiceSameIdReentrancyReverts` | SAFE | — | Reverts `InvoiceAlreadyFinanced`; no position/lock created. Funding transfers are the LAST external calls. |
| 6 | Finance hook → `withdrawSenior` to drain freshly-locked liquidity | `test_SAFE_FinanceThenWithdrawCannotDrainLockedLiquidity` | SAFE | — | Reverts `ERC4626ExceededMaxWithdraw`; `lockAssets` runs before `fundInvoice`, so liquidity is already committed. |
| 7 | Surplus/any-transfer hook → re-enter `settleInvoice` (supplier contract) | `test_SAFE_SettleSurplusReentrancyReverts` | SAFE | — | Reverts `FinancingPositionAlreadyResolved`; resolved flag precedes all transfers. |
| 8 | ERC721 `onERC721Received` on `createInvoice` → `verify`/`financeInvoice` | `test_SAFE_ERC721OnReceivedCannotAdvanceLifecycle` | SAFE | — | `verify` needs VERIFIER_ROLE, finance needs VERIFIED; both fail. Invoice stays CREATED. |
| 9 | Read-only reentrancy: read `totalAssets` mid-withdraw (shares burned, NAV not yet decremented) | `test_INFO_ReadOnlyReentrancyStaleNavDuringWithdraw` | INFO | Info/Low | A **stale, inflated** NAV IS observable mid-withdraw; no in-protocol consumer reads it during a state-change, so no exploit. External integrators must not price against these vaults mid-callback. |
| 10 | Cross-pool: senior transfer hook → drain junior via `withdrawJunior` | `test_SAFE_CrossPoolIsolationJuniorUntouchedDuringSeniorHook` | SAFE | — | Reverts `ERC4626ExceededMaxWithdraw`; pools are fully independent, junior liquidity still locked. |
| 11 | Value extraction: in-budget reentrant `withdrawSenior` during settle (attack actually executes) | `test_SAFE_NoValueExtractionViaReentrantWithdrawDuringSettle` | SAFE | — | Reentrant withdraw succeeds but LP gets exactly fair value (shares burned 1:1); pool ends cash ≥ NAV. No profit. |
| 12 | Prove the callback fires (no guard) yet CEI still protects settle | `test_SAFE_HookActuallyFiresProvingNoGuardButCEIHolds` | SAFE | — | `hookFireCount` increments by 1 (reentrancy reachable), settle still completes correctly. |

## How to run

```bash
FOUNDRY_TEST=security-findings FOUNDRY_OUT=out-v05 FOUNDRY_CACHE_PATH=cache-v05 \
  forge test --match-path 'security-findings/05-reentrancy/poc/*.t.sol' -vv
```

## Observed final suite result

```
Suite result: ok. 12 passed; 0 failed; 0 skipped; finished in 6.58ms (18.12ms CPU time)
```

## CEI map — external call vs state write per state-changing function

References are to `src/core/InvoiceFinancingPool.sol` and `src/pools/SeniorPool.sol`
(JuniorPool is identical).

### `settleInvoice` (L369-458)
- Effects FIRST: `position.resolved = true` (L416), `totalLockedAssets -= principal` (L417).
- Interactions AFTER: `ASSET.safeTransferFrom` ×3 (L420 senior, L424 junior, L428 surplus→supplier).
- Post-transfer pool calls: `unlockAssets` (L431/432), `creditAssets` (L434-440),
  `updateBuyerExposure` (L442), `markSettled` (L444).
- Why safe: any reentry sees `resolved==true` → reverts. During the transfer hooks the
  tranche NAV is still LOCKED (unlock has not run), so `availableLiquidity` is depressed and
  a cross-function `withdraw*` cannot over-draw (probes 2, 10). `creditAssets` re-checks
  `balanceOf >= availableLiquidity()+assets` (SeniorPool L172-176) as a solvency assertion.

### `resolveDefault` (L494-581)
- Effects FIRST: `resolved=true` (L542), `totalLockedAssets -=` (L543), `totalBadDebt +=` (L544).
- Interactions AFTER: `safeTransferFrom` ×2 (L547 senior, L551 junior); then `unlockAssets`
  (L554/555), `writeDown` (L557-563), `updateBuyerExposure` (L565), `markDefaulted` (L567).
- Why safe: identical pattern to settle. Reentry → `FinancingPositionAlreadyResolved`
  (probe 3). The waterfall math (`seniorRecovery`/`juniorLoss`) is computed from immutable
  stored position fields before any external call.

### `financeInvoice` (L258-337)
- Effects FIRST: `financingPositions[id] = …` (L299-309), `totalLockedAssets +=` (L311),
  `SENIOR/JUNIOR_POOL.lockAssets` (L316/317), `updateBuyerExposure(+)` (L319),
  `markFunded` (L321).
- Interactions LAST: `SENIOR_POOL.fundInvoice` (L323), `JUNIOR_POOL.fundInvoice` (L324) —
  the only external token movements, and they are the final statements.
- Why safe: reentry → `InvoiceAlreadyFinanced` (position set) or NFT no longer VERIFIED
  (probe 5). Liquidity is already locked before the transfer, so a colluding LP cannot
  withdraw the committed principal in the hook (probe 6).

### `depositSeniorFor` / `depositJuniorFor` (L592-637)
- Interaction: `ASSET.safeTransferFrom(msg.sender → coordinator)` (L601/629) fires the hook
  BEFORE `POOL.deposit` mints shares.
- Why safe: at hook time no shares exist yet and NAV is unchanged; a reentrant deposit is a
  full, self-funded deposit (pulls its own assets). No double-count / mispricing (probe 4).
  `forceApprove(pool,0)` after deposit prevents residual allowance.

### `withdrawSeniorTo` / `withdrawJuniorTo` (L652-691)
- Interaction: `POOL.withdraw` → `_withdraw` (SeniorPool L213-224) burns shares +
  `super._withdraw`'s `safeTransfer(receiver)` fires the hook, THEN `accountedAssets -=
  assets` (L223).
- Read-only window: mid-hook, shares are already burned but `accountedAssets` is still the
  pre-withdraw value → `totalAssets()`/`convertToAssets` return a **stale inflated** number
  (probe 9). This is the classic read-only-reentrancy shape.
- Why no HIGH/CRITICAL: OZ `withdraw` first calls the overridden `maxWithdraw` (SeniorPool
  L78-86), which caps withdrawable to `min(ownerAssets, availableLiquidity, cash)`, and
  `_withdraw` re-asserts `assets <= availableLiquidity()` (L217). No in-protocol function
  reads a pool's own share price during another contract's callback, so the stale value is
  never consumed on-chain to move value.

## What protects this / what breaks

**What protects it (defense-in-depth without a guard):**
1. **CEI on the resolution paths** — `resolved` and the aggregate counters are written
   before every `ASSET` transfer, so same-function reentrancy always hits the resolved/
   already-financed guard.
2. **NAV != token balance** — `totalAssets()` returns internal `accountedAssets`, so raw
   token movement in a hook cannot shift share price, and `availableLiquidity =
   accountedAssets - lockedAssets` stays depressed while a position is mid-resolution.
3. **`maxWithdraw`/`_withdraw` availableLiquidity cap** — every LP exit is bounded by
   un-locked, cash-backed NAV; the elevated `lockedAssets` during settle/finance makes any
   cross-function over-withdraw revert with `ERC4626ExceededMaxWithdraw`.
4. **`creditAssets` solvency assertion** — NAV can only grow if real cash already backs it
   (SeniorPool L172-176), so no phantom yield can be minted via a callback.
5. **Role-gated lifecycle** — the ERC721 mint hook cannot advance CREATED→VERIFIED→FUNDED
   without VERIFIER_ROLE / eligibility.

**What would break it (hypothetical, not present):**
- If any effect (e.g. `resolved=true`, `lockedAssets` bump, or `accountedAssets`
  decrement) were moved to AFTER its associated transfer, the corresponding probe would flip
  to a FINDING. The `accountedAssets -= assets` in `_withdraw` runs after the transfer, but
  is harmless only because `maxWithdraw`/`availableLiquidity` already gate the amount — if a
  future change let `withdraw` bypass `maxWithdraw`, the read-only window (probe 9) could
  become a share-price-manipulation lever for an external integrator.
- An external protocol that prices collateral off `SeniorPool.convertToAssets` /
  `totalAssets` and can be entered during a withdraw callback would read the stale inflated
  NAV. That is an integrator-side risk, documented as INFO here.

## Medium/Low/Info notes
- **INFO (read-only reentrancy):** `SeniorPool`/`JuniorPool` `totalAssets()` and
  `convertToAssets()` are transiently inflated during a withdraw's `safeTransfer(receiver)`
  callback (probe 9). No in-protocol consumer, but external integrators must not use these
  vaults as a mid-callback price oracle.
- **INFO (no ReentrancyGuard):** intentional; CEI + the NAV/liquidity design are sufficient
  for the current call graph. Adding `nonReentrant` to `settleInvoice`/`resolveDefault`/
  `financeInvoice`/`deposit*`/`withdraw*` would be cheap belt-and-suspenders and would also
  close the read-only window against future integrators.

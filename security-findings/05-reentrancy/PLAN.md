# Vector 05 — Reentrancy & External-Call Safety — Attack Plan

## Scope
`InvoiceFinancingPool`: `settleInvoice`, `resolveDefault`, `financeInvoice` (→ pool
`fundInvoice`), `depositSenior/Junior*`, `withdrawSenior/Junior*`. There is **NO
ReentrancyGuard anywhere** in the protocol; reentrancy safety relies purely on CEI
ordering. The pools (`SeniorPool`/`JuniorPool`) are ERC-4626 vaults whose NAV is the
internal `accountedAssets`, not the raw token balance.

## Attack surface / external-call inventory (src/core/InvoiceFinancingPool.sol)
- `settleInvoice`: state writes `position.resolved=true` (L416) + `totalLockedAssets-=principal`
  (L417) happen **before** three `ASSET.safeTransferFrom` calls (L420/424/428). Pool
  `unlockAssets`/`creditAssets` run **after** the transfers (L431-440).
- `resolveDefault`: `position.resolved=true` (L542), `totalLockedAssets-=` (L543),
  `totalBadDebt+=` (L544) **before** two `safeTransferFrom` (L547/551); `unlockAssets`
  + `writeDown` run **after** (L554-563).
- `financeInvoice`: position stored + `totalLockedAssets+=` + `lockAssets` +
  `updateBuyerExposure` + `markFunded` **all before** the two `fundInvoice` external
  transfers (L323/324), which are the LAST external calls.
- `deposit*For`: `safeTransferFrom(LP→coordinator)` (L601/629) fires **before**
  `POOL.deposit` mints shares.
- `withdraw*To`: `POOL.withdraw` → `_withdraw` burns shares + `safeTransfer(receiver)`
  runs **before** `accountedAssets -= assets` (SeniorPool L221-223). Read-only window.

The callback asset is `MaliciousTokens.ReentrantToken` (ERC777-style: fires
`hookTarget.call(hookData)` inside `_update`, i.e. mid-transfer, before the outer
protocol call returns). Deploy via `_deployProtocol(address(new ReentrantToken()))`
in an overridden `setUp`.

## Known-attack classes for this vector
1. Classic single-function reentrancy (re-enter the same fn mid-transfer).
2. Cross-function reentrancy (settle → withdraw; finance → withdraw; etc.).
3. Read-only reentrancy (observe stale `totalAssets`/`convertToAssets`/`availableLiquidity`).
4. ERC777 / callback-asset transfer hooks (the ReentrantToken above).
5. ERC721 `onERC721Received` hook on `_safeMint` of the invoice NFT.
6. Cross-pool reentrancy (act on junior during a senior transfer hook, and vice versa).
7. Value extraction: any callback sequence that leaves attacker with more assets than
   owed, or pools with less NAV than cash.

## Hypotheses (≥10 concrete attacker goals)
1. **Settle same-invoice reentrancy** — from the settle repayment transfer hook,
   re-enter `settleInvoice(sameId)`. Goal: double-settle / double fee credit.
   Expect: revert `FinancingPositionAlreadyResolved` (resolved set pre-transfer). SAFE.
2. **Settle → withdraw over-withdraw** — from the settle hook (unlock NOT yet run),
   attacker (an LP) re-enters `withdrawSenior`/`withdrawJunior`. Goal: withdraw against
   the elevated post-settle NAV before locked liquidity is released. Expect: capped by
   still-low `availableLiquidity`; no over-withdraw. SAFE.
3. **resolveDefault same-invoice reentrancy** — from the recovery transfer hook,
   re-enter `resolveDefault(sameId)`. Goal: double write-down / double bad debt. Expect:
   revert `FinancingPositionAlreadyResolved`. SAFE.
4. **Deposit reentrancy** — from the `transferFrom(LP→coordinator)` hook, re-enter
   `depositSenior` again. Goal: mint shares twice for one asset transfer / mispricing.
   Expect: each deposit pulls its own assets; share price conserved. SAFE.
5. **financeInvoice reentrancy** — supplier is a contract; on the senior `fundInvoice`
   transfer hook re-enter `financeInvoice(sameId)`. Goal: fund twice / drain. Expect:
   revert `InvoiceAlreadyFinanced` (position stored pre-transfer). SAFE.
6. **financeInvoice → withdraw mid-financing** — from the senior fundInvoice hook
   (senior locked+sent, junior lock already set), a colluding LP re-enters withdraw.
   Goal: pull liquidity that is now committed. Expect: `availableLiquidity` already
   reduced by both locks; no over-withdraw. SAFE.
7. **Surplus transfer → supplier reentrancy** — supplier is a contract receiving the
   settle surplus; on that hook re-enter `settleInvoice`/`withdraw`. Goal: exploit the
   window after senior/junior repaid but before unlock. Expect: resolved already true;
   withdraw capped. SAFE.
8. **ERC721 onReceived on createInvoice** — supplier is a contract; on the `_safeMint`
   `onERC721Received` hook re-enter `verify`/`financeInvoice`. Goal: advance lifecycle
   CREATED→VERIFIED→FUNDED without the roles. Expect: role/eligibility reverts. SAFE.
9. **Read-only reentrancy during withdraw** — from the withdraw `safeTransfer(receiver)`
   hook (shares burned, accountedAssets not yet decremented), read `totalAssets`,
   `convertToAssets`, `availableLiquidity`. Goal: prove a stale inflated NAV is
   observable that an integrator could be tricked by. Document the window + severity.
10. **Cross-pool isolation** — during the senior repayment transfer hook, act on the
    junior pool (withdraw / read) and vice versa. Goal: use one pool's mid-tx state to
    harm the other. Expect: pools are independent; junior state untouched. SAFE.
11. **Value-extraction attempt (the real goal)** — construct ANY callback sequence via
    the ReentrantToken that ends with the attacker holding more assets than owed OR a
    pool holding less NAV than cash. Assert conservation: after every probe,
    `seniorPool.totalAssets()` and cash relationship holds, attacker balance ≤ legit.
12. **CEI map (README)** — enumerate every external call vs state write per
    state-changing function, proving why each ordering is safe (or flagging it).

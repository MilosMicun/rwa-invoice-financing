# Vector 01 — ERC-4626 Vault Accounting & Share-Price Manipulation

## Scope
- `src/pools/SeniorPool.sol` (ERC-4626)
- `src/pools/JuniorPool.sol` (ERC-4626)  — identical code to SeniorPool
- Their interaction with `src/core/InvoiceFinancingPool.sol` deposit/withdraw wrappers.

## Key design facts (verified in src)
- `totalAssets()` returns the internal `accountedAssets`, NOT the ERC20 balance
  (`SeniorPool.sol:68-70`). Raw token donations therefore do NOT change NAV or
  share price. This neutralizes the classic donation/inflation attack by construction.
- OZ v5.6.1 ERC4626, `_decimalsOffset()` NOT overridden (=0). Inflation resistance
  comes only from OZ's `+1` virtual asset/share (`ERC4626.sol:248-256`) plus the
  `accountedAssets` design.
- `convertToShares(a) = a*(supply+1)/(accountedAssets+1)` floor.
- `convertToAssets(s) = s*(accountedAssets+1)/(supply+1)` floor.
- `availableLiquidity() = accountedAssets - lockedAssets` (`:73-75`). `lockAssets`
  and `writeDown` both require `amount <= availableLiquidity`, keeping
  `accountedAssets >= lockedAssets` so availableLiquidity never underflows.
- `_deposit` bumps `accountedAssets += assets` AFTER super; `_withdraw` requires
  `assets <= availableLiquidity` and then `accountedAssets -= assets` (`:206-224`).
- `maxWithdraw` = min(ownerAssets, availableLiquidity, cashBalance) (`:78-86`).
- `creditAssets`/`fundInvoice`/`lockAssets`/`unlockAssets`/`writeDown` are all
  `onlyInvoiceFinancingPool` (`:96,111,129,164,187`).

## Attack classes for this vector
1. First-depositor / inflation (donation) attack.
2. Decimals-offset rounding weakness.
3. Empty-vault / NAV-to-zero share explosion.
4. Deposit/withdraw round-trip rounding theft / griefing.
5. `maxWithdraw`/`maxRedeem` bypass of locked liquidity.
6. Withdrawing donated/extra cash that is not the LP's NAV.
7. `convertToShares`/`convertToAssets` monotonicity & dust minting.
8. Diluting a later depositor after a writeDown reduced price.
9. External reachability of privileged NAV mutators (`creditAssets` etc).
10. Direct ERC-4626 entry (bypass coordinator) breaking coordinator assumptions.
11. `availableLiquidity` underflow while shares outstanding.
12. `mint()` path vs `deposit()` path rounding differences.

## Numbered hypotheses (attacker goal + method) — >=10

1. **Donation inflation (classic first-depositor).** Attacker deposits 1 wei,
   transfers a large raw token amount directly to the vault, victim deposits and
   is rounded to ~0 shares, attacker redeems and steals victim's deposit.
   Method: `_depositSenior(attacker,1)`, `asset.transfer(seniorPool, 1e24)`,
   `_depositSenior(victim, 2e24)`, check victim shares & convertToAssets.
   Expected: SAFE — NAV unchanged by donation.

2. **NAV inflation only via `creditAssets`.** Confirm that only the `onlyPool`
   `creditAssets` path (settlement yield) moves NAV; a raw ERC20 push to the vault
   does not. Method: record price, push tokens, assert convertToShares identical;
   then run a real settlement and assert NAV grew by the credited fee only.
   Expected: SAFE.

3. **NAV-to-zero share explosion.** Drive junior `accountedAssets` to a tiny value
   via near-total writeDown while shares outstanding, new depositor deposits.
   Because of OZ `+1`, price cannot literally divide-by-zero; check convertToShares
   for the new depositor and whether pre-existing holders are stolen from.
   Expected: SAFE (assess honestly; new depositor over-mints only against a
   near-worthless vault, which is fair first-loss, not theft).

4. **Round-trip rounding extraction.** Attacker deposits then immediately withdraws
   repeatedly. Can floor(deposit shares)/ceil(withdraw shares) net the attacker
   value out of existing LPs, or grief NAV downward? Method: loop deposit(x)+
   withdraw(x) and compare attacker asset balance & existing LP convertToAssets.
   Expected: SAFE (attacker loses dust to virtual shares, never gains).

5. **maxWithdraw / locked-liquidity bypass.** After financing locks most NAV, an LP
   tries to withdraw more than `availableLiquidity`. Method: withdraw(availLiq+1)
   directly on the vault and via coordinator. Expected: SAFE (revert
   ExceededMaxWithdraw / InsufficientAvailableLiquidity).

6. **Withdraw donated/extra cash.** After a settlement leaves extra cash, or after
   a raw donation, an LP tries to withdraw more assets than their NAV entitlement.
   Method: donate to vault, LP calls maxWithdraw / attempts withdraw > ownerAssets.
   Expected: SAFE (bounded by convertToAssets(ownerShares) and availableLiquidity).

7. **Dust minting / convert monotonicity.** 1-wei deposits into a high-NAV vault
   mint 0 shares (assets burned to virtual shares) — is that a griefing/theft?
   Method: deposit 1 wei into a large vault, check shares minted and whether the
   1 wei is stolen from existing holders. Expected: SAFE/INFO (self-grief only).

8. **Later depositor after writeDown.** After junior writeDown lowers price, a new
   junior LP deposits at the reduced price. Confirm they are NOT diluted beyond the
   legitimate first-loss already realized, and cannot dilute existing holders.
   Method: writeDown via a real default, new LP deposits, compare pre/post
   convertToAssets of the existing holder. Expected: SAFE.

9. **`creditAssets` external reachability.** A non-pool address calls
   `creditAssets` / `writeDown` / `lockAssets` / `unlockAssets` / `fundInvoice`
   directly. Expected: SAFE (revert NotInvoiceFinancingPool).

10. **Direct ERC-4626 deposit/withdraw bypassing coordinator.** Attacker calls
    `seniorPool.deposit`/`withdraw` directly (no coordinator). Does anything the
    coordinator assumes break (approvals, receiver, NAV)? Method: deposit directly,
    check shares/NAV consistent; withdraw directly, check bounded by
    availableLiquidity. Expected: SAFE (ERC-4626 self-consistent; coordinator is a
    convenience, not a security boundary for entry/exit).

11. **`availableLiquidity` underflow.** Attempt to make `lockedAssets >
    accountedAssets` (e.g., writeDown after lock). Prove availableLiquidity never
    underflows and lock/writeDown guards hold. Method: lock most NAV, force a
    writeDown path via default and assert `accountedAssets >= lockedAssets`
    throughout. Expected: SAFE.

12. **`mint()` vs `deposit()` rounding.** Compare the two entry paths for
    exploitable asymmetry (mint rounds assets up, deposit rounds shares down).
    Method: mint(shares) vs deposit(assets) into same-state vault; confirm no
    free-share arbitrage. Expected: SAFE.

## Deliverables
- `poc/VaultAccounting.t.sol` — >=12 test functions, all green.
- `README.md` — results table + suite result + narrative.
- `findings/<ID>/README.md` — only for confirmed HIGH/CRITICAL (expected none).

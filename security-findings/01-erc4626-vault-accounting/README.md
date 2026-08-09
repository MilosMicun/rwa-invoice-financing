# Vector 01 — ERC-4626 Vault Accounting & Share-Price Manipulation

Scope: `src/pools/SeniorPool.sol`, `src/pools/JuniorPool.sol` (both ERC-4626), and
their interaction with `src/core/InvoiceFinancingPool.sol` deposit/withdraw wrappers.
OZ v5.6.1 ERC4626, `_decimalsOffset()` = 0 (not overridden).

## Results

| # | Hypothesis | Test function | Verdict | Severity | One-line result |
|---|------------|---------------|---------|----------|-----------------|
| 1 | First-depositor donation inflation steals victim deposit | `test_SAFE_H1_donationInflationDoesNotMovePrice` | SAFE | — | Raw donation does not move `totalAssets()`/price; victim keeps full value; attacker gains nothing. |
| 2 | NAV can be inflated by pushing tokens into the vault | `test_SAFE_H2_navMovesOnlyViaCreditAssets` | SAFE | — | Raw push leaves NAV flat; NAV grows only by exactly the credited fee via `creditAssets` (onlyPool). |
| 3 | NAV-to-zero share explosion lets a fresh depositor steal | `test_SAFE_H3_navToZeroNoShareExplosionTheft` | SAFE | — | OZ `+1` virtual asset blocks divide-by-zero; writeDown is legit first-loss; new deposit cannot dilute existing holders. |
| 4 | Deposit/withdraw round-trip rounding extraction/grief | `test_SAFE_H4_roundTripRoundingNoExtraction` | SAFE | — | 20 round-trips: attacker never profits; existing LP value never decreases. |
| 5 | Withdraw more than availableLiquidity (touch locked capital) | `test_SAFE_H5_maxWithdrawLockedLiquidityBypass` | SAFE | — | `maxWithdraw` bounded by availableLiquidity; over-withdraw reverts on both direct + coordinator paths. |
| 6 | Withdraw donated/extra cash that is not the LP's NAV | `test_SAFE_H6_cannotWithdrawDonatedCash` | SAFE | — | Entitlement fixed to `convertToAssets(shares)`; donation stays stranded as raw balance, unclaimable. |
| 7 | Sub-price dust deposit mints 0 shares → theft/grief | `test_SAFE_H7_dustMintSelfGriefOnly` | SAFE/INFO | INFO | Attacker only self-griefs the dust; existing LP gains at most the dust; not a theft vector. |
| 8 | Later depositor diluted beyond first-loss / dilutes others | `test_SAFE_H8_depositAfterWriteDownIsFair` | SAFE | — | Late depositor buys in fairly at reduced price; existing holders not diluted. |
| 9 | Privileged NAV mutators externally reachable | `test_SAFE_H9_privilegedMutatorsNotExternallyReachable` | SAFE | — | `creditAssets/writeDown/lock/unlock/fundInvoice` all revert `NotInvoiceFinancingPool` for non-pool. |
| 10 | Direct ERC-4626 entry/exit bypasses coordinator invariants | `test_SAFE_H10_directEntryExitConsistent` | SAFE | — | Direct deposit/withdraw is self-consistent; over-withdraw still blocked by the vault's own guard. |
| 11 | `availableLiquidity` underflows (lockedAssets > accountedAssets) | `test_SAFE_H11_availableLiquidityNeverUnderflows` | SAFE | — | writeDown requires `amount <= availableLiquidity`; invariant `accounted >= locked` holds throughout. |
| 12 | `mint()` vs `deposit()` rounding asymmetry → free value | `test_SAFE_H12_mintVsDepositNoFreeValue` | SAFE | — | Both paths: redeemable value never exceeds paid; no free-share arbitrage. |

No HIGH/CRITICAL findings. 12 probes, all SAFE (one INFO note). No `findings/` folders created.

## How to run

From repo root:

```bash
FOUNDRY_TEST=security-findings FOUNDRY_OUT=out-v01 FOUNDRY_CACHE_PATH=cache-v01 \
  forge test --match-path 'security-findings/01-erc4626-vault-accounting/poc/*.t.sol' \
  --skip '*/0[2-9]-*' --skip '*/1[0-9]-*' -vv
```

(The `--skip` flags exclude sibling in-progress vector folders so this vector compiles in isolation.)

## Observed Suite result

```
Suite result: ok. 12 passed; 0 failed; 0 skipped; finished in 4.15ms (6.91ms CPU time)
```

## What protects this / what breaks

The core defense is that **`totalAssets()` returns the internal `accountedAssets`
counter, not the ERC20 balance** (`SeniorPool.sol:68-70`, `JuniorPool.sol:68-70`).
`accountedAssets` is mutated only through four authenticated, `onlyInvoiceFinancingPool`
paths — `_deposit` (`:206-210`), `_withdraw` (`:213-224`), `creditAssets` (`:164-181`),
`writeDown` (`:187-203`) — plus the ERC-4626 flows the coordinator drives. As a result:

- **Donation / inflation attacks are neutralized by construction** (H1, H2, H6). Any
  raw ERC20 transfer into a vault is invisible to share pricing. The classic
  first-depositor attack (donate to move `totalAssets`) simply does nothing here.
  The virtual `+1` asset/share from OZ v5.6.1 (`ERC4626.sol:248-256`) is a redundant
  second layer, but the accounting design is what actually defeats the attack.

- **Locked liquidity is protected on exit** (H5, H10). `_withdraw` reverts if
  `assets > availableLiquidity()` (`SeniorPool.sol:217-219`), and `maxWithdraw`
  additionally clamps to the real cash balance and the owner's NAV entitlement
  (`:78-86`). Neither the coordinator wrapper nor a direct ERC-4626 call can withdraw
  capital committed to active financings.

- **`availableLiquidity` never underflows** (H11). `lockAssets` and `writeDown` both
  require `amount <= availableLiquidity()` (`:101-103`, `:196-198`), and
  `resolveDefault` unlocks the locked principal *before* writing down loss
  (`InvoiceFinancingPool.sol:554-563`), so `accountedAssets >= lockedAssets` is an
  invariant.

- **NAV increases only via `creditAssets`** with a cash-backing solvency assertion
  (`:172-176`), so realized yield cannot be minted out of thin air, and **NAV
  decreases via `writeDown` = intended first-loss**, which lowers share price for
  everyone proportionally (fair) rather than stealing from any single holder (H3, H8).

- **Rounding always favors the vault** (H4, H7, H12). Deposits floor shares, withdraws/
  mints round against the entrant, and the OZ virtual share absorbs dust. An attacker
  can only lose value (self-grief) to rounding — never extract it from existing LPs.

### INFO note (not a finding)
Dust deposits below the marginal cost of one share (when price > 1) mint 0 shares and
the dust is effectively donated to the pool (H7). This is standard ERC-4626 behavior,
harms only the depositor, and is economically irrational to trigger. Not exploitable.

### MEDIUM/LOW/INFO observations
- **INFO — stranded donations.** Tokens pushed directly to a vault (H6) are permanently
  unaccounted and unrecoverable by any actor (no sweep function). Griefer's own loss;
  no protocol impact beyond a dead balance. Not a vault-accounting risk.
- **LOW/INFO — coordinator is not an exit boundary.** LPs (or attackers holding shares)
  can call `seniorPool.withdraw/redeem` directly, bypassing the coordinator wrapper
  (H10). This is harmless for vault accounting (the vault enforces its own limits), but
  any KYC/whitelist logic a production deployment adds *at the coordinator layer* would
  be bypassable at the vault layer. Out of scope for v1 (entry/exit intentionally
  permissionless per `InvoiceFinancingPool.sol:21-23`); flagged for the productionization
  note.

All conclusions reference the exact source lines above; every probe is encoded as a
passing assertion in `poc/VaultAccounting.t.sol`.

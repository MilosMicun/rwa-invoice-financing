# Vector 04 — Access Control & Privilege Escalation — RESULTS

All 16 probes are green. **No HIGH/CRITICAL findings.** The access-control surface is
correctly and consistently gated. Every privileged capability that could cause harm is
bound to an *intended* privileged role (DEFAULT_ADMIN / RISK_ADMIN / the pool contract),
and no NON-privileged actor can reach any harmful primitive. The residual concerns
(admin blast radius, role-revocation DoS, deploy footgun, oracle role co-location) are
all gated behind a fully-trusted admin key and match the protocol's explicitly documented
permissioned trust model. They are recorded as INFO / centralization, not findings.

## Results table

| # | Hypothesis | Test function | Verdict | Severity | One-line result |
|---|------------|---------------|---------|----------|-----------------|
| 1 | Non-supplier can finance to redirect the advance | `test_SAFE_financeInvoice_onlySupplier` | SAFE | — | `UnauthorizedFinancer`; advance always goes to `invoice.supplier`. |
| 2 | Attacker calls vault mutators directly | `test_SAFE_vaultMutators_onlyPool` | SAFE | — | All 10 (5×senior, 5×junior) revert `NotInvoiceFinancingPool`; NAV intact. |
| 3 | Attacker moves `buyerExposure` | `test_SAFE_updateBuyerExposure_onlyPool` | SAFE | — | Reverts `AccessControlUnauthorizedAccount(POOL_ROLE)`; exposure unchanged. |
| 4 | Attacker sets risk params / denylist | `test_SAFE_riskSetters_onlyRiskAdmin` | SAFE | — | Both revert `AccessControlUnauthorizedAccount(RISK_ADMIN_ROLE)`. |
| 5 | Attacker drives NFT lifecycle | `test_SAFE_invoiceNft_lifecycleRoles` | SAFE | — | create/verify/markFunded/markSettled/markDefaulted/freeze/unfreeze all revert. |
| 6 | Attacker submits/disputes oracle status; injects via finalize | `test_SAFE_oracle_submitDisputeRoles` | SAFE | — | submit/dispute revert; permissionless `finalize` only forwards a staged outcome. |
| 7 | Attacker re-points oracle / admin re-points twice | `test_SAFE_setOracle_onlyAdmin_oneShot` | SAFE | — | `UnauthorizedAdmin` then `OracleAlreadySet`; oracle immutable after set. |
| 8 | Single admin key can push a chosen oracle outcome | `test_SAFE_oracle_roleSeparationNotEnforced_isDesign` | SAFE (INFO) | Centralization | Intended (docs); recovery still capped at principal, waterfall unaffected. |
| 9 | Rogue POOL_ROLE EOA on NFT strands LP capital | `test_SAFE_nftAdminBlastRadius_bricksPosition_requiresAdmin` | SAFE (INFO) | Centralization | Real desync + stranding, but needs compromised DEFAULT_ADMIN; no unprivileged path. |
| 10 | Rogue POOL_ROLE EOA on Risk denies financing | `test_SAFE_riskAdminBlastRadius_exposureDoS_requiresAdmin` | SAFE (INFO) | Centralization | Exposure inflated → `BuyerConcentrationExceeded`; needs compromised admin. |
| 11 | Admin revokes pool POOL_ROLE on NFT mid-life | `test_SAFE_roleRevocationDoS_stranding_requiresAdmin` | SAFE (INFO) | Centralization | settle reverts, assets stranded; admin-only. |
| 11b | Admin revokes pool POOL_ROLE on Risk mid-life | `test_SAFE_roleRevocationDoS_riskManager_requiresAdmin` | SAFE (INFO) | Centralization | settle reverts on exposure decrement; admin-only. |
| 12 | Deployer captures oracle wiring (ADMIN = msg.sender) | `test_SAFE_deployFootgun_adminIsDeployer` | SAFE (INFO) | Deployment footgun | `ADMIN` bound to deployer; intended admin locked out on a mis-deployed pool. |
| 13 | Attacker calls `onStatusFinalized` directly | `test_SAFE_onStatusFinalized_onlyOracle` | SAFE | — | Reverts `UnauthorizedOracle`; no fake-outcome preload. |
| 14 | DEFAULT_ADMIN has a vault backdoor | `test_SAFE_admin_cannotTouchVaults` | SAFE | — | Vault gate is an immutable address check, not a role; admin cannot touch NAV. |
| 15 | A different legit supplier redirects funds | `test_SAFE_financeInvoice_noFundRedirection` | SAFE | — | Cross-supplier finance reverts; advance bound to `invoice.supplier`. |

Probe count: 16 test functions (12 planned hypotheses; several split/extended: 11→11b, plus 13/14/15 added for completeness).

## How to run

The prompt's canonical command (`FOUNDRY_TEST=security-findings ...`) currently fails to
**compile** because of an unrelated non-ASCII character in another vector's file
(`security-findings/07-lifecycle-state-machine/poc/Lifecycle.t.sol:505` uses an em-dash in
a revert string). That is not part of this vector and I did not modify it. To build/run
this vector in isolation, scope `FOUNDRY_TEST` to the vector folder:

```bash
FOUNDRY_TEST=security-findings/04-access-control FOUNDRY_OUT=out-v04 FOUNDRY_CACHE_PATH=cache-v04 \
  forge test --match-path 'security-findings/04-access-control/poc/*.t.sol' -vv
```

## Observed final result

```
Suite result: ok. 16 passed; 0 failed; 0 skipped; finished in 6.78ms (22.16ms CPU time)
```

## What protects this / what breaks

**What protects it.**
- **financeInvoice** is bound to `msg.sender == invoice.supplier`
  (`InvoiceFinancingPool.sol:261-263`), and the advance is always sent to
  `invoice.supplier` via `SENIOR_POOL.fundInvoice(invoice.supplier, ...)` /
  `JUNIOR_POOL.fundInvoice(...)` (`:323-324`). There is no caller-supplied recipient, so
  there is no fund-redirection primitive even for a different legitimate supplier.
- **Vault NAV mutators** (`lockAssets/unlockAssets/fundInvoice/creditAssets/writeDown`)
  are gated by `onlyInvoiceFinancingPool` (`SeniorPool.sol:55-64,96,111,129,164,187`;
  JuniorPool is byte-identical). The gate is an **immutable address equality check**
  (`INVOICE_FINANCING_POOL`, set in the constructor), *not* an AccessControl role — so it
  cannot be granted, re-pointed, or bypassed by any admin (probe 14 confirms even
  DEFAULT_ADMIN reverts).
- **RiskManager** guards `updateBuyerExposure` with `onlyRole(POOL_ROLE)` (`:245`) and
  `setRiskParams`/`setBuyerDenied` with `onlyRole(RISK_ADMIN_ROLE)` (`:208,218`).
- **InvoiceNFT** guards every lifecycle transition with the correct role: `createInvoice`
  ORIGINATOR (`:66`), `verify` VERIFIER (`:107`), `markFunded/markSettled/markDefaulted`
  POOL (`:128,152,173`), `freeze/unfreeze` RISK (`:194,216`).
- **Oracle** guards `submitStatus` (SUBMITTER, `:106-107`) and `disputeStatus`
  (DISPUTE_ADMIN, `:154`). `finalize` is intentionally permissionless (`:197`) but is a
  pure propagator: it only forwards `update.newStatus/recoveredAmount` that a privileged
  submitter previously staged (`:228-230`) — a keeper cannot inject or alter an outcome.
- **onStatusFinalized** on the pool is bound to the configured oracle address
  (`InvoiceFinancingPool.sol:193-195`), and the pool re-validates recovery ≤ principal
  (`:218-220`), so even a finalized DEFAULTED outcome cannot exceed principal and the
  senior-first waterfall (`:531-538`) is untouched.
- **setInvoiceStatusOracle** is `onlyAdmin` and one-shot (`:157-166`): a non-zero
  `invoiceStatusOracle` reverts a second set with `OracleAlreadySet`.

**What "breaks" only under a compromised/misused admin (INFO, matches documented trust model).**
- **Oracle role co-location** (probe 8): the constructor grants SUBMITTER + DISPUTE +
  DEFAULT_ADMIN all to the same `admin` (`InvoiceStatusOracle.sol:60-62`). The contract
  docstring (`:20-23`) explicitly acknowledges this and recommends production separation
  via multisig. A single key can therefore stage an outcome and refuse to dispute it. This
  is the protocol's stated "process integrity, not truth" model. Recovery remains bounded
  by principal, so it cannot manufacture senior loss beyond the real principal split.
- **Admin blast radius** (probes 9, 10): a rogue DEFAULT_ADMIN can grant `POOL_ROLE` to an
  arbitrary EOA on InvoiceNFT or RiskManager. On the NFT this desyncs the NFT status vs the
  pool position and can *permanently strand* locked LP capital (once the NFT leaves FUNDED,
  `settleInvoice`/`resolveDefault` revert with `InvoiceNotFunded`). On RiskManager it lets
  the EOA arbitrarily move `buyerExposure` (concentration DoS / settlement underflow). Both
  require a fully-compromised admin key; there is no unprivileged path.
- **Role-revocation DoS** (probes 11, 11b): if the admin revokes the pool's `POOL_ROLE`
  on InvoiceNFT or RiskManager while positions are live, `settleInvoice`/`resolveDefault`
  revert (they call `markSettled`/`updateBuyerExposure`), stranding locked capital. Admin-only.
- **Deploy footgun** (probe 12): `ADMIN` is bound to `msg.sender` at construction
  (`InvoiceFinancingPool.sol:128`). If the pool is deployed by the wrong EOA/factory, that
  deployer alone controls the one-shot oracle wiring and the intended admin is locked out.
  This is a deployment-time operational risk, fully avoidable with a correct deploy script
  (`script/Deploy.s.sol` is currently a placeholder). Not exploitable after a correct deploy.

### Medium/Low/Info notes
- **INFO — oracle role co-location** and **deploy footgun**: recommend (a) granting
  SUBMITTER and DISPUTE to distinct addresses / a multisig, and (b) either passing an
  explicit `admin` to the pool constructor instead of `msg.sender`, or ensuring the deploy
  script transfers/parametrizes admin deterministically.
- **LOW — role-revocation / rogue-POOL_ROLE stranding**: consider a two-step /
  timelocked admin, and/or an escape hatch that lets already-finalized positions settle
  even if the NFT was externally desynced (e.g. resolve from the pool position, not the NFT
  status). All strictly under the trust boundary; no unprivileged trigger exists.

# RWA Invoice Financing — Security Audit Plan

**Target:** `src/` — a Foundry reference protocol that finances verified invoices through
Senior/Junior ERC-4626 tranches, coordinated by `InvoiceFinancingPool`, with a
non-transferable `InvoiceNFT` lifecycle, a permissioned `InvoiceStatusOracle`, and an
`RWARiskManager` underwriting boundary.

**Auditor scope:** HIGH and CRITICAL severity only. Medium/Low/Informational are noted when
adjacent to a high-severity probe but are not the focus.

**Method:** For each attack vector we (1) map the relevant known attack classes (drawn from the
Solodit taxonomy, Code4rena/Sherlock/Cantina report patterns, and the SCSVS), (2) write an
explicit plan of hypotheses, (3) implement **≥10 Foundry PoCs per vector** that each either
*confirm a defense* (SAFE, documented negative result) or *demonstrate an exploit* (FINDING),
and (4) adversarially verify every claimed HIGH/CRITICAL finding with an independent reviewer.

All PoCs inherit the shared, smoke-tested deployment harness in
[`_base/Harness.sol`](./_base/Harness.sol) so every reproduction runs against the real protocol
topology. Malicious asset variants (ERC777-style callback token, fee-on-transfer token) live in
[`_base/MaliciousTokens.sol`](./_base/MaliciousTokens.sol).

## How to reproduce

Every PoC lives under `security-findings/<vector>/poc/`. Because these tests live outside the
default `test/` directory, run them with the Foundry test-dir override (each vector uses an
isolated build/cache dir so runs never collide):

```bash
# One vector:
FOUNDRY_TEST=security-findings FOUNDRY_OUT=out-v01 FOUNDRY_CACHE_PATH=cache-v01 \
  forge test --match-path 'security-findings/01-erc4626-vault-accounting/poc/*.t.sol' -vvv

# Everything under security-findings:
FOUNDRY_TEST=security-findings forge test --match-path 'security-findings/**/*.t.sol'
```

## Protocol facts established during reconnaissance (ground truth for all vectors)

- **ERC-4626 NAV source is `accountedAssets`, not token balance.** `totalAssets()` returns an
  internal accounting variable, so raw token *donations* do **not** move share price. This
  neutralizes the classic first-depositor donation/inflation attack by construction.
- **`_decimalsOffset()` is NOT overridden → 0.** The vaults rely solely on OZ's `+1` virtual
  asset/share and the `accountedAssets` design for inflation resistance (OZ 5.6.1).
- **`availableLiquidity = accountedAssets − lockedAssets`.** `lockAssets` requires
  `amount ≤ availableLiquidity`; `writeDown` requires `amount ≤ availableLiquidity`. This keeps
  `accountedAssets ≥ lockedAssets` invariant and prevents underflow.
- **Settlement/default use CEI:** `resolved` is set and `totalLockedAssets`/`totalBadDebt`
  updated *before* external transfers; NAV `unlock`/`credit`/`writeDown` happen *after* transfers.
- **Recovery waterfall is senior-first:** `seniorRecovery = min(recovery, seniorPrincipal)`, the
  rest to junior; junior absorbs first loss via `writeDown`.
- **Trust model is permissioned by design:** originator/verifier/risk/pool roles, a permissioned
  oracle submitter + dispute admin, and a risk admin. Admin-can-do-X is generally *intended*, not
  a bug — unless it breaks a guarantee the protocol explicitly makes (e.g. the senior-protection
  waterfall, one-shot oracle, or LP accounting conservation).
- **Fee/principal splits:** funding split rounds senior down, junior gets remainder; fee split
  rounds junior down, senior gets remainder. Fee is fixed at funding time.

## Attack vectors (angles)

| # | Vector | Primary target | Known-attack classes covered |
|---|--------|----------------|------------------------------|
| 01 | ERC-4626 vault accounting & share-price manipulation | `SeniorPool`, `JuniorPool` | inflation/donation, first-depositor, decimals-offset, NAV-to-zero, round-trip rounding, max{Withdraw,Redeem} |
| 02 | Tranche waterfall & loss/recovery accounting | `InvoiceFinancingPool.settle/resolveDefault` | waterfall inversion, first-loss violation, writedown-DoS, bad-debt miscount, split rounding, NAV conservation |
| 03 | Oracle manipulation, timing & trust boundaries | `InvoiceStatusOracle`, `onStatusFinalized` | permissionless finalize, dispute-window/staleness bypass, resubmission overwrite, recovery-bound brick, one-shot oracle |
| 04 | Access control & privilege escalation | all contracts | missing/incorrect modifiers, role separation, admin blast radius, role-revocation DoS |
| 05 | Reentrancy & external-call safety | settle/resolve/deposit/withdraw/fund | classic + cross-function + read-only reentrancy via ERC777-style asset, CEI validation |
| 06 | Economic / MEV / front-running / fee-on-transfer | cross-cutting | loss front-running (exit before writedown), JIT yield capture, fee-on-transfer accounting break, concentration TOCTOU |
| 07 | Invoice lifecycle state machine & freeze griefing | `InvoiceNFT` + pool interplay | illegal transitions, double-finance, settle/default mutual-exclusion, freeze strand/griefing, non-transferability |
| 08 | Arithmetic, rounding, precision & DoS | `RWARiskManager` math + pool | mulDiv overflow, fee/advance rounding-to-zero, exposure under/overflow, ZeroTranchePrincipal DoS, conservation fuzz |

Each vector's detailed hypothesis list and per-probe verdicts live in its own `PLAN.md` and
`README.md`. Confirmed HIGH/CRITICAL findings each get a `findings/<ID>/README.md` write-up with a
reproducible PoC reference. The consolidated results are in
[`FINDINGS-SUMMARY.md`](./FINDINGS-SUMMARY.md).

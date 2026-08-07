# Stateful Invariant Specification

## 1. Purpose

This document specifies the stateful invariant suite for the invoice-financing protocol. It describes the properties tested, the independent handler model, the production state used as the actual side of comparisons, and the boundaries of the generated state space.

The suite is not formal verification. The suite executes arbitrary sequences of admissible protocol actions and checks the invariant catalogue after every generated handler call throughout each run.

The catalogue contains four kinds of properties:

- independently ghost-reconstructed invariants;
- cross-storage consistency invariants;
- direct protocol bounds;
- lifecycle coherence invariants anchored by ghost state.

Not all invariants are independently ghost-reconstructed.

## 2. Suite Summary

| Property | Final suite |
|---|---:|
| Invariant functions | 12 |
| Targeted handler actions | 8 |
| Buyers | 2 distinct actors |
| Suppliers | 1 |
| Permissionless default executor | Separate Resolver actor |
| Expected-value model | Per-invoice `GhostPosition` |
| Invariant runs | 256 |
| Configured depth per run | 500 |
| Configured action slots per invariant | 128,000 |
| Configured action slots across 12 invariants | 1,536,000 |
| `invariant.fail_on_revert` | `true` |
| Observed handler reverts | 0 |
| Observed discards | 0 |

`foundry.toml` explicitly pins `runs`, `depth`, `fail_on_revert`, and `show_metrics`. Zero handler reverts were observed during local verification, and any unexpected handler revert is enforced as an invariant-run failure.

## 3. Target Contracts

The invariant fixture deploys and exercises:

- `InvoiceFinancingPool`, the financing coordinator;
- `InvoiceNFT`, the invoice identity and lifecycle registry;
- `InvoiceStatusOracle`, the outcome-submission and finalization component;
- `RWARiskManager`, including eligibility, concentration, and Buyer exposure;
- `SeniorPool`;
- `JuniorPool`;
- `MockERC20`, the test settlement asset.

The handler is the only fuzz target. Production contracts are reached through the handler’s eight targeted actions.

## 4. Handler Action Surface

### `createAndFinanceInvoice(faceValueSeed, tenorSeed, buyerSeed)`

- Selects `BUYER_ONE` or `BUYER_TWO` using `buyerSeed % 2`.
- Bounds face value between the configured minimum and `100_000e18`.
- Bounds tenor between one second and the configured maximum.
- Independently calculates principal and tranche allocations.
- Reconstructs the selected Buyer’s unresolved exposure from ghosts.
- Returns early if ghost concentration, non-zero allocation, denylist, production concentration, or tranche-liquidity checks fail.
- All early returns occur before `InvoiceNFT.createInvoice()`.
- Creates the invoice as `ORIGINATOR`, verifies it as `VERIFIER`, checks production eligibility, captures `expectedFundedAt`, and finances it as `SUPPLIER`.
- Appends the invoice ID and records `GhostPosition` only after successful financing.
- Production denylist, concentration, eligibility, and liquidity reads are admission-only.

Once invoice creation begins, an unexpected failure propagates and reverts the entire handler transaction. It cannot leave an untracked `CREATED` or `VERIFIED` invoice.

### `submitSettledOutcome(invoiceSeed)`

- Selects an enumerated financed invoice.
- Requires an unresolved, unfinalized ghost and current production NFT status `FUNDED`.
- Permits submission when no pending outcome exists or the prior pending outcome has become stale under model timing.
- Calls `submitStatus(invoiceId, SETTLED, 0)` as `ADMIN`.
- Records the pending status, zero recovery, and submission timestamp only after success.
- Uses the NFT read only as a lifecycle precondition.

### `submitDefaultedOutcome(invoiceSeed, recoverySeed)`

- Uses the same submission preconditions.
- Bounds recovery from zero through `ghost.principal`.
- Calls `submitStatus(invoiceId, DEFAULTED, recoveredAmount)` as `ADMIN`.
- Records the submitted status, recovery, and timestamp only after success.
- Derives recovery from ghost principal, not production position storage.

### `finalizeOutcome(invoiceSeed)`

- Requires a pending, unfinalized, non-stale ghost outcome.
- Warps to the exact model dispute-window boundary if necessary.
- Calls permissionless `InvoiceStatusOracle.finalize(invoiceId)`.
- Copies the pending ghost status and recovery into finalized ghost fields only after success.
- Does not require current NFT status `FUNDED`, so finalization while `FROZEN` remains reachable.
- Does not read oracle or pool finalized storage to populate the expected outcome.

### `settleInvoice(invoiceSeed, surplusSeed)`

- Requires an unresolved ghost finalized as `SETTLED`.
- Requires current production NFT status `FUNDED`.
- Reconstructs the stored financing fee independently from ghost terms and immutable model configuration.
- Bounds optional surplus through `10_000e18`.
- Mints and approves the required payment, then calls `InvoiceFinancingPool.settleInvoice`.
- Sets only `ghost.resolved = true` after success.
- Uses the NFT read only as a lifecycle precondition.

### `resolveDefault(invoiceSeed)`

- Requires an unresolved ghost finalized as `DEFAULTED`.
- Requires current production NFT status `FUNDED`.
- Uses `ghost.finalizedRecovery`.
- Mints non-zero recovery to `RESOLVER`.
- As `RESOLVER`, approves the pool when necessary and calls `resolveDefault`.
- Sets only `ghost.resolved = true` after success.
- Executes zero-recovery defaults as `RESOLVER` without minting or approval.

### `freezeInvoice(invoiceSeed)`

- Requires current production NFT status `FUNDED`.
- Snapshots pool, tranche, and both Buyer-exposure accounting.
- Calls `InvoiceNFT.freezeInvoice` as `RISK_ADMIN`.
- Verifies `FROZEN` with `previousStatus == FUNDED`.
- Verifies that freeze changed no accounting.
- Does not modify `GhostPosition`.

### `unfreezeInvoice(invoiceSeed)`

- Requires `FROZEN` with `previousStatus == FUNDED`.
- Snapshots accounting.
- Calls `InvoiceNFT.unfreezeInvoice` as `RISK_ADMIN`.
- Verifies restoration to `FUNDED` and accounting neutrality.
- Does not modify `GhostPosition`.

Ineligible seeds generally produce early returns. Unexpected production reverts are not caught and fail the invariant run.

## 5. Actor and Permission Model

| Actor | Stateful role |
|---|---|
| `ADMIN` | Submits oracle outcomes |
| `ORIGINATOR` | Creates invoices |
| `VERIFIER` | Verifies invoices |
| `RISK_ADMIN` | Freezes and unfreezes invoices |
| `SUPPLIER` | Owns the invoice claim and requests financing |
| `BUYER_ONE` | First independently tracked obligor |
| `BUYER_TWO` | Second independently tracked obligor |
| `RESOLVER` | Permissionless default executor |
| Handler contract | Permissionless finalizer and settlement payer |
| Senior and Junior LPs | Provide fixture liquidity during setup only |

The constructor rejects zero Supplier, Buyer, or Resolver addresses and rejects overlap among the Supplier, both Buyers, and Resolver. Administrative actors are not subjected to additional handler-specific validation.

Buyer selection is fuzz-driven. Both Buyer exposure mapping keys are checked independently. One Supplier remains intentional and limits Supplier-isolation coverage.

## 6. Independent Model Configuration

The fixture passes these values to the handler without reading them back from production storage:

| Model field | Fixture value |
|---|---:|
| `maxExposurePerBuyer` | `1_000_000e18` |
| `advanceRateBps` | `8_000` |
| `seniorFundingShareBps` | `7_000` |
| `bpsDenominator` | `10_000` |
| `maxInvoiceTenor` | `90 days` |
| `minInvoiceAmount` | `1_000e18` |
| `financingFeeAprBps` | `1_200` |
| `disputeWindow` | `1 day` |
| `maxStaleness` | `7 days` |

The handler validates:

- non-zero and internally consistent basis-point configuration;
- non-zero invoice and tenor limits;
- `maxStaleness > disputeWindow > 0`;
- bounded multiplication safety;
- bounded settlement-payment arithmetic;
- a non-vacuous minimum invoice whose principal and both tranche allocations are non-zero;
- minimum principal not exceeding per-Buyer concentration capacity.

The model must be updated whenever production economics are intentionally changed.

## 7. `GhostPosition` Model

```solidity
struct GhostPosition {
    bool exists;
    address supplier;
    address buyer;
    uint256 principal;
    uint256 seniorPrincipal;
    uint256 juniorPrincipal;
    uint256 fundedAt;
    uint256 dueDate;
    bool pendingOutcomeExists;
    IInvoiceNFT.InvoiceStatus pendingStatus;
    uint256 pendingRecovery;
    uint256 pendingSubmittedAt;
    bool finalized;
    IInvoiceNFT.InvoiceStatus finalizedStatus;
    uint256 finalizedRecovery;
    bool resolved;
}
```

Fields have these purposes:

- `exists` protects enumeration integrity.
- Identity fields preserve expected Supplier and Buyer.
- Principal fields preserve the independently calculated aggregate and tranche allocations.
- `fundedAt` and `dueDate` preserve locally captured financing terms.
- Pending fields preserve the last successfully submitted oracle outcome.
- Finalized fields preserve the successfully finalized expected outcome.
- `resolved` tracks successful economic settlement or default execution.

Expected economic values originate only from:

- fuzz inputs;
- immutable `ModelConfig`;
- timestamps locally captured by the handler;
- successful handler transitions.

Expected values are not populated from:

- `pool.financingPositions()`;
- pool accounting aggregates;
- RiskManager exposure;
- RiskManager calculation helpers;
- Oracle `StatusUpdate` storage;
- pool finalized status or recovery;
- production funding-share getters.

Production storage remains usable for:

- admission checks;
- lifecycle preconditions;
- dependency wiring;
- accounting-neutrality observations;
- the actual side of invariant comparisons.

## 8. Independent Formulas

The handler uses bounded direct arithmetic:

```text
principal =
    faceValue * advanceRateBps / bpsDenominator

seniorPrincipal =
    principal * seniorFundingShareBps / bpsDenominator

juniorPrincipal =
    principal - seniorPrincipal
```

Settlement funding is reconstructed as:

```text
duration = dueDate - fundedAt

financingFee =
    principal * (financingFeeAprBps * duration)
        / (365 days * bpsDenominator)
```

Solidity integer division rounds down. Senior principal is therefore rounded down, and Junior receives the tranche-split remainder.

The formulas mirror the economic specification without calling production calculation helpers. A conceptual specification error shared by both the production and ghost formulas may remain undetected. Unit and fuzz tests separately validate primitive advance and fee mathematics; the stateful suite focuses on aggregation and lifecycle conservation across action sequences.

## 9. Ghost-State Transition Rules

| Successful action | Ghost transition |
|---|---|
| Create and finance | Create one ghost with identity, principal allocations, timestamps, and `resolved = false` |
| Submit `SETTLED` | Replace pending outcome with `SETTLED`, zero recovery, and current timestamp |
| Submit `DEFAULTED` | Replace pending outcome with `DEFAULTED`, bounded recovery, and current timestamp |
| Finalize | Copy pending status and recovery into finalized fields; set `finalized = true` |
| Settle | Set `resolved = true` |
| Resolve default | Set `resolved = true` |
| Freeze | No ghost mutation |
| Unfreeze | No ghost mutation |

Ghost updates always occur after their corresponding production call succeeds.

A stale pending outcome may be replaced passively if time advanced through other handler activity. There is no targeted dispute action or deliberate stale-replacement action.

## 10. Complete Invariant Catalogue

### 10.1 `invariant_TotalLockedAssetsEqualsTrancheLocks`

- **Classification:** Cross-storage consistency.
- **Property:**

  ```text
  pool.totalLockedAssets()
      == seniorPool.lockedAssets() + juniorPool.lockedAssets()
  ```

- **Expected source:** The two tranche lock values; no ghost-derived expected value.
- **Actual state:** Aggregate coordinator lock and both vault locks.
- **Ghost dependency:** None.
- **Catches:** Aggregate/tranche desynchronization and one-sided lock or unlock.
- **Assumptions:** Both tranches participate in every valid financing position.

### 10.2 `invariant_TotalLockedAssetsEqualsUnresolvedPrincipal`

- **Classification:** Independently ghost-reconstructed.
- **Property:**

  ```text
  pool.totalLockedAssets()
      == Σ ghost.principal
         for every existing unresolved ghost
  ```

- **Expected source:** Handler enumeration and `GhostPosition`.
- **Actual state:** `pool.totalLockedAssets()`.
- **Ghost dependency:** `exists`, `principal`, `resolved`.
- **Catches:** Missing, duplicate, premature, or incomplete aggregate lock updates.
- **Assumptions:** Every enumerated invoice has an existing ghost; the invariant asserts this explicitly.

### 10.3 `invariant_BuyerExposureEqualsActivePrincipal`

- **Classification:** Independently ghost-reconstructed.
- **Property:** For each enumerated Buyer:

  ```text
  riskManager.getBuyerExposure(buyer)
      == Σ unresolved ghost.principal
         where ghost.buyer == buyer
  ```

- **Expected source:** Ghost identity, principal, and resolution.
- **Actual state:** Both RiskManager Buyer-exposure mapping keys.
- **Ghost dependency:** `exists`, `buyer`, `principal`, `resolved`.
- **Catches:** Cross-Buyer contamination, missing exposure increases or decreases, and resolution of the wrong Buyer’s exposure.
- **Assumptions:** The handler models exactly the two enumerated Buyers.

### 10.4 `invariant_PositionPrincipalSplitConservesPrincipal`

- **Classification:** Independently ghost-reconstructed.
- **Property:**

  ```text
  ghost.principal
      == ghost.seniorPrincipal + ghost.juniorPrincipal
  ```

  Production principal and tranche allocation fields must also equal their ghost counterparts.

- **Expected source:** Independently calculated ghost allocation.
- **Actual state:** Production financing-position principal and tranche fields.
- **Ghost dependency:** `exists`, `principal`, `seniorPrincipal`, `juniorPrincipal`.
- **Catches:** Incorrect production allocation, rounding-remainder errors, and corrupt stored position terms.
- **Assumptions:** Junior receives the modelled rounding remainder.

### 10.5 `invariant_TrancheLocksNeverExceedTrancheNav`

- **Classification:** Direct protocol bound.
- **Property:**

  ```text
  seniorPool.lockedAssets() <= seniorPool.totalAssets()
  juniorPool.lockedAssets() <= juniorPool.totalAssets()
  ```

- **Expected source:** The bound itself; no ghost reconstruction.
- **Actual state:** Each vault’s locked assets and NAV.
- **Ghost dependency:** None.
- **Catches:** Over-locking and NAV reductions below outstanding locked exposure.
- **Assumptions:** Vault NAV represents cash plus active receivable exposure.

### 10.6 `invariant_PositionResolutionMatchesInvoiceLifecycle`

- **Classification:** Lifecycle coherence with ghost resolution anchor.
- **Property:** Production `position.resolved` equals `ghost.resolved`. An unresolved position is `FUNDED`, or `FROZEN` from `FUNDED`; a resolved position matches the terminal ghost outcome.
- **Expected source:** Ghost resolution and finalized status.
- **Actual state:** Production position resolution and `InvoiceNFT` lifecycle.
- **Ghost dependency:** `exists`, `resolved`, `finalized`, `finalizedStatus`.
- **Catches:** Accounting resolution without lifecycle transition, terminal lifecycle without resolution, and settlement/default mismatch.
- **Assumptions:** Finalized-but-unresolved positions remain economically active until execution.

### 10.7 `invariant_FinalizedOracleDataIsCanonical`

- **Classification:** Independently ghost-reconstructed.
- **Property:** Pending Oracle data matches the pending ghost. When finalized, Oracle and pool status and recovery both equal the finalized ghost. Unfinalized pool state remains `CREATED` with zero recovery.
- **Expected source:** Successful ghost submission and finalization transitions.
- **Actual state:** Oracle `StatusUpdate`, pool finalized flag, finalized status, and finalized recovery.
- **Ghost dependency:** All pending and finalized fields plus `principal`.
- **Catches:** Oracle/pool propagation errors, recovery corruption, unexpected finalization, and stale production records.
- **Assumptions:** No dispute action exists in the handler; generated pending updates therefore remain undisputed. `SETTLED` recovery is zero and `DEFAULTED` recovery does not exceed ghost principal.

### 10.8 `invariant_TerminalLifecycleMatchesOracleOutcome`

- **Classification:** Lifecycle coherence with ghost outcome anchor.
- **Property:** Resolved `SETTLED` ghosts have NFT status `SETTLED`; resolved `DEFAULTED` ghosts have NFT status `DEFAULTED`. Unresolved positions are not terminal and may be `FUNDED` or `FROZEN` from `FUNDED`.
- **Expected source:** Ghost finalized status and resolution.
- **Actual state:** `InvoiceNFT` status and `previousStatus`.
- **Ghost dependency:** `exists`, `resolved`, `finalized`, `finalizedStatus`, `finalizedRecovery`.
- **Catches:** Wrong terminal transition, premature terminal status, and execution while frozen.
- **Assumptions:** Oracle finalization alone does not change the NFT terminal status.

### 10.9 `invariant_TotalBadDebtEqualsResolvedDefaultLosses`

- **Classification:** Independently ghost-reconstructed.
- **Property:**

  ```text
  pool.totalBadDebt()
      == Σ (ghost.principal - ghost.finalizedRecovery)
         for resolved, finalized defaults
  ```

- **Expected source:** Ghost principal, recovery, status, and resolution.
- **Actual state:** `pool.totalBadDebt()`.
- **Ghost dependency:** `exists`, `principal`, `resolved`, `finalized`, `finalizedStatus`, `finalizedRecovery`.
- **Catches:** Missing, duplicated, or incorrectly calculated realized principal loss.
- **Assumptions:** Unpaid financing fees are not principal NAV and are excluded from bad debt.

### 10.10 `invariant_TrancheLocksEqualUnresolvedPrincipalSplits`

- **Classification:** Independently ghost-reconstructed.
- **Property:**

  ```text
  seniorPool.lockedAssets()
      == Σ unresolved ghost.seniorPrincipal

  juniorPool.lockedAssets()
      == Σ unresolved ghost.juniorPrincipal
  ```

- **Expected source:** Ghost tranche allocations and resolution.
- **Actual state:** Each tranche’s `lockedAssets`.
- **Ghost dependency:** `exists`, `seniorPrincipal`, `juniorPrincipal`, `resolved`.
- **Catches:** Incorrect tranche unlocks, one-sided resolution, and tranche desynchronization hidden by a correct aggregate lock.
- **Assumptions:** Every enumerated invoice has an existing ghost.

### 10.11 `invariant_TrancheCashBacksAvailableLiquidity`

- **Classification:** Cross-storage cash-versus-accounting consistency.
- **Property:**

  ```text
  asset.balanceOf(address(seniorPool))
      == seniorPool.availableLiquidity()

  asset.balanceOf(address(juniorPool))
      == juniorPool.availableLiquidity()
  ```

- **Expected source:** Vault accounting; no ghost reconstruction.
- **Actual state:** ERC-20 balances and vault available-liquidity accounting.
- **Ghost dependency:** None.
- **Catches:** Missing cash transfers, incorrect fee credit, incorrect recovery transfer, unlock/write-down imbalance, and unsupported untracked cash.
- **Assumptions:** Standard mock ERC-20, no donations, no rebasing, no transfer fees, and no untracked vault flows.

### 10.12 `invariant_FinancedPositionTermsRemainCanonical`

- **Classification:** Independently ghost-reconstructed.
- **Property:** Production Supplier, Buyer, principal, Senior principal, Junior principal, funding timestamp, due date, and resolution equal the ghost. NFT identity, timestamps, and ownership also equal ghost expectations.
- **Expected source:** Locally recorded ghost financing terms.
- **Actual state:** One production financing-position getter call, `InvoiceNFT.getInvoice()`, and NFT ownership.
- **Ghost dependency:** Identity, principal allocations, timestamps, and resolution.
- **Catches:** Mutable or corrupt position terms, identity mismatch, timestamp mismatch, wrong owner, and resolution divergence.
- **Assumptions:** `financingFee` is intentionally ignored by this invariant and tested separately at the primitive-formula and settlement levels.

## 11. Cash-Backing Model

The current handler supports exact equality:

```text
asset.balanceOf(address(SeniorPool))
    == SeniorPool.availableLiquidity()

asset.balanceOf(address(JuniorPool))
    == JuniorPool.availableLiquidity()
```

The relationship is preserved as follows:

1. **Initial deposits:** Token cash and accounted NAV increase by the same amount; locks remain zero.
2. **Invoice financing:** Locking preserves NAV but reduces available liquidity. Funding transfers exactly the locked principal out of each vault, reducing cash by the same amount.
3. **Settlement principal:** Principal cash returns to each vault before the corresponding lock is released.
4. **Settlement fee:** Fee cash arrives before `creditAssets` increases accounted NAV.
5. **Default recovery:** Recovered principal is transferred to the applicable vault.
6. **Unlock:** Releasing the full principal allocation increases accounting availability.
7. **Write-down:** Unrecovered principal reduces NAV, bringing available liquidity back into equality with actual cash.

Exact equality assumes:

- no direct token donations;
- no fee-on-transfer behavior;
- no rebasing;
- no untracked vault inflows or outflows;
- no dynamic LP deposit or withdrawal action in the handler.

If direct donations are added and explicitly tracked, the property becomes:

```text
balanceOf(vault)
    == availableLiquidity + trackedDonationSurplus
```

Without tracked donation state, it must be weakened to:

```text
balanceOf(vault) >= availableLiquidity
```

The suite does not assert global ERC-20 conservation across every external actor.

## 12. Valid-by-Construction and Revert Discipline

The handler generates admissible actions rather than treating expected production reverts as useful state transitions.

For financing, it independently checks:

- model concentration;
- non-zero principal allocations;
- bounded arithmetic.

It then uses production reads only for admission:

- Buyer denylist;
- production concentration;
- Senior available liquidity;
- Junior available liquidity;
- post-verification eligibility.

A production/ghost exposure mismatch is not copied into ghost state. An admission check may return early, while the exposure invariant can still observe the pre-existing mismatch.

Other actions return early for absent invoices, wrong ghost outcomes, already resolved state, stale updates, or incompatible NFT lifecycle. These expected early returns preserve valid-by-construction execution and do not represent handler failures.

Unexpected production reverts are not caught. With `invariant.fail_on_revert = true`, any unexpected handler revert fails the invariant run.

Ghost state changes only after the corresponding production call succeeds. If a later call reverts, transaction atomicity rolls back earlier changes in that handler invocation.

Local invariant verification observed zero handler reverts and zero discards.

## 13. Oracle and Lifecycle Assumptions

The handler records pending outcomes directly from successful submissions:

- `SETTLED` always uses zero recovery;
- `DEFAULTED` recovery is bounded by ghost principal.

Finalization copies the pending ghost outcome after production finalization succeeds.

The handler reaches the exact dispute-window boundary by warping to:

```text
pendingSubmittedAt + disputeWindow
```

Finalization remains allowed through:

```text
pendingSubmittedAt + maxStaleness
```

and returns early after that boundary.

The handler does not require NFT status `FUNDED` during finalization. An outcome may therefore finalize while the invoice is `FROZEN`. Settlement or default execution remains blocked until unfreeze restores `FUNDED`.

The stateful handler does not:

- dispute an update;
- deliberately warp an update stale as a dedicated action;
- deliberately generate a replacement sequence.

Passive stale replacement can still occur when time advances through other finalization actions.

## 14. Accounting and Rounding Assumptions

- Basis-point arithmetic uses a denominator of `10_000`.
- Integer division rounds down.
- Senior allocation rounds down.
- Junior receives the funding-share remainder.
- Settlement fee uses the full funded-to-due-date duration.
- Unpaid fees are not deployed principal NAV and do not contribute to bad debt.
- Default recovery is allocated Senior-first by production accounting.
- Junior absorbs first loss; Senior absorbs residual loss.
- Freeze and unfreeze are accounting-neutral.
- Finalization records an outcome but does not execute economic accounting.
- The handler’s bounded arithmetic is safe only for validated model limits.

## 15. Covered State Space

The stateful suite covers arbitrary sequences involving:

- multiple concurrent invoices;
- two independently selected Buyers;
- one Supplier;
- bounded face values and tenors;
- normal 70/30 funding allocation;
- Buyer concentration admission;
- pending `SETTLED` outcomes;
- pending `DEFAULTED` outcomes;
- zero through full principal recovery;
- oracle finalization;
- the exact dispute-window finalization boundary;
- maximum-staleness enforcement;
- passive stale resubmission when elapsed time makes it reachable;
- finalized-but-unresolved positions;
- finalization while frozen;
- freeze and unfreeze;
- settlement with exact payment or bounded surplus;
- default execution by a separate Resolver;
- cumulative bad debt;
- tranche lock aggregation;
- cash backing under the standard mock token.

## 16. Explicitly Excluded State Space

| Exclusion | Current treatment |
|---|---|
| Oracle disputes | Excluded from the handler; covered by unit and integration tests |
| Deliberate stale replacement sequences | No targeted handler action; replacement behavior is covered by unit tests, while passive stale resubmission may occur statefully |
| Dynamic LP deposits and withdrawals | Initial deposits only in the stateful fixture; lifecycle withdrawals are covered by integration tests |
| Direct token donations | Excluded and not comprehensively covered by the stateful suite; optional future extension |
| ERC-4626 donation/share-price manipulation | Outside this handler; documented as a risk and suitable for dedicated vault tests |
| Fee-on-transfer tokens | Not applicable to `MockERC20`; unsupported by the cash-equality assumption |
| Rebasing tokens | Not applicable to `MockERC20`; unsupported by the cash-equality assumption |
| Role changes | Dynamic role mutation is excluded; role enforcement is covered by unit tests |
| Risk-parameter mutations | Excluded from the handler; parameter boundaries and selected mutations are covered by unit, fuzz, and integration tests |
| Second Supplier | Excluded intentionally; optional state-space extension |
| Arbitrary external vault transfers | Excluded; would require tracked surplus or a weaker cash-backing property |
| Invalid small-principal financing | No longer a valid protocol action after the zero-tranche guard; constructor and financing regression tests cover it |

## 17. Known Limitations

- `ModelConfig` must change whenever production economics intentionally change.
- Mirroring the same conceptual formula in production and the ghost model cannot detect a shared specification error.
- Only two Buyers and one Supplier are modelled.
- Dynamic LP operations and donations are not handler actions.
- `financingFee` is independently reconstructed for settlement execution but is not stored in `GhostPosition`.
- The canonical-position invariant checks identity, principal split, timestamps, and resolution but intentionally ignores stored `financingFee`.
- Primitive advance and fee mathematics are covered separately by unit and fuzz tests.
- The suite checks the configured protocol state space, not every possible deployment configuration.
- Exact cash equality is specific to the standard mock asset and restricted handler flows.
- Future intentional changes to the pinned invariant execution profile require revalidation of runtime and CI practicality.

## 18. Execution Configuration

`foundry.toml` explicitly pins the invariant execution profile:

```toml
[invariant]
runs = 256
depth = 500
fail_on_revert = true
show_metrics = true
```

Configured action slots per invariant:

```text
256 × 500 = 128,000 configured action slots per invariant
```

Configured action slots across the complete catalogue:

```text
128,000 × 12 = 1,536,000 configured action slots across the catalogue
```

Early-returning handler calls still consume configured action slots. With `fail_on_revert = true`, an unexpected handler revert fails the invariant run.

## 19. Latest Verified Result

### Local state after configuration commit `9c08419`

Stateful invariant verification completed with:

```text
12 passed
0 failed
0 skipped
0 handler reverts
0 discards
```

The invariant-suite runtime was approximately 16 minutes 12 seconds.

The complete local suite contained:

```text
210 regular unit, integration, and fuzz tests
12 stateful invariant tests
222 total tests

222 passed
0 failed
0 skipped
```

### CI status

GitHub Actions passed for commit `d040db0` on the current
`audit/final-review` branch state. That state includes the strengthened
stateful invariant model and the invariant execution configuration introduced
in commit `9c08419`.

## 20. Running the Suite

Build:

```bash
forge build
```

Run the stateful invariant suite:

```bash
forge test \
  --match-path test/invariant/InvoiceFinancingPoolInvariant.t.sol \
  -vvv
```

Run the complete test suite:

```bash
forge test
```

Check formatting:

```bash
forge fmt --check
```

Check patch whitespace:

```bash
git diff --check
```

## 21. Relationship to Unit, Fuzz, Integration, and Audit Documentation

The test layers serve different purposes:

- **Unit tests** validate individual guards, lifecycle transitions, permissions, timing boundaries, and specific accounting cases.
- **Fuzz tests** validate primitive formulas, mathematical bounds, and parameterized accounting behavior.
- **Integration tests** validate complete economic lifecycles, withdrawals, oracle disputes, parameter changes, and multi-contract interaction.
- **Stateful invariants** validate accounting conservation, identity, isolation, and lifecycle coherence across arbitrary valid action sequences.
- **Risk and audit documentation** records known assumptions, exclusions, findings, and operational limitations. It does not replace executable tests.

The invariant suite should be read together with the unit, fuzz, and integration suites. A property excluded from the stateful handler is not automatically untested, but coverage must be established in the appropriate test layer rather than inferred.

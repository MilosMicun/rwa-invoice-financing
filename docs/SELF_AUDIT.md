# Self-Audit and Security Review Record

## 1. Purpose and Scope

This document records the internal security review process for the RWA Invoice Financing Protocol, the disposition of findings discovered internally and through independent external review, and the evidence used to evaluate their remediation. It is an evidence ledger and review narrative, not the canonical risk register.

This record is not a formal production audit report, formal verification, production-readiness certification, or representation that no vulnerabilities remain. [`RISKS.md`](RISKS.md) remains the canonical register for residual risks and trust assumptions. [`SPEC.md`](SPEC.md), [`STATE_MACHINE.md`](STATE_MACHINE.md), [`ARCHITECTURE.md`](ARCHITECTURE.md), and [`INVARIANTS.md`](INVARIANTS.md) remain authoritative for their respective protocol and assurance domains.

### Reviewed scope

The review considered:

- invoice lifecycle integrity and terminal-state transitions;
- role-based authorization and trust boundaries;
- financing-position immutability and one-time resolution;
- Senior and Junior tranche accounting;
- ERC-4626 share pricing, liquidity, and loss recognition;
- paid settlement and default waterfalls;
- oracle submission, dispute, finalization, and recovery constraints;
- failure-path atomicity and double-execution prevention;
- unit, integration, fuzz, and stateful invariant evidence.

### Excluded scope

The review does not establish:

- legal enforceability or authenticity of an invoice;
- Buyer credit quality or accuracy of off-chain payment and recovery records;
- KYC, AML, sanctions, identity, custody, or fiat-rail controls;
- production oracle or servicing infrastructure;
- frontend or off-chain application security;
- production governance, role administration, monitoring, or incident response;
- compatibility with fee-on-transfer, rebasing, callback-bearing, or similar non-standard settlement assets;
- behavior of a production deployment that has not yet been exercised.

## 2. Review Methodology

The review combined:

- design and architecture review;
- lifecycle and state-machine review;
- authorization and trust-boundary analysis;
- economic and accounting review;
- success-path and failure-path analysis;
- unit and integration testing;
- bounded fuzz testing;
- stateful invariant testing with an independently maintained ghost model;
- manual self-audit;
- independent external security review;
- remediation-specific regression validation.

A finding is not treated as resolved merely because a test passes. The intended security property must first be defined, the root cause addressed, regression evidence added without weakening relevant existing coverage, and the affected system revalidated. Findings intentionally accepted as limitations or trust assumptions are not described as resolved.

## 3. Reviewed Security Properties

The review evaluated the following principal properties:

- **Lifecycle integrity:** invoices advance only through allowed lifecycle transitions; `SETTLED` and `DEFAULTED` are terminal; settlement and default are mutually exclusive.
- **Authorization:** only authorized roles originate, verify, freeze, submit, dispute, and configure within their defined boundaries; only the recorded Supplier may finance an invoice.
- **Position integrity:** financed terms remain canonical, unresolved principal remains locked, Buyer exposure tracks active principal, and a position resolves at most once.
- **Accounting conservation:** principal, fee, recovery, and loss allocations conserve their respective totals; unpaid expected fees are not recorded as principal bad debt.
- **Tranche safety:** for each tranche, `pendingLoss <= lockedAssets` and `lockedAssets - pendingLoss <= totalAssets()`.
- **Default waterfall:** recovery is allocated Senior-first; the Junior principal allocation for the specific financing absorbs loss first; Senior impairment is reserved only for loss exceeding that allocation.
- **Impairment timing:** once a `DEFAULTED` outcome is finalized, its canonical impairment affects ERC-4626 NAV before LP entry or exit can use stale pricing.
- **Oracle outcome integrity:** finalized status and recovery are immutable, impossible recovery is rejected before persistence, and permissionless execution cannot select or reduce recovered principal.
- **Failure atomicity:** a reverted cross-contract operation cannot leave partial lifecycle, accounting, exposure, or token effects.

The complete catalogue of 12 stateful properties and the limits of their generated state space are documented in [`INVARIANTS.md`](INVARIANTS.md).

### Current tranche accounting model

The reviewed accounting terms are:

```text
accountedAssets
    = gross accounting assets before reserved default impairment

lockedAssets
    = gross tranche principal committed to unresolved financings

pendingLoss
    = finalized but unresolved economic impairment

totalAssets()
    = accountedAssets - pendingLoss

availableLiquidity()
    = accountedAssets - lockedAssets
```

`pendingLoss` is not subtracted again from `availableLiquidity()`.

At `DEFAULTED` finalization, the pool validates recovery, computes the canonical waterfall from the stored financing position, stores the finalized outcome, and reserves any non-zero tranche impairment through `pendingLoss`. NAV changes immediately, but the position remains unresolved: principal stays locked, Buyer exposure and `totalBadDebt` remain unchanged, raw tranche cash does not move, and InvoiceNFT is not marked terminal.

`resolveDefault()` later consumes the finalized outcome, receives recovery, releases locks, and realizes the already-reserved loss through `writeDown()`. Each write-down decreases `accountedAssets` and `pendingLoss` by the same amount, so resolution does not apply a second NAV haircut. Successful resolution then reduces Buyer exposure, records realized principal bad debt, and marks InvoiceNFT `DEFAULTED`.

## 4. Internally Discovered Findings

| ID | Finding | Classification | Status | Remediation |
|---|---|---|---|---|
| H-01 | Caller-Controlled Default Recovery Amount | High protocol vulnerability | Resolved before independent external review | `23f7f72` |
| — | Zero-Tranche Financing | Low protocol finding | Resolved | `047f404` |
| A-01 | Stateful Ghost Model Independence | Assurance / verification quality | Resolved | `d0bd8f2` |

### H-01 — Caller-Controlled Default Recovery Amount

**Classification:** High protocol vulnerability  
**Status:** Resolved before independent external review  
**Remediation commit:** `23f7f72` (`fix: bind default recovery to oracle-finalized outcome`)

**Root cause.** The original oracle finalized only the terminal default status, while `resolveDefault(invoiceId, recoveredAmount)` allowed the permissionless executor to supply the recovery value used by the loss waterfall. One off-chain economic fact was split across two trust domains.

**Security impact.** A caller could report less recovery than was actually realized, including zero, causing excessive tranche write-downs, excessive `totalBadDebt`, and permanent resolution against a false economic input. The issue corrupted accounting rather than directly transferring protocol assets to the caller.

**Security property.** Economic execution must consume immutable oracle-finalized recovery. A permissionless executor may trigger execution but must not select or reduce the economic recovery amount.

**Remediation.** The oracle outcome now includes recovered principal. The pool callback stores it in `finalizedRecoveryAmount[invoiceId]`, and `resolveDefault(uint256 invoiceId)` accepts no recovery argument. Resolution reads only the finalized value. The callback validates status-specific recovery and the existence of a financed position.

**Evidence.** Current regression coverage includes:

- `test_ResolveDefault_CannotExecuteWithLessThanOracleFinalizedRecovery`;
- `testFuzz_ResolveDefault_UsesOracleFinalizedRecovery`;
- `testFuzz_ResolveDefault_CannotExecuteWithLessThanOracleFinalizedRecovery`;
- `test_OnStatusFinalized_RecordsDefaultedStatusAndRecovery`.

The later oracle recovery-bound liveness finding addressed a different stage: rejection of an impossible value before oracle persistence. It is recorded separately in Section 5.

### Zero-Tranche Financing

**Classification:** Low protocol finding  
**Status:** Resolved  
**Remediation commit:** `047f404` (`fix: reject zero tranche principal allocations`)

**Root cause.** Constructor funding shares could assign zero BPS to one tranche, and integer rounding for a sufficiently small financed principal could produce a zero Senior or Junior allocation even with non-zero shares. Such a position is incompatible with the two-tranche financing model.

**Security impact.** The configuration or rounded financing result could reach an invalid one-sided allocation and fail through downstream tranche behavior rather than at the coordinator's explicit financing boundary. No asset loss was demonstrated.

**Remediation.** The constructor rejects zero Senior or Junior funding shares. After calculating the position split, `financeInvoice()` reverts with `ZeroTranchePrincipal` if either tranche allocation is zero, before either tranche is called.

**Evidence.** The remediation commit added:

- `test_Constructor_Reverts_WhenSeniorFundingShareIsZero`;
- `test_Constructor_Reverts_WhenJuniorFundingShareIsZero`;
- `test_FinanceInvoice_Reverts_WhenTranchePrincipalIsZero`;
- `test_FinanceInvoice_Succeeds_WhenFaceValueEqualsMinimumAmount`.

### A-01 — Stateful Ghost Model Independence

**Classification:** Assurance / verification-quality finding  
**Status:** Resolved  
**Remediation commit:** `d0bd8f2` (`test: strengthen stateful invariant ghost model`)

**Root cause.** Parts of the earlier stateful suite reconstructed expected results too directly from production state and calculation helpers, including financing-position fields and finalized outcome storage. This weakened the independence of expected-versus-actual comparisons.

**Assurance impact.** No exploitable production vulnerability was demonstrated. The weakness reduced the harness's ability to detect production-state corruption or errors shared between the implementation and its expected-value construction.

**Remediation.** The handler introduced an explicit `ModelConfig` and per-invoice `GhostPosition`, reconstructs principal, tranche allocations, Buyer exposure, financing fees, oracle outcomes, and resolution state from fuzz inputs and successful handler transitions, and uses production storage primarily for admission checks or as the actual side of comparisons. The state space was also extended to two independently tracked Buyers and a separate Resolver actor.

**Evidence.** Current ghost-anchored properties include:

- `invariant_TotalLockedAssetsEqualsUnresolvedPrincipal`;
- `invariant_BuyerExposureEqualsActivePrincipal`;
- `invariant_PositionPrincipalSplitConservesPrincipal`;
- `invariant_FinalizedOracleDataIsCanonical`;
- `invariant_TotalBadDebtEqualsResolvedDefaultLosses`;
- `invariant_TrancheLocksEqualUnresolvedPrincipalSplits`;
- `invariant_FinancedPositionTermsRemainCanonical`.

The ghost model remains an executable test model, not formal verification. Its current exclusions are summarized in Sections 7 and 9 and specified in [`INVARIANTS.md`](INVARIANTS.md).

## 5. Independent External Review Findings

| Finding | External severity | Project disposition | Remediation |
|---|---|---|---|
| V06-01 — stale NAV / default-loss timing | High | Resolved | `01d6a64` |
| Oracle recovery-bound liveness | Medium | Resolved | `0b3e69f` |
| V06-02 — just-in-time settlement-fee participation | Medium | Accepted v1 economic limitation | No production code remediation |
| Fee-on-transfer / non-standard asset incompatibility | Low / Informational | Accepted v1 asset assumption | No production code remediation |
| Funded-invoice freeze liveness | Low | Accepted operational tradeoff; retained internally as Medium | No production code remediation |
| Privileged-role / centralization residuals | Informational / centralization | Acknowledged trust model | No decentralization remediation claimed |

### V06-01 — Stale NAV / Default-Loss Timing

**Severity:** High  
**Status:** Resolved  
**Remediation commit:** `01d6a64` (`fix: price finalized default losses into tranche nav`)

**Attack.** A finalized default could remain unresolved while its economic loss was absent from ERC-4626 NAV. LPs could enter or exit against stale pre-default share pricing, shifting finalized loss between shareholders.

**Security property.** Once default impairment becomes canonical, tranche NAV must reflect that impairment before LP entry or exit can use stale pricing.

**Remediation.** Each tranche now tracks `pendingLoss`. During `DEFAULTED` finalization, the pool calculates losses from the stored financing position and calls `reserveLoss()` for each non-zero tranche loss. `totalAssets()` returns `accountedAssets - pendingLoss`. Later `writeDown()` decreases both values equally, realizing the reservation without a second NAV haircut.

**Evidence.** Dedicated regression tests include:

- `test_DefaultFinalization_HaircutsJuniorExitForTwoEqualLpsEvenAfterThirtyDays`;
- `test_ResolveDefault_RealizesReservedLossWithoutSecondNavHaircut`;
- `test_DepositAfterDefaultFinalization_UsesImpairedNavAndAvoidsSecondLoss`;
- `test_MultipleFinalizedDefaults_AggregateAndResolveIndependently`.

The full local suite passed 229 of 229 tests, and GitHub CI is green after the documentation remediation.

### Oracle Recovery-Bound Liveness

**Severity:** Medium  
**Status:** Resolved  
**Remediation commit:** `0b3e69f` (`fix: reject impossible oracle recovery submissions`)

**Root cause.** A `DEFAULTED` recovery above financed principal could previously become an active persisted oracle update and fail only when the pool callback attempted finalization. The invalid active update could block a valid replacement until it was disputed or stale.

**Security property.** Impossible economic outcomes must be rejected before persistence.

**Remediation.** `InvoiceStatusOracle.submitStatus()` reads the principal stored in `POOL.financingPositions(invoiceId)` and rejects `recoveredAmount > principal` before writing `StatusUpdate`. It does not use invoice face value, a newly calculated advance, or current Risk Manager configuration. `InvoiceFinancingPool.onStatusFinalized()` independently revalidates the same bound as defense in depth.

**Evidence.** Current regression coverage includes:

- `test_SubmitStatus_Reverts_WhenDefaultRecoveryExceedsPrincipalAndLeavesNoActiveUpdate`;
- `test_SubmitStatus_AllowsImmediateValidDefaultAfterExcessRecoveryReverts`;
- `test_SubmitStatus_AllowsDefaultRecoveryEqualToPrincipal`;
- `testFuzz_OracleSubmitStatus_Reverts_WhenDefaultRecoveryExceedsPrincipal`;
- `test_OnStatusFinalized_Reverts_WhenRecoveryExceedsPrincipal` for the retained pool-side guard.

### V06-02 — Just-in-Time Settlement-Fee Participation

**Severity:** Medium  
**Status:** Accepted v1 economic limitation  
**Production code remediation:** None

The finding is valid. A realized settlement fee is credited as a lump-sum increase to tranche `accountedAssets` and therefore NAV. ERC-4626 shareholders present when the credit occurs participate pro rata. v1 does not snapshot financing-time shareholders or weight entitlement by holding duration, so an LP may enter shortly before settlement and share in the fee without bearing the full financing-duration risk.

This behavior does not break accounting conservation, transfer principal, or violate a documented accounting invariant. It can dilute the yield of longer-standing LPs. A correct mitigation would require materially different economics, such as continuous accrual, shareholder snapshots, duration weighting, or lockups. The residual risk is intentionally accepted for v1 and is not claimed as fixed or a false positive.

### Fee-on-Transfer / Non-Standard Asset Incompatibility

**External severity:** Low / Informational  
**Status:** Accepted v1 asset assumption

The protocol assumes a reviewed standard ERC-20 settlement asset. It does not claim support for fee-on-transfer, rebasing, callback-bearing, or similar non-standard tokens. Taxed-token behavior must not be treated as supported. The complete asset-assumption risk is maintained as R-15 in [`RISKS.md`](RISKS.md).

### Funded-Invoice Freeze Liveness

**External severity:** Low  
**Internal project classification:** Medium  
**Status:** Accepted operational tradeoff

A privileged Risk role can delay economic resolution by keeping a funded invoice frozen. Freeze and unfreeze themselves are accounting-neutral. If a `DEFAULTED` update was submitted before freezing, it may still finalize while frozen and reserve the canonical impairment in `pendingLoss`, immediately affecting NAV. Settlement or default resolution remains blocked until unfreeze restores `FUNDED`.

This is an operational and governance risk rather than an unprivileged exploit. The project intentionally retains the stricter internal Medium classification. See R-05 in [`RISKS.md`](RISKS.md).

### Privileged-Role / Centralization Residuals

**Severity:** Informational / centralization  
**Status:** Acknowledged trust model

v1 is permissioned. Administrative, originator, verifier, risk, oracle-submitter, and dispute roles remain trusted security boundaries; no decentralization guarantee is claimed. A future production deployment would require explicit decisions on role separation, administrative blast radius, multisig or timelock use, key management, monitoring, and incident response. These residuals are acknowledged, not described as fixed.

## 6. Accepted Risks and Trust Assumptions

The principal accepted boundaries are:

- authorized oracle actors are trusted to report accurate off-chain status and recovered principal;
- administrative and Risk roles can materially affect eligibility, operation, and liveness;
- a funded invoice may remain unresolved while frozen, although finalized default impairment still affects NAV;
- v1 assumes a reviewed standard ERC-20 settlement asset;
- fee entitlement is based on share ownership at settlement credit time rather than holding duration;
- invoice authenticity, Buyer payment, recovery, legal enforceability, and servicing correctness remain off-chain facts;
- production role separation, governance, key management, monitoring, and incident response remain deployment responsibilities.

These are summarized here for review context. [`RISKS.md`](RISKS.md) is the canonical and more complete risk register.

## 7. Verification Evidence

The current validated test state is:

```text
217 regular unit, integration, and fuzz tests
12 stateful invariant tests
229 total tests

229 passed
0 failed
0 skipped
```

The invariant execution profile is:

```toml
[invariant]
runs = 256
depth = 500
fail_on_revert = true
show_metrics = true
```

The 12 stateful invariants cover lifecycle coherence, oracle outcome consistency, lock and exposure accounting, bad debt, cash backing, position immutability, and net unresolved exposure within the generated handler state space. They do not constitute formal verification.

Important assurance limits are:

- dynamic LP deposits and withdrawals are not stateful handler actions;
- V06-01 LP timing is covered by dedicated deterministic and integration regression tests outside the stateful handler;
- V06-02 just-in-time fee timing is not claimed as a stateful invariant;
- dynamic LP entry and exit timing remains outside the current invariant state space.

GitHub CI is green after remediation and the documentation synchronization commit `174423c` (`docs: align protocol documentation with audit remediations`).

## 8. Remediation Validation Standard

The current standard marks a finding Resolved only after, where applicable:

1. the root cause is understood;
2. the intended security property is defined;
3. implementation remediation is completed;
4. regression coverage is added;
5. relevant existing tests are preserved;
6. the full local suite passes;
7. build, format, and diff-hygiene checks pass;
8. GitHub CI passes.

This standard does not convert an intentionally accepted finding into a resolved finding. V06-02, non-standard asset incompatibility, freeze liveness, and privileged-role residuals retain their stated accepted or acknowledged dispositions.

## 9. Known Assurance Gaps

The current evidence does not include:

- formal verification;
- a formal production audit engagement;
- a public production deployment;
- production oracle or servicing infrastructure;
- a completed production governance and key-management architecture;
- a stateful model of dynamic LP entry and exit;
- a support guarantee for non-standard settlement assets;
- verification of legal enforceability, credit quality, or real-world invoice authenticity.

The independent external security review is material assurance evidence, but it is not production certification. Test success is evidence for the exercised model and does not prove the absence of unknown vulnerabilities or unsafe deployment configurations.

## 10. Final Assessment

Within the documented v1 model, the reviewed lifecycle, accounting, oracle, and authorization properties are supported by unit, integration, fuzz, invariant, manual-review, and independent external-review evidence.

The internally discovered High and Low protocol findings and the ghost-model assurance finding have verified remediation commits and regression evidence. The two external findings marked Resolved have implementation remediations and targeted tests. Other external findings remain explicitly accepted limitations, asset assumptions, operational tradeoffs, or acknowledged trust boundaries.

Known residual risks, accepted limitations, trust assumptions, and assurance gaps remain documented in this record and in [`RISKS.md`](RISKS.md). The repository is not represented as production-ready.

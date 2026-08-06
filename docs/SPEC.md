# RWA Invoice Financing Protocol Specification

## Overview

This document defines the v1 financial model, actor permissions, contract responsibilities, lifecycle state machine, oracle outcome flow, tranche accounting, settlement waterfalls, and liquidity constraints of the RWA Invoice Financing Protocol.

The protocol models real-world invoice financing through:

* non-transferable invoice claim NFTs;
* permissioned invoice verification and risk controls;
* Senior and Junior ERC-4626 liquidity tranches;
* supplier-requested financing;
* permissioned oracle reporting of off-chain terminal outcomes;
* deterministic settlement and default accounting;
* explicit separation between lifecycle state, accounting state, and off-chain truth.

Suppliers receive liquidity before invoice maturity. Senior and Junior liquidity providers finance those advances. Off-chain payment or default outcomes are submitted through an authorized oracle process and consumed by the pool through deterministic accounting rules.

The protocol is not trustless. Invoice validity, buyer payment, legal enforceability, and recovered principal exist outside the blockchain. The architecture therefore focuses on making trust assumptions explicit and preventing trusted actors from bypassing on-chain accounting rules.

The smart contracts are intended to implement this specification.

---

# 1. v1 Scope and Non-Goals

The v1 protocol prioritizes:

* deterministic accounting;
* explicit state transitions;
* clear trust boundaries;
* tranche-level NAV accounting;
* auditability;
* focused security testing.

The following features are intentionally excluded from v1:

* partial settlement lifecycle states;
* recovery of financing fees during default;
* secondary trading of invoice NFTs;
* dynamic or per-invoice interest rates;
* multi-oracle quorum;
* recovery escrow;
* automated bank-payment reconciliation;
* automated legal enforcement;
* cross-protocol invoice uniqueness;
* insurance reserves;
* refinancing or restructuring;
* withdrawal queues;
* epoch-based liquidity;
* automated liquidation markets;
* protocol upgradeability;
* KYC or LP whitelisting;
* protocol-wide pause functionality.

These exclusions are deliberate. The v1 implementation models the core financial machine before adding production-level operational complexity.

---

# 2. Core Design Principles

## 2.1 Lifecycle State and Accounting State Are Separate

`InvoiceNFT.sol` is the canonical source of truth for invoice lifecycle state.

`InvoiceFinancingPool.sol` is the canonical source of truth for financing and accounting state.

`InvoiceStatusOracle.sol` is the canonical source of finalized off-chain terminal outcomes before accounting execution.

These responsibilities must not be collapsed into one contract or one privileged role.

---

## 2.2 Oracle Truth and Accounting Execution Are Separate

The oracle reports off-chain economic truth:

* whether a funded invoice is `SETTLED` or `DEFAULTED`;
* recovered principal for a `DEFAULTED` outcome.

The oracle does not:

* transfer repayment assets;
* execute tranche accounting;
* write down NAV;
* update buyer exposure;
* transition InvoiceNFT to a terminal state.

The pool validates and stores the finalized oracle outcome.

A permissionless executor later supplies the required assets and triggers deterministic settlement or default accounting.

The executor cannot choose or modify the finalized economic outcome.

---

## 2.3 NAV Is Not Raw Token Balance

SeniorPool and JuniorPool account for active receivable exposure as part of NAV even after the corresponding cash has been transferred to the Supplier.

Therefore:

```text
ERC-4626 totalAssets != raw token balance
```

Each tranche separately tracks:

* `accountedAssets`: tranche NAV;
* `lockedAssets`: NAV committed to active financing positions;
* raw ERC-20 token balance: immediately available cash backing.

---

## 2.4 Active Position Terms Are Immutable

The following values are stored when an invoice is financed:

* financed principal;
* Senior principal;
* Junior principal;
* financing fee;
* funding timestamp;
* due date;
* Supplier;
* Buyer.

Later changes to risk parameters, funding shares, or fee shares must not retroactively change an active financing position.

---

# 3. Core Invariants

The protocol must preserve the following properties:

* An invoice can be financed at most once.
* Only `VERIFIED` invoices can be funded.
* Only `FUNDED` invoices can be settled.
* Only `FUNDED` invoices can be defaulted.
* `SETTLED` and `DEFAULTED` are terminal lifecycle states.
* Settlement and default execution are mutually exclusive.
* A financing position can be resolved at most once.
* Oracle outcomes can be finalized only for existing financed positions.
* A finalized oracle outcome cannot be overwritten.
* A `SETTLED` oracle outcome must have zero recovered principal.
* A `DEFAULTED` recovered amount must not exceed financed principal.
* A permissionless executor cannot choose or modify recovered principal.
* Default execution must use exactly the oracle-finalized recovered principal.
* Funding share components must conserve principal.
* Fee share components must conserve the stored financing fee.
* Default recovery allocation must conserve recovered principal.
* Default loss allocation must conserve realized principal loss.
* Settlement must not increase `totalBadDebt`.
* Default bad-debt increase must equal financed principal minus finalized recovered principal.
* Unpaid financing fee must not be counted as principal bad debt.
* `totalBadDebt` must never decrease during normal operation.
* `totalLockedAssets` must equal unresolved financed principal.
* Senior and Junior locked assets must be tracked independently.
* Senior locked assets plus Junior locked assets must equal aggregate locked assets.
* Tranche locked assets must never exceed tranche NAV.
* Funding must fail if either tranche lacks sufficient available liquidity.
* LP withdrawals must not consume locked liquidity.
* Freeze and unfreeze must not change principal, NAV, fee, exposure, or locked-asset accounting.
* Resolution of one invoice must not mutate unrelated financing positions.

---

# 4. Actors and Roles

## 4.1 Originator

### Economic Role

The Originator registers an off-chain invoice claim in the protocol.

The Originator may be a servicing entity, financing platform, or other authorized operational actor responsible for onboarding receivable data.

### Permissions

* Create InvoiceNFT records.
* Provide Supplier, Buyer, face value, and due date.

### Cannot

* Verify its own invoice unless separately granted the Verifier role.
* Finance an invoice on behalf of the Supplier.
* Report settlement or default outcomes.
* Execute lifecycle terminal transitions directly.
* Move tranche liquidity.

---

## 4.2 Supplier

### Economic Role

The Supplier is the original creditor of the invoice receivable.

The Supplier exchanges part of the future receivable value for immediate liquidity.

### Permissions

* Request financing for an invoice where it is the recorded Supplier.
* Receive the financed principal.
* Receive surplus paid above principal plus financing fee during settlement.

### Cannot

* Verify the invoice.
* Determine oracle settlement truth.
* Select default recovery.
* Modify tranche accounting.
* Finance the same invoice twice.

The Supplier has no privileged settlement or default authority. Like any address, it may technically act as a permissionless executor if it supplies the required tokens, but it cannot alter the finalized outcome.

---

## 4.3 Buyer

### Economic Role

The Buyer is the off-chain payment obligor associated with the invoice.

Buyer credit quality and payment behavior determine the underlying economic risk.

### Privileges

The Buyer receives no privileged on-chain role.

It may act as a permissionless settlement payer or executor, but it cannot:

* change invoice lifecycle state directly;
* submit oracle outcomes without an oracle role;
* modify principal, fee, or recovery;
* override waterfall accounting.

---

## 4.4 Verifier

### Economic Role

The Verifier confirms that a created invoice may progress into the financing lifecycle.

### Permissions

* Transition an invoice from `CREATED` to `VERIFIED`.

### Cannot

* Finance the invoice.
* Update buyer exposure.
* report settlement or default;
* freeze or unfreeze invoices unless separately granted the Risk role.

The Verifier role and Originator role are logically separate.

---

## 4.5 Risk Administrator

### Economic Role

The Risk Administrator manages underwriting configuration and operational invoice risk controls.

The Risk Manager administrator may:

* update bounded underwriting parameters;
* deny or allow Buyers.

The InvoiceNFT Risk role may:

* freeze eligible invoices;
* unfreeze previously frozen invoices.

These authorities may be assigned to different addresses.

### Cannot

* rewrite active financing terms;
* directly modify tranche NAV;
* bypass settlement or default accounting;
* resolve an invoice twice.

---

## 4.6 Senior Liquidity Provider

### Economic Role

The Senior Liquidity Provider supplies lower-risk capital to SeniorPool.

Senior capital receives recovery priority during default but receives only its configured fee share.

### Permissions

* Deposit underlying assets.
* Receive SeniorPool ERC-4626 shares.
* Withdraw or redeem available liquidity.
* Participate in realized financing fee income.

### Main Risks

* liquidity lock during active financing;
* residual principal loss after Junior loss allocation;
* Buyer concentration;
* oracle failure;
* ERC-4626 rounding and dust.

Senior capital is protected by Junior capital but is not guaranteed.

---

## 4.7 Junior Liquidity Provider

### Economic Role

The Junior Liquidity Provider supplies first-loss capital to JuniorPool.

Junior capital absorbs loss before Senior capital and receives enhanced configured fee participation.

### Permissions

* Deposit underlying assets.
* Receive JuniorPool ERC-4626 shares.
* Withdraw or redeem available liquidity.
* Participate in realized financing fee income.

### Main Risks

* first-loss exposure;
* NAV depletion;
* liquidity lock;
* oracle failure;
* Buyer concentration;
* ERC-4626 rounding and dust.

---

## 4.8 Oracle Submitter

### Economic Role

The Oracle Submitter reports off-chain terminal invoice outcomes.

Unlike a price oracle, it reports discrete servicing outcomes:

* `SETTLED`;
* `DEFAULTED`;
* recovered principal for a default.

### Permissions

* Submit a terminal outcome for a funded invoice.
* Resubmit an outcome after the prior update was disputed or became stale.

### Cannot

* execute settlement or default accounting;
* move tranche funds;
* update buyer exposure;
* mark InvoiceNFT terminal directly;
* report arbitrary lifecycle states;
* report non-zero recovery for `SETTLED`;
* modify finalized outcomes.

---

## 4.9 Dispute Administrator

### Economic Role

The Dispute Administrator challenges an active oracle update during the dispute window.

### Permissions

* Mark an unfinalized oracle update as disputed before the dispute window expires.

### Cannot

* finalize an update merely by holding the dispute role;
* mutate tranche accounting;
* directly resolve an invoice;
* modify a finalized update.

A disputed update cannot be finalized. A replacement update may later be submitted.

---

## 4.10 Pool Administrator

### Economic Role

The Pool Administrator configures the immutable oracle trust boundary after deployment.

### Permissions

* Set the InvoiceStatusOracle address once.

### Cannot

* replace the oracle after it has been set;
* manually set finalized outcomes;
* directly alter tranche NAV;
* bypass waterfall execution.

---

## 4.11 Permissionless Executor

### Economic Role

An executor triggers accounting after an outcome has been finalized.

The executor may be:

* the Buyer;
* a servicing operator;
* a recovery operator;
* a keeper;
* any other address holding the required tokens and approvals.

### Permissions

* Call `settleInvoice(invoiceId, paidAmount)`.
* Call `resolveDefault(invoiceId)`.

### Cannot

* choose terminal status;
* choose recovered principal;
* alter stored financing terms;
* override waterfall allocation;
* resolve an invoice more than once.

For default execution, the executor must supply exactly the oracle-finalized recovered principal.

---

# 5. Contract Architecture

## 5.1 InvoiceNFT.sol — Lifecycle Registry

InvoiceNFT represents invoice identity and lifecycle state.

Each invoice stores:

```solidity
struct Invoice {
    address supplier;
    address buyer;
    uint256 faceValue;
    uint256 dueDate;
    uint256 fundedAt;
    InvoiceStatus status;
    InvoiceStatus previousStatus;
}
```

Supported lifecycle states:

```solidity
enum InvoiceStatus {
    CREATED,
    VERIFIED,
    FUNDED,
    SETTLED,
    DEFAULTED,
    FROZEN
}
```

InvoiceNFT is responsible for:

* invoice identity;
* Supplier and Buyer association;
* face value and due date;
* lifecycle transitions;
* funding timestamp;
* freeze-state restoration;
* prevention of repeated lifecycle funding;
* non-transferability.

InvoiceNFT is not responsible for:

* underwriting calculations;
* buyer concentration;
* tranche accounting;
* repayment token transfers;
* fee distribution;
* bad-debt recognition.

Invoice NFTs are non-transferable in v1.

---

## 5.2 RWARiskManager.sol — Underwriting Boundary

RWARiskManager controls:

* minimum invoice amount;
* maximum invoice tenor;
* advance rate;
* financing fee APR;
* maximum active exposure per Buyer;
* Buyer denylist;
* active Buyer exposure.

Intrinsic eligibility and portfolio concentration are separate checks.

Intrinsic eligibility evaluates:

* invoice lifecycle status;
* face value;
* remaining tenor;
* Buyer denylist status.

Concentration evaluates whether an additional financed principal amount would exceed the Buyer exposure limit.

Only InvoiceFinancingPool may update active Buyer exposure.

---

## 5.3 InvoiceFinancingPool.sol — SPV and Accounting Coordinator

InvoiceFinancingPool acts as the on-chain SPV coordinator.

It is responsible for:

* deploying and coordinating SeniorPool and JuniorPool;
* wrapping LP deposits and withdrawals;
* financing eligible invoices;
* storing immutable financing positions;
* locking tranche liquidity;
* updating Buyer exposure;
* advancing principal to Suppliers;
* recording finalized oracle outcomes;
* executing settlement;
* executing default recovery and loss allocation;
* updating aggregate locked assets;
* recording cumulative principal bad debt;
* transitioning InvoiceNFT to terminal states.

It does not replace ERC-4626 tranche accounting.

---

## 5.4 SeniorPool.sol and JuniorPool.sol — ERC-4626 Tranches

Both tranche vaults track:

```text
accountedAssets
lockedAssets
availableLiquidity
raw token balance
```

`accountedAssets` is the ERC-4626 NAV source.

`lockedAssets` represents NAV committed to unresolved financed invoices.

```solidity
availableLiquidity = accountedAssets - lockedAssets;
```

Financing transfers cash out of the vault but does not immediately reduce NAV because the vault receives economic exposure to the receivable.

Loss is recognized only through an explicit `writeDown()` during default resolution.

---

## 5.5 InvoiceStatusOracle.sol — Off-Chain Outcome Adapter

The oracle stores:

```solidity
struct StatusUpdate {
    uint256 invoiceId;
    IInvoiceNFT.InvoiceStatus newStatus;
    uint256 recoveredAmount;
    uint256 submittedAt;
    bool disputed;
    bool finalized;
}
```

It supports:

* permissioned submission;
* dispute administration;
* dispute-window delay;
* maximum staleness;
* stale or disputed resubmission;
* permissionless finalization;
* immutable finalized outcomes;
* pool callback propagation.

The oracle does not execute financial accounting.

---

# 6. Invoice Lifecycle State Machine

## 6.1 CREATED → VERIFIED

### Trigger

An address holding `VERIFIER_ROLE` calls `verify(invoiceId)`.

### Guards

* Invoice exists.
* Current status is `CREATED`.

### Effects

* Status becomes `VERIFIED`.
* No liquidity moves.
* No financing position exists.
* No Buyer exposure is created.

---

## 6.2 VERIFIED → FUNDED

### Trigger

The recorded Supplier calls:

```solidity
financeInvoice(invoiceId)
```

on InvoiceFinancingPool.

### Guards

* Caller is the recorded Supplier.
* Financing position does not already exist.
* Invoice passes intrinsic eligibility.
* Buyer concentration remains within limits.
* SeniorPool has sufficient available liquidity.
* JuniorPool has sufficient available liquidity.
* InvoiceNFT remains in `VERIFIED`.

### Effects

The pool:

1. calculates financed principal;
2. calculates the Senior and Junior principal split;
3. calculates and stores the financing fee;
4. stores the financing position;
5. increases aggregate locked assets;
6. locks Senior and Junior liquidity independently;
7. increases active Buyer exposure;
8. marks InvoiceNFT as `FUNDED`;
9. transfers tranche cash to the Supplier.

All effects occur atomically. Any failure reverts the entire transaction.

---

## 6.3 FUNDED → SETTLED

Settlement has two distinct stages:

### Stage 1 — Oracle Outcome Finalization

The Oracle Submitter submits:

```text
status = SETTLED
recoveredAmount = 0
```

The update passes through the dispute and staleness process.

A permissionless caller finalizes the oracle update.

InvoiceFinancingPool records the finalized outcome but does not yet:

* release locked liquidity;
* transfer repayment assets;
* distribute fees;
* reduce Buyer exposure;
* mutate `InvoiceNFT` or mark it terminal.

After finalization and before accounting execution, the current `InvoiceNFT` status may be `FUNDED`, or `FROZEN` with `previousStatus` equal to `FUNDED`. If the invoice is `FROZEN`, finalization remains recorded but settlement execution is blocked until unfreeze.

### Stage 2 — Settlement Accounting Execution

A permissionless payer calls:

```solidity
settleInvoice(invoiceId, paidAmount)
```

### Guards

* Financing position exists.
* Position is unresolved.
* Oracle outcome is finalized.
* Finalized status is `SETTLED`.
* Finalized recovery is zero.
* InvoiceNFT status is still `FUNDED`.
* Invoice is not `FROZEN`.
* `paidAmount >= principal + financingFee`.

### Effects

The pool:

1. marks the financing position resolved;
2. decreases aggregate locked assets by principal;
3. transfers Senior principal plus Senior fee to SeniorPool;
4. transfers Junior principal plus Junior fee to JuniorPool;
5. returns surplus to the Supplier;
6. unlocks Senior and Junior principal;
7. credits realized fee income to tranche NAV;
8. decreases Buyer exposure by principal;
9. marks InvoiceNFT as `SETTLED`.

`totalBadDebt` does not change.

---

## 6.4 FUNDED → DEFAULTED

Default also has two distinct stages.

### Stage 1 — Oracle Outcome Finalization

The Oracle Submitter submits:

```text
status = DEFAULTED
recoveredAmount = recovered principal
```

### Oracle Recovery Rules

* Recovery may be zero.
* Recovery must not exceed financed principal.
* Recovery represents principal only.
* Financing-fee recovery during default is outside v1 scope.

The update passes through the dispute and staleness process.

A permissionless caller finalizes the update.

InvoiceFinancingPool records:

* finalized `DEFAULTED` status;
* finalized recovered principal.

The callback requires an existing financing position.

Finalization does not change `InvoiceNFT` status or mark it terminal. After finalization and before accounting execution, the current status may be `FUNDED`, or `FROZEN` with `previousStatus` equal to `FUNDED`. If the invoice is `FROZEN`, finalization remains recorded but default execution is blocked until unfreeze.

### Stage 2 — Default Accounting Execution

A permissionless executor calls:

```solidity
resolveDefault(invoiceId)
```

The function accepts no recovery argument.

### Guards

* Financing position exists.
* Position is unresolved.
* Oracle outcome is finalized.
* Finalized status is `DEFAULTED`.
* InvoiceNFT status is still `FUNDED`.
* Invoice is not `FROZEN`.
* Stored finalized recovery does not exceed stored principal.

### Effects

The pool:

1. reads `finalizedRecoveryAmount[invoiceId]`;
2. calculates Senior recovery;
3. calculates Junior recovery;
4. calculates Junior loss;
5. calculates Senior loss;
6. calculates realized principal bad debt;
7. marks the position resolved;
8. decreases aggregate locked assets;
9. increases cumulative bad debt;
10. transfers recovered assets to the tranche vaults;
11. unlocks Senior and Junior principal;
12. writes down Junior NAV first;
13. writes down Senior NAV for residual loss;
14. decreases Buyer exposure;
15. marks InvoiceNFT as `DEFAULTED`.

The executor cannot change the recovery amount.

---

## 6.5 FROZEN Overlay

`FROZEN` is an operational and legal overlay represented as an InvoiceNFT lifecycle status.

An invoice may be frozen only from:

* `VERIFIED`;
* `FUNDED`.

When frozen:

* current status becomes `FROZEN`;
* prior status is stored in `previousStatus`;
* no principal changes;
* no NAV changes;
* no fee is realized;
* no Buyer exposure changes;
* no locked assets are released;
* financing is blocked;
* settlement execution is blocked;
* default execution is blocked.

An oracle update submitted before the freeze may still be finalized because oracle finalization does not execute accounting or mutate InvoiceNFT.

Accounting execution remains blocked until unfreeze.

---

## 6.6 FROZEN → Previous Status

An address holding the InvoiceNFT Risk role may unfreeze an invoice.

The invoice returns to its stored previous status:

* `VERIFIED`; or
* `FUNDED`.

Unfreeze must not change economic accounting.

---

## 6.7 Terminal States

`SETTLED` and `DEFAULTED` are terminal.

After either transition, the invoice cannot:

* be funded again;
* settle again;
* default again;
* be frozen;
* return to an earlier lifecycle state.

---

## 6.8 Forbidden Transitions

The following transitions must be impossible:

* `CREATED → FUNDED`
* `CREATED → SETTLED`
* `CREATED → DEFAULTED`
* `CREATED → FROZEN`
* `VERIFIED → SETTLED`
* `VERIFIED → DEFAULTED`
* `FUNDED → CREATED`
* `FUNDED → VERIFIED`
* `FROZEN → SETTLED` without unfreeze
* `FROZEN → DEFAULTED` without unfreeze
* `SETTLED → any state`
* `DEFAULTED → any state`
* any invoice becoming `FUNDED` more than once
* settlement after default
* default after settlement

---

# 7. Underwriting and Financing Model

## 7.1 Risk Parameters

The v1 Risk Manager stores:

```solidity
struct RiskParams {
    uint256 maxExposurePerBuyer;
    uint256 advanceRate;
    uint256 maxInvoiceTenor;
    uint256 minInvoiceAmount;
    uint256 financingFeeApr;
}
```

Basis-point values use:

```solidity
BPS_DENOMINATOR = 10_000
```

Risk parameters are bounded by implementation-level validation.

---

## 7.2 Intrinsic Eligibility

An invoice is intrinsically eligible only when:

* status is `VERIFIED`;
* face value meets the minimum;
* due date is in the future;
* remaining tenor is within the configured maximum;
* Buyer is not denied.

A non-existent invoice returns false from the Risk Manager eligibility query.

---

## 7.3 Buyer Concentration

Buyer concentration is checked separately from intrinsic eligibility.

```solidity
existingExposure + newPrincipal <= maxExposurePerBuyer
```

Exposure represents active financed principal, not:

* invoice face value;
* expected repayment;
* lifetime financing volume;
* financing fee.

Exposure increases during financing and decreases only after successful settlement or default resolution.

---

## 7.4 Advance Calculation

Financed principal is:

```solidity
principal =
    faceValue * advanceRateBps / 10_000;
```

---

## 7.5 Tranche Principal Split

Principal is divided as:

```solidity
seniorPrincipal =
    principal * seniorFundingShareBps / 10_000;

juniorPrincipal =
    principal - seniorPrincipal;
```

Any integer rounding remainder is allocated to JuniorPool.

The following must always hold:

```solidity
seniorPrincipal + juniorPrincipal == principal;
```

Funding requires sufficient available liquidity in both tranches independently.

---

# 8. Financing Fee Model

## 8.1 Formula

The v1 financing fee uses simple linear APR:

```solidity
financingFee =
    principal
    * financingFeeAprBps
    * (dueDate - fundedAt)
    / (365 days * 10_000);
```

The fee is calculated and stored when the invoice is funded.

---

## 8.2 Fixed-Tenor Treatment

The full funded-to-due-date tenor is used.

Early settlement does not reduce the fee.

This makes the fee deterministic and prevents settlement-time repricing.

---

## 8.3 Settlement Recognition

The fee is not recognized as tranche NAV at funding.

It becomes realized only during successful settlement.

The stored fee is divided as:

```solidity
juniorFee =
    financingFee * juniorFeeShareBps / 10_000;

seniorFee =
    financingFee - juniorFee;
```

The following must hold:

```solidity
juniorFee + seniorFee == financingFee;
```

---

## 8.4 Default Treatment

Unpaid financing fee is not included in `totalBadDebt`.

The fee represents unrealized expected income, not deployed principal NAV.

Therefore:

```solidity
principalLoss =
    principal - recoveredPrincipal;
```

and:

```solidity
totalBadDebtDelta =
    principalLoss;
```

If principal is fully recovered but the financing fee is not paid, the default path may resolve with:

```text
recoveredPrincipal = principal
principalLoss = 0
totalBadDebtDelta = 0
```

Fee recovery during default is not modeled in v1.

---

# 9. Oracle Outcome Protocol

## 9.1 Allowed Outcomes

The oracle may submit only:

* `SETTLED`;
* `DEFAULTED`.

All other InvoiceNFT statuses are invalid oracle outcomes.

---

## 9.2 Submission Requirements

An outcome may be submitted only while InvoiceNFT status is `FUNDED`.

For `SETTLED`:

```solidity
recoveredAmount == 0
```

For `DEFAULTED`:

```solidity
0 <= recoveredAmount <= financedPrincipal
```

The upper principal bound is validated by InvoiceFinancingPool when the oracle callback is finalized.

---

## 9.3 Active Update Rules

An active non-disputed, non-stale update cannot be overwritten.

Resubmission is allowed only when the previous update:

* was disputed; or
* became stale.

A replacement update may change:

* terminal status;
* recovered principal.

---

## 9.4 Dispute Window

A Dispute Administrator may dispute an update while `block.timestamp <= submittedAt + DISPUTE_WINDOW`.

At the exact dispute-window boundary, both dispute and finalization are timing-valid, but only the first executed transaction succeeds. The later transaction reverts because the update is already disputed or finalized.

A disputed update cannot be finalized.

---

## 9.5 Maximum Staleness

Finalization remains allowed while `block.timestamp <= submittedAt + MAX_STALENESS`, including at the exact maximum-staleness boundary.

After that boundary, finalization reverts because the update is stale and must be replaced.

The configured maximum staleness must exceed the dispute window.

---

## 9.6 Permissionless Finalization

Any address may finalize a valid update while `block.timestamp >= submittedAt + DISPUTE_WINDOW` and `block.timestamp <= submittedAt + MAX_STALENESS`.

Finalization:

1. marks the oracle update finalized;
2. calls `InvoiceFinancingPool.onStatusFinalized(...)`;
3. emits the finalized outcome and finalization timestamp.

If the pool callback reverts, the entire transaction reverts, including the oracle's local `finalized` update.

---

## 9.7 Pool Callback Validation

InvoiceFinancingPool independently validates:

* oracle is configured;
* caller is the configured oracle;
* status is `SETTLED` or `DEFAULTED`;
* financing position exists;
* outcome is not already finalized;
* `SETTLED` recovery equals zero;
* `DEFAULTED` recovery does not exceed stored principal.

The finalized status and recovery then become immutable pool state.

---

# 10. Paid-Path Waterfall

Expected repayment is:

```solidity
expectedRepayment =
    principal + financingFee;
```

Settlement requires:

```solidity
paidAmount >= expectedRepayment;
```

Surplus is:

```solidity
surplus =
    paidAmount - expectedRepayment;
```

Repayment is allocated as:

```solidity
seniorRepayment =
    seniorPrincipal + seniorFee;

juniorRepayment =
    juniorPrincipal + juniorFee;
```

Execution order:

1. close local position accounting;
2. transfer Senior repayment to SeniorPool;
3. transfer Junior repayment to JuniorPool;
4. transfer surplus to the Supplier;
5. unlock Senior principal;
6. unlock Junior principal;
7. credit Senior fee to Senior NAV;
8. credit Junior fee to Junior NAV;
9. decrease Buyer exposure;
10. mark InvoiceNFT `SETTLED`.

Principal is not credited to NAV again because it remained part of `accountedAssets` while deployed.

Only incremental fee income increases tranche NAV.

---

# 11. Default-Path Waterfall

## 11.1 Recovery Allocation

Recovered principal is allocated to SeniorPool first:

```solidity
seniorRecovery =
    min(recoveredAmount, seniorPrincipal);
```

Junior recovery receives the remainder:

```solidity
juniorRecovery =
    recoveredAmount - seniorRecovery;
```

The following must hold:

```solidity
seniorRecovery + juniorRecovery
    == recoveredAmount;
```

---

## 11.2 Loss Allocation

Senior loss is:

```solidity
seniorLoss =
    seniorPrincipal - seniorRecovery;
```

Junior loss is:

```solidity
juniorLoss =
    juniorPrincipal - juniorRecovery;
```

Total realized principal loss is:

```solidity
loss =
    principal - recoveredAmount;
```

The following must hold:

```solidity
seniorLoss + juniorLoss == loss;
```

Because recovery is allocated to Senior first, Junior absorbs first-loss exposure.

Senior suffers loss only after Junior principal for that position is fully impaired.

---

## 11.3 Bad Debt

`totalBadDebt` is cumulative and non-decreasing.

For each resolved default:

```solidity
badDebtDelta =
    principal - finalizedRecoveryAmount;
```

Unpaid financing fee is excluded.

---

## 11.4 NAV Effects

Recovered cash restores token backing for NAV that was already accounted.

Recovery does not independently increase NAV.

Losses reduce NAV through:

```solidity
writeDown(lossAmount)
```

Write-down order:

1. Junior loss;
2. Senior residual loss.

LP shares are not burned. The NAV decrease is reflected through ERC-4626 share price.

---

# 12. ERC-4626 Tranche Accounting

## 12.1 Accounted Assets

Each tranche overrides `totalAssets()` to return internal `accountedAssets`.

This represents:

* free cash;
* active receivable exposure;
* realized fee income;
* minus realized writedowns.

---

## 12.2 Locked Assets

Funding increases locked assets without reducing NAV.

```solidity
lockedAssets += tranchePrincipal;
```

Settlement or default resolution unlocks the original stored tranche principal.

```solidity
lockedAssets -= tranchePrincipal;
```

---

## 12.3 Available Liquidity

```solidity
availableLiquidity =
    accountedAssets - lockedAssets;
```

This value limits:

* new financing;
* withdrawals;
* redemptions.

---

## 12.4 Raw Cash Constraint

Withdrawals are additionally limited by the actual ERC-20 balance held by the tranche.

Therefore maximum withdrawal is bounded by:

* LP ownership;
* available accounting liquidity;
* raw cash balance.

---

## 12.5 Funding

`fundInvoice()` transfers cash to the Supplier but does not reduce `accountedAssets`.

The vault replaces cash with receivable exposure.

---

## 12.6 Fee Credit

`creditAssets()` is used only for incremental realized yield.

Before NAV increases, the tranche verifies that the corresponding cash backing exists.

Principal must not be credited twice.

---

## 12.7 Write-Down

`writeDown()` decreases `accountedAssets` without burning LP shares.

The corresponding locked position must first be unlocked.

---

## 12.8 Direct Token Transfers

A direct ERC-20 transfer to SeniorPool or JuniorPool does not automatically increase accounted NAV.

Only explicit protocol accounting functions modify `accountedAssets`.

---

# 13. Liquidity Architecture

Invoice financing creates a structural liquidity mismatch.

LP shares may represent valid NAV while the corresponding cash is deployed into illiquid invoice receivables.

This is an inherent property of the asset class.

## Liquidity Constraints

The following must hold:

```solidity
seniorLockedAssets <= seniorTotalAssets;
juniorLockedAssets <= juniorTotalAssets;
```

```solidity
totalLockedAssets =
    seniorLockedAssets + juniorLockedAssets;
```

```solidity
seniorAvailableLiquidity =
    seniorTotalAssets - seniorLockedAssets;
```

```solidity
juniorAvailableLiquidity =
    juniorTotalAssets - juniorLockedAssets;
```

Funding fails if either tranche cannot satisfy its required principal contribution.

Withdrawals fail if they would consume liquidity committed to unresolved positions.

---

# 14. Atomicity and CEI Requirements

Financing, settlement, and default resolution must be atomic.

The protocol uses checks-effects-interactions ordering:

* validate lifecycle and oracle conditions;
* close local accounting;
* perform external token and vault calls;
* update dependent protocol components;
* finalize InvoiceNFT lifecycle state.

If any external call fails, the entire transaction reverts.

This preserves consistency across:

* financing positions;
* aggregate locked assets;
* tranche locked assets;
* tranche NAV;
* Buyer exposure;
* InvoiceNFT lifecycle;
* token balances.

---

# 15. Security and Trust Assumptions

The protocol assumes:

* Originators submit genuine invoice data.
* Verifiers perform valid invoice review.
* Risk administrators configure economically reasonable parameters.
* Oracle Submitters report accurate off-chain outcomes.
* Dispute administrators act independently and within the dispute window.
* The underlying ERC-20 is non-rebasing and non-fee-on-transfer.
* Off-chain legal and servicing processes reconcile recovery assets correctly.
* Role-bearing accounts are secured.

The protocol does not independently prove:

* invoice authenticity;
* legal assignment;
* Buyer acceptance;
* absence of cross-protocol double financing;
* bank payment;
* recovered principal;
* legal enforceability.

These limitations are documented in `RISKS.md`.

---

# 16. Final Security Boundary

The v1 protocol separates three core responsibilities.

## Oracle

Attests:

* terminal invoice outcome;
* recovered principal for defaulted invoices.

## Pool

Validates and stores the finalized outcome, then executes:

* principal restoration;
* fee distribution;
* recovery allocation;
* tranche writedowns;
* Buyer exposure reduction;
* bad-debt recognition;
* terminal lifecycle transition.

## Executor

Supplies required assets and triggers accounting.

The executor cannot:

* choose status;
* choose recovery;
* change financing terms;
* override waterfalls;
* resolve twice.

This separation is the central accounting and authorization boundary of the protocol.

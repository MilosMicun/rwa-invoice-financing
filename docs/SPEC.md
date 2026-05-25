# RWA Invoice Financing Protocol Specification

## Overview

This document defines the core financial model, actors, state machine, accounting rules,
and liquidity architecture of the RWA Invoice Financing Protocol.

The protocol models invoice financing as an on-chain representation of real-world
receivables financing. Suppliers receive liquidity before invoice maturity, liquidity
providers fund senior and junior capital pools, and invoice settlement outcomes are
reported on-chain through permissioned oracle updates.

The goal of this specification is to define the system before implementation.

The smart contracts should be treated as an implementation of this specification,
not the other way around.

## v1 Scope and Non-Goals

The v1 protocol intentionally prioritizes deterministic accounting, explicit state
transitions, and auditability over feature completeness.

The following features are intentionally excluded from v1:

- Partial settlement states
- Secondary trading of invoice NFTs
- Dynamic interest rates
- Multi-oracle quorum settlement
- Automated legal enforcement
- Insurance reserves
- Refinancing or restructuring of invoices
- Epoch-based withdrawal queues
- Automated liquidation markets

These exclusions are intentional. The purpose of v1 is to model the core financial
machine clearly before adding production-level complexity.

## Core Invariants

- An invoice can be financed at most once.
- Only VERIFIED invoices can be funded.
- Only FUNDED invoices can be settled.
- Only FUNDED invoices can be defaulted.
- SETTLED and DEFAULTED invoices are terminal.
- Settlement and default execution are mutually exclusive.
- `totalLockedAssets` must never exceed `totalPoolAssets`.
- SeniorPool and JuniorPool must track locked assets independently.
- Funding must fail if either tranche lacks sufficient available liquidity.
- LP withdrawals must not reduce available liquidity below locked asset requirements.
- Freeze and unfreeze operations must not change economic accounting.
- Admin and OracleSubmitter roles must not bypass waterfall accounting.
- Oracle updates must be constrained by the invoice state machine.
- Waterfall execution must be deterministic for the same input values.

---

# 1. Actors and Roles

## Supplier

### Economic Role

The Supplier is the original creditor of the invoice receivable.

The Supplier transfers receivable exposure to the financing protocol in exchange for
immediate liquidity before the invoice maturity date.

Invoices submitted to the protocol are expected to represent valid off-chain payment
obligations accepted by the Buyer. In the Serbian market context, this may include
invoices registered and accepted through the SEF system.

Each financed invoice is represented by an NFT that models the receivable claim and
its lifecycle state within the protocol. The invoice NFT is not treated as simple
metadata storage, but as a financial position with explicit state transitions.

### Permissions

- Create invoice financing requests
- Submit invoices for protocol eligibility review
- Request financing against approved invoices
- Receive liquidity advances from the financing pool

### Cannot

- Update oracle settlement data
- Confirm invoice repayment status
- Trigger default resolution
- Freeze or unfreeze invoices
- Finance the same invoice more than once

The Supplier must never control settlement truth or default resolution, as this would
allow manipulation of protocol accounting and bad debt recognition.

### Main Risks

- Invoice rejection during eligibility review
- Buyer non-payment or delayed payment
- Invoice disputes
- Operational freezes
- Legal unenforceability of receivables
- Reduced financing advance rate
- Delayed liquidity access during protocol stress

---

## Buyer

### Economic Role

The Buyer is the off-chain payment obligor associated with an invoice financed by
the protocol.

The Buyer does not act as an on-chain protocol participant, but represents the
underlying credit exposure that determines invoice repayment, settlement completion,
and default risk.

The economic solvency of the protocol is directly influenced by Buyer payment behavior
and concentration exposure.

### Permissions

The Buyer has no direct on-chain permissions within the protocol.

Invoice repayment is expected to occur off-chain through traditional payment rails and
is later reflected on-chain through authorized oracle updates.

### Cannot

- Modify invoice lifecycle state
- Trigger settlement execution
- Update repayment status
- Modify invoice maturity terms
- Influence waterfall accounting logic

Off-chain payment obligors must never control on-chain settlement truth, as this would
compromise accounting integrity and bad debt recognition.

### Main Risks

- Payment default
- Delayed settlement
- Invoice disputes
- Buyer insolvency
- Jurisdictional enforcement failure
- Concentration risk from excessive exposure to a single Buyer

---

## Senior Liquidity Provider

### Economic Role

The Senior Liquidity Provider supplies conservative liquidity capital to the protocol
in exchange for lower-risk yield exposure.

Senior liquidity is deposited into the SeniorPool ERC-4626 vault and receives
repayment priority during recovery and default resolution flows.

Senior capital is economically protected by the Junior tranche, which absorbs
first-loss exposure before losses impact Senior liquidity providers.

Senior liquidity is protected, but not guaranteed.

### Permissions

- Deposit liquidity into the SeniorPool
- Receive ERC-4626 vault shares
- Redeem available liquidity that is not locked in active financing positions
- Accrue financing yield through waterfall distributions

### Cannot

- Select invoices for financing
- Control invoice valuation
- Modify oracle settlement data
- Withdraw liquidity locked in active invoice financing positions
- Influence waterfall accounting execution

Senior liquidity providers must not control underwriting or settlement truth, as this
would compromise pool neutrality and accounting integrity.

### Main Risks

- Residual bad debt after Junior tranche depletion
- Liquidity delays caused by locked financing positions
- Systemic Buyer defaults
- Concentration exposure to large Buyers
- Oracle failure or delayed settlement reporting
- Share price decline from protocol losses

---

## Junior Liquidity Provider

### Economic Role

The Junior Liquidity Provider supplies higher-risk liquidity capital to the protocol
in exchange for enhanced yield exposure.

Junior liquidity is deposited into the JuniorPool ERC-4626 vault and absorbs
first-loss exposure during default and bad debt events.

The Junior tranche economically protects Senior liquidity providers by absorbing
protocol losses before losses impact Senior capital.

In exchange for elevated risk exposure, Junior liquidity providers receive prioritized
financing fee participation within the waterfall structure.

### Permissions

- Deposit liquidity into the JuniorPool
- Receive ERC-4626 vault shares
- Redeem available liquidity not locked in active financing positions
- Accrue financing yield through waterfall distributions

### Cannot

- Select invoices for financing
- Control invoice valuation
- Modify oracle settlement data
- Withdraw liquidity locked in active financing positions
- Influence waterfall accounting execution

Junior liquidity providers must not control underwriting or settlement truth, as this
would compromise protocol neutrality and accounting integrity.

### Main Risks

- First-loss exposure during invoice defaults
- Junior NAV depletion during bad debt events
- Liquidity delays caused by locked financing positions
- Oracle failures or delayed settlement reporting
- Share price decline from protocol losses
- Concentration exposure to large Buyer defaults

---

## OracleSubmitter

### Economic Role

The OracleSubmitter acts as a permissioned off-chain reporting agent responsible for
synchronizing real-world invoice settlement events with on-chain accounting state
transitions.

Unlike traditional DeFi price oracles, the OracleSubmitter does not provide market
pricing data. Instead, it reports settlement status, default status, and invoice
dispute information associated with invoice financing positions.

The OracleSubmitter has the ability to mutate protocol accounting state through
authorized settlement and default updates, making oracle integrity a critical security
assumption of the system.

### Permissions

- Update invoice settlement status
- Mark invoices as paid, defaulted, or disputed
- Submit verified off-chain state transitions
- Trigger settlement-related accounting flows through valid state transitions

### Cannot

- Move LP funds directly
- Mint or burn liquidity shares
- Bypass invoice state machine restrictions
- Rewrite financed principal amounts
- Modify waterfall accounting logic manually
- Withdraw protocol liquidity
- Freeze or unfreeze invoices directly

OracleSubmitters must not have unrestricted administrative control, as oracle compromise
can economically corrupt protocol accounting integrity.

Freeze and unfreeze authority belongs to Admin / ProtocolOwner or an explicitly
authorized operational risk role, not to OracleSubmitter.

### Main Risks

- Oracle downtime
- Malicious settlement reporting
- Delayed settlement updates
- Collusion with Suppliers
- False default reporting
- Stale invoice state synchronization
- Legal mismatch between off-chain and on-chain settlement reality
- Unauthorized accounting state transitions

---

## Admin / ProtocolOwner

### Economic Role

The Admin / ProtocolOwner is responsible for constrained governance, protocol
configuration, operational risk management, and emergency coordination procedures.

Unlike fully permissionless DeFi systems, the protocol assumes limited administrative
authority to support legal enforceability, oracle coordination, operational freezes,
and eligibility controls required in real-world receivables financing.

The protocol architecture attempts to minimize direct custodial authority while
preserving bounded governance capabilities necessary for system integrity and
operational recovery.

### Permissions

- Configure protocol eligibility parameters
- Manage whitelist and blacklist controls
- Trigger emergency freezes and protocol pauses
- Freeze or unfreeze invoices through the operational risk process
- Assign or revoke oracle roles
- Update bounded system parameters
- Coordinate operational recovery procedures

### Cannot

- Fabricate settlement events
- Rewrite historical accounting state
- Arbitrarily mint LP assets
- Bypass waterfall accounting execution
- Seize LP liquidity directly
- Override invoice state machine invariants

Administrative authority must remain operationally constrained, as unrestricted
governance control would compromise accounting neutrality and protocol credibility.

### Main Risks

- Admin key compromise
- Governance capture
- Abusive operational freezes
- Parameter misconfiguration
- Oracle manipulation through governance abuse
- Excessive protocol centralization
- Regulatory intervention pressure
- Censorship risk

RWA protocols intentionally trade a degree of decentralization for legal enforceability
and operational coordination with off-chain systems.

---

# 2. SPV to Smart Contract Mapping

## InvoiceFinancingPool.sol → SPV Layer

InvoiceFinancingPool.sol acts as the on-chain equivalent of a Special Purpose Vehicle.

In traditional invoice financing, an SPV holds receivable exposure, finances Suppliers
against approved invoices, receives repayment flows, and distributes cash according to
a predefined capital structure.

In this protocol, InvoiceFinancingPool.sol performs the same economic role within the
smart contract system.

The pool finances approved invoices by advancing liquidity to the Supplier. In exchange,
the pool receives the economic claim to future repayment associated with the financed
receivable.

The pool is responsible for:

- Locking liquidity into active invoice financing positions
- Tracking financed principal
- Tracking invoice maturity and settlement status
- Receiving oracle-reported repayment outcomes
- Executing paid and default waterfall logic
- Releasing locked assets after settlement
- Recognizing losses when recovery is insufficient
- Accumulating realized credit losses through `totalBadDebt`

Legal enforcement and real-world collection actions remain off-chain. The smart contract
models the financial and accounting consequences of those outcomes, but does not itself
enforce legal claims.

---

## InvoiceNFT.sol → Receivable Claim Representation

InvoiceNFT.sol represents the receivable claim associated with an approved invoice
financing position.

Each invoice submitted to the protocol is represented by a unique NFT. The NFT is not
treated as collectible metadata, but as a financial position that tracks invoice
identity, lifecycle state, financing status, and settlement progression.

The NFT acts as the canonical source of truth for invoice lifecycle state. A single
invoice identifier must map to a single NFT and a single financing lifecycle.

This prevents the same invoice from being financed more than once at the state machine
level, rather than relying on off-chain process controls.

InvoiceNFT.sol is responsible for:

- Representing invoice identity
- Tracking invoice lifecycle state
- Linking on-chain invoice state to off-chain invoice references
- Preserving financing status
- Preventing double financing of the same invoice

InvoiceNFT.sol is not responsible for:

- Holding pooled liquidity
- Distributing repayment flows
- Executing waterfall accounting
- Calculating financing fees
- Recognizing pool-level bad debt

Those responsibilities belong to InvoiceFinancingPool.sol and the pool accounting layer.

---

## Lifecycle State vs Accounting State

The protocol separates lifecycle state from accounting state.

InvoiceNFT.sol is the canonical source of truth for invoice lifecycle state, including
invoice identity, current lifecycle state, frozen status, preserved financial state,
and whether the invoice has already been financed.

InvoiceFinancingPool.sol is the canonical source of truth for accounting state,
including financed principal, funding timestamp, due date, locked assets, fee
accounting, repayment outcomes, NAV effects, and bad debt recognition.

Every financing, settlement, default, freeze, and unfreeze operation must update the
relevant lifecycle and accounting state atomically within a single transaction.

If either the lifecycle update or the accounting update cannot be completed, the entire
transaction must revert.

This prevents divergence between invoice state and pool accounting.

---

## SeniorPool.sol / JuniorPool.sol → Capital Structure Tranches

SeniorPool.sol and JuniorPool.sol represent separate capital structure tranches within
the invoice financing protocol.

The SeniorPool provides lower-risk liquidity capital and is designed for liquidity
providers seeking more stable repayment priority. Senior capital receives priority
during recovery and default resolution flows, but remains exposed to residual losses
if Junior capital is fully depleted.

The JuniorPool provides higher-risk liquidity capital and acts as the first-loss
tranche of the system. Junior capital absorbs losses before Senior capital is affected,
providing economic protection to the SeniorPool.

In exchange for this elevated risk, Junior liquidity providers receive enhanced upside
through prioritized financing fee participation in the waterfall structure.

Both pools are modeled as ERC-4626 vaults. Liquidity providers deposit assets and
receive vault shares representing proportional ownership of each pool's net asset value.

If invoice defaults result in pool-level losses, the affected pool NAV is written down
and ERC-4626 share price naturally reflects that loss.

This tranche structure allows the protocol to separate risk and return profiles while
preserving deterministic accounting through vault share mechanics.

---

## OracleSubmitter → Settlement Reporting Layer

The OracleSubmitter represents the settlement reporting layer of the protocol.

In traditional invoice financing, repayment status, disputes, delays, and default events
are observed and reported by off-chain servicing, legal, or operational agents.

In this protocol, the OracleSubmitter maps off-chain settlement reality to authorized
on-chain invoice state transitions.

The OracleSubmitter reports settlement state, but does not own settlement logic.

It may trigger settlement-related flows only through valid state machine transitions.
It must not bypass invoice lifecycle rules, modify financed principal, change fee
calculations, or manually alter waterfall accounting.

Oracle integrity is a central trust assumption of the protocol. A stale, malicious, or
incorrect oracle update can corrupt accounting state, delay bad debt recognition,
release locked liquidity incorrectly, or cause incorrect NAV updates.

For this reason, oracle permissions must remain narrow, explicit, and constrained by
the invoice state machine.

---

## Admin / ProtocolOwner → Operational Governance Layer

The Admin / ProtocolOwner represents the operational governance layer required for
real-world invoice financing.

RWA systems require bounded administrative authority because invoice eligibility, legal
disputes, oracle coordination, and emergency procedures depend on off-chain operational
processes.

The Admin / ProtocolOwner is responsible for configuring protocol parameters, managing
eligibility rules, assigning or revoking oracle submitter roles, and triggering
emergency freezes or protocol pauses when required.

Admin authority may control protocol operations, but must not rewrite financial outcomes.

The Admin / ProtocolOwner must not fabricate settlement events, rewrite historical
accounting state, bypass waterfall logic, seize LP liquidity, or override invoice state
machine invariants.

This creates a deliberate trust model: the protocol accepts limited operational authority
for legal enforceability and emergency response, while constraining that authority from
becoming unrestricted control over user funds or accounting outcomes.

---

# 3. Invoice NFT State Machine

The Invoice NFT lifecycle is modeled as a deterministic state machine.

Each invoice may move only through explicitly allowed lifecycle transitions. Invalid
transitions must revert at the smart contract level and must not rely on off-chain
process controls.

The state machine exists to enforce financial correctness, prevent double financing,
preserve settlement integrity, and make every invoice lifecycle auditable.

The core financial states are:

- CREATED
- VERIFIED
- FUNDED
- SETTLED
- DEFAULTED

FROZEN is modeled as an operational/legal overlay rather than a final financial state.
Freezing an invoice must preserve the last valid financial state so that the invoice
can resume from that state after unfreeze.

A financed invoice must never return to a state where it can be financed again.
Double financing must be impossible at the state machine level.

---

## CREATED → VERIFIED

### Trigger

An authorized Admin or OracleSubmitter confirms that the submitted invoice is eligible
for financing.

This verification represents protocol acceptance that the invoice corresponds to a valid
off-chain receivable and may enter the financing lifecycle.

### Guard

- Invoice must exist
- Invoice must be in CREATED state
- Invoice must not already be verified
- Invoice must not already be financed
- Supplier must be eligible
- Buyer must be eligible
- Invoice reference must be unique
- Invoice must represent an accepted unpaid receivable

### Accounting Effects

- Invoice state changes from CREATED to VERIFIED
- Invoice becomes eligible for funding
- No liquidity is moved
- No locked assets are created

### Event

```solidity
event InvoiceVerified(
    uint256 indexed invoiceId,
    address indexed supplier,
    address indexed buyer
);
```

### Failure Mode Prevented

This transition prevents invalid, duplicated, disputed, or unaccepted invoices from
entering the financing lifecycle.

A non-verified invoice must never be eligible for funding.

---

## VERIFIED → FUNDED

### Trigger

The Supplier requests financing against a verified invoice, and the InvoiceFinancingPool
advances liquidity to the Supplier in exchange for the economic claim to future invoice
repayment.

This transition represents the moment when the invoice becomes an active financing
position and protocol liquidity becomes locked until settlement, default resolution,
or recovery.

### Guard

- Invoice must exist
- Invoice must be in VERIFIED state
- Invoice must not already be funded
- Invoice must not be frozen
- Protocol must not be paused
- Principal must be greater than zero
- Advance amount must respect the maximum advance rate
- Pool must have enough available liquidity in both required tranches
- Invoice due date must be in the future
- Invoice reference must remain unique
- Supplier and Buyer must remain eligible

### Accounting Effects

- Invoice state changes from VERIFIED to FUNDED
- Financed principal is recorded
- Senior financed principal is recorded
- Junior financed principal is recorded
- Funding timestamp is recorded
- Invoice due date is recorded
- Senior locked assets increase by the senior financed principal
- Junior locked assets increase by the junior financed principal
- Available liquidity decreases by the financed principal
- Supplier receives the advance liquidity

### Event

```solidity
event InvoiceFunded(
    uint256 indexed invoiceId,
    address indexed supplier,
    uint256 principal,
    uint256 seniorPrincipal,
    uint256 juniorPrincipal,
    uint256 fundedAt,
    uint256 dueDate
);
```

### Failure Mode Prevented

This transition prevents unverified invoices, duplicated invoices, expired invoices,
frozen invoices, or underfunded pool states from becoming active financing positions.

It also prevents the protocol from advancing liquidity without recording the
corresponding locked asset and financing obligation.

---

## FUNDED → SETTLED

### Trigger

An authorized OracleSubmitter reports that the Buyer has paid the financed invoice and
that the repayment amount is sufficient to fully settle the financing position.

This transition represents the successful completion of the invoice financing lifecycle.

### Guard

- Invoice must exist
- Invoice must be in FUNDED state
- Invoice must not be frozen
- Settlement must not already be executed
- Caller must be an authorized OracleSubmitter or Admin-controlled settlement role
- Reported paid amount must be greater than or equal to financed principal plus financing fee
- Partial settlement is not supported in v1: if reported payment is less than expected repayment, the invoice cannot transition to SETTLED and must be resolved through the default path using the reported amount as recovered amount

### Accounting Effects

- Invoice state changes from FUNDED to SETTLED
- Invoice is no longer an active financing position
- Locked liquidity is released
- Senior locked assets decrease by the senior financed principal
- Junior locked assets decrease by the junior financed principal
- Financing fee is calculated
- Principal is restored to the pool accounting system
- Financing fee is distributed according to the paid-path waterfall
- Any surplus above principal and financing fee is returned to the Supplier
- Settlement timestamp is recorded as `block.timestamp` at the time of the on-chain settlement call; oracle-reported off-chain timestamps are not used for protocol accounting
- Invoice cannot be funded, defaulted, or frozen again as an active position

### Event

```solidity
event InvoiceSettled(
    uint256 indexed invoiceId,
    uint256 paidAmount,
    uint256 principal,
    uint256 financingFee,
    uint256 juniorFee,
    uint256 seniorFee,
    uint256 settledAt
);
```

### Failure Mode Prevented

This transition prevents Suppliers, Buyers, or unauthorized actors from falsely marking
invoices as paid.

It also prevents double settlement, premature liquidity release, incorrect fee
distribution, and accounting corruption caused by settling invoices that are not active
funded positions.

---

## FUNDED → DEFAULTED

### Trigger

An authorized OracleSubmitter reports that the financed invoice failed to settle by
its due date or has become legally, operationally, or economically unrecoverable.

This transition represents failure of the financed receivable to repay the protocol
according to the expected settlement terms.

### Guard

- Invoice must exist
- Invoice must be in FUNDED state
- Invoice must not be frozen
- Caller must be an authorized OracleSubmitter or Admin-controlled default role
- Default must not already be executed
- Settlement must not already be executed
- Invoice due date must have passed, or an authorized dispute/default reason must exist
- Recovered amount must be less than or equal to the expected repayment amount

### Accounting Effects

- Invoice state changes from FUNDED to DEFAULTED
- Invoice becomes a terminal defaulted financing position
- Locked liquidity is released from the active financing bucket
- Senior locked assets decrease by the senior financed principal
- Junior locked assets decrease by the junior financed principal
- Expected repayment is calculated as financed principal plus financing fee
- Loss is calculated as expected repayment minus recovered amount
- Recovered amount is distributed according to the default-path waterfall
- JuniorPool absorbs first-loss exposure through NAV writedown
- SeniorPool absorbs residual loss if JuniorPool NAV is insufficient
- `totalBadDebt` increases by the realized credit loss recognized by the protocol
- Invoice cannot be settled, funded, or defaulted again

### Event

```solidity
event InvoiceDefaulted(
    uint256 indexed invoiceId,
    uint256 recoveredAmount,
    uint256 lossAmount,
    uint256 juniorLoss,
    uint256 seniorLoss,
    uint256 defaultedAt
);
```

### Failure Mode Prevented

This transition prevents defaulted invoices from remaining indefinitely as active
financing positions and prevents losses from being hidden outside pool accounting.

It also prevents unauthorized actors from declaring defaults, prevents double default
execution, and ensures that bad debt recognition follows the defined waterfall order.

---

## FROZEN Overlay

### Concept

FROZEN is not modeled as a terminal financial state.

FROZEN represents an operational, legal, or risk-control overlay applied to an invoice
that is otherwise in a valid financial lifecycle state.

An invoice may be frozen only from VERIFIED or FUNDED state.

Freezing an invoice must preserve the last valid financial state so that, after
unfreeze, the invoice resumes from the same lifecycle position.

This prevents freeze/unfreeze operations from resetting invoice economics, reopening
financing eligibility, or bypassing settlement/default rules.

### Allowed Freeze Sources

- VERIFIED → FROZEN overlay
- FUNDED → FROZEN overlay

### Not Allowed

- CREATED invoices cannot be frozen
- SETTLED invoices cannot be frozen
- DEFAULTED invoices cannot be frozen
- FROZEN must not be used to reset invoice lifecycle state
- FROZEN must not allow a funded invoice to become fundable again

### Trigger

An authorized Admin or operational risk role freezes an invoice due to legal dispute,
suspected fraud, oracle uncertainty, compliance concern, or operational investigation.

OracleSubmitter cannot directly freeze invoices.

### Guard

- Invoice must exist
- Invoice must be in VERIFIED or FUNDED state
- Invoice must not already be frozen
- Caller must be authorized Admin or operational risk role
- Freeze reason must be recorded

### Accounting Effects

- `isFrozen` is set to true
- Last valid financial state is preserved
- No financing fee is distributed
- No settlement waterfall is executed
- No default waterfall is executed
- No liquidity is released merely because of freeze
- If invoice is FUNDED, locked assets remain locked

### Event

```solidity
event InvoiceFrozen(
    uint256 indexed invoiceId,
    uint8 previousFinancialState,
    string reason,
    uint256 frozenAt
);
```

### Failure Mode Prevented

The freeze overlay prevents disputed, suspicious, or operationally uncertain invoices
from continuing through financing, settlement, or default flows until the issue is
resolved.

It also prevents legal or operational intervention from corrupting financial state.

---

## UNFREEZE Overlay

### Trigger

An authorized Admin or operational risk role resolves the freeze reason and restores
the invoice to its preserved financial state.

OracleSubmitter cannot directly unfreeze invoices.

### Guard

- Invoice must exist
- Invoice must be frozen
- Caller must be authorized Admin or operational risk role
- Preserved financial state must be VERIFIED or FUNDED
- Freeze reason must be resolved

### Accounting Effects

- `isFrozen` is set to false
- Invoice resumes from the preserved financial state
- No principal, fee, NAV, or locked liquidity accounting is changed merely by unfreeze
- If the preserved state was VERIFIED, the invoice may continue toward funding
- If the preserved state was FUNDED, the invoice may continue toward settlement or default

### Event

```solidity
event InvoiceUnfrozen(
    uint256 indexed invoiceId,
    uint8 restoredFinancialState,
    uint256 unfrozenAt
);
```

### Failure Mode Prevented

Unfreeze prevents operational freezes from becoming permanent accounting deadlocks
while ensuring that freeze resolution cannot reset financial history, reopen
settled/defaulted invoices, or bypass normal lifecycle transitions.

---

## Terminal States

SETTLED and DEFAULTED are terminal financial states.

Once an invoice reaches SETTLED, it represents a successfully completed financing
lifecycle. The invoice must not be funded, defaulted, frozen, or settled again.

Once an invoice reaches DEFAULTED, it represents a completed default resolution
lifecycle. The invoice must not be funded, settled, frozen, or defaulted again.

Terminal states exist to prevent double settlement, double default execution, liquidity
re-release, bad debt manipulation, and reopening of completed financial positions.

---

## Forbidden Transitions

The following transitions must be impossible at the smart contract level:

- CREATED → FUNDED
- CREATED → SETTLED
- CREATED → DEFAULTED
- CREATED → FROZEN
- VERIFIED → SETTLED
- VERIFIED → DEFAULTED
- FUNDED → VERIFIED
- FUNDED → CREATED
- SETTLED → any state
- DEFAULTED → any state
- FROZEN → SETTLED without unfreeze
- FROZEN → DEFAULTED without unfreeze
- FROZEN → FUNDED if the preserved state was already FUNDED
- Any invoice → FUNDED more than once

These forbidden transitions enforce that invoice financing is linear, auditable, and
irreversible after settlement or default.

State machine correctness must not depend on frontend behavior, off-chain operators,
or manual process discipline. Invalid transitions must revert inside the smart contract.

---

## State Machine Invariants

- Only VERIFIED invoices may be funded.
- Only FUNDED invoices may be settled.
- Only FUNDED invoices may be defaulted.
- SETTLED invoices are terminal.
- DEFAULTED invoices are terminal.
- A funded invoice must never become fundable again.
- An invoice must never be financed more than once.
- Freeze and unfreeze operations must not change principal, fee, NAV, or locked liquidity accounting.
- A frozen invoice must resume from its preserved financial state after unfreeze.
- Settlement and default execution must be mutually exclusive.

---

# 4. Financing Fee Model

The protocol charges a financing fee for advancing liquidity to Suppliers before
invoice maturity.

The financing fee compensates liquidity providers for committing capital to illiquid
invoice financing positions and taking payment delay, default, and liquidity mismatch
risk.

Without a financing fee model, the system would behave like an escrow service rather
than a credit protocol.

## Fee Formula

The v1 protocol uses a fixed APR model applied linearly over the full invoice tenure.

```solidity
financingFee = principal * aprBps * (dueDate - fundedAt) / 365 days / 10_000;
```

Where:

- `principal` is the financed amount advanced to the Supplier
- `aprBps` is the annualized financing rate expressed in basis points
- `fundedAt` is the timestamp when the invoice becomes funded
- `dueDate` is the expected invoice maturity date
- `dueDate - fundedAt` is the invoice financing duration
- `365 days` resolves to `31_536_000` seconds; leap years are ignored in v1

## APR Configuration

`aprBps` is a protocol-level configuration parameter in v1.

It may be updated by Admin only within bounded governance limits.

Future versions may support per-Buyer, per-invoice, or risk-adjusted APR models.

## Early Settlement Treatment

The v1 protocol calculates financing fee using the full invoice tenor from `fundedAt`
to `dueDate`.

Early repayment does not reduce the financing fee in v1.

This makes the fee deterministic at funding time and avoids settlement-time fee
ambiguity.

## Model Assumptions

The v1 fee model intentionally uses simple linear APR rather than compounding.

This is acceptable because invoice financing positions have fixed maturities, defined
tenors, and do not continuously roll interest like open-ended lending markets.

The fee is known at funding time and can be deterministically calculated from
principal, APR, funding timestamp, and due date.

## Accounting Treatment

The financing fee is not paid upfront.

It is realized during settlement when the Buyer repayment is reported and the invoice
transitions from FUNDED to SETTLED.

Upon successful settlement:

- Principal releases locked liquidity
- Financing fee is distributed through the paid-path waterfall
- JuniorPool receives its configured fee share
- SeniorPool receives the remaining fee according to the waterfall rules
- Any surplus above principal and financing fee is returned to the Supplier

If the invoice defaults, unrealized financing fee may not be fully collected. Default
handling is governed by the default-path waterfall.

---

# 5. Waterfall Logic

Waterfall logic defines the deterministic order in which repayment cash flows, fees,
recoveries, and losses are allocated between protocol participants.

The protocol uses different waterfall rules for successful settlement and default
resolution.

Waterfall execution must be rule-based and must not depend on discretionary decisions
from Suppliers, Buyers, LPs, OracleSubmitters, or Admins.

The purpose of waterfall logic is to make repayment and loss allocation explicit,
auditable, and resistant to manipulation.

## Paid Path

The paid path is executed when a funded invoice is reported as fully paid and
transitions from FUNDED to SETTLED.

Expected repayment is defined as:

```solidity
expectedRepayment = principal + financingFee;
```

If the reported paid amount exceeds expected repayment, the surplus is returned to
the Supplier:

```solidity
surplus = paidAmount - expectedRepayment;
```

## Fee Split

The v1 protocol uses a fixed financing fee split between JuniorPool and SeniorPool.

```solidity
juniorFee = financingFee * juniorFeeShareBps / 10_000;
seniorFee = financingFee - juniorFee;
```

The following invariant must always hold:

```solidity
juniorFeeShareBps + seniorFeeShareBps == 10_000;
```

JuniorPool receives enhanced relative upside because it absorbs first-loss exposure.

SeniorPool receives the remaining fee participation in exchange for providing lower-risk,
repayment-priority capital.

Fee share parameters are protocol-level configuration values and may only be updated
by Admin within bounded governance limits.

## Paid-Path Allocation

Repayment allocation follows this order:

1. Financed principal releases locked liquidity
2. `juniorFee` is distributed to JuniorPool
3. `seniorFee` is distributed to SeniorPool
4. Any surplus above principal and financing fee is returned to the Supplier

The paid-path waterfall ensures that LP yield is earned only when repayment is actually
realized.

## Default Path

The default path is executed when a funded invoice fails to fully settle and transitions
from FUNDED to DEFAULTED.

Default resolution allocation follows this order:

1. Recovered amount is allocated to SeniorPool first
2. Unrecovered loss is absorbed by JuniorPool first through NAV writedown
3. If JuniorPool NAV is insufficient, SeniorPool absorbs the residual loss
4. Realized credit losses are recorded in `totalBadDebt`

JuniorPool acts as the first-loss tranche and protects SeniorPool until Junior capital
is depleted.

SeniorPool is protected by JuniorPool but is not risk-free. Extreme defaults,
concentrated Buyer exposure, or insufficient Junior capital can still result in
SeniorPool losses.

`totalBadDebt` tracks cumulative realized credit losses recognized by the protocol.
It is a protocol-level accounting metric and must not be reset during normal protocol
operation.

Per-tranche loss attribution is available through `InvoiceDefaulted` event logs, which
record `juniorLoss` and `seniorLoss` separately for each default event.

## Partial Payment Handling

Partial settlement states are not supported in v1.

If `paidAmount` is less than `expectedRepayment`, the invoice cannot transition to
SETTLED.

The invoice must be resolved through the default path, with the reported amount treated
as `recoveredAmount`.

This keeps the state machine deterministic and avoids introducing a separate
PARTIALLY_SETTLED state in v1.

## Waterfall Invariants

- Paid-path execution must happen only once per invoice.
- Default-path execution must happen only once per invoice.
- Settlement and default execution must be mutually exclusive.
- JuniorPool receives its configured fee share in the paid path.
- SeniorPool receives its configured remaining fee share in the paid path.
- JuniorPool absorbs first-loss exposure in the default path.
- SeniorPool receives recovery priority in the default path.
- SeniorPool absorbs losses only after JuniorPool is depleted.
- `totalBadDebt` must never decrease during normal protocol operation.
- Waterfall execution must not be manually overridden by Admin or OracleSubmitter.
- Waterfall accounting must be deterministic for the same input values.

---

# 6. Pool Token Architecture

The protocol uses ERC-4626 vaults for both SeniorPool and JuniorPool.

Each pool accepts liquidity deposits and issues vault shares representing proportional
ownership of that pool's net asset value.

This design makes LP accounting explicit, composable, and consistent with existing
DeFi vault standards.

## SeniorPool

SeniorPool represents the lower-risk capital tranche.

Senior liquidity providers deposit assets into the SeniorPool and receive ERC-4626
shares representing ownership of SeniorPool NAV.

SeniorPool receives repayment priority during default resolution flows, but may still
absorb residual losses if JuniorPool capital is fully depleted.

## JuniorPool

JuniorPool represents the higher-risk first-loss capital tranche.

Junior liquidity providers deposit assets into the JuniorPool and receive ERC-4626
shares representing ownership of JuniorPool NAV.

JuniorPool absorbs first-loss exposure during default events and receives prioritized
financing fee participation during successful settlement.

## NAV and Share Price

Pool losses are reflected through NAV writedowns.

When a pool absorbs loss, its accounting total assets decrease. Because ERC-4626 share
price is derived from total assets divided by total shares, losses naturally reduce
share price without requiring a separate LP accounting system.

This is the core reason ERC-4626 is used in this architecture.

The protocol does not need to manually track each LP's loss allocation. LP exposure
is represented through vault share ownership.

## NAV Writedown Mechanism

NAV writedowns are executed through restricted pool accounting functions callable
only by InvoiceFinancingPool during default resolution.

These functions reduce pool-accounted assets without burning LP shares, causing
ERC-4626 share price to reflect realized losses.

Pool writedown functions must not be callable by Suppliers, Buyers, LPs,
OracleSubmitters, or arbitrary Admin actions outside the defined default resolution
flow.

This ensures that losses become visible through vault share price while preventing
discretionary manipulation of LP balances.

## Design Tradeoff

Using ERC-4626 introduces known share price manipulation risks, especially when vaults
are small or early in their lifecycle.

For this portfolio implementation, this tradeoff is accepted and documented.

The protocol prioritizes clear vault-based accounting, composability, and consistency
with the previous lending protocol architecture over building a custom share accounting
system.

Future production versions would require additional mitigations such as:

- Minimum initial liquidity
- Virtual shares / virtual assets
- Deposit caps during early pool bootstrap
- Stricter oracle and settlement controls
- Withdrawal queue mechanics

---

# 7. Liquidity Architecture

Invoice financing creates a structural liquidity mismatch.

LP shares in this protocol are redeemable, but underlying assets may be locked inside
active invoice financing positions until settlement, default resolution, or recovery
completion.

Unlike DeFi lending pools where collateral and debt positions may be continuously
rebalanced or liquidated, invoice receivables are illiquid by design. They mature at
fixed future dates and depend on off-chain Buyer repayment.

This means liquidity providers may not always be able to withdraw their full share
value immediately, even if their ERC-4626 shares represent valid ownership of pool NAV.

This is not a bug. It is the fundamental characteristic of invoice financing: capital
is committed for the duration of the invoice tenor.

## Available Liquidity

The protocol distinguishes between total pool assets and assets locked in active
financing positions.

```solidity
availableLiquidity = totalPoolAssets - totalLockedAssets;
```

Where:

- `totalPoolAssets` represents total assets controlled by the pool accounting system
- `totalLockedAssets` represents capital committed to active funded invoices
- `availableLiquidity` represents the amount that may be used for new financing or withdrawals

Withdrawals must be limited by available liquidity.

A liquidity provider may only redeem assets that are not currently locked inside active
invoice financing positions.

## Senior and Junior Liquidity Buckets

SeniorPool and JuniorPool are separate ERC-4626 vaults with separate liquidity, locked
asset accounting, NAV, and share price.

InvoiceFinancingPool coordinates financing across both pools according to a fixed
capital allocation ratio.

```solidity
seniorPrincipal = principal * seniorFundingShareBps / 10_000;
juniorPrincipal = principal - seniorPrincipal;
```

The following invariant must always hold:

```solidity
seniorFundingShareBps + juniorFundingShareBps == 10_000;
```

Each pool must have enough available liquidity before an invoice can be funded:

```solidity
seniorAvailableLiquidity >= seniorPrincipal;
juniorAvailableLiquidity >= juniorPrincipal;
```

When an invoice is funded:

```solidity
seniorLockedAssets += seniorPrincipal;
juniorLockedAssets += juniorPrincipal;
```

When an invoice is settled or defaulted:

```solidity
seniorLockedAssets -= seniorPrincipal;
juniorLockedAssets -= juniorPrincipal;
```

The split recorded at funding time is used for all subsequent settlement, default, and
locked asset release calculations. Changes to `seniorFundingShareBps` after funding do
not affect active positions.

This architecture preserves separate ERC-4626 accounting while allowing the
InvoiceFinancingPool to act as the coordinating SPV layer.

## Locked Assets

When an invoice transitions from VERIFIED to FUNDED, the financed principal becomes
locked across the SeniorPool and JuniorPool according to the configured funding share.

When an invoice transitions from FUNDED to SETTLED or DEFAULTED, locked assets are
released from the active financing bucket.

Locked assets prevent the protocol from treating deployed capital as freely withdrawable
liquidity.

## Withdrawal Constraints

LP withdrawals must respect the available liquidity constraint.

If pool liquidity is fully deployed into active invoices, withdrawal requests may need
to wait until invoices settle, default, or recover.

The v1 protocol enforces this by reverting withdrawals that exceed available liquidity.

Future versions may introduce withdrawal queues, epoch-based redemptions, or liquidity
reserve buffers.

## Oracle Timeout Limitation

The v1 protocol does not include an automatic timeout mechanism for unresolved funded
invoices.

If OracleSubmitter never reports settlement, default, dispute, or operational
resolution, a FUNDED invoice may remain active and locked until an authorized update
is submitted.

This is a known v1 limitation and reinforces the importance of oracle availability,
operational monitoring, and bounded emergency controls.

Future versions may introduce time-based escalation paths, automated grace periods,
or dispute-resolution workflows.

## Liquidity Invariants

- `totalLockedAssets` must never exceed `totalPoolAssets`.
- `availableLiquidity` must never be negative.
- SeniorPool and JuniorPool must track locked assets independently.
- Funding an invoice must increase SeniorPool and JuniorPool locked assets according to the configured funding share.
- Settling an invoice must decrease SeniorPool and JuniorPool locked assets according to the original financed split.
- Defaulting an invoice must decrease SeniorPool and JuniorPool locked assets according to the original financed split.
- Funding must fail if either tranche lacks sufficient available liquidity.
- Senior and Junior funding shares must sum to 10,000 basis points.
- LP withdrawals must not reduce pool liquidity below locked asset requirements.
- Locked assets must not be withdrawn while invoices remain active.
- Liquidity constraints must apply independently to SeniorPool and JuniorPool accounting.
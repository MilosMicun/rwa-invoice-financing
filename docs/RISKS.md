# RWA Invoice Financing Protocol — Risks and Security Assumptions

## Purpose

This document records the protocol's security findings, trust assumptions, known limitations, and accepted v1 design risks.

The protocol coordinates on-chain accounting for real-world invoice financing. It cannot independently verify invoice validity, buyer payment, legal enforceability, or recovered amounts. These facts originate off-chain and enter the protocol through explicitly authorized actors.

The objective of this document is not to claim that the protocol is trustless. It is to define where trust exists, constrain its authority, and ensure that trusted actors cannot bypass deterministic accounting rules.

---

# 1. Severity Classification

## Critical

A vulnerability that may directly enable:

* theft or permanent loss of a substantial portion of protocol assets;
* arbitrary corruption of protocol-wide accounting;
* permanent loss of control over core contracts;
* complete bypass of fundamental authorization boundaries.

## High

A vulnerability that may enable:

* material loss or incorrect writedown of LP capital;
* unauthorized terminal lifecycle transitions;
* manipulation of bad-debt recognition;
* corruption of a major protocol accounting boundary.

## Medium

A vulnerability that may cause:

* temporary loss of protocol availability;
* accounting inconsistencies under constrained conditions;
* violation of secondary protocol invariants;
* material griefing without direct asset theft.

## Low

A limited-impact issue involving:

* narrow edge cases;
* non-critical liveness problems;
* incomplete validation with limited economic impact;
* behavior that is recoverable through normal operations.

## Informational

A non-exploitable observation involving:

* code clarity;
* documentation;
* event completeness;
* operational assumptions;
* defense-in-depth improvements.

---

# 2. Resolved Security Findings

## H-01 — Caller-Controlled Default Recovery Amount

**Severity:** High
**Status:** Resolved
**Affected component:** `InvoiceFinancingPool.resolveDefault()`
**Discovered during:** Fuzz and invariant design review

### Original Design

The original default execution function accepted the recovered amount directly from the execution caller:

```solidity
function resolveDefault(
    uint256 invoiceId,
    uint256 recoveredAmount
) external;
```

The oracle finalized only the terminal `DEFAULTED` status.

After finalization, any address could call `resolveDefault()` and select the recovery amount used by the waterfall.

### Root Cause

The protocol incorrectly split one off-chain economic outcome across two trust domains:

* the authorized oracle determined whether the invoice had defaulted;
* the permissionless executor determined how much principal had been recovered.

Recovered principal is an off-chain financial fact. It is not an execution preference and must not be controlled by an arbitrary transaction sender.

### Impact

After a legitimate `DEFAULTED` oracle outcome, an arbitrary caller could submit a lower recovery amount, including zero.

This could have caused the protocol to:

* recognize excessive principal loss;
* write down JuniorPool NAV unnecessarily;
* write down SeniorPool NAV after Junior depletion;
* increase `totalBadDebt` beyond the actual realized principal loss;
* mark the financing position permanently resolved;
* prevent the actual recovered amount from being accounted for later.

The caller did not directly receive stolen assets, but could permanently corrupt tranche NAV and bad-debt accounting.

### Remediation

The oracle outcome now includes both:

* the finalized terminal status;
* the oracle-attested recovered principal.

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

The pool callback records the complete finalized outcome:

```solidity
function onStatusFinalized(
    uint256 invoiceId,
    IInvoiceNFT.InvoiceStatus status,
    uint256 recoveredAmount
) external;
```

The pool requires that:

* a financed position already exists;
* `SETTLED` outcomes use zero recovery;
* `DEFAULTED` recovery does not exceed stored principal;
* finalized outcomes cannot be overwritten.

Default execution no longer accepts a caller-controlled recovery parameter:

```solidity
function resolveDefault(uint256 invoiceId) external;
```

The function reads recovery exclusively from:

```solidity
finalizedRecoveryAmount[invoiceId]
```

The executor may trigger deterministic accounting but cannot select or modify the economic outcome.

### Regression Coverage

The integration suite includes:

```text
test_ResolveDefault_CannotExecuteWithLessThanOracleFinalizedRecovery
```

The test verifies that:

* the oracle finalizes a non-zero recovered amount;
* an underfunded executor cannot resolve the position with fewer assets;
* the position remains active after the failed attempt;
* locked assets remain unchanged;
* buyer exposure remains unchanged;
* `totalBadDebt` remains unchanged;
* resolution succeeds only when the full oracle-finalized recovery is supplied;
* realized bad debt equals principal minus finalized recovered principal.

### Residual Risk

The remediation prevents arbitrary executors from changing recovery, but the authorized oracle may still submit an incorrect amount.

Oracle integrity therefore remains an explicit protocol trust assumption.

A production deployment should use stronger operational controls such as:

* independent servicing and oracle roles;
* multisig-controlled submitters;
* multiple independent data sources;
* auditable bank or payment-rail reconciliation;
* dispute escalation procedures;
* recovery escrow or collection accounts;
* multi-oracle quorum confirmation.

---

# 3. Oracle and Off-Chain Truth Risk

## R-01 — Malicious or Incorrect Oracle Reporting

**Severity:** High
**Status:** Accepted v1 trust assumption

The protocol cannot independently verify:

* whether an invoice was paid;
* whether a buyer defaulted;
* how much principal was recovered;
* whether an off-chain dispute is valid;
* whether a legal collection process has concluded.

The authorized oracle may submit a false terminal outcome or an incorrect recovered amount.

### Existing Mitigations

* permissioned `ORACLE_SUBMITTER_ROLE`;
* explicit `SETTLED` and `DEFAULTED` status restriction;
* dispute window before finalization;
* maximum staleness limit;
* permissionless finalization only after timing checks;
* immutable finalized outcomes;
* pool-side validation of recovery against stored principal;
* oracle cannot directly execute tranche accounting;
* oracle cannot directly mutate InvoiceNFT lifecycle state.

### Residual Risk

A validly authorized but malicious oracle can still corrupt economic truth.

This cannot be fully solved by Solidity because the underlying facts exist off-chain.

---

## R-02 — Oracle Downtime and Locked Capital

**Severity:** Medium
**Status:** Accepted v1 limitation

A funded invoice remains active until an authorized terminal outcome is submitted and finalized.

If the oracle becomes unavailable:

* the InvoiceNFT remains `FUNDED`;
* tranche capital remains locked;
* buyer exposure remains active;
* LP withdrawals remain constrained by available liquidity;
* settlement or default accounting cannot execute.

### Existing Mitigations

* permissionless finalization after submission;
* bounded dispute and staleness windows;
* admin ability to manage oracle roles through the oracle access-control system.

### Production Considerations

A production version may require:

* multiple submitters;
* fallback oracle procedures;
* governance-controlled oracle replacement;
* timeout escalation;
* emergency servicing workflows;
* automated maturity and grace-period monitoring.

---

# 4. Administrative and Governance Risk

## R-03 — Admin Key Compromise

**Severity:** High
**Status:** Accepted trust assumption

Administrative authority controls or participates in:

* protocol deployment configuration;
* risk parameter updates;
* buyer denylist management;
* role assignment;
* oracle configuration;
* operational risk controls.

A compromised administrator could weaken underwriting parameters, assign malicious roles, or disrupt protocol operation.

### Existing Mitigations

* operational roles are explicitly separated;
* the InvoiceNFT admin does not automatically receive all operational roles;
* oracle assignment in `InvoiceFinancingPool` is set only once;
* accounting waterfalls cannot be manually overridden by admin functions;
* loss and fee allocation remain deterministic.

### Production Considerations

Production deployments should use:

* multisig administration;
* timelocked parameter changes;
* separate risk, oracle, and emergency committees;
* bounded parameter updates;
* monitored role changes;
* emergency role revocation procedures.

---

## R-04 — Risk Parameter Misconfiguration

**Severity:** Medium
**Status:** Partially mitigated

Incorrect parameters may cause:

* excessive buyer exposure;
* overly high advance rates;
* insufficient fee compensation;
* financing of long-tenor invoices;
* financing of economically insignificant invoices.

### Existing Mitigations

* non-zero parameter validation;
* maximum advance rate;
* maximum financing fee APR;
* separate invoice eligibility and concentration checks;
* buyer exposure tracked against financed principal;
* risk parameter changes do not retroactively change stored active positions.

### Residual Risk

Permitted values may still be economically unsafe even when technically within contract bounds.

Smart contracts enforce limits, not underwriting quality.

---

# 5. Freeze and Operational Risk

## R-05 — Funded Invoice Freeze Can Delay Resolution

**Severity:** Medium
**Status:** Accepted operational tradeoff

An authorized risk role may freeze a funded invoice.

While frozen:

* settlement execution is blocked;
* default execution is blocked;
* locked assets remain locked;
* buyer exposure remains active;
* finalized oracle outcomes may exist but cannot be consumed.

This prevents disputed or legally uncertain invoices from progressing through accounting, but it can also delay LP liquidity.

### Existing Mitigations

* only `VERIFIED` and `FUNDED` invoices may be frozen;
* previous financial state is preserved;
* freeze and unfreeze do not change principal, NAV, fee, or exposure accounting;
* unfreeze restores the preserved lifecycle state;
* terminal invoices cannot be frozen.

### Residual Risk

A malicious or unavailable risk administrator may keep an active invoice frozen indefinitely.

A production version should record freeze reasons, introduce monitoring, and define governance escalation procedures.

---

# 6. Liquidity and ERC-4626 Risks

## R-06 — Structural Liquidity Mismatch

**Severity:** Medium
**Status:** Inherent protocol property

Invoice financing deploys liquid LP capital into illiquid real-world receivables.

ERC-4626 shares may represent valid NAV while the corresponding assets remain locked in active financing positions.

### Existing Mitigations

* separate `accountedAssets` and `lockedAssets`;
* `availableLiquidity = totalAssets - lockedAssets`;
* withdrawals are bounded by both available liquidity and actual token balance;
* SeniorPool and JuniorPool enforce liquidity independently;
* funding reverts if either tranche lacks sufficient liquidity.

### Residual Risk

LPs may be unable to withdraw the full value of their shares until active invoices settle or default.

This is not an implementation bug. It is an inherent characteristic of invoice financing.

---

## R-07 — ERC-4626 Rounding and Dust

**Severity:** Low
**Status:** Accepted v1 limitation

ERC-4626 conversions may create small rounding differences when:

* depositing;
* withdrawing;
* minting;
* redeeming;
* calculating share value after yield or loss.

Small residual shares or asset dust may remain after full-value withdrawals.

### Existing Mitigations

* OpenZeppelin Contracts v5.6.1 ERC-4626 conversions include one virtual asset and `10 ** _decimalsOffset()` virtual shares;
* SeniorPool and JuniorPool inherit the default `_decimalsOffset()` of zero, so the current conversion uses one virtual share;
* accounting assertions use explicit rounding-aware boundaries where required;
* integration tests accept minimal residual dust after profitable withdrawal.

The existing virtual asset/share mechanism mitigates donation and first-depositor manipulation risk but does not completely eliminate it or all rounding and dust effects.

### Production Considerations

A production deployment may additionally use:

* a larger `_decimalsOffset()`;
* minimum deposit amounts;
* initial locked liquidity;
* explicit dust-handling rules;
* deposit and withdrawal caps.

---

## R-08 — Direct Token Donations Do Not Automatically Increase NAV

**Severity:** Informational
**Status:** Intentional design behavior

SeniorPool and JuniorPool use internal `accountedAssets` as the ERC-4626 NAV source.

Directly transferring underlying tokens to a tranche vault does not automatically increase `totalAssets()`.

This prevents raw token balance from becoming the accounting source of truth but means unsolicited donations may remain outside accounted LP NAV.

### Existing Mitigations

* authorized `creditAssets()` is used for realized yield;
* crediting NAV requires sufficient token backing;
* financing does not reduce NAV merely because cash leaves the vault;
* losses are recognized explicitly through `writeDown()`.

### Residual Risk

Unexpected direct transfers may become unaccounted excess cash unless a future governance or reconciliation mechanism is introduced.

---

# 7. Tranche and Waterfall Risks

## R-09 — Junior Capital Does Not Guarantee Senior Protection

**Severity:** Informational
**Status:** Intended economic behavior

JuniorPool is the first-loss tranche, but SeniorPool is not risk-free.

If realized loss exceeds junior exposure for a financing position, SeniorPool absorbs the residual loss.

### Existing Mitigations

* recovery is allocated to SeniorPool first;
* JuniorPool absorbs losses first;
* SeniorPool loss is recognized only after junior loss allocation;
* funding split is stored per position;
* default allocation is deterministic.

---

## R-10 — Unpaid Financing Fee Is Not Recorded as Bad Debt

**Severity:** Informational
**Status:** Intentional accounting policy

`totalBadDebt` tracks cumulative realized financed-principal loss:

```text
principal loss = financed principal - recovered principal
```

Unpaid financing fees are excluded because they were never recognized as tranche NAV.

### Rationale

Recording unpaid expected yield as bad debt would overstate realized capital loss and mix:

* loss of deployed principal;
* failure to realize expected income.

Per-position financing fee remains stored for auditability, but default bad debt represents principal impairment only.

---

## R-11 — Small Principal or Extreme Funding Share Configuration

**Severity:** Low
**Status:** Mitigated in code

The protocol requires both tranche vaults to lock non-zero asset amounts.

With extreme non-zero funding-share parameters or a sufficiently small principal, one tranche split can round to zero. `financeInvoice()` now rejects a calculated zero tranche principal before either vault is called.

### Existing Mitigations

* the constructor rejects zero Senior or Junior funding shares while preserving the requirement that their sum equals `10,000` BPS;
* `financeInvoice()` rejects a calculated zero Senior or Junior tranche principal;
* the current test configuration uses non-zero `70/30` funding shares;
* deployment-configured minimum invoice amount and bounded advance rate may reduce dust-sized positions, but they do not independently guarantee a non-zero allocation to both tranches.

### Production Considerations

The deployment script is not yet complete. The repository therefore does not provide evidence of an actual deployed `70/30` configuration.

Production configuration should additionally consider:

* minimum financed principal per tranche;
* the relationship among funding shares, minimum invoice amount, and advance rate.

---

# 8. Concentration and Credit Risks

## R-12 — Buyer Concentration Risk

**Severity:** High economic risk
**Status:** Mitigated but not eliminated

Multiple invoices may expose the protocol to the same buyer.

A large buyer default can create correlated tranche losses.

### Existing Mitigations

* active buyer exposure tracking;
* maximum exposure per buyer;
* concentration checked separately from intrinsic invoice eligibility;
* exposure increases atomically during financing;
* exposure decreases only after settlement or default resolution;
* exposure uses financed principal rather than invoice face value.

### Residual Risk

The configured concentration limit may still be economically excessive.

The contract cannot assess broader off-chain relationships between apparently distinct buyers.

---

## R-13 — Invoice Validity and Double-Financing Outside the Registry

**Severity:** High off-chain risk
**Status:** Accepted trust assumption

InvoiceNFT prevents the same on-chain invoice identifier from being financed more than once.

It cannot independently prove that:

* two different invoice IDs do not represent the same off-chain receivable;
* the same invoice was not financed through another protocol or lender;
* invoice documentation is genuine;
* the buyer accepted the obligation;
* the receivable remains legally enforceable.

### Existing Mitigations

* originator and verifier role separation;
* explicit invoice lifecycle;
* supplier-only financing request;
* non-transferable invoice NFT;
* on-chain prevention of repeat funding for the same invoice ID.

### Production Considerations

Production systems require:

* unique off-chain invoice references;
* SEF or equivalent registry reconciliation;
* lender and factoring database checks;
* legal assignment verification;
* document hashing and audit trails;
* fraud monitoring.

---

# 9. Execution and Token Risks

## R-14 — Resolver Must Supply Oracle-Finalized Recovery Tokens

**Severity:** Medium operational risk
**Status:** Accepted v1 execution model

Default execution is permissionless, but the caller must hold and approve the exact oracle-finalized recovered amount.

This separates economic truth from execution authority, but a random keeper has no incentive to supply recovery funds from its own balance.

### Existing Behavior

* the caller cannot reduce the recovery amount;
* insufficient token balance or allowance causes the whole transaction to revert;
* accounting remains unchanged after failed execution.

### Production Considerations

A production architecture should preferably route recovered funds through:

* a servicing account;
* a dedicated recovery escrow;
* a collection contract;
* a prefunded settlement account.

After funds are escrowed, any keeper could execute accounting without financing the recovery personally.

---

## R-15 — Underlying Asset Assumptions

**Severity:** Medium
**Status:** Accepted v1 assumption

The protocol assumes a standard ERC-20 asset.

Non-standard tokens may break accounting, including tokens with:

* transfer fees;
* rebasing behavior;
* callback hooks;
* blacklist mechanics;
* pausable transfers;
* non-standard return values beyond SafeERC20 compatibility.

### Existing Mitigations

* OpenZeppelin `SafeERC20`;
* explicit token-balance backing checks in tranche vaults.

### Production Considerations

Production deployment should use a reviewed, non-rebasing, non-fee-on-transfer settlement asset.

---

# 10. Testing and Verification Scope

The current suite includes:

* constructor and role validation;
* invoice lifecycle transitions;
* freeze and unfreeze behavior;
* non-transferability;
* risk parameter boundaries;
* buyer exposure accounting;
* oracle submission, dispute, staleness, and finalization;
* oracle-attested recovery propagation;
* funding and tranche liquidity accounting;
* paid-path fee distribution;
* junior first-loss behavior;
* senior residual loss;
* zero recovery;
* cumulative bad debt;
* multiple active-position isolation;
* H-01 security regression coverage.

At configuration commit `9c08419`, the repository contains:

- 210 regular unit, integration, and fuzz test functions;
- 12 stateful invariant functions;
- 222 total checks.

Local runtime verification completed with:

```text
222 passed
0 failed
0 skipped
```

The stateful invariant suite also completed with:

```text
12 passed
0 failed
0 skipped
0 handler reverts
0 discards
```

`forge build`, `forge fmt --check`, and `git diff --check` also passed locally.

GitHub Actions passed for commit `d040db0` on the current
`audit/final-review` branch state. That state includes the invariant execution
configuration introduced in commit `9c08419`.

---

# 11. Out-of-Scope Production Features

The following are intentionally outside the v1 portfolio scope:

* multi-oracle quorum;
* recovery escrow;
* automated bank-payment reconciliation;
* KYC and LP whitelisting;
* protocol-wide pause mechanism;
* upgradeability;
* cross-protocol invoice uniqueness;
* legal enforcement automation;
* insurance reserve;
* withdrawal queues;
* epoch-based liquidity;
* partial settlement state;
* restructuring and refinancing;
* secondary invoice NFT trading.

Excluding these features keeps v1 focused on explicit state transitions, deterministic tranche accounting, and auditability.

Their exclusion must not be interpreted as evidence that they are unnecessary in a production RWA deployment.

---

# 12. Security Model Summary

The protocol deliberately separates three responsibilities:

## Oracle

Attests off-chain economic truth:

* terminal invoice status;
* recovered principal for defaulted invoices.

## Pool

Validates and stores finalized outcomes, then executes:

* principal restoration;
* fee distribution;
* recovery allocation;
* tranche writedowns;
* buyer exposure reduction;
* bad-debt recognition.

## Executor

Triggers settlement or default execution and supplies required tokens.

The executor cannot:

* choose terminal status;
* choose recovered principal;
* modify stored financing terms;
* override waterfall allocation;
* resolve the same position twice.

This separation is the core security boundary of the v1 accounting architecture.

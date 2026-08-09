# Vector 04 — Access Control & Privilege Escalation — PLAN

## Scope
All contracts. Role systems in play:
- **InvoiceNFT** (OZ AccessControl): `ORIGINATOR_ROLE`, `VERIFIER_ROLE`, `RISK_ROLE`, `POOL_ROLE`, `DEFAULT_ADMIN_ROLE`.
- **RWARiskManager** (OZ AccessControl): `RISK_ADMIN_ROLE`, `POOL_ROLE`, `DEFAULT_ADMIN_ROLE`.
- **InvoiceStatusOracle** (OZ AccessControl): `ORACLE_SUBMITTER_ROLE`, `DISPUTE_ADMIN_ROLE`, `DEFAULT_ADMIN_ROLE`.
- **InvoiceFinancingPool**: custom `onlyAdmin` (ADMIN == deployer, immutable); `onStatusFinalized` gated by `invoiceStatusOracle`; `financeInvoice` gated by `msg.sender == invoice.supplier`.
- **SeniorPool / JuniorPool**: `onlyInvoiceFinancingPool` on `lockAssets/unlockAssets/fundInvoice/creditAssets/writeDown` (immutable INVOICE_FINANCING_POOL).

## Known-attack classes for this vector
1. Missing / incorrect function modifiers (a state-changing fn with no auth).
2. Function-level auth gaps (right role, wrong check; or `tx.origin` misuse).
3. Role-separation failures (one signer holds mutually-exclusive roles by construction).
4. Unprotected initializers / setters (re-init, second-set, front-run of one-shot setter).
5. Admin blast radius (a legit admin can grant a powerful role to an arbitrary EOA and desync state / cause loss).
6. Role-revocation DoS (admin revokes the pool's operational role mid-lifecycle → live positions stuck).
7. Deploy footgun (ADMIN bound to `msg.sender`; wrong deployer captures privileged wiring).

## Hypotheses (attacker goal + method) — >=10

1. **financeInvoice supplier gate** — Attacker goal: finance someone else's invoice to redirect advance or grief.
   Method: create+verify invoice for `supplier`, call `financeInvoice` from `attacker`. Expect `UnauthorizedFinancer`.
   Also confirm advance always goes to `invoice.supplier` (position.supplier) even when a *different* legitimate supplier finances their own — no redirection primitive.

2. **Vault fns onlyInvoiceFinancingPool** — Attacker goal: directly lock/unlock/fund/credit/writeDown vault NAV to steal cash or corrupt share price.
   Method: from `attacker`, call each of `lockAssets/unlockAssets/fundInvoice/creditAssets/writeDown` on both pools. Expect `NotInvoiceFinancingPool` on every call.

3. **RiskManager.updateBuyerExposure onlyPOOL** — Attacker goal: manipulate `buyerExposure` to evade concentration cap or force `ExposureUnderflow` DoS.
   Method: `attacker` calls `updateBuyerExposure`. Expect `AccessControlUnauthorizedAccount`.

4. **RiskManager.setRiskParams / setBuyerDenied onlyRISK_ADMIN** — Attacker goal: raise advance/APR, or denylist a buyer to grief.
   Method: `attacker` calls both setters. Expect `AccessControlUnauthorizedAccount`.

5. **InvoiceNFT lifecycle role gates** — Attacker goal: verify/markFunded/markSettled/markDefaulted/freeze/unfreeze without the role.
   Method: `attacker` calls each. Expect `AccessControlUnauthorizedAccount` (createInvoice too).

6. **Oracle submit/dispute role gates** — Attacker goal: submit a fake outcome or block a legit one.
   Method: `attacker` calls `submitStatus` and `disputeStatus`. Expect `AccessControlUnauthorizedAccount`.
   Also: `finalize` IS permissionless by design — confirm a non-privileged caller can only finalize what a submitter already staged (no injection).

7. **pool.setInvoiceStatusOracle onlyAdmin + one-shot** — Attacker goal: hijack the oracle callback source, or re-point it.
   Method: `attacker` calls `setInvoiceStatusOracle` → `UnauthorizedAdmin`. Then `admin` calls it a second time → `OracleAlreadySet`.

8. **Oracle role-separation NOT enforced (single admin)** — Goal: single key submits, refrains from disputing, finalizes any SETTLED/DEFAULTED outcome.
   Method: as `admin`, submit DEFAULTED with attacker-chosen recovery, warp, finalize. Show arbitrary outcome pushed to pool. Classify: centralization/design (trust model), not a code bug — the recovery is still bounded by principal and waterfall stays senior-first.

9. **InvoiceNFT admin blast radius (POOL_ROLE to EOA)** — Goal: rogue EOA with POOL_ROLE desyncs NFT vs pool position; check for loss/gain vs griefing.
   Method: `admin` grants `POOL_ROLE` to `attacker`; attacker calls `markSettled`/`markDefaulted` on a FUNDED invoice out-of-band. Show NFT status diverges from the pool's `financingPositions[id].resolved` (still false) and, critically, that this **bricks** legitimate settle/resolve (pool's `markSettled`/`markDefaulted` then revert because status is no longer FUNDED) — locked assets stranded. Assess severity.

10. **RiskManager admin blast radius (POOL_ROLE to EOA)** — Goal: rogue EOA moves `buyerExposure` arbitrarily.
    Method: `admin` grants `POOL_ROLE` to `attacker`; attacker inflates exposure to block all new financing for a buyer (concentration DoS) and/or decrements it to underflow-revert legit settlement. Assess.

11. **Role-revocation DoS** — Goal: admin revokes the pool's `POOL_ROLE` on RiskManager and/or InvoiceNFT mid-life; show finance/settle/resolve then revert, funds/positions stuck.
    Method: bootstrap a FUNDED invoice, finalize oracle, revoke `POOL_ROLE` on InvoiceNFT (and separately RiskManager), attempt settle → revert; assets remain locked. Assess.

12. **Deploy footgun (ADMIN = msg.sender)** — Goal: if the pool is deployed by an actor other than the intended admin, that deployer controls the one-shot oracle wiring.
    Method: deploy a fresh pool from `attacker`; show `pool.ADMIN() == attacker` and only `attacker` can set the oracle; the intended `admin` cannot. Assess as a deployment/operational footgun.

## Method notes
- Every PoC inherits `Harness`; default `setUp` wires all roles.
- SAFE probes: `vm.expectRevert(selector)` on the malicious action, or assert the guarantee still holds.
- FINDING probes: construct the exploit and assert the harmful outcome; only for genuine HIGH/CRITICAL by a non-privileged actor OR an admin action that breaks a stated protocol guarantee under realistic assumptions.
- Trust model is intentionally permissioned. Admin-only capabilities are classified SAFE/INFO unless they break a stated guarantee (senior-protection waterfall, one-shot oracle, LP accounting conservation, funds-not-stranded, no-unauthorized-loss/gain).

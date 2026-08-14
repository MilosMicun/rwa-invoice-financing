# Sepolia Deployment Record

## 1. Deployment Summary

This document records the public Ethereum Sepolia deployment of the RWA Invoice Financing protocol. It is an engineering and portfolio deployment record for a public testnet, not evidence of a mainnet or production deployment.

| Property | Value |
|---|---|
| Network | Ethereum Sepolia |
| Chain ID | `11155111` |
| Deployment block | `11487242` |
| Git commit | `08dcbaf` (`feat: add Sepolia deployment workflow`) |
| Solidity compiler | Solc `0.8.33` |
| Foundry | `1.5.1-stable` |
| Deployment credentials | Separate EOAs backed by encrypted Foundry keystores |

## 2. Contract Addresses

All six protocol contracts are source-verified on Sepolia Etherscan.

| Contract | Sepolia address |
|---|---|
| `InvoiceNFT` | [`0xc00Bd076a831C8716B63bbA1De1B374c5C120A59`](https://sepolia.etherscan.io/address/0xc00Bd076a831C8716B63bbA1De1B374c5C120A59) |
| `RWARiskManager` | [`0x7b26D9C8441b1573FA780776400399ef846D5267`](https://sepolia.etherscan.io/address/0x7b26D9C8441b1573FA780776400399ef846D5267) |
| `InvoiceFinancingPool` | [`0x28ebbBF765bAA41B40A32E2d398897acf1b31136`](https://sepolia.etherscan.io/address/0x28ebbBF765bAA41B40A32E2d398897acf1b31136) |
| `SeniorPool` | [`0x1b4F190a6e41d652324F42a3e952E42000C2Da2C`](https://sepolia.etherscan.io/address/0x1b4F190a6e41d652324F42a3e952E42000C2Da2C) |
| `JuniorPool` | [`0xCfBFB78f7466CC39a0c7d11E433226318d399b2E`](https://sepolia.etherscan.io/address/0xCfBFB78f7466CC39a0c7d11E433226318d399b2E) |
| `InvoiceStatusOracle` | [`0x99Da04B576aC19aF6b00294DeA4f96EA2A1bf23b`](https://sepolia.etherscan.io/address/0x99Da04B576aC19aF6b00294DeA4f96EA2A1bf23b) |

## 3. External Asset Dependency

The deployment uses [Circle Sepolia USDC (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`)](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) as its settlement asset. USDC has `6` decimals, so monetary risk parameters are represented on-chain in 6-decimal USDC base units.

The settlement-asset assumptions and accepted limitations in [`RISKS.md`](RISKS.md) remain applicable.

## 4. Deployment Architecture

Deployment and bootstrap proceeded in this order:

1. deploy `InvoiceNFT`;
2. deploy `RWARiskManager`;
3. deploy `InvoiceFinancingPool`;
4. constructor-create `SeniorPool` and `JuniorPool` internally during the `InvoiceFinancingPool` deployment;
5. deploy `InvoiceStatusOracle`;
6. grant the intended operational and pool roles and wire the oracle once;
7. revoke ADMIN's temporary bootstrap operational roles;
8. perform a separate post-deployment read-only smoke audit;
9. verify all six protocol contracts on Sepolia Etherscan.

`SeniorPool` and `JuniorPool` did not have independent top-level CREATE transactions. Both tranche contracts were constructor-created by `InvoiceFinancingPool`.

## 5. Sepolia Configuration

These values are the Sepolia demonstration configuration. They are not production underwriting recommendations.

### Underwriting

| Parameter | Human-readable value | On-chain value |
|---|---:|---:|
| Advance rate | 80% | `8000` BPS |
| Maximum invoice tenor | 90 days | `7_776_000` seconds |
| Minimum invoice amount | 10 USDC | `10_000_000` base units |
| Maximum exposure per Buyer | 1,000 USDC | `1_000_000_000` base units |
| Financing fee APR | 12% | `1200` BPS |

### Tranche allocation

| Parameter | Value |
|---|---:|
| Senior funding share | 70% (`7000` BPS) |
| Junior funding share | 30% (`3000` BPS) |
| Senior fee share | 40% (`4000` BPS) |
| Junior fee share | 60% (`6000` BPS) |

### Oracle timing

| Parameter | Value |
|---|---:|
| Dispute window | 1 day (`86_400` seconds) |
| Maximum staleness | 7 days (`604_800` seconds) |

## 6. Permission Model

The deployment uses three separate principals:

| Principal | Address | Final authority |
|---|---|---|
| ADMIN / DEPLOYER | `0x9f33C581581BC878f638541DB2b75e117A36BEfD` | `DEFAULT_ADMIN_ROLE` on `InvoiceNFT`, `RWARiskManager`, and `InvoiceStatusOracle`; immutable `InvoiceFinancingPool.ADMIN` |
| OPERATIONS | `0xf2541FC59E68C999b130775392d4d86aE8B281B5` | `InvoiceNFT.ORIGINATOR_ROLE`; `InvoiceStatusOracle.ORACLE_SUBMITTER_ROLE` |
| CONTROL / RISK | `0x7077eeeB52Bf997a821c94983fC0D45763bae504` | `InvoiceNFT.VERIFIER_ROLE`; `InvoiceNFT.RISK_ROLE`; `RWARiskManager.RISK_ADMIN_ROLE`; `InvoiceStatusOracle.DISPUTE_ADMIN_ROLE` |
| `InvoiceFinancingPool` | `0x28ebbBF765bAA41B40A32E2d398897acf1b31136` | `InvoiceNFT.POOL_ROLE`; `RWARiskManager.POOL_ROLE` |

ADMIN does not retain normal operational roles. After all grants and wiring succeeded, ADMIN relinquished:

- `RWARiskManager.RISK_ADMIN_ROLE`;
- `InvoiceStatusOracle.ORACLE_SUBMITTER_ROLE`;
- `InvoiceStatusOracle.DISPUTE_ADMIN_ROLE`.

ADMIN retained the three `DEFAULT_ADMIN_ROLE` assignments and the pool's immutable `ADMIN` authority. Operational separation is implemented, while ultimate administrative recovery remains permissioned through `DEFAULT_ADMIN_ROLE`. This permission model does not imply full decentralization.

## 7. Post-Deployment Acceptance

A separate post-deployment read-only smoke audit was performed against live Sepolia state after broadcast.

> **OVERALL POST-DEPLOYMENT SMOKE AUDIT: PASS**

The acceptance review confirmed:

- Sepolia chain identity;
- runtime bytecode presence for all six protocol contracts;
- core immutable and dependency wiring;
- tranche asset and coordinator wiring;
- one-time oracle wiring;
- the complete economic configuration;
- the positive permission graph;
- the negative separation-of-duties matrix;
- bootstrap operational-role revocations;
- the initial accounting state.

Initial accounting was confirmed as follows:

| Contract | Property | Value |
|---|---|---:|
| `InvoiceFinancingPool` | `totalLockedAssets` | `0` |
| `InvoiceFinancingPool` | `totalBadDebt` | `0` |
| `SeniorPool` | `totalAssets()` | `0` |
| `SeniorPool` | `lockedAssets` | `0` |
| `SeniorPool` | `pendingLoss` | `0` |
| `SeniorPool` | `availableLiquidity()` | `0` |
| `JuniorPool` | `totalAssets()` | `0` |
| `JuniorPool` | `lockedAssets` | `0` |
| `JuniorPool` | `pendingLoss` | `0` |
| `JuniorPool` | `availableLiquidity()` | `0` |

In the tranche accounting model, `accountedAssets` is gross accounting assets before reserved default impairment, `lockedAssets` is gross tranche principal committed to unresolved financings, and `pendingLoss` is finalized but unresolved economic impairment. Therefore `totalAssets()` is `accountedAssets - pendingLoss`, while `availableLiquidity()` is `accountedAssets - lockedAssets`.

The live smoke audit verifies deployment configuration; it does not replace the repository's unit, integration, fuzz, and stateful invariant suites. Before deployment, the validated repository state was:

- `229 / 229` tests passing, with `0` failed and `0` skipped;
- `12` stateful invariants;
- `256` invariant runs at depth `500`;
- `fail_on_revert = true`;
- GitHub CI green before broadcast.

## 8. Source Verification

All six deployed protocol contracts are source-verified on Sepolia Etherscan. The linked address pages in [Contract Addresses](#2-contract-addresses) expose the verified source, compiler configuration, and deployed bytecode for review.

Source verification improves transparency and reproducibility, but it is not an audit or a production-readiness certification.

## 9. Deployment Transactions

The four top-level CREATE transactions were:

| Deployment | Sepolia transaction |
|---|---|
| `InvoiceNFT` | [`0x61748aa91d60209b0f241023c4f91de9b768edf60907449a2995bebea86a3524`](https://sepolia.etherscan.io/tx/0x61748aa91d60209b0f241023c4f91de9b768edf60907449a2995bebea86a3524) |
| `RWARiskManager` | [`0x1354b924d9edcacc61a10e81ee4683394c6ad9d40d86a57aac99ea94ee66cf4d`](https://sepolia.etherscan.io/tx/0x1354b924d9edcacc61a10e81ee4683394c6ad9d40d86a57aac99ea94ee66cf4d) |
| `InvoiceFinancingPool` | [`0xe736a7369e7cfe6f3e81569cfc26f01a95554f57918dedc7155df3e07d91fc70`](https://sepolia.etherscan.io/tx/0xe736a7369e7cfe6f3e81569cfc26f01a95554f57918dedc7155df3e07d91fc70) |
| `InvoiceStatusOracle` | [`0x40de82b0617fa70806ea8cbad6d964b7ba6faa1b85d18deaa6f123b6c4b390e2`](https://sepolia.etherscan.io/tx/0x40de82b0617fa70806ea8cbad6d964b7ba6faa1b85d18deaa6f123b6c4b390e2) |

The remaining bootstrap actions were executed as additional role-grant, oracle-wiring, and role-revocation transactions. Their resulting live state was checked through the separate post-deployment read-only smoke audit. `SeniorPool` and `JuniorPool` were created inside the `InvoiceFinancingPool` deployment transaction.

## 10. Trust and Production Boundary

This is a public Sepolia portfolio deployment. ADMIN is an EOA, while OPERATIONS and CONTROL / RISK are separate EOAs; all three are backed by encrypted Foundry keystores. Their operational responsibilities are separated on-chain, but ultimate `DEFAULT_ADMIN_ROLE` authority remains permissioned.

No multisig or timelock was introduced for this testnet portfolio deployment. A real production deployment would require an environment-specific administrative and key-management policy, potentially including institutional custody, multisig, timelock, or other governance controls, together with appropriate monitoring and incident-response procedures.

The accepted v1 limitations and trust assumptions documented in [`RISKS.md`](RISKS.md) remain applicable. This deployment must not be interpreted as evidence of production readiness, full decentralization, or the absence of undiscovered vulnerabilities.

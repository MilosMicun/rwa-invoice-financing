# Sepolia Live Demo Record

## 1. Purpose and Scope

This document records the completed end-to-end interaction demo for the canonical Ethereum Sepolia deployment of the RWA Invoice Financing protocol. The demo exercised the deployed contracts through liquidity entry, invoice origination and verification, financing, oracle outcome submission, dispute-window finalization, default resolution, paid settlement, and final accounting inspection.

This is a public-testnet protocol-engineering record. It complements the [`Sepolia deployment record`](DEPLOYMENT.md), which documents deployment and configuration acceptance, by showing that the deployed system was subsequently used through both terminal economic paths. It is not evidence of production readiness, full decentralization, formal verification, or a production audit.

The live evidence consists of:

- the canonical deployed contract addresses;
- the staged [`LiveDemo.s.sol`](../script/LiveDemo.s.sol) interaction harness;
- the linked Sepolia transactions below; and
- the resulting on-chain lifecycle and accounting state.

Foundry broadcast JSON artifacts are not required repository evidence.

## 2. Canonical Deployment

| Property | Value |
|---|---|
| Network | Ethereum Sepolia |
| Chain ID | `11155111` |
| Settlement asset | Circle Sepolia USDC, 6 decimals |

| Contract | Sepolia address |
|---|---|
| USDC | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) |
| `InvoiceNFT` | [`0xc00Bd076a831C8716B63bbA1De1B374c5C120A59`](https://sepolia.etherscan.io/address/0xc00Bd076a831C8716B63bbA1De1B374c5C120A59) |
| `RWARiskManager` | [`0x7b26D9C8441b1573FA780776400399ef846D5267`](https://sepolia.etherscan.io/address/0x7b26D9C8441b1573FA780776400399ef846D5267) |
| `InvoiceFinancingPool` | [`0x28ebbBF765bAA41B40A32E2d398897acf1b31136`](https://sepolia.etherscan.io/address/0x28ebbBF765bAA41B40A32E2d398897acf1b31136) |
| `SeniorPool` | [`0x1b4F190a6e41d652324F42a3e952E42000C2Da2C`](https://sepolia.etherscan.io/address/0x1b4F190a6e41d652324F42a3e952E42000C2Da2C) |
| `JuniorPool` | [`0xCfBFB78f7466CC39a0c7d11E433226318d399b2E`](https://sepolia.etherscan.io/address/0xCfBFB78f7466CC39a0c7d11E433226318d399b2E) |
| `InvoiceStatusOracle` | [`0x99Da04B576aC19aF6b00294DeA4f96EA2A1bf23b`](https://sepolia.etherscan.io/address/0x99Da04B576aC19aF6b00294DeA4f96EA2A1bf23b) |

## 3. Scenario Design

The demo used two invoices with identical funding terms and different finalized outcomes. This isolates outcome handling from origination and funding configuration: one position demonstrates stored-fee settlement, while the other demonstrates Senior-first recovery, Junior first-loss, loss reservation at oracle finalization, and later realization without a second NAV impairment.

The live deployment used this configuration:

| Parameter | Value |
|---|---:|
| Advance rate | 80% (`8000` BPS) |
| Maximum invoice tenor | 90 days |
| Minimum invoice amount | 10 USDC |
| Maximum active exposure per Buyer | 1,000 USDC |
| Financing fee APR | 12% (`1200` BPS) |
| Senior / Junior funding split | 70% / 30% |
| Senior / Junior fee split | 40% / 60% |
| Oracle dispute window | 1 day (`86,400` seconds) |
| Oracle maximum staleness | 7 days (`604,800` seconds) |

| Parameter | Invoice 1 — settlement path | Invoice 2 — default path |
|---|---:|---:|
| Face value | 12.5 USDC | 12.5 USDC |
| Advance rate | 80% | 80% |
| Financed principal | 10 USDC | 10 USDC |
| Tenor | 30 days | 30 days |
| Financing APR at funding | 12% (`1200` BPS) | 12% (`1200` BPS) |
| Senior principal | 7 USDC | 7 USDC |
| Junior principal | 3 USDC | 3 USDC |
| Final oracle outcome | `SETTLED` | `DEFAULTED` |

The LP seeded exactly 14 USDC into `SeniorPool` and 6 USDC into `JuniorPool`, providing the 20 USDC required to finance both invoices.

Invoice 1 stored a financing fee of 0.098599 USDC at funding. Settlement therefore required exactly 10.098599 USDC: 10 USDC principal plus the stored fee. The realized fee was allocated as 0.039440 USDC to Senior and 0.059159 USDC to Junior under the configured 40% / 60% fee split.

Invoice 2 finalized with 7 USDC recovered principal. Recovery was allocated entirely to the 7 USDC Senior principal. Junior recovered zero and absorbed the remaining 3 USDC principal loss; Senior recorded no loss.

## 4. Actors and Role Separation

| Actor | Address | Demo responsibility |
|---|---|---|
| ADMIN | `0x9f33C581581BC878f638541DB2b75e117A36BEfD` | Retained deployment administration; not used as a normal demo operator |
| OPERATIONS | `0xf2541FC59E68C999b130775392d4d86aE8B281B5` | Created both invoices and submitted both oracle outcomes |
| CONTROL | `0x7077eeeB52Bf997a821c94983fC0D45763bae504` | Verified both invoices; retained risk and dispute administration where applicable |
| DEMO_LP | `0xD5Ebe7cB4682A3D82dA44ada1256C1721f005eC3` | Supplied Senior and Junior liquidity without receiving a protocol role |
| DEMO_SUPPLIER | `0x04E79d79da077f34817Ef517a34E29ee5faD850C` | Owned both invoice NFTs and requested financing without receiving a protocol role |
| DEMO_EXECUTOR | `0x47D17DaDA70F527c07c5E4dEFB22E9Fc7B3881Bf` | Permissionlessly finalized outcomes, supplied recovery and settlement assets, and executed both resolutions |
| SETTLED Buyer | `0x1111111111111111111111111111111111111111` | Economic obligor identity for Invoice 1; no signature or protocol role |
| DEFAULT Buyer | `0x2222222222222222222222222222222222222222` | Economic obligor identity for Invoice 2; no signature or protocol role |

The separation is material to the demo. Origination, verification, Supplier financing, oracle submission, and permissionless execution were performed by distinct actors according to the deployed permission model. No demo LP, Supplier, Executor, or Buyer was granted a protocol role.

## 5. Execution Record

The interaction harness is staged because the oracle dispute window spans separate on-chain transactions and real elapsed time. Invoice IDs are emitted and logged during creation, then passed explicitly to later stages; the script does not persist them in local files or hidden state.

| Stage | Script entrypoint | Required actor | Result |
|---|---|---|---|
| Inspect deployment | `inspect()` | Read-only caller | Checked Sepolia chain identity, canonical wiring, configuration, roles, balances, and accounting identities |
| Seed liquidity | `seedLiquidity()` | DEMO_LP | Deposited 14 USDC Senior and 6 USDC Junior |
| Create invoices | `createInvoices(settledBuyer, defaultedBuyer)` | OPERATIONS | Created Invoice 1 and Invoice 2 in `CREATED` |
| Verify invoices | `verifyInvoices(1, 2)` | CONTROL | Moved both invoices to `VERIFIED` |
| Finance invoices | `financeInvoices(1, 2)` | DEMO_SUPPLIER | Advanced 10 USDC per invoice and stored both financing positions |
| Submit outcomes | `submitOutcomes(1, 2)` | OPERATIONS | Submitted `SETTLED` for Invoice 1 and `DEFAULTED` with 7 USDC recovery for Invoice 2 |
| Wait | On-chain timing | None | Allowed the real 1-day dispute window to elapse |
| Finalize outcomes | `finalizeOutcomes(1, 2)` | DEMO_EXECUTOR | Permissionlessly finalized both eligible, non-disputed, non-stale updates |
| Resolve default | `resolveDefault(2)` | DEMO_EXECUTOR | Supplied 7 USDC recovery and realized the reserved 3 USDC Junior loss |
| Settle invoice | `settleInvoice(1)` | DEMO_EXECUTOR | Paid the exact stored principal plus stored fee |
| Inspect final state | `finalInspection(1, 2)` | Read-only caller | Confirmed terminal lifecycle, released exposure and locks, cleared pending losses, and final tranche accounting |

Invoice 1's oracle update recorded `submittedAt = 1787061948`. Finalization occurred only after the deployed 86,400-second dispute window had elapsed. The script checked the update's on-chain submission time, dispute state, finalized state, earliest finalization boundary, and staleness boundary before submitting finalization transactions; it did not simulate time with `vm.warp()`.

## 6. Sepolia Transaction Evidence

Transactions are listed in execution order within each stage. Approval transactions are shown separately from the protocol action that consumed the approved USDC.

| Stage | Action | Sepolia transaction |
|---|---|---|
| Seed liquidity | Approve 20 USDC | [`0x9b9a349695403a7c5c91af61057bb1b26a4e36fa6140a490b0c998a5ea7b1e98`](https://sepolia.etherscan.io/tx/0x9b9a349695403a7c5c91af61057bb1b26a4e36fa6140a490b0c998a5ea7b1e98) |
| Seed liquidity | Deposit 14 USDC Senior | [`0xf9cf8fabf9459457029c7654cf943b244ecc316021ac27d098e053912144851e`](https://sepolia.etherscan.io/tx/0xf9cf8fabf9459457029c7654cf943b244ecc316021ac27d098e053912144851e) |
| Seed liquidity | Deposit 6 USDC Junior | [`0x99d6ddd9474d82cee186855c7a0846f84bcd21a3bfa86e9c41e0d637a4cd1370`](https://sepolia.etherscan.io/tx/0x99d6ddd9474d82cee186855c7a0846f84bcd21a3bfa86e9c41e0d637a4cd1370) |
| Create invoices | Create Invoice 1 | [`0x8b40122d133e9968a9321decbec7c8bf2e15b5fa6623ad439bde2261e7498b53`](https://sepolia.etherscan.io/tx/0x8b40122d133e9968a9321decbec7c8bf2e15b5fa6623ad439bde2261e7498b53) |
| Create invoices | Create Invoice 2 | [`0xf2e39075c801b3dc5cc7d774697eb77076635d334d5622db129d58b3e293ac75`](https://sepolia.etherscan.io/tx/0xf2e39075c801b3dc5cc7d774697eb77076635d334d5622db129d58b3e293ac75) |
| Verify invoices | Verify Invoice 1 | [`0x001d706736486d51bb486d95146c31b9f8952f2ebcc8d97c4b207495446573f9`](https://sepolia.etherscan.io/tx/0x001d706736486d51bb486d95146c31b9f8952f2ebcc8d97c4b207495446573f9) |
| Verify invoices | Verify Invoice 2 | [`0x5de202afc24d45cfed2a6d694d0af9c9477adadcf6301a25d20be8f136f0d797`](https://sepolia.etherscan.io/tx/0x5de202afc24d45cfed2a6d694d0af9c9477adadcf6301a25d20be8f136f0d797) |
| Finance invoices | Finance Invoice 1 | [`0xb1ab434f525cb9ea537e0505c23a3d6aa125284206bcf0e4dce3e9c0d324605e`](https://sepolia.etherscan.io/tx/0xb1ab434f525cb9ea537e0505c23a3d6aa125284206bcf0e4dce3e9c0d324605e) |
| Finance invoices | Finance Invoice 2 | [`0x12cc114ebc88d1a593a340cd49d0241051e50f93619e7a9d8ebd7fbda85f69ab`](https://sepolia.etherscan.io/tx/0x12cc114ebc88d1a593a340cd49d0241051e50f93619e7a9d8ebd7fbda85f69ab) |
| Submit outcomes | Submit Invoice 1 `SETTLED` | [`0x7b7bbee4952b5359e7ca7b53f1cee73ed7986e9f0fc0ad9546218a1bc6192155`](https://sepolia.etherscan.io/tx/0x7b7bbee4952b5359e7ca7b53f1cee73ed7986e9f0fc0ad9546218a1bc6192155) |
| Submit outcomes | Submit Invoice 2 `DEFAULTED` | [`0xceb1a83fecb4a019703533ce777c7c046a2b53c5841269b5ac3ac05316053d2c`](https://sepolia.etherscan.io/tx/0xceb1a83fecb4a019703533ce777c7c046a2b53c5841269b5ac3ac05316053d2c) |
| Finalize outcomes | Finalize Invoice 1 | [`0x78973c21f8fc4ba8687ed833e4ed381374ad2d149f8166d2b0f100fbf35806a0`](https://sepolia.etherscan.io/tx/0x78973c21f8fc4ba8687ed833e4ed381374ad2d149f8166d2b0f100fbf35806a0) |
| Finalize outcomes | Finalize Invoice 2 | [`0x28771ac38090e3d4efc6e930d858fa044201fa43e924a221a44bf30b28aa53bf`](https://sepolia.etherscan.io/tx/0x28771ac38090e3d4efc6e930d858fa044201fa43e924a221a44bf30b28aa53bf) |
| Resolve default | Approve 7 USDC recovery | [`0x16f9f42314f48651267b714af832cd31e992c70d5fb70947b9666bb7d439235b`](https://sepolia.etherscan.io/tx/0x16f9f42314f48651267b714af832cd31e992c70d5fb70947b9666bb7d439235b) |
| Resolve default | Execute `resolveDefault(2)` | [`0xd96df5139ad24b896db0cef7a3c71fa75d9bf599e7863e9a3859026b919c91f6`](https://sepolia.etherscan.io/tx/0xd96df5139ad24b896db0cef7a3c71fa75d9bf599e7863e9a3859026b919c91f6) |
| Settle invoice | Approve 10.098599 USDC | [`0x0a78b68f554e497189f17799a9f12927502b9426425777eb206b8528dd724b15`](https://sepolia.etherscan.io/tx/0x0a78b68f554e497189f17799a9f12927502b9426425777eb206b8528dd724b15) |
| Settle invoice | Execute `settleInvoice(1)` | [`0xadfd637c0729679026e6d8fc30ae30658e4bc6f2d5de13a4e98f94da122c3f28`](https://sepolia.etherscan.io/tx/0xadfd637c0729679026e6d8fc30ae30658e4bc6f2d5de13a4e98f94da122c3f28) |

## 7. Default Finalization Checkpoint

The most important live checkpoint occurred after the `DEFAULTED` oracle outcome was finalized but before `resolveDefault(2)` executed.

The protocol uses these accounting terms:

- `accountedAssets`: gross accounting assets before reserved default impairment;
- `lockedAssets`: tranche principal committed to unresolved financings;
- `pendingLoss`: finalized but unresolved economic impairment;
- `totalAssets() = accountedAssets - pendingLoss`;
- `availableLiquidity() = accountedAssets - lockedAssets`.

At default finalization, the 3 USDC unrecovered Junior principal was reserved in `pendingLoss`. This immediately reduced Junior NAV from 6 USDC to 3 USDC, but it did not resolve the financing position or move recovery cash.

| State | Live value after finalization, before resolution |
|---|---:|
| Pool `totalLockedAssets` | 20 USDC |
| Pool `totalBadDebt` | 0 USDC |
| Invoice 2 NFT status | `FUNDED` |
| Invoice 2 position resolved | `false` |
| DEFAULT Buyer exposure | 10 USDC |

| Tranche accounting | Senior | Junior |
|---|---:|---:|
| `totalAssets()` | 14 USDC | 3 USDC |
| `lockedAssets` | 14 USDC | 6 USDC |
| `pendingLoss` | 0 USDC | 3 USDC |
| `availableLiquidity()` | 0 USDC | 0 USDC |
| Derived `accountedAssets` | 14 USDC | 6 USDC |

Both public derivations of gross accounted assets remained equal:

```text
totalAssets() + pendingLoss
    == availableLiquidity() + lockedAssets
```

Default finalization therefore demonstrated the intended separation between economic recognition and execution: NAV reflected the finalized loss while locks, Buyer exposure, position resolution, NFT lifecycle, and cumulative realized bad debt remained unchanged.

## 8. Default Resolution and No Second NAV Haircut

`resolveDefault(2)` supplied the oracle-finalized 7 USDC recovery. Senior received the full 7 USDC recovery, Junior received zero, and the already-reserved 3 USDC Junior loss was realized.

| NAV checkpoint | Before resolution | After resolution |
|---|---:|---:|
| Senior `totalAssets()` | 14 USDC | 14 USDC |
| Junior `totalAssets()` | 3 USDC | 3 USDC |

Resolution did not apply a second impairment. `JuniorPool.writeDown()` decreased gross `accountedAssets` and `pendingLoss` by the same 3 USDC, preserving the NAV haircut already recognized at finalization.

After default resolution:

- cumulative `totalBadDebt` increased from 0 to 3 USDC;
- aggregate `totalLockedAssets` decreased from 20 USDC to 10 USDC;
- Senior `lockedAssets` decreased to 7 USDC;
- Junior `lockedAssets` decreased to 3 USDC;
- Junior `pendingLoss` cleared to zero;
- DEFAULT Buyer exposure cleared to zero;
- Invoice 2 became `DEFAULTED`; and
- Invoice 2's financing position became resolved.

The 3 USDC change in `totalBadDebt` is the scenario-specific realized principal-loss delta. `totalBadDebt` is otherwise a cumulative protocol metric.

## 9. Settlement and Final On-Chain State

Invoice 1 settlement used the financing position's stored terms rather than recomputing historical economics from current Risk Manager configuration. DEMO_EXECUTOR approved and paid exactly 10.098599 USDC, comprising 10 USDC stored principal and 0.098599 USDC stored financing fee.

`finalInspection(1, 2)` passed with this state:

| Lifecycle state | Final value |
|---|---|
| Invoice 1 | `SETTLED`; position resolved |
| Invoice 2 | `DEFAULTED`; position resolved |
| SETTLED Buyer exposure | 0 USDC |
| DEFAULT Buyer exposure | 0 USDC |

| Protocol accounting | Final value |
|---|---:|
| Pool `totalLockedAssets` | 0 USDC |
| Pool cumulative `totalBadDebt` | 3 USDC |

| Tranche accounting | Senior | Junior |
|---|---:|---:|
| `totalAssets()` | 14.039440 USDC | 3.059159 USDC |
| `lockedAssets` | 0 USDC | 0 USDC |
| `pendingLoss` | 0 USDC | 0 USDC |
| `availableLiquidity()` | 14.039440 USDC | 3.059159 USDC |
| Derived `accountedAssets` | 14.039440 USDC | 3.059159 USDC |

The final Senior NAV includes its settlement fee share. Final Junior NAV reflects the 3 USDC first-loss impairment and its settlement fee share. LP capital was intentionally left in the tranche pools so the final state remains publicly inspectable.

## 10. Reviewer Inspection and Reproduction

The canonical deployment can be inspected without a privileged signer. For example, a reviewer may simulate either read-only stage against a Sepolia RPC endpoint without `--broadcast`:

```bash
forge script script/LiveDemo.s.sol:LiveDemo \
  --sig "inspect()" \
  --rpc-url "$SEPOLIA_RPC_URL"

forge script script/LiveDemo.s.sol:LiveDemo \
  --sig "finalInspection(uint256,uint256)" 1 2 \
  --rpc-url "$SEPOLIA_RPC_URL"
```

No private key, password, mnemonic, keystore path, or RPC credential is embedded in the script or this document.

The write stages are intentionally strict-state-gated and non-idempotent. Reusing an already-consumed lifecycle transition fails instead of silently skipping it. The completed canonical run should therefore be reviewed through the linked transactions, contract state, and read-only entrypoints rather than blindly replayed against the same positions.

Canonical privileged writes require the deployed role-backed OPERATIONS or CONTROL accounts. Supplier-only financing requires the recorded Supplier. Finalization, settlement, and default resolution are permissionless under the production API, but the executor must supply any required USDC and approval. A reviewer can reproduce the complete scenario on a separately deployed instance by configuring the harness for that deployment and using accounts with the equivalent role separation.

No frontend or local persistence layer is required. The staged script is the protocol-engineering interaction layer, and on-chain state is the source of truth between invocations.

## 11. Limitations and Trust Boundary

This demo establishes that one canonical public-testnet scenario executed through the intended deployed APIs and produced the recorded state transitions and accounting results. It does not establish that every configuration, adversarial path, operational failure, or real-world invoice process is safe.

Material boundaries remain:

- Ethereum Sepolia and test USDC do not represent mainnet capital or production operations;
- invoice validity, payment status, and recovered principal remain off-chain facts reported through a permissioned oracle role;
- ADMIN retains ultimate permissioned recovery authority through deployed administrative roles;
- the deployment does not use a multisig, timelock, decentralized oracle quorum, KYC/AML system, legal-enforcement integration, or production monitoring framework;
- a successful live demo does not replace unit, integration, fuzz, invariant, or independent security review; and
- undiscovered vulnerabilities may remain.

The broader accepted risks and deferred production features remain documented in [`RISKS.md`](RISKS.md) and [`SELF_AUDIT.md`](SELF_AUDIT.md).

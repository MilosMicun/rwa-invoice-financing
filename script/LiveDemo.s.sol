// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {InvoiceFinancingPool} from "../src/core/InvoiceFinancingPool.sol";
import {InvoiceNFT} from "../src/core/InvoiceNFT.sol";
import {IInvoiceFinancingPool} from "../src/interfaces/IInvoiceFinancingPool.sol";
import {IInvoiceNFT} from "../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceStatusOracle} from "../src/interfaces/IInvoiceStatusOracle.sol";
import {InvoiceStatusOracle} from "../src/oracle/InvoiceStatusOracle.sol";
import {JuniorPool} from "../src/pools/JuniorPool.sol";
import {SeniorPool} from "../src/pools/SeniorPool.sol";
import {RWARiskManager} from "../src/risk/RWARiskManager.sol";

/// @notice Staged, non-deployment demo harness for the canonical Sepolia protocol.
/// @dev Each state-changing entrypoint is intended to be invoked separately with the
/// correct Foundry CLI sender. No key, RPC URL, or cross-invocation local state is used.
contract LiveDemo is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint8 internal constant USDC_DECIMALS = 6;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    address internal constant ADMIN = 0x9f33C581581BC878f638541DB2b75e117A36BEfD;
    address internal constant OPERATIONS = 0xf2541FC59E68C999b130775392d4d86aE8B281B5;
    address internal constant CONTROL = 0x7077eeeB52Bf997a821c94983fC0D45763bae504;

    address internal constant DEMO_LP = 0xD5Ebe7cB4682A3D82dA44ada1256C1721f005eC3;
    address internal constant DEMO_SUPPLIER = 0x04E79d79da077f34817Ef517a34E29ee5faD850C;
    address internal constant DEMO_EXECUTOR = 0x47D17DaDA70F527c07c5E4dEFB22E9Fc7B3881Bf;

    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant INVOICE_NFT_ADDRESS = 0xc00Bd076a831C8716B63bbA1De1B374c5C120A59;
    address internal constant RISK_MANAGER_ADDRESS = 0x7b26D9C8441b1573FA780776400399ef846D5267;
    address internal constant POOL_ADDRESS = 0x28ebbBF765bAA41B40A32E2d398897acf1b31136;
    address internal constant SENIOR_POOL_ADDRESS = 0x1b4F190a6e41d652324F42a3e952E42000C2Da2C;
    address internal constant JUNIOR_POOL_ADDRESS = 0xCfBFB78f7466CC39a0c7d11E433226318d399b2E;
    address internal constant ORACLE_ADDRESS = 0x99Da04B576aC19aF6b00294DeA4f96EA2A1bf23b;

    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant MAX_INVOICE_TENOR = 90 days;
    uint256 internal constant MIN_INVOICE_AMOUNT = 10e6;
    uint256 internal constant MAX_EXPOSURE_PER_BUYER = 1_000e6;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;
    uint256 internal constant SENIOR_FUNDING_SHARE_BPS = 7_000;
    uint256 internal constant JUNIOR_FUNDING_SHARE_BPS = 3_000;
    uint256 internal constant SENIOR_FEE_SHARE_BPS = 4_000;
    uint256 internal constant JUNIOR_FEE_SHARE_BPS = 6_000;
    uint256 internal constant DISPUTE_WINDOW = 1 days;
    uint256 internal constant MAX_STALENESS = 7 days;

    uint256 internal constant INVOICE_TENOR = 30 days;
    uint256 internal constant FACE_VALUE = 12_500_000;
    uint256 internal constant PRINCIPAL = 10_000_000;
    uint256 internal constant SENIOR_PRINCIPAL = 7_000_000;
    uint256 internal constant JUNIOR_PRINCIPAL = 3_000_000;
    uint256 internal constant SENIOR_SEED = 14_000_000;
    uint256 internal constant JUNIOR_SEED = 6_000_000;
    uint256 internal constant TOTAL_SEED = 20_000_000;
    uint256 internal constant DEFAULT_RECOVERY = 7_000_000;
    uint256 internal constant DEFAULT_LOSS = 3_000_000;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    IERC20 internal immutable USDC = IERC20(SEPOLIA_USDC);
    InvoiceNFT internal immutable INVOICE_NFT = InvoiceNFT(INVOICE_NFT_ADDRESS);
    RWARiskManager internal immutable RISK_MANAGER = RWARiskManager(RISK_MANAGER_ADDRESS);
    InvoiceFinancingPool internal immutable POOL = InvoiceFinancingPool(POOL_ADDRESS);
    SeniorPool internal immutable SENIOR_POOL = SeniorPool(SENIOR_POOL_ADDRESS);
    JuniorPool internal immutable JUNIOR_POOL = JuniorPool(JUNIOR_POOL_ADDRESS);
    InvoiceStatusOracle internal immutable ORACLE = InvoiceStatusOracle(ORACLE_ADDRESS);

    struct TrancheState {
        uint256 totalAssets;
        uint256 lockedAssets;
        uint256 pendingLoss;
        uint256 availableLiquidity;
        uint256 accountedAssets;
        uint256 cash;
    }

    error WrongChainId(uint256 actual, uint256 expected);
    error MissingCode(address target);
    error UnexpectedBroadcaster(address actual, address expected);
    error AddressMismatch(bytes32 property, address actual, address expected);
    error ValueMismatch(bytes32 property, uint256 actual, uint256 expected);
    error BoolMismatch(bytes32 property, bool actual, bool expected);
    error RoleMismatch(address target, bytes32 role, address account, bool actual, bool expected);
    error InvalidBuyer(address buyer);
    error DuplicateBuyer(address buyer);
    error DuplicateInvoiceId(uint256 invoiceId);
    error InsufficientBalance(address account, uint256 actual, uint256 required);
    error InsufficientLiquidity(uint256 seniorAvailable, uint256 juniorAvailable);
    error ExistingAllowance(address owner, uint256 allowance);
    error ExistingDemoShares(uint256 seniorShares, uint256 juniorShares);
    error ExistingActiveProtocolState(uint256 totalLockedAssets, uint256 seniorPendingLoss, uint256 juniorPendingLoss);
    error InvalidInvoiceTiming(uint256 invoiceId, uint256 dueDate, uint256 currentTimestamp);
    error UpdateMissing(uint256 invoiceId);
    error UpdateDisputed(uint256 invoiceId);
    error UpdateAlreadyFinalized(uint256 invoiceId);
    error FinalizationTooEarly(uint256 invoiceId, uint256 currentTimestamp, uint256 earliestFinalizeAt);
    error UpdateStale(uint256 invoiceId, uint256 currentTimestamp, uint256 staleAfter);
    error AccountingIdentityMismatch(address tranche, uint256 fromNav, uint256 fromLiquidity);
    error ExpectedNonZero(bytes32 property);

    /// @notice Validates and logs the canonical system without broadcasting a transaction.
    function inspect() external view {
        _preflight();
        _validateConfigurationAndRoles();

        console2.log("=== LIVE DEMO: SYSTEM INSPECTION ===");
        console2.log("Network: Ethereum Sepolia");
        console2.log("Chain ID:", block.chainid);
        console2.log("USDC:", SEPOLIA_USDC);
        console2.log("InvoiceNFT:", INVOICE_NFT_ADDRESS);
        console2.log("RWARiskManager:", RISK_MANAGER_ADDRESS);
        console2.log("InvoiceFinancingPool:", POOL_ADDRESS);
        console2.log("SeniorPool:", SENIOR_POOL_ADDRESS);
        console2.log("JuniorPool:", JUNIOR_POOL_ADDRESS);
        console2.log("InvoiceStatusOracle:", ORACLE_ADDRESS);
        console2.log("DEMO_LP USDC balance:", USDC.balanceOf(DEMO_LP));
        console2.log("DEMO_SUPPLIER USDC balance:", USDC.balanceOf(DEMO_SUPPLIER));
        console2.log("DEMO_EXECUTOR USDC balance:", USDC.balanceOf(DEMO_EXECUTOR));
        _logProtocolAccounting();
    }

    /// @notice Deposits the exact two-invoice Senior and Junior liquidity as DEMO_LP.
    function seedLiquidity() external {
        _preflight();
        _requireUnprivileged(DEMO_LP);

        uint256 seniorSharesBefore = SENIOR_POOL.balanceOf(DEMO_LP);
        uint256 juniorSharesBefore = JUNIOR_POOL.balanceOf(DEMO_LP);
        if (seniorSharesBefore != 0 || juniorSharesBefore != 0) {
            revert ExistingDemoShares(seniorSharesBefore, juniorSharesBefore);
        }

        uint256 lpBalanceBefore = USDC.balanceOf(DEMO_LP);
        if (lpBalanceBefore < TOTAL_SEED) {
            revert InsufficientBalance(DEMO_LP, lpBalanceBefore, TOTAL_SEED);
        }
        _requireZeroAllowance(DEMO_LP);

        TrancheState memory seniorBefore = _seniorState();
        TrancheState memory juniorBefore = _juniorState();

        _startBroadcastAs(DEMO_LP);
        USDC.approve(POOL_ADDRESS, TOTAL_SEED);
        POOL.depositSenior(SENIOR_SEED);
        POOL.depositJunior(JUNIOR_SEED);
        vm.stopBroadcast();

        _expectEq("lp.balance", USDC.balanceOf(DEMO_LP) + TOTAL_SEED, lpBalanceBefore);
        _expectEq("lp.allowance", USDC.allowance(DEMO_LP, POOL_ADDRESS), 0);
        if (SENIOR_POOL.balanceOf(DEMO_LP) == 0) revert ExpectedNonZero("senior.shares");
        if (JUNIOR_POOL.balanceOf(DEMO_LP) == 0) revert ExpectedNonZero("junior.shares");

        TrancheState memory seniorAfter = _seniorState();
        TrancheState memory juniorAfter = _juniorState();
        _expectEq("senior.accounted.delta", seniorAfter.accountedAssets, seniorBefore.accountedAssets + SENIOR_SEED);
        _expectEq("junior.accounted.delta", juniorAfter.accountedAssets, juniorBefore.accountedAssets + JUNIOR_SEED);
        _expectEq(
            "senior.available.delta", seniorAfter.availableLiquidity, seniorBefore.availableLiquidity + SENIOR_SEED
        );
        _expectEq(
            "junior.available.delta", juniorAfter.availableLiquidity, juniorBefore.availableLiquidity + JUNIOR_SEED
        );
        _expectEq("senior.locked", seniorAfter.lockedAssets, seniorBefore.lockedAssets);
        _expectEq("junior.locked", juniorAfter.lockedAssets, juniorBefore.lockedAssets);
        _expectEq("senior.pending", seniorAfter.pendingLoss, seniorBefore.pendingLoss);
        _expectEq("junior.pending", juniorAfter.pendingLoss, juniorBefore.pendingLoss);

        console2.log("=== LIVE DEMO: LIQUIDITY SEEDED ===");
        console2.log("Actor:", DEMO_LP);
        console2.log("Senior deposit:", SENIOR_SEED);
        console2.log("Junior deposit:", JUNIOR_SEED);
        _logProtocolAccounting();
    }

    /// @notice Creates the settled-path and default-path invoices as OPERATIONS.
    function createInvoices(address settledBuyer, address defaultedBuyer)
        external
        returns (uint256 settledId, uint256 defaultedId)
    {
        _preflight();
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.ORIGINATOR_ROLE(), OPERATIONS, true);
        _validateBuyer(settledBuyer);
        _validateBuyer(defaultedBuyer);
        if (settledBuyer == defaultedBuyer) revert DuplicateBuyer(settledBuyer);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        _startBroadcastAs(OPERATIONS);
        settledId = INVOICE_NFT.createInvoice(DEMO_SUPPLIER, settledBuyer, FACE_VALUE, dueDate);
        defaultedId = INVOICE_NFT.createInvoice(DEMO_SUPPLIER, defaultedBuyer, FACE_VALUE, dueDate);
        vm.stopBroadcast();

        if (settledId == defaultedId) revert DuplicateInvoiceId(settledId);
        _assertInvoice(settledId, settledBuyer, IInvoiceNFT.InvoiceStatus.CREATED);
        _assertInvoice(defaultedId, defaultedBuyer, IInvoiceNFT.InvoiceStatus.CREATED);

        console2.log("=== LIVE DEMO: INVOICES CREATED ===");
        console2.log("Actor:", OPERATIONS);
        console2.log("Settled-path invoice ID:", settledId);
        console2.log("Default-path invoice ID:", defaultedId);
        console2.log("Face value per invoice:", FACE_VALUE);
        console2.log("Due date:", dueDate);
    }

    /// @notice Verifies both freshly created invoices as CONTROL.
    function verifyInvoices(uint256 settledId, uint256 defaultedId) external {
        _preflight();
        _requireDistinctIds(settledId, defaultedId);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.VERIFIER_ROLE(), CONTROL, true);

        IInvoiceNFT.Invoice memory settledInvoice = INVOICE_NFT.getInvoice(settledId);
        IInvoiceNFT.Invoice memory defaultedInvoice = INVOICE_NFT.getInvoice(defaultedId);
        _validateCanonicalInvoice(settledId, settledInvoice, IInvoiceNFT.InvoiceStatus.CREATED);
        _validateCanonicalInvoice(defaultedId, defaultedInvoice, IInvoiceNFT.InvoiceStatus.CREATED);
        if (settledInvoice.buyer == defaultedInvoice.buyer) revert DuplicateBuyer(settledInvoice.buyer);

        _startBroadcastAs(CONTROL);
        INVOICE_NFT.verify(settledId);
        INVOICE_NFT.verify(defaultedId);
        vm.stopBroadcast();

        _expectInvoiceStatus(settledId, IInvoiceNFT.InvoiceStatus.VERIFIED);
        _expectInvoiceStatus(defaultedId, IInvoiceNFT.InvoiceStatus.VERIFIED);

        console2.log("=== LIVE DEMO: INVOICES VERIFIED ===");
        console2.log("Actor:", CONTROL);
        console2.log("Settled-path invoice ID:", settledId);
        console2.log("Default-path invoice ID:", defaultedId);
    }

    /// @notice Requests financing for both verified invoices as their recorded Supplier.
    function financeInvoices(uint256 settledId, uint256 defaultedId) external {
        _preflight();
        _requireDistinctIds(settledId, defaultedId);
        _requireUnprivileged(DEMO_SUPPLIER);

        IInvoiceNFT.Invoice memory settledInvoice = INVOICE_NFT.getInvoice(settledId);
        IInvoiceNFT.Invoice memory defaultedInvoice = INVOICE_NFT.getInvoice(defaultedId);
        _validateFinanceableInvoice(settledId, settledInvoice);
        _validateFinanceableInvoice(defaultedId, defaultedInvoice);
        if (settledInvoice.buyer == defaultedInvoice.buyer) revert DuplicateBuyer(settledInvoice.buyer);
        _assertCanonicalFinancingApr();

        _expectEq("settled.exposure", RISK_MANAGER.getBuyerExposure(settledInvoice.buyer), 0);
        _expectEq("defaulted.exposure", RISK_MANAGER.getBuyerExposure(defaultedInvoice.buyer), 0);
        _expectPositionAbsent(settledId);
        _expectPositionAbsent(defaultedId);

        uint256 seniorAvailable = SENIOR_POOL.availableLiquidity();
        uint256 juniorAvailable = JUNIOR_POOL.availableLiquidity();
        if (seniorAvailable < SENIOR_SEED || juniorAvailable < JUNIOR_SEED) {
            revert InsufficientLiquidity(seniorAvailable, juniorAvailable);
        }

        uint256 lockedBefore = POOL.totalLockedAssets();
        uint256 supplierBalanceBefore = USDC.balanceOf(DEMO_SUPPLIER);
        TrancheState memory seniorBefore = _seniorState();
        TrancheState memory juniorBefore = _juniorState();
        if (lockedBefore != 0 || seniorBefore.pendingLoss != 0 || juniorBefore.pendingLoss != 0) {
            revert ExistingActiveProtocolState(lockedBefore, seniorBefore.pendingLoss, juniorBefore.pendingLoss);
        }

        _startBroadcastAs(DEMO_SUPPLIER);
        POOL.financeInvoice(settledId);
        POOL.financeInvoice(defaultedId);
        vm.stopBroadcast();

        _assertCanonicalPosition(settledId, settledInvoice.buyer, false);
        _assertCanonicalPosition(defaultedId, defaultedInvoice.buyer, false);
        _assertFundingTimeFee(settledId);
        _assertFundingTimeFee(defaultedId);
        _expectInvoiceStatus(settledId, IInvoiceNFT.InvoiceStatus.FUNDED);
        _expectInvoiceStatus(defaultedId, IInvoiceNFT.InvoiceStatus.FUNDED);
        _expectEq("pool.locked.delta", POOL.totalLockedAssets(), lockedBefore + TOTAL_SEED);
        _expectEq("supplier.balance.delta", USDC.balanceOf(DEMO_SUPPLIER), supplierBalanceBefore + TOTAL_SEED);
        _expectEq("settled.exposure", RISK_MANAGER.getBuyerExposure(settledInvoice.buyer), PRINCIPAL);
        _expectEq("defaulted.exposure", RISK_MANAGER.getBuyerExposure(defaultedInvoice.buyer), PRINCIPAL);

        TrancheState memory seniorAfter = _seniorState();
        TrancheState memory juniorAfter = _juniorState();
        _expectEq("senior.nav", seniorAfter.totalAssets, seniorBefore.totalAssets);
        _expectEq("junior.nav", juniorAfter.totalAssets, juniorBefore.totalAssets);
        _expectEq("senior.locked.delta", seniorAfter.lockedAssets, seniorBefore.lockedAssets + SENIOR_SEED);
        _expectEq("junior.locked.delta", juniorAfter.lockedAssets, juniorBefore.lockedAssets + JUNIOR_SEED);
        _expectEq(
            "senior.available.delta", seniorAfter.availableLiquidity + SENIOR_SEED, seniorBefore.availableLiquidity
        );
        _expectEq(
            "junior.available.delta", juniorAfter.availableLiquidity + JUNIOR_SEED, juniorBefore.availableLiquidity
        );

        console2.log("=== LIVE DEMO: INVOICES FINANCED ===");
        console2.log("Actor:", DEMO_SUPPLIER);
        _logPosition(settledId, "Settled-path");
        _logPosition(defaultedId, "Default-path");
        _logProtocolAccounting();
    }

    /// @notice Submits SETTLED and DEFAULTED outcomes as OPERATIONS.
    function submitOutcomes(uint256 settledId, uint256 defaultedId) external {
        _preflight();
        _requireDistinctIds(settledId, defaultedId);
        _requireRole(ORACLE_ADDRESS, ORACLE.ORACLE_SUBMITTER_ROLE(), OPERATIONS, true);
        _validateActiveCanonicalPosition(settledId);
        _validateActiveCanonicalPosition(defaultedId);
        _requireDistinctPositionBuyers(settledId, defaultedId);
        _expectNoOracleUpdate(settledId);
        _expectNoOracleUpdate(defaultedId);

        _startBroadcastAs(OPERATIONS);
        ORACLE.submitStatus(settledId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        ORACLE.submitStatus(defaultedId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);
        vm.stopBroadcast();

        _assertSubmittedUpdate(settledId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _assertSubmittedUpdate(defaultedId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        console2.log("=== LIVE DEMO: ORACLE OUTCOMES SUBMITTED ===");
        console2.log("Actor:", OPERATIONS);
        _logOracleUpdate(settledId, "Settled-path");
        _logOracleUpdate(defaultedId, "Default-path");
        console2.log("Wait for on-chain dispute window before finalization:", ORACLE.disputeWindow());
    }

    /// @notice Permissionlessly finalizes both outcomes after validating on-chain timing.
    function finalizeOutcomes(uint256 settledId, uint256 defaultedId) external {
        _preflight();
        _requireDistinctIds(settledId, defaultedId);
        _requireUnprivileged(DEMO_EXECUTOR);
        _validateActiveCanonicalPosition(settledId);
        _validateActiveCanonicalPosition(defaultedId);
        _requireDistinctPositionBuyers(settledId, defaultedId);
        _validateFinalizableUpdate(settledId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _validateFinalizableUpdate(defaultedId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceNFT.Invoice memory settledInvoice = INVOICE_NFT.getInvoice(settledId);
        IInvoiceNFT.Invoice memory defaultedInvoice = INVOICE_NFT.getInvoice(defaultedId);
        TrancheState memory seniorBefore = _seniorState();
        TrancheState memory juniorBefore = _juniorState();
        uint256 totalLockedBefore = POOL.totalLockedAssets();
        uint256 totalBadDebtBefore = POOL.totalBadDebt();
        uint256 settledExposureBefore = RISK_MANAGER.getBuyerExposure(settledInvoice.buyer);
        uint256 defaultedExposureBefore = RISK_MANAGER.getBuyerExposure(defaultedInvoice.buyer);

        _startBroadcastAs(DEMO_EXECUTOR);
        ORACLE.finalize(settledId);
        ORACLE.finalize(defaultedId);
        vm.stopBroadcast();

        _expectBool("settled.finalized", POOL.isOracleStatusFinalized(settledId), true);
        _expectBool("defaulted.finalized", POOL.isOracleStatusFinalized(defaultedId), true);
        _expectStatusValue(
            "settled.oracleStatus", POOL.finalizedOracleStatus(settledId), IInvoiceNFT.InvoiceStatus.SETTLED
        );
        _expectStatusValue(
            "defaulted.oracleStatus", POOL.finalizedOracleStatus(defaultedId), IInvoiceNFT.InvoiceStatus.DEFAULTED
        );
        _expectEq("settled.recovery", POOL.finalizedRecoveryAmount(settledId), 0);
        _expectEq("defaulted.recovery", POOL.finalizedRecoveryAmount(defaultedId), DEFAULT_RECOVERY);
        _expectInvoiceStatus(settledId, IInvoiceNFT.InvoiceStatus.FUNDED);
        _expectInvoiceStatus(defaultedId, IInvoiceNFT.InvoiceStatus.FUNDED);
        _expectBool("settled.resolved", _position(settledId).resolved, false);
        _expectBool("defaulted.resolved", _position(defaultedId).resolved, false);
        _expectEq("pool.locked", POOL.totalLockedAssets(), totalLockedBefore);
        _expectEq("pool.badDebt", POOL.totalBadDebt(), totalBadDebtBefore);
        _expectEq("settled.exposure", RISK_MANAGER.getBuyerExposure(settledInvoice.buyer), settledExposureBefore);
        _expectEq("defaulted.exposure", RISK_MANAGER.getBuyerExposure(defaultedInvoice.buyer), defaultedExposureBefore);

        TrancheState memory seniorAfter = _seniorState();
        TrancheState memory juniorAfter = _juniorState();
        _expectEq("senior.pending", seniorAfter.pendingLoss, seniorBefore.pendingLoss);
        _expectEq("junior.pending.delta", juniorAfter.pendingLoss, juniorBefore.pendingLoss + DEFAULT_LOSS);
        _expectEq("senior.nav", seniorAfter.totalAssets, seniorBefore.totalAssets);
        _expectEq("junior.nav.delta", juniorAfter.totalAssets + DEFAULT_LOSS, juniorBefore.totalAssets);
        _expectEq("senior.accounted", seniorAfter.accountedAssets, seniorBefore.accountedAssets);
        _expectEq("junior.accounted", juniorAfter.accountedAssets, juniorBefore.accountedAssets);
        _expectEq("senior.locked", seniorAfter.lockedAssets, seniorBefore.lockedAssets);
        _expectEq("junior.locked", juniorAfter.lockedAssets, juniorBefore.lockedAssets);
        _expectEq("senior.available", seniorAfter.availableLiquidity, seniorBefore.availableLiquidity);
        _expectEq("junior.available", juniorAfter.availableLiquidity, juniorBefore.availableLiquidity);
        _expectEq("senior.cash", seniorAfter.cash, seniorBefore.cash);
        _expectEq("junior.cash", juniorAfter.cash, juniorBefore.cash);

        console2.log("=== LIVE DEMO: OUTCOMES FINALIZED ===");
        console2.log("Actor:", DEMO_EXECUTOR);
        console2.log("Critical checkpoint: default finalized, not economically resolved");
        console2.log("Default-path invoice status (FUNDED=2):", uint256(INVOICE_NFT.getInvoice(defaultedId).status));
        console2.log("Default-path Buyer exposure:", RISK_MANAGER.getBuyerExposure(defaultedInvoice.buyer));
        console2.log("Default-path position resolved:", _position(defaultedId).resolved);
        console2.log("Junior reserved pendingLoss delta:", DEFAULT_LOSS);
        console2.log("totalBadDebt (unchanged):", POOL.totalBadDebt());
        _logProtocolAccounting();
    }

    /// @notice Supplies the finalized recovery and resolves the default as DEMO_EXECUTOR.
    function resolveDefault(uint256 defaultedId) external {
        _preflight();
        _requireUnprivileged(DEMO_EXECUTOR);
        IInvoiceFinancingPool.FinancingPosition memory position = _position(defaultedId);
        _validateCanonicalPosition(defaultedId, position, false);
        _expectInvoiceStatus(defaultedId, IInvoiceNFT.InvoiceStatus.FUNDED);
        _expectBool("oracle.finalized", POOL.isOracleStatusFinalized(defaultedId), true);
        _expectStatusValue(
            "oracle.status", POOL.finalizedOracleStatus(defaultedId), IInvoiceNFT.InvoiceStatus.DEFAULTED
        );
        _expectEq("oracle.recovery", POOL.finalizedRecoveryAmount(defaultedId), DEFAULT_RECOVERY);
        _requireZeroAllowance(DEMO_EXECUTOR);

        uint256 executorBalanceBefore = USDC.balanceOf(DEMO_EXECUTOR);
        if (executorBalanceBefore < DEFAULT_RECOVERY) {
            revert InsufficientBalance(DEMO_EXECUTOR, executorBalanceBefore, DEFAULT_RECOVERY);
        }

        TrancheState memory seniorBefore = _seniorState();
        TrancheState memory juniorBefore = _juniorState();
        uint256 exposureBefore = RISK_MANAGER.getBuyerExposure(position.buyer);
        uint256 totalLockedBefore = POOL.totalLockedAssets();
        uint256 totalBadDebtBefore = POOL.totalBadDebt();
        _expectEq("junior.pendingLoss", juniorBefore.pendingLoss, DEFAULT_LOSS);
        _expectEq("senior.pendingLoss", seniorBefore.pendingLoss, 0);

        console2.log("=== LIVE DEMO: PRE-DEFAULT-RESOLUTION SNAPSHOT ===");
        _logProtocolAccounting();

        _startBroadcastAs(DEMO_EXECUTOR);
        USDC.approve(POOL_ADDRESS, DEFAULT_RECOVERY);
        POOL.resolveDefault(defaultedId);
        vm.stopBroadcast();

        _expectEq("executor.balance.delta", USDC.balanceOf(DEMO_EXECUTOR) + DEFAULT_RECOVERY, executorBalanceBefore);
        _expectEq("executor.allowance", USDC.allowance(DEMO_EXECUTOR, POOL_ADDRESS), 0);
        _expectInvoiceStatus(defaultedId, IInvoiceNFT.InvoiceStatus.DEFAULTED);
        _expectBool("position.resolved", _position(defaultedId).resolved, true);
        _expectEq("buyer.exposure.delta", RISK_MANAGER.getBuyerExposure(position.buyer) + PRINCIPAL, exposureBefore);
        _expectEq("pool.locked.delta", POOL.totalLockedAssets() + PRINCIPAL, totalLockedBefore);
        _expectEq("pool.badDebt.delta", POOL.totalBadDebt(), totalBadDebtBefore + DEFAULT_LOSS);

        TrancheState memory seniorAfter = _seniorState();
        TrancheState memory juniorAfter = _juniorState();
        _expectEq("senior.nav.noDoubleHaircut", seniorAfter.totalAssets, seniorBefore.totalAssets);
        _expectEq("junior.nav.noDoubleHaircut", juniorAfter.totalAssets, juniorBefore.totalAssets);
        _expectEq("senior.pending", seniorAfter.pendingLoss, 0);
        _expectEq("junior.pending", juniorAfter.pendingLoss, 0);
        _expectEq("senior.accounted", seniorAfter.accountedAssets, seniorBefore.accountedAssets);
        _expectEq(
            "junior.accounted.writeDown", juniorAfter.accountedAssets + DEFAULT_LOSS, juniorBefore.accountedAssets
        );
        _expectEq("senior.locked.delta", seniorAfter.lockedAssets + SENIOR_PRINCIPAL, seniorBefore.lockedAssets);
        _expectEq("junior.locked.delta", juniorAfter.lockedAssets + JUNIOR_PRINCIPAL, juniorBefore.lockedAssets);
        _expectEq("senior.cash.recovery", seniorAfter.cash, seniorBefore.cash + DEFAULT_RECOVERY);
        _expectEq("junior.cash", juniorAfter.cash, juniorBefore.cash);

        console2.log("=== LIVE DEMO: DEFAULT RESOLVED ===");
        console2.log("Actor:", DEMO_EXECUTOR);
        console2.log("Invoice ID:", defaultedId);
        console2.log("Recovery supplied:", DEFAULT_RECOVERY);
        console2.log("Realized bad debt delta:", DEFAULT_LOSS);
        console2.log("Senior NAV before / after:", seniorBefore.totalAssets, seniorAfter.totalAssets);
        console2.log("Junior NAV before / after:", juniorBefore.totalAssets, juniorAfter.totalAssets);
        _logProtocolAccounting();
    }

    /// @notice Pays the exact stored repayment and settles the paid-path invoice.
    function settleInvoice(uint256 settledId) external {
        _preflight();
        _requireUnprivileged(DEMO_EXECUTOR);
        IInvoiceFinancingPool.FinancingPosition memory position = _position(settledId);
        _validateCanonicalPosition(settledId, position, false);
        _expectInvoiceStatus(settledId, IInvoiceNFT.InvoiceStatus.FUNDED);
        _expectBool("oracle.finalized", POOL.isOracleStatusFinalized(settledId), true);
        _expectStatusValue("oracle.status", POOL.finalizedOracleStatus(settledId), IInvoiceNFT.InvoiceStatus.SETTLED);
        _expectEq("oracle.recovery", POOL.finalizedRecoveryAmount(settledId), 0);
        _requireZeroAllowance(DEMO_EXECUTOR);

        uint256 requiredSettlement = position.principal + position.financingFee;
        uint256 executorBalanceBefore = USDC.balanceOf(DEMO_EXECUTOR);
        if (executorBalanceBefore < requiredSettlement) {
            revert InsufficientBalance(DEMO_EXECUTOR, executorBalanceBefore, requiredSettlement);
        }

        uint256 juniorFee = position.financingFee * POOL.JUNIOR_FEE_SHARE_BPS() / BPS_DENOMINATOR;
        uint256 seniorFee = position.financingFee - juniorFee;
        TrancheState memory seniorBefore = _seniorState();
        TrancheState memory juniorBefore = _juniorState();
        uint256 exposureBefore = RISK_MANAGER.getBuyerExposure(position.buyer);
        uint256 totalLockedBefore = POOL.totalLockedAssets();
        uint256 totalBadDebtBefore = POOL.totalBadDebt();

        _startBroadcastAs(DEMO_EXECUTOR);
        USDC.approve(POOL_ADDRESS, requiredSettlement);
        POOL.settleInvoice(settledId, requiredSettlement);
        vm.stopBroadcast();

        _expectEq("executor.balance.delta", USDC.balanceOf(DEMO_EXECUTOR) + requiredSettlement, executorBalanceBefore);
        _expectEq("executor.allowance", USDC.allowance(DEMO_EXECUTOR, POOL_ADDRESS), 0);
        _expectInvoiceStatus(settledId, IInvoiceNFT.InvoiceStatus.SETTLED);
        _expectBool("position.resolved", _position(settledId).resolved, true);
        _expectEq("buyer.exposure.delta", RISK_MANAGER.getBuyerExposure(position.buyer) + PRINCIPAL, exposureBefore);
        _expectEq("pool.locked.delta", POOL.totalLockedAssets() + PRINCIPAL, totalLockedBefore);
        _expectEq("pool.badDebt", POOL.totalBadDebt(), totalBadDebtBefore);

        TrancheState memory seniorAfter = _seniorState();
        TrancheState memory juniorAfter = _juniorState();
        _expectEq("senior.nav.fee", seniorAfter.totalAssets, seniorBefore.totalAssets + seniorFee);
        _expectEq("junior.nav.fee", juniorAfter.totalAssets, juniorBefore.totalAssets + juniorFee);
        _expectEq("senior.accounted.fee", seniorAfter.accountedAssets, seniorBefore.accountedAssets + seniorFee);
        _expectEq("junior.accounted.fee", juniorAfter.accountedAssets, juniorBefore.accountedAssets + juniorFee);
        _expectEq("senior.locked.delta", seniorAfter.lockedAssets + SENIOR_PRINCIPAL, seniorBefore.lockedAssets);
        _expectEq("junior.locked.delta", juniorAfter.lockedAssets + JUNIOR_PRINCIPAL, juniorBefore.lockedAssets);
        _expectEq("senior.cash.repayment", seniorAfter.cash, seniorBefore.cash + SENIOR_PRINCIPAL + seniorFee);
        _expectEq("junior.cash.repayment", juniorAfter.cash, juniorBefore.cash + JUNIOR_PRINCIPAL + juniorFee);

        console2.log("=== LIVE DEMO: INVOICE SETTLED ===");
        console2.log("Actor:", DEMO_EXECUTOR);
        console2.log("Invoice ID:", settledId);
        console2.log("Stored principal:", position.principal);
        console2.log("Stored financing fee:", position.financingFee);
        console2.log("Exact settlement payment:", requiredSettlement);
        console2.log("Senior fee share:", seniorFee);
        console2.log("Junior fee share:", juniorFee);
        _logProtocolAccounting();
    }

    /// @notice Validates and logs the resolved two-invoice end state.
    function finalInspection(uint256 settledId, uint256 defaultedId) external view {
        _preflight();
        _requireDistinctIds(settledId, defaultedId);
        IInvoiceFinancingPool.FinancingPosition memory settledPosition = _position(settledId);
        IInvoiceFinancingPool.FinancingPosition memory defaultedPosition = _position(defaultedId);
        _validateCanonicalPosition(settledId, settledPosition, true);
        _validateCanonicalPosition(defaultedId, defaultedPosition, true);
        if (settledPosition.buyer == defaultedPosition.buyer) revert DuplicateBuyer(settledPosition.buyer);
        _expectInvoiceStatus(settledId, IInvoiceNFT.InvoiceStatus.SETTLED);
        _expectInvoiceStatus(defaultedId, IInvoiceNFT.InvoiceStatus.DEFAULTED);
        _expectEq("settled.exposure", RISK_MANAGER.getBuyerExposure(settledPosition.buyer), 0);
        _expectEq("defaulted.exposure", RISK_MANAGER.getBuyerExposure(defaultedPosition.buyer), 0);
        _expectEq("pool.locked", POOL.totalLockedAssets(), 0);
        _expectEq("senior.locked", SENIOR_POOL.lockedAssets(), 0);
        _expectEq("junior.locked", JUNIOR_POOL.lockedAssets(), 0);
        _expectEq("senior.pending", SENIOR_POOL.pendingLoss(), 0);
        _expectEq("junior.pending", JUNIOR_POOL.pendingLoss(), 0);
        // totalBadDebt is cumulative; the scenario-specific delta is proven in resolveDefault().
        if (POOL.totalBadDebt() < DEFAULT_LOSS) {
            revert ValueMismatch("pool.badDebt.minimum", POOL.totalBadDebt(), DEFAULT_LOSS);
        }

        uint256 juniorFee = settledPosition.financingFee * POOL.JUNIOR_FEE_SHARE_BPS() / BPS_DENOMINATOR;
        uint256 seniorFee = settledPosition.financingFee - juniorFee;

        console2.log("=== LIVE DEMO: FINAL INSPECTION ===");
        console2.log("Settled-path invoice ID / status:", settledId, uint256(INVOICE_NFT.getInvoice(settledId).status));
        console2.log(
            "Default-path invoice ID / status:", defaultedId, uint256(INVOICE_NFT.getInvoice(defaultedId).status)
        );
        console2.log("Both financing positions resolved: true");
        console2.log("Realized settlement fee:", settledPosition.financingFee);
        console2.log("Senior fee share included in NAV:", seniorFee);
        console2.log("Junior fee share included in NAV:", juniorFee);
        console2.log("Scenario default loss (delta proven during resolveDefault):", DEFAULT_LOSS);
        console2.log("Cumulative protocol totalBadDebt:", POOL.totalBadDebt());
        _logProtocolAccounting();
    }

    function _preflight() internal view {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert WrongChainId(block.chainid, SEPOLIA_CHAIN_ID);

        _requireCode(SEPOLIA_USDC);
        _requireCode(INVOICE_NFT_ADDRESS);
        _requireCode(RISK_MANAGER_ADDRESS);
        _requireCode(POOL_ADDRESS);
        _requireCode(SENIOR_POOL_ADDRESS);
        _requireCode(JUNIOR_POOL_ADDRESS);
        _requireCode(ORACLE_ADDRESS);

        _expectEq("usdc.decimals", IERC20Metadata(SEPOLIA_USDC).decimals(), USDC_DECIMALS);
        _expectAddress("pool.asset", address(POOL.ASSET()), SEPOLIA_USDC);
        _expectAddress("pool.invoiceNft", address(POOL.INVOICE_NFT()), INVOICE_NFT_ADDRESS);
        _expectAddress("pool.riskManager", address(POOL.RISK_MANAGER()), RISK_MANAGER_ADDRESS);
        _expectAddress("pool.seniorPool", address(POOL.SENIOR_POOL()), SENIOR_POOL_ADDRESS);
        _expectAddress("pool.juniorPool", address(POOL.JUNIOR_POOL()), JUNIOR_POOL_ADDRESS);
        _expectAddress("pool.oracle", POOL.invoiceStatusOracle(), ORACLE_ADDRESS);
        _expectAddress("senior.asset", SENIOR_POOL.asset(), SEPOLIA_USDC);
        _expectAddress("junior.asset", JUNIOR_POOL.asset(), SEPOLIA_USDC);
        _expectAddress("senior.coordinator", SENIOR_POOL.INVOICE_FINANCING_POOL(), POOL_ADDRESS);
        _expectAddress("junior.coordinator", JUNIOR_POOL.INVOICE_FINANCING_POOL(), POOL_ADDRESS);
        _expectAddress("oracle.invoiceNft", address(ORACLE.INVOICE_NFT()), INVOICE_NFT_ADDRESS);
        _expectAddress("oracle.pool", address(ORACLE.POOL()), POOL_ADDRESS);
        _expectAddress("risk.invoiceNft", address(RISK_MANAGER.INVOICE_NFT()), INVOICE_NFT_ADDRESS);
    }

    function _validateConfigurationAndRoles() internal view {
        (uint256 maxExposure, uint256 advanceRate, uint256 maxTenor, uint256 minimum, uint256 feeApr) =
            RISK_MANAGER.riskParams();
        _expectEq("risk.maxExposure", maxExposure, MAX_EXPOSURE_PER_BUYER);
        _expectEq("risk.advanceRate", advanceRate, ADVANCE_RATE_BPS);
        _expectEq("risk.maxTenor", maxTenor, MAX_INVOICE_TENOR);
        _expectEq("risk.minimum", minimum, MIN_INVOICE_AMOUNT);
        _expectEq("risk.feeApr", feeApr, FINANCING_FEE_APR_BPS);
        _expectEq("pool.seniorFunding", POOL.SENIOR_FUNDING_SHARE_BPS(), SENIOR_FUNDING_SHARE_BPS);
        _expectEq("pool.juniorFunding", POOL.JUNIOR_FUNDING_SHARE_BPS(), JUNIOR_FUNDING_SHARE_BPS);
        _expectEq("pool.seniorFee", POOL.SENIOR_FEE_SHARE_BPS(), SENIOR_FEE_SHARE_BPS);
        _expectEq("pool.juniorFee", POOL.JUNIOR_FEE_SHARE_BPS(), JUNIOR_FEE_SHARE_BPS);
        _expectEq("oracle.disputeWindow", ORACLE.disputeWindow(), DISPUTE_WINDOW);
        _expectEq("oracle.maxStaleness", ORACLE.maxStaleness(), MAX_STALENESS);
        _expectAddress("pool.admin", POOL.ADMIN(), ADMIN);

        _requireRole(INVOICE_NFT_ADDRESS, DEFAULT_ADMIN_ROLE, ADMIN, true);
        _requireRole(RISK_MANAGER_ADDRESS, DEFAULT_ADMIN_ROLE, ADMIN, true);
        _requireRole(ORACLE_ADDRESS, DEFAULT_ADMIN_ROLE, ADMIN, true);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.ORIGINATOR_ROLE(), OPERATIONS, true);
        _requireRole(ORACLE_ADDRESS, ORACLE.ORACLE_SUBMITTER_ROLE(), OPERATIONS, true);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.VERIFIER_ROLE(), CONTROL, true);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.RISK_ROLE(), CONTROL, true);
        _requireRole(RISK_MANAGER_ADDRESS, RISK_MANAGER.RISK_ADMIN_ROLE(), CONTROL, true);
        _requireRole(ORACLE_ADDRESS, ORACLE.DISPUTE_ADMIN_ROLE(), CONTROL, true);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.POOL_ROLE(), POOL_ADDRESS, true);
        _requireRole(RISK_MANAGER_ADDRESS, RISK_MANAGER.POOL_ROLE(), POOL_ADDRESS, true);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.ORIGINATOR_ROLE(), ADMIN, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.VERIFIER_ROLE(), ADMIN, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.RISK_ROLE(), ADMIN, false);
        _requireRole(ORACLE_ADDRESS, ORACLE.ORACLE_SUBMITTER_ROLE(), ADMIN, false);
        _requireRole(ORACLE_ADDRESS, ORACLE.DISPUTE_ADMIN_ROLE(), ADMIN, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.VERIFIER_ROLE(), OPERATIONS, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.RISK_ROLE(), OPERATIONS, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.ORIGINATOR_ROLE(), CONTROL, false);
        _requireRole(ORACLE_ADDRESS, ORACLE.ORACLE_SUBMITTER_ROLE(), CONTROL, false);
        _requireUnprivileged(DEMO_LP);
        _requireUnprivileged(DEMO_SUPPLIER);
        _requireUnprivileged(DEMO_EXECUTOR);
    }

    function _validateBuyer(address buyer) internal pure {
        if (buyer == address(0) || buyer == DEMO_SUPPLIER) revert InvalidBuyer(buyer);
    }

    function _validateCanonicalInvoice(
        uint256 invoiceId,
        IInvoiceNFT.Invoice memory invoice,
        IInvoiceNFT.InvoiceStatus expectedStatus
    ) internal view {
        _expectAddress("invoice.supplier", invoice.supplier, DEMO_SUPPLIER);
        _validateBuyer(invoice.buyer);
        _expectEq("invoice.faceValue", invoice.faceValue, FACE_VALUE);
        _expectStatusValue("invoice.status", invoice.status, expectedStatus);
        if (invoice.dueDate <= block.timestamp) {
            revert InvalidInvoiceTiming(invoiceId, invoice.dueDate, block.timestamp);
        }
    }

    function _validateFinanceableInvoice(uint256 invoiceId, IInvoiceNFT.Invoice memory invoice) internal view {
        _validateCanonicalInvoice(invoiceId, invoice, IInvoiceNFT.InvoiceStatus.VERIFIED);
        if (invoice.dueDate - block.timestamp > MAX_INVOICE_TENOR) {
            revert InvalidInvoiceTiming(invoiceId, invoice.dueDate, block.timestamp);
        }
        _expectBool("risk.eligible", RISK_MANAGER.isEligible(invoiceId), true);
        _expectEq("risk.advance", RISK_MANAGER.calculateAdvance(invoice.faceValue), PRINCIPAL);
        _expectBool("risk.concentration", RISK_MANAGER.checkConcentration(invoice.buyer, PRINCIPAL), true);
    }

    function _assertCanonicalFinancingApr() internal view {
        (,,,, uint256 financingFeeApr) = RISK_MANAGER.riskParams();
        _expectEq("risk.feeApr.atFunding", financingFeeApr, FINANCING_FEE_APR_BPS);
    }

    function _assertFundingTimeFee(uint256 invoiceId) internal view {
        IInvoiceFinancingPool.FinancingPosition memory position = _position(invoiceId);
        uint256 expectedFee = RISK_MANAGER.calculateFee(position.principal, position.fundedAt, position.dueDate);
        _expectEq("position.fee.atFunding", position.financingFee, expectedFee);
    }

    function _validateActiveCanonicalPosition(uint256 invoiceId) internal view {
        _expectInvoiceStatus(invoiceId, IInvoiceNFT.InvoiceStatus.FUNDED);
        _validateCanonicalPosition(invoiceId, _position(invoiceId), false);
    }

    function _validateCanonicalPosition(
        uint256 invoiceId,
        IInvoiceFinancingPool.FinancingPosition memory position,
        bool expectedResolved
    ) internal view {
        _expectAddress("position.supplier", position.supplier, DEMO_SUPPLIER);
        _validateBuyer(position.buyer);
        _expectEq("position.principal", position.principal, PRINCIPAL);
        _expectEq("position.senior", position.seniorPrincipal, SENIOR_PRINCIPAL);
        _expectEq("position.junior", position.juniorPrincipal, JUNIOR_PRINCIPAL);
        if (position.fundedAt == 0) revert ExpectedNonZero("position.fundedAt");
        _expectBool("position.resolved", position.resolved, expectedResolved);
        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);
        _expectAddress("position.buyer", position.buyer, invoice.buyer);
        _expectEq("position.dueDate", position.dueDate, invoice.dueDate);
        _expectEq("position.fundedAt.nft", position.fundedAt, invoice.fundedAt);
    }

    function _assertCanonicalPosition(uint256 invoiceId, address buyer, bool resolved) internal view {
        IInvoiceFinancingPool.FinancingPosition memory position = _position(invoiceId);
        _validateCanonicalPosition(invoiceId, position, resolved);
        _expectAddress("position.buyer", position.buyer, buyer);
    }

    function _expectPositionAbsent(uint256 invoiceId) internal view {
        IInvoiceFinancingPool.FinancingPosition memory position = _position(invoiceId);
        _expectEq("position.fundedAt", position.fundedAt, 0);
        _expectBool("position.resolved", position.resolved, false);
    }

    function _position(uint256 invoiceId)
        internal
        view
        returns (IInvoiceFinancingPool.FinancingPosition memory position)
    {
        (bool success, bytes memory result) =
            POOL_ADDRESS.staticcall(abi.encodeCall(IInvoiceFinancingPool.financingPositions, (invoiceId)));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        position = abi.decode(result, (IInvoiceFinancingPool.FinancingPosition));
    }

    function _expectNoOracleUpdate(uint256 invoiceId) internal view {
        IInvoiceStatusOracle.StatusUpdate memory update = ORACLE.getStatusUpdate(invoiceId);
        _expectEq("update.invoiceId", update.invoiceId, 0);
        _expectEq("update.submittedAt", update.submittedAt, 0);
        _expectBool("update.disputed", update.disputed, false);
        _expectBool("update.finalized", update.finalized, false);
        _expectBool("pool.finalized", POOL.isOracleStatusFinalized(invoiceId), false);
    }

    function _assertSubmittedUpdate(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status, uint256 recoveredAmount)
        internal
        view
    {
        IInvoiceStatusOracle.StatusUpdate memory update = ORACLE.getStatusUpdate(invoiceId);
        _expectEq("update.invoiceId", update.invoiceId, invoiceId);
        _expectStatusValue("update.status", update.newStatus, status);
        _expectEq("update.recovery", update.recoveredAmount, recoveredAmount);
        if (update.submittedAt == 0) revert UpdateMissing(invoiceId);
        _expectBool("update.disputed", update.disputed, false);
        _expectBool("update.finalized", update.finalized, false);
    }

    function _validateFinalizableUpdate(
        uint256 invoiceId,
        IInvoiceNFT.InvoiceStatus expectedStatus,
        uint256 expectedRecovery
    ) internal view {
        IInvoiceStatusOracle.StatusUpdate memory update = ORACLE.getStatusUpdate(invoiceId);
        if (update.submittedAt == 0) revert UpdateMissing(invoiceId);
        if (update.disputed) revert UpdateDisputed(invoiceId);
        if (update.finalized) revert UpdateAlreadyFinalized(invoiceId);
        _expectEq("update.invoiceId", update.invoiceId, invoiceId);
        _expectStatusValue("update.status", update.newStatus, expectedStatus);
        _expectEq("update.recovery", update.recoveredAmount, expectedRecovery);

        uint256 earliestFinalizeAt = update.submittedAt + ORACLE.disputeWindow();
        if (block.timestamp < earliestFinalizeAt) {
            revert FinalizationTooEarly(invoiceId, block.timestamp, earliestFinalizeAt);
        }
        uint256 staleAfter = update.submittedAt + ORACLE.maxStaleness();
        if (block.timestamp > staleAfter) revert UpdateStale(invoiceId, block.timestamp, staleAfter);
    }

    function _assertInvoice(uint256 invoiceId, address buyer, IInvoiceNFT.InvoiceStatus status) internal view {
        IInvoiceNFT.Invoice memory invoice = INVOICE_NFT.getInvoice(invoiceId);
        _validateCanonicalInvoice(invoiceId, invoice, status);
        _expectAddress("invoice.buyer", invoice.buyer, buyer);
        _expectEq("invoice.fundedAt", invoice.fundedAt, 0);
    }

    function _expectInvoiceStatus(uint256 invoiceId, IInvoiceNFT.InvoiceStatus expected) internal view {
        _expectStatusValue("invoice.status", INVOICE_NFT.getInvoice(invoiceId).status, expected);
    }

    function _seniorState() internal view returns (TrancheState memory state) {
        state.totalAssets = SENIOR_POOL.totalAssets();
        state.lockedAssets = SENIOR_POOL.lockedAssets();
        state.pendingLoss = SENIOR_POOL.pendingLoss();
        state.availableLiquidity = SENIOR_POOL.availableLiquidity();
        state.accountedAssets = state.totalAssets + state.pendingLoss;
        state.cash = USDC.balanceOf(SENIOR_POOL_ADDRESS);
        _assertAccountingIdentity(SENIOR_POOL_ADDRESS, state);
    }

    function _juniorState() internal view returns (TrancheState memory state) {
        state.totalAssets = JUNIOR_POOL.totalAssets();
        state.lockedAssets = JUNIOR_POOL.lockedAssets();
        state.pendingLoss = JUNIOR_POOL.pendingLoss();
        state.availableLiquidity = JUNIOR_POOL.availableLiquidity();
        state.accountedAssets = state.totalAssets + state.pendingLoss;
        state.cash = USDC.balanceOf(JUNIOR_POOL_ADDRESS);
        _assertAccountingIdentity(JUNIOR_POOL_ADDRESS, state);
    }

    function _assertAccountingIdentity(address tranche, TrancheState memory state) internal pure {
        uint256 fromNav = state.totalAssets + state.pendingLoss;
        uint256 fromLiquidity = state.availableLiquidity + state.lockedAssets;
        if (fromNav != fromLiquidity) revert AccountingIdentityMismatch(tranche, fromNav, fromLiquidity);
    }

    function _logProtocolAccounting() internal view {
        TrancheState memory senior = _seniorState();
        TrancheState memory junior = _juniorState();
        console2.log("Pool totalLockedAssets:", POOL.totalLockedAssets());
        console2.log("Pool totalBadDebt:", POOL.totalBadDebt());
        console2.log("Senior totalAssets:", senior.totalAssets);
        console2.log("Senior lockedAssets:", senior.lockedAssets);
        console2.log("Senior pendingLoss:", senior.pendingLoss);
        console2.log("Senior availableLiquidity:", senior.availableLiquidity);
        console2.log("Senior derived accountedAssets:", senior.accountedAssets);
        console2.log("Junior totalAssets:", junior.totalAssets);
        console2.log("Junior lockedAssets:", junior.lockedAssets);
        console2.log("Junior pendingLoss:", junior.pendingLoss);
        console2.log("Junior availableLiquidity:", junior.availableLiquidity);
        console2.log("Junior derived accountedAssets:", junior.accountedAssets);
    }

    function _logPosition(uint256 invoiceId, string memory label) internal view {
        IInvoiceFinancingPool.FinancingPosition memory position = _position(invoiceId);
        console2.log(string.concat(label, " invoice ID:"), invoiceId);
        console2.log(string.concat(label, " lifecycle status:"), uint256(INVOICE_NFT.getInvoice(invoiceId).status));
        console2.log(string.concat(label, " principal:"), position.principal);
        console2.log(string.concat(label, " Senior principal:"), position.seniorPrincipal);
        console2.log(string.concat(label, " Junior principal:"), position.juniorPrincipal);
        console2.log(string.concat(label, " stored financing fee:"), position.financingFee);
        console2.log(string.concat(label, " Buyer exposure:"), RISK_MANAGER.getBuyerExposure(position.buyer));
    }

    function _logOracleUpdate(uint256 invoiceId, string memory label) internal view {
        IInvoiceStatusOracle.StatusUpdate memory update = ORACLE.getStatusUpdate(invoiceId);
        console2.log(string.concat(label, " invoice ID:"), invoiceId);
        console2.log(string.concat(label, " submitted status:"), uint256(update.newStatus));
        console2.log(string.concat(label, " recovered amount:"), update.recoveredAmount);
        console2.log(string.concat(label, " submittedAt:"), update.submittedAt);
        console2.log(string.concat(label, " earliestFinalizeAt:"), update.submittedAt + ORACLE.disputeWindow());
        console2.log(string.concat(label, " staleAfter:"), update.submittedAt + ORACLE.maxStaleness());
        console2.log(string.concat(label, " disputed:"), update.disputed);
        console2.log(string.concat(label, " finalized:"), update.finalized);
    }

    function _requireUnprivileged(address account) internal view {
        _requireRole(INVOICE_NFT_ADDRESS, DEFAULT_ADMIN_ROLE, account, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.ORIGINATOR_ROLE(), account, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.VERIFIER_ROLE(), account, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.RISK_ROLE(), account, false);
        _requireRole(INVOICE_NFT_ADDRESS, INVOICE_NFT.POOL_ROLE(), account, false);
        _requireRole(RISK_MANAGER_ADDRESS, DEFAULT_ADMIN_ROLE, account, false);
        _requireRole(RISK_MANAGER_ADDRESS, RISK_MANAGER.RISK_ADMIN_ROLE(), account, false);
        _requireRole(RISK_MANAGER_ADDRESS, RISK_MANAGER.POOL_ROLE(), account, false);
        _requireRole(ORACLE_ADDRESS, DEFAULT_ADMIN_ROLE, account, false);
        _requireRole(ORACLE_ADDRESS, ORACLE.ORACLE_SUBMITTER_ROLE(), account, false);
        _requireRole(ORACLE_ADDRESS, ORACLE.DISPUTE_ADMIN_ROLE(), account, false);
    }

    function _requireRole(address target, bytes32 role, address account, bool expected) internal view {
        bool actual = IAccessControl(target).hasRole(role, account);
        if (actual != expected) revert RoleMismatch(target, role, account, actual, expected);
    }

    function _requireZeroAllowance(address owner) internal view {
        uint256 allowance = USDC.allowance(owner, POOL_ADDRESS);
        if (allowance != 0) revert ExistingAllowance(owner, allowance);
    }

    function _startBroadcastAs(address expected) internal {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != expected) revert UnexpectedBroadcaster(broadcaster, expected);
    }

    function _requireDistinctIds(uint256 firstId, uint256 secondId) internal pure {
        if (firstId == secondId) revert DuplicateInvoiceId(firstId);
    }

    function _requireDistinctPositionBuyers(uint256 firstId, uint256 secondId) internal view {
        address firstBuyer = _position(firstId).buyer;
        if (firstBuyer == _position(secondId).buyer) revert DuplicateBuyer(firstBuyer);
    }

    function _requireCode(address target) internal view {
        if (target.code.length == 0) revert MissingCode(target);
    }

    function _expectAddress(bytes32 property, address actual, address expected) internal pure {
        if (actual != expected) revert AddressMismatch(property, actual, expected);
    }

    function _expectEq(bytes32 property, uint256 actual, uint256 expected) internal pure {
        if (actual != expected) revert ValueMismatch(property, actual, expected);
    }

    function _expectBool(bytes32 property, bool actual, bool expected) internal pure {
        if (actual != expected) revert BoolMismatch(property, actual, expected);
    }

    function _expectStatusValue(bytes32 property, IInvoiceNFT.InvoiceStatus actual, IInvoiceNFT.InvoiceStatus expected)
        internal
        pure
    {
        _expectEq(property, uint256(actual), uint256(expected));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {InvoiceFinancingPool} from "../src/core/InvoiceFinancingPool.sol";
import {InvoiceNFT} from "../src/core/InvoiceNFT.sol";
import {IRWARiskManager} from "../src/interfaces/IRWARiskManager.sol";
import {InvoiceStatusOracle} from "../src/oracle/InvoiceStatusOracle.sol";
import {JuniorPool} from "../src/pools/JuniorPool.sol";
import {SeniorPool} from "../src/pools/SeniorPool.sol";
import {RWARiskManager} from "../src/risk/RWARiskManager.sol";

contract Deploy is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint8 internal constant USDC_DECIMALS = 6;

    address internal constant ADMIN = 0x9f33C581581BC878f638541DB2b75e117A36BEfD;
    address internal constant OPERATIONS = 0xf2541FC59E68C999b130775392d4d86aE8B281B5;
    address internal constant CONTROL = 0x7077eeeB52Bf997a821c94983fC0D45763bae504;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

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

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    error WrongChainId(uint256 actual, uint256 expected);
    error InvalidDeploymentPrincipals(address admin, address operations, address control);
    error MissingCode(string component, address target);
    error UnexpectedTokenDecimals(uint8 actual, uint8 expected);
    error InvalidTrancheAddresses(address seniorPool, address juniorPool);
    error AddressMismatch(string property, address actual, address expected);
    error ValueMismatch(string property, uint256 actual, uint256 expected);
    error RoleMismatch(address target, bytes32 role, address account, bool actual, bool expected);

    struct Deployment {
        InvoiceNFT invoiceNft;
        RWARiskManager riskManager;
        InvoiceFinancingPool pool;
        SeniorPool seniorPool;
        JuniorPool juniorPool;
        InvoiceStatusOracle oracle;
    }

    function run() external {
        _preflight();

        vm.startBroadcast();

        Deployment memory deployment;
        deployment.invoiceNft = new InvoiceNFT(ADMIN);

        IRWARiskManager.RiskParams memory riskParams = IRWARiskManager.RiskParams({
            maxExposurePerBuyer: MAX_EXPOSURE_PER_BUYER,
            advanceRate: ADVANCE_RATE_BPS,
            maxInvoiceTenor: MAX_INVOICE_TENOR,
            minInvoiceAmount: MIN_INVOICE_AMOUNT,
            financingFeeApr: FINANCING_FEE_APR_BPS
        });

        deployment.riskManager = new RWARiskManager(ADMIN, deployment.invoiceNft, riskParams);
        deployment.pool = new InvoiceFinancingPool(
            IERC20(SEPOLIA_USDC),
            deployment.invoiceNft,
            deployment.riskManager,
            SENIOR_FUNDING_SHARE_BPS,
            JUNIOR_FUNDING_SHARE_BPS,
            SENIOR_FEE_SHARE_BPS,
            JUNIOR_FEE_SHARE_BPS
        );

        // The pool derives ADMIN from msg.sender, so reject an incorrect broadcaster immediately.
        _expectAddress("InvoiceFinancingPool.ADMIN", deployment.pool.ADMIN(), ADMIN);

        deployment.seniorPool = deployment.pool.SENIOR_POOL();
        deployment.juniorPool = deployment.pool.JUNIOR_POOL();
        deployment.oracle =
            new InvoiceStatusOracle(ADMIN, deployment.invoiceNft, deployment.pool, DISPUTE_WINDOW, MAX_STALENESS);

        _bootstrap(deployment);
        _revokeBootstrapPrivileges(deployment);

        vm.stopBroadcast();

        _validateDeployment(deployment);
        _logDeployment(deployment);
    }

    function _preflight() internal view {
        _validateDeploymentPrincipals();

        if (block.chainid != SEPOLIA_CHAIN_ID) {
            revert WrongChainId(block.chainid, SEPOLIA_CHAIN_ID);
        }
        _requireCode("Sepolia USDC", SEPOLIA_USDC);

        uint8 actualDecimals = IERC20Metadata(SEPOLIA_USDC).decimals();
        if (actualDecimals != USDC_DECIMALS) {
            revert UnexpectedTokenDecimals(actualDecimals, USDC_DECIMALS);
        }
    }

    function _validateDeploymentPrincipals() internal pure {
        if (
            ADMIN == address(0) || OPERATIONS == address(0) || CONTROL == address(0) || ADMIN == OPERATIONS
                || ADMIN == CONTROL || OPERATIONS == CONTROL
        ) {
            revert InvalidDeploymentPrincipals(ADMIN, OPERATIONS, CONTROL);
        }
    }

    function _bootstrap(Deployment memory deployment) internal {
        deployment.invoiceNft.grantRole(deployment.invoiceNft.ORIGINATOR_ROLE(), OPERATIONS);
        deployment.invoiceNft.grantRole(deployment.invoiceNft.VERIFIER_ROLE(), CONTROL);
        deployment.invoiceNft.grantRole(deployment.invoiceNft.RISK_ROLE(), CONTROL);
        deployment.invoiceNft.grantRole(deployment.invoiceNft.POOL_ROLE(), address(deployment.pool));

        deployment.riskManager.grantRole(deployment.riskManager.RISK_ADMIN_ROLE(), CONTROL);
        deployment.riskManager.grantRole(deployment.riskManager.POOL_ROLE(), address(deployment.pool));

        deployment.oracle.grantRole(deployment.oracle.ORACLE_SUBMITTER_ROLE(), OPERATIONS);
        deployment.oracle.grantRole(deployment.oracle.DISPUTE_ADMIN_ROLE(), CONTROL);

        deployment.pool.setInvoiceStatusOracle(address(deployment.oracle));
    }

    function _revokeBootstrapPrivileges(Deployment memory deployment) internal {
        deployment.riskManager.revokeRole(deployment.riskManager.RISK_ADMIN_ROLE(), ADMIN);
        deployment.oracle.revokeRole(deployment.oracle.ORACLE_SUBMITTER_ROLE(), ADMIN);
        deployment.oracle.revokeRole(deployment.oracle.DISPUTE_ADMIN_ROLE(), ADMIN);
    }

    function _validateDeployment(Deployment memory deployment) internal view {
        _validateCodeAndAddresses(deployment);
        _validateWiring(deployment);
        _validateConfiguration(deployment);
        _validateRoles(deployment);
        _validateInitialAccounting(deployment);
    }

    function _validateCodeAndAddresses(Deployment memory deployment) internal view {
        _requireCode("InvoiceNFT", address(deployment.invoiceNft));
        _requireCode("RWARiskManager", address(deployment.riskManager));
        _requireCode("InvoiceFinancingPool", address(deployment.pool));
        _requireCode("SeniorPool", address(deployment.seniorPool));
        _requireCode("JuniorPool", address(deployment.juniorPool));
        _requireCode("InvoiceStatusOracle", address(deployment.oracle));

        address seniorPoolAddress = address(deployment.seniorPool);
        address juniorPoolAddress = address(deployment.juniorPool);
        if (
            seniorPoolAddress == address(0) || juniorPoolAddress == address(0) || seniorPoolAddress == juniorPoolAddress
        ) {
            revert InvalidTrancheAddresses(seniorPoolAddress, juniorPoolAddress);
        }
    }

    function _validateWiring(Deployment memory deployment) internal view {
        _expectAddress("InvoiceFinancingPool.ASSET", address(deployment.pool.ASSET()), SEPOLIA_USDC);
        _expectAddress(
            "InvoiceFinancingPool.INVOICE_NFT", address(deployment.pool.INVOICE_NFT()), address(deployment.invoiceNft)
        );
        _expectAddress(
            "InvoiceFinancingPool.RISK_MANAGER",
            address(deployment.pool.RISK_MANAGER()),
            address(deployment.riskManager)
        );
        _expectAddress("InvoiceFinancingPool.ADMIN", deployment.pool.ADMIN(), ADMIN);
        _expectAddress(
            "InvoiceFinancingPool.SENIOR_POOL", address(deployment.pool.SENIOR_POOL()), address(deployment.seniorPool)
        );
        _expectAddress(
            "InvoiceFinancingPool.JUNIOR_POOL", address(deployment.pool.JUNIOR_POOL()), address(deployment.juniorPool)
        );
        _expectAddress(
            "InvoiceFinancingPool.invoiceStatusOracle",
            deployment.pool.invoiceStatusOracle(),
            address(deployment.oracle)
        );

        _expectAddress(
            "RWARiskManager.INVOICE_NFT", address(deployment.riskManager.INVOICE_NFT()), address(deployment.invoiceNft)
        );
        _expectAddress(
            "InvoiceStatusOracle.INVOICE_NFT", address(deployment.oracle.INVOICE_NFT()), address(deployment.invoiceNft)
        );
        _expectAddress("InvoiceStatusOracle.POOL", address(deployment.oracle.POOL()), address(deployment.pool));

        _expectAddress("SeniorPool.asset", deployment.seniorPool.asset(), SEPOLIA_USDC);
        _expectAddress("JuniorPool.asset", deployment.juniorPool.asset(), SEPOLIA_USDC);
        _expectAddress(
            "SeniorPool.INVOICE_FINANCING_POOL",
            deployment.seniorPool.INVOICE_FINANCING_POOL(),
            address(deployment.pool)
        );
        _expectAddress(
            "JuniorPool.INVOICE_FINANCING_POOL",
            deployment.juniorPool.INVOICE_FINANCING_POOL(),
            address(deployment.pool)
        );
    }

    function _validateConfiguration(Deployment memory deployment) internal view {
        (
            uint256 maxExposurePerBuyer,
            uint256 advanceRate,
            uint256 maxInvoiceTenor,
            uint256 minInvoiceAmount,
            uint256 financingFeeApr
        ) = deployment.riskManager.riskParams();

        _expectValue("RWARiskManager.maxExposurePerBuyer", maxExposurePerBuyer, MAX_EXPOSURE_PER_BUYER);
        _expectValue("RWARiskManager.advanceRate", advanceRate, ADVANCE_RATE_BPS);
        _expectValue("RWARiskManager.maxInvoiceTenor", maxInvoiceTenor, MAX_INVOICE_TENOR);
        _expectValue("RWARiskManager.minInvoiceAmount", minInvoiceAmount, MIN_INVOICE_AMOUNT);
        _expectValue("RWARiskManager.financingFeeApr", financingFeeApr, FINANCING_FEE_APR_BPS);

        _expectValue(
            "InvoiceFinancingPool.SENIOR_FUNDING_SHARE_BPS",
            deployment.pool.SENIOR_FUNDING_SHARE_BPS(),
            SENIOR_FUNDING_SHARE_BPS
        );
        _expectValue(
            "InvoiceFinancingPool.JUNIOR_FUNDING_SHARE_BPS",
            deployment.pool.JUNIOR_FUNDING_SHARE_BPS(),
            JUNIOR_FUNDING_SHARE_BPS
        );
        _expectValue(
            "InvoiceFinancingPool.SENIOR_FEE_SHARE_BPS", deployment.pool.SENIOR_FEE_SHARE_BPS(), SENIOR_FEE_SHARE_BPS
        );
        _expectValue(
            "InvoiceFinancingPool.JUNIOR_FEE_SHARE_BPS", deployment.pool.JUNIOR_FEE_SHARE_BPS(), JUNIOR_FEE_SHARE_BPS
        );
        _expectValue("InvoiceStatusOracle.disputeWindow", deployment.oracle.disputeWindow(), DISPUTE_WINDOW);
        _expectValue("InvoiceStatusOracle.maxStaleness", deployment.oracle.maxStaleness(), MAX_STALENESS);
    }

    function _validateRoles(Deployment memory deployment) internal view {
        address invoiceNft = address(deployment.invoiceNft);
        address riskManager = address(deployment.riskManager);
        address oracle = address(deployment.oracle);
        address pool = address(deployment.pool);

        bytes32 originatorRole = deployment.invoiceNft.ORIGINATOR_ROLE();
        bytes32 verifierRole = deployment.invoiceNft.VERIFIER_ROLE();
        bytes32 riskRole = deployment.invoiceNft.RISK_ROLE();
        bytes32 invoicePoolRole = deployment.invoiceNft.POOL_ROLE();
        bytes32 riskAdminRole = deployment.riskManager.RISK_ADMIN_ROLE();
        bytes32 riskPoolRole = deployment.riskManager.POOL_ROLE();
        bytes32 submitterRole = deployment.oracle.ORACLE_SUBMITTER_ROLE();
        bytes32 disputeAdminRole = deployment.oracle.DISPUTE_ADMIN_ROLE();

        _expectRole(invoiceNft, DEFAULT_ADMIN_ROLE, ADMIN, true);
        _expectRole(riskManager, DEFAULT_ADMIN_ROLE, ADMIN, true);
        _expectRole(oracle, DEFAULT_ADMIN_ROLE, ADMIN, true);

        _expectRole(invoiceNft, originatorRole, OPERATIONS, true);
        _expectRole(oracle, submitterRole, OPERATIONS, true);

        _expectRole(invoiceNft, verifierRole, CONTROL, true);
        _expectRole(invoiceNft, riskRole, CONTROL, true);
        _expectRole(riskManager, riskAdminRole, CONTROL, true);
        _expectRole(oracle, disputeAdminRole, CONTROL, true);

        _expectRole(invoiceNft, invoicePoolRole, pool, true);
        _expectRole(riskManager, riskPoolRole, pool, true);

        _expectRole(invoiceNft, invoicePoolRole, ADMIN, false);
        _expectRole(invoiceNft, originatorRole, ADMIN, false);
        _expectRole(invoiceNft, verifierRole, ADMIN, false);
        _expectRole(invoiceNft, riskRole, ADMIN, false);
        _expectRole(riskManager, riskPoolRole, ADMIN, false);
        _expectRole(riskManager, riskAdminRole, ADMIN, false);
        _expectRole(oracle, submitterRole, ADMIN, false);
        _expectRole(oracle, disputeAdminRole, ADMIN, false);

        _expectRole(invoiceNft, DEFAULT_ADMIN_ROLE, OPERATIONS, false);
        _expectRole(riskManager, DEFAULT_ADMIN_ROLE, OPERATIONS, false);
        _expectRole(oracle, DEFAULT_ADMIN_ROLE, OPERATIONS, false);
        _expectRole(invoiceNft, verifierRole, OPERATIONS, false);
        _expectRole(invoiceNft, riskRole, OPERATIONS, false);
        _expectRole(riskManager, riskAdminRole, OPERATIONS, false);
        _expectRole(oracle, disputeAdminRole, OPERATIONS, false);
        _expectRole(invoiceNft, invoicePoolRole, OPERATIONS, false);
        _expectRole(riskManager, riskPoolRole, OPERATIONS, false);

        _expectRole(invoiceNft, DEFAULT_ADMIN_ROLE, CONTROL, false);
        _expectRole(riskManager, DEFAULT_ADMIN_ROLE, CONTROL, false);
        _expectRole(oracle, DEFAULT_ADMIN_ROLE, CONTROL, false);
        _expectRole(invoiceNft, originatorRole, CONTROL, false);
        _expectRole(oracle, submitterRole, CONTROL, false);
        _expectRole(invoiceNft, invoicePoolRole, CONTROL, false);
        _expectRole(riskManager, riskPoolRole, CONTROL, false);
    }

    function _validateInitialAccounting(Deployment memory deployment) internal view {
        _expectValue("InvoiceFinancingPool.totalLockedAssets", deployment.pool.totalLockedAssets(), 0);
        _expectValue("InvoiceFinancingPool.totalBadDebt", deployment.pool.totalBadDebt(), 0);

        _expectValue("SeniorPool.totalAssets", deployment.seniorPool.totalAssets(), 0);
        _expectValue("SeniorPool.lockedAssets", deployment.seniorPool.lockedAssets(), 0);
        _expectValue("SeniorPool.pendingLoss", deployment.seniorPool.pendingLoss(), 0);
        _expectValue("SeniorPool.availableLiquidity", deployment.seniorPool.availableLiquidity(), 0);

        _expectValue("JuniorPool.totalAssets", deployment.juniorPool.totalAssets(), 0);
        _expectValue("JuniorPool.lockedAssets", deployment.juniorPool.lockedAssets(), 0);
        _expectValue("JuniorPool.pendingLoss", deployment.juniorPool.pendingLoss(), 0);
        _expectValue("JuniorPool.availableLiquidity", deployment.juniorPool.availableLiquidity(), 0);
    }

    function _requireCode(string memory component, address target) internal view {
        if (target.code.length == 0) {
            revert MissingCode(component, target);
        }
    }

    function _expectAddress(string memory property, address actual, address expected) internal pure {
        if (actual != expected) {
            revert AddressMismatch(property, actual, expected);
        }
    }

    function _expectValue(string memory property, uint256 actual, uint256 expected) internal pure {
        if (actual != expected) {
            revert ValueMismatch(property, actual, expected);
        }
    }

    function _expectRole(address target, bytes32 role, address account, bool expected) internal view {
        bool actual = IAccessControl(target).hasRole(role, account);
        if (actual != expected) {
            revert RoleMismatch(target, role, account, actual, expected);
        }
    }

    function _logDeployment(Deployment memory deployment) internal view {
        console2.log("Network: Ethereum Sepolia");
        console2.log("Chain ID:", block.chainid);
        console2.log("ADMIN:", ADMIN);
        console2.log("OPERATIONS:", OPERATIONS);
        console2.log("CONTROL:", CONTROL);
        console2.log("USDC:", SEPOLIA_USDC);
        console2.log("InvoiceNFT:", address(deployment.invoiceNft));
        console2.log("RWARiskManager:", address(deployment.riskManager));
        console2.log("InvoiceFinancingPool:", address(deployment.pool));
        console2.log("SeniorPool:", address(deployment.seniorPool));
        console2.log("JuniorPool:", address(deployment.juniorPool));
        console2.log("InvoiceStatusOracle:", address(deployment.oracle));
    }
}

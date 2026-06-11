// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

import {InvoiceNFT} from "../../src/core/InvoiceNFT.sol";
import {InvoiceFinancingPool} from "../../src/core/InvoiceFinancingPool.sol";
import {RWARiskManager} from "../../src/risk/RWARiskManager.sol";

import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceFinancingPool} from "../../src/interfaces/IInvoiceFinancingPool.sol";
import {IRWARiskManager} from "../../src/interfaces/IRWARiskManager.sol";

contract InvoiceFinancingPoolAdminTest is Test {
    MockERC20 internal asset;
    InvoiceNFT internal invoiceNft;
    RWARiskManager internal riskManager;
    InvoiceFinancingPool internal pool;

    address internal admin = makeAddr("admin");
    address internal oracle = makeAddr("oracle");
    address internal secondOracle = makeAddr("secondOracle");
    address internal unauthorizedCaller = makeAddr("unauthorizedCaller");

    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");
    address internal seniorLp = makeAddr("seniorLp");
    address internal juniorLp = makeAddr("juniorLp");

    uint256 internal constant MAX_EXPOSURE_PER_BUYER = 1_000_000e18;
    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant MAX_INVOICE_TENOR = 90 days;
    uint256 internal constant MIN_INVOICE_AMOUNT = 1_000e18;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;

    uint256 internal constant SENIOR_FUNDING_SHARE_BPS = 7_000;
    uint256 internal constant JUNIOR_FUNDING_SHARE_BPS = 3_000;
    uint256 internal constant SENIOR_FEE_SHARE_BPS = 4_000;
    uint256 internal constant JUNIOR_FEE_SHARE_BPS = 6_000;

    uint256 internal constant SENIOR_DEPOSIT = 700_000e18;
    uint256 internal constant JUNIOR_DEPOSIT = 300_000e18;
    uint256 internal constant FACE_VALUE = 100_000e18;
    uint256 internal constant INVOICE_TENOR = 30 days;
    uint256 internal constant DEFAULT_RECOVERY = 40_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20();
        invoiceNft = new InvoiceNFT(admin);

        IRWARiskManager.RiskParams memory params = IRWARiskManager.RiskParams({
            maxExposurePerBuyer: MAX_EXPOSURE_PER_BUYER,
            advanceRate: ADVANCE_RATE_BPS,
            maxInvoiceTenor: MAX_INVOICE_TENOR,
            minInvoiceAmount: MIN_INVOICE_AMOUNT,
            financingFeeApr: FINANCING_FEE_APR_BPS
        });

        riskManager = new RWARiskManager(admin, invoiceNft, params);

        vm.prank(admin);
        pool = new InvoiceFinancingPool(
            asset,
            invoiceNft,
            riskManager,
            SENIOR_FUNDING_SHARE_BPS,
            JUNIOR_FUNDING_SHARE_BPS,
            SENIOR_FEE_SHARE_BPS,
            JUNIOR_FEE_SHARE_BPS
        );

        vm.startPrank(admin);
        invoiceNft.grantRole(invoiceNft.ORIGINATOR_ROLE(), originator);
        invoiceNft.grantRole(invoiceNft.VERIFIER_ROLE(), verifier);
        invoiceNft.grantRole(invoiceNft.POOL_ROLE(), address(pool));
        riskManager.grantRole(riskManager.POOL_ROLE(), address(pool));
        vm.stopPrank();
    }

    function _setOracle() internal {
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);
    }

    function _depositTranches() internal {
        asset.mint(seniorLp, SENIOR_DEPOSIT);
        asset.mint(juniorLp, JUNIOR_DEPOSIT);

        vm.startPrank(seniorLp);
        asset.approve(address(pool), SENIOR_DEPOSIT);
        pool.depositSenior(SENIOR_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(juniorLp);
        asset.approve(address(pool), JUNIOR_DEPOSIT);
        pool.depositJunior(JUNIOR_DEPOSIT);
        vm.stopPrank();
    }

    function _createAndFinanceInvoice() internal returns (uint256 invoiceId) {
        vm.prank(originator);
        invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);
    }

    function _getPositionPrincipal(uint256 invoiceId) internal view returns (uint256 principal) {
        (,, principal,,,,,,) = pool.financingPositions(invoiceId);
    }

    function test_Constructor_StoresAdminIdentity() public view {
        assertEq(pool.ADMIN(), admin);
    }

    function test_Constructor_DeploysDistinctNonZeroTranchePools() public view {
        address seniorPool = address(pool.SENIOR_POOL());
        address juniorPool = address(pool.JUNIOR_POOL());

        assertTrue(seniorPool != address(0));
        assertTrue(juniorPool != address(0));
        assertTrue(seniorPool != juniorPool);
    }

    function test_Constructor_LeavesOracleUnset() public view {
        assertEq(pool.invoiceStatusOracle(), address(0));
    }

    function test_SetInvoiceStatusOracle_SetsOracle() public {
        _setOracle();

        assertEq(pool.invoiceStatusOracle(), oracle);
    }

    function test_SetInvoiceStatusOracle_Reverts_WhenCallerIsNotAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.UnauthorizedAdmin.selector, unauthorizedCaller));

        vm.prank(unauthorizedCaller);
        pool.setInvoiceStatusOracle(oracle);
    }

    function test_SetInvoiceStatusOracle_Reverts_WhenOracleIsZeroAddress() public {
        vm.expectRevert(IInvoiceFinancingPool.ZeroAddress.selector);

        vm.prank(admin);
        pool.setInvoiceStatusOracle(address(0));
    }

    function test_SetInvoiceStatusOracle_Reverts_WhenOracleWasAlreadySet() public {
        _setOracle();

        vm.expectRevert(IInvoiceFinancingPool.OracleAlreadySet.selector);

        vm.prank(admin);
        pool.setInvoiceStatusOracle(secondOracle);

        assertEq(pool.invoiceStatusOracle(), oracle);
    }

    function test_OnStatusFinalized_Reverts_WhenOracleIsNotSet() public {
        vm.expectRevert(IInvoiceFinancingPool.OracleNotSet.selector);

        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
    }

    function test_OnStatusFinalized_Reverts_WhenCallerIsNotConfiguredOracle() public {
        _setOracle();

        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.UnauthorizedOracle.selector, unauthorizedCaller));

        vm.prank(unauthorizedCaller);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsCreated() public {
        _setOracle();

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.CREATED
            )
        );

        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.CREATED, 0);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsVerified() public {
        _setOracle();

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.VERIFIED
            )
        );

        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.VERIFIED, 0);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsFunded() public {
        _setOracle();

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.FUNDED)
        );

        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.FUNDED, 0);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsFrozen() public {
        _setOracle();

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.FROZEN)
        );

        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.FROZEN, 0);
    }

    function test_OnStatusFinalized_Reverts_WhenFinancingPositionDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        _setOracle();

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.FinancingPositionDoesNotExist.selector, nonexistentInvoiceId)
        );

        vm.prank(oracle);
        pool.onStatusFinalized(nonexistentInvoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        assertFalse(pool.isOracleStatusFinalized(nonexistentInvoiceId));
        assertEq(pool.finalizedRecoveryAmount(nonexistentInvoiceId), 0);
    }

    function test_OnStatusFinalized_RecordsSettledStatusAndZeroRecovery() public {
        _depositTranches();
        uint256 invoiceId = _createAndFinanceInvoice();

        _setOracle();

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
        assertTrue(pool.isOracleStatusFinalized(invoiceId));
    }

    function test_OnStatusFinalized_RecordsDefaultedStatusAndRecovery() public {
        _depositTranches();
        uint256 invoiceId = _createAndFinanceInvoice();

        _setOracle();

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), DEFAULT_RECOVERY);
        assertTrue(pool.isOracleStatusFinalized(invoiceId));
    }

    function test_OnStatusFinalized_AllowsZeroRecoveryForDefault() public {
        _depositTranches();
        uint256 invoiceId = _createAndFinanceInvoice();

        _setOracle();

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
        assertTrue(pool.isOracleStatusFinalized(invoiceId));
    }

    function test_OnStatusFinalized_Reverts_WhenSettledRecoveryIsNonZero() public {
        _depositTranches();
        uint256 invoiceId = _createAndFinanceInvoice();

        _setOracle();

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.InvalidRecoveryForStatus.selector,
                IInvoiceNFT.InvoiceStatus.SETTLED,
                DEFAULT_RECOVERY
            )
        );

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, DEFAULT_RECOVERY);

        assertFalse(pool.isOracleStatusFinalized(invoiceId));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
    }

    function test_OnStatusFinalized_Reverts_WhenRecoveryExceedsPrincipal() public {
        _depositTranches();
        uint256 invoiceId = _createAndFinanceInvoice();
        uint256 principal = _getPositionPrincipal(invoiceId);
        uint256 excessiveRecovery = principal + 1;

        _setOracle();

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.RecoveredAmountExceedsPrincipal.selector, invoiceId, excessiveRecovery, principal
            )
        );

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, excessiveRecovery);

        assertFalse(pool.isOracleStatusFinalized(invoiceId));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
    }

    function test_OnStatusFinalized_Reverts_WhenSameStatusIsFinalizedTwice() public {
        _depositTranches();
        uint256 invoiceId = _createAndFinanceInvoice();

        _setOracle();

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.OracleStatusAlreadyFinalized.selector, invoiceId));

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
    }

    function test_OnStatusFinalized_Reverts_WhenOppositeTerminalStatusIsSubmitted() public {
        _depositTranches();
        uint256 invoiceId = _createAndFinanceInvoice();

        _setOracle();

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.OracleStatusAlreadyFinalized.selector, invoiceId));

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
    }

    function test_IsOracleStatusFinalized_ReturnsFalseForUninitializedInvoice() public view {
        uint256 invoiceId = 999;

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
        assertFalse(pool.isOracleStatusFinalized(invoiceId));
    }

    function test_OnStatusFinalized_IsolatedAcrossInvoiceIds() public {
        _depositTranches();

        uint256 settledInvoiceId = _createAndFinanceInvoice();
        uint256 defaultedInvoiceId = _createAndFinanceInvoice();
        uint256 untouchedInvoiceId = 999;

        _setOracle();

        vm.startPrank(oracle);
        pool.onStatusFinalized(settledInvoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        pool.onStatusFinalized(defaultedInvoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);
        vm.stopPrank();

        assertEq(uint256(pool.finalizedOracleStatus(settledInvoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(pool.finalizedRecoveryAmount(settledInvoiceId), 0);

        assertEq(uint256(pool.finalizedOracleStatus(defaultedInvoiceId)), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(pool.finalizedRecoveryAmount(defaultedInvoiceId), DEFAULT_RECOVERY);

        assertEq(uint256(pool.finalizedOracleStatus(untouchedInvoiceId)), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
        assertEq(pool.finalizedRecoveryAmount(untouchedInvoiceId), 0);
        assertFalse(pool.isOracleStatusFinalized(untouchedInvoiceId));
    }
}


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

    uint256 internal constant MAX_EXPOSURE_PER_BUYER = 1_000_000e18;
    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant MAX_INVOICE_TENOR = 90 days;
    uint256 internal constant MIN_INVOICE_AMOUNT = 1_000e18;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;

    uint256 internal constant SENIOR_FUNDING_SHARE_BPS = 7_000;
    uint256 internal constant JUNIOR_FUNDING_SHARE_BPS = 3_000;
    uint256 internal constant SENIOR_FEE_SHARE_BPS = 4_000;
    uint256 internal constant JUNIOR_FEE_SHARE_BPS = 6_000;

    function setUp() public {
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
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

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
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.expectRevert(IInvoiceFinancingPool.OracleAlreadySet.selector);
        vm.prank(admin);
        pool.setInvoiceStatusOracle(secondOracle);

        assertEq(pool.invoiceStatusOracle(), oracle);
    }

    function test_OnStatusFinalized_Reverts_WhenOracleIsNotSet() public {
        vm.expectRevert(IInvoiceFinancingPool.OracleNotSet.selector);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.SETTLED);
    }

    function test_OnStatusFinalized_Reverts_WhenCallerIsNotConfiguredOracle() public {
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.UnauthorizedOracle.selector, unauthorizedCaller));
        vm.prank(unauthorizedCaller);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.SETTLED);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsCreated() public {
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.CREATED
            )
        );
        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.CREATED);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsVerified() public {
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.VERIFIED
            )
        );
        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.VERIFIED);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsFunded() public {
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.FUNDED)
        );
        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.FUNDED);
    }

    function test_OnStatusFinalized_Reverts_WhenStatusIsFrozen() public {
        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceFinancingPool.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.FROZEN)
        );
        vm.prank(oracle);
        pool.onStatusFinalized(1, IInvoiceNFT.InvoiceStatus.FROZEN);
    }

    function test_OnStatusFinalized_RecordsSettledStatus() public {
        uint256 invoiceId = 1;

        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertTrue(pool.isOracleStatusFinalized(invoiceId));
    }

    function test_OnStatusFinalized_RecordsDefaultedStatus() public {
        uint256 invoiceId = 1;

        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertTrue(pool.isOracleStatusFinalized(invoiceId));
    }

    function test_OnStatusFinalized_Reverts_WhenSameStatusIsFinalizedTwice() public {
        uint256 invoiceId = 1;

        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.OracleStatusAlreadyFinalized.selector, invoiceId));
        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);
    }

    function test_OnStatusFinalized_Reverts_WhenOppositeTerminalStatusIsSubmitted() public {
        uint256 invoiceId = 1;

        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.OracleStatusAlreadyFinalized.selector, invoiceId));
        vm.prank(oracle);
        pool.onStatusFinalized(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
    }

    function test_IsOracleStatusFinalized_ReturnsFalseForUninitializedInvoice() public view {
        uint256 invoiceId = 999;

        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
        assertFalse(pool.isOracleStatusFinalized(invoiceId));
    }

    function test_OnStatusFinalized_IsolatedAcrossInvoiceIds() public {
        uint256 settledInvoiceId = 1;
        uint256 defaultedInvoiceId = 2;
        uint256 untouchedInvoiceId = 3;

        vm.prank(admin);
        pool.setInvoiceStatusOracle(oracle);

        vm.startPrank(oracle);
        pool.onStatusFinalized(settledInvoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);
        pool.onStatusFinalized(defaultedInvoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);
        vm.stopPrank();

        assertEq(uint256(pool.finalizedOracleStatus(settledInvoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(uint256(pool.finalizedOracleStatus(defaultedInvoiceId)), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertFalse(pool.isOracleStatusFinalized(untouchedInvoiceId));
    }
}

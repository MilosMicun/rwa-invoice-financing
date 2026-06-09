// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {InvoiceFinancingPool} from "../../src/core/InvoiceFinancingPool.sol";
import {InvoiceNFT} from "../../src/core/InvoiceNFT.sol";
import {InvoiceStatusOracle} from "../../src/oracle/InvoiceStatusOracle.sol";
import {RWARiskManager} from "../../src/risk/RWARiskManager.sol";
import {SeniorPool} from "../../src/pools/SeniorPool.sol";
import {JuniorPool} from "../../src/pools/JuniorPool.sol";
import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceFinancingPool} from "../../src/interfaces/IInvoiceFinancingPool.sol";
import {IInvoiceStatusOracle} from "../../src/interfaces/IInvoiceStatusOracle.sol";
import {IRWARiskManager} from "../../src/interfaces/IRWARiskManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract InvoiceFinancingPoolEconomicLifecycleTest is Test {
    MockERC20 internal asset;
    InvoiceNFT internal invoiceNFT;
    RWARiskManager internal riskManager;
    InvoiceFinancingPool internal pool;
    InvoiceStatusOracle internal oracle;
    SeniorPool internal seniorPool;
    JuniorPool internal juniorPool;

    address internal admin = makeAddr("admin");
    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal riskAdmin = makeAddr("riskAdmin");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");
    address internal resolver = makeAddr("resolver");
    address internal seniorLP = makeAddr("seniorLP");
    address internal juniorLP = makeAddr("juniorLP");

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SENIOR_DEPOSIT = 700_000e18;
    uint256 internal constant JUNIOR_DEPOSIT = 300_000e18;
    uint256 internal constant FACE_VALUE = 100_000e18;
    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant SENIOR_FUNDING_SHARE_BPS = 7_000;
    uint256 internal constant JUNIOR_FUNDING_SHARE_BPS = 3_000;
    uint256 internal constant SENIOR_FEE_SHARE_BPS = 4_000;
    uint256 internal constant JUNIOR_FEE_SHARE_BPS = 6_000;
    uint256 internal constant MAX_TENOR = 90 days;
    uint256 internal constant INVOICE_TENOR = 30 days;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;
    uint256 internal constant MIN_INVOICE_AMOUNT = 1_000e18;
    uint256 internal constant MAX_EXPOSURE_PER_BUYER = 1_000_000e18;
    uint256 internal constant DISPUTE_WINDOW = 1 days;
    uint256 internal constant MAX_STALENESS = 7 days;

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20();
        invoiceNFT = new InvoiceNFT(admin);

        IRWARiskManager.RiskParams memory params = IRWARiskManager.RiskParams({
            maxExposurePerBuyer: MAX_EXPOSURE_PER_BUYER,
            advanceRate: ADVANCE_RATE_BPS,
            maxInvoiceTenor: MAX_TENOR,
            minInvoiceAmount: MIN_INVOICE_AMOUNT,
            financingFeeApr: FINANCING_FEE_APR_BPS
        });

        riskManager = new RWARiskManager(admin, invoiceNFT, params);

        vm.prank(admin);
        pool = new InvoiceFinancingPool(
            asset,
            invoiceNFT,
            riskManager,
            SENIOR_FUNDING_SHARE_BPS,
            JUNIOR_FUNDING_SHARE_BPS,
            SENIOR_FEE_SHARE_BPS,
            JUNIOR_FEE_SHARE_BPS
        );

        seniorPool = pool.SENIOR_POOL();
        juniorPool = pool.JUNIOR_POOL();
        oracle = new InvoiceStatusOracle(admin, invoiceNFT, pool, DISPUTE_WINDOW, MAX_STALENESS);

        vm.startPrank(admin);
        invoiceNFT.grantRole(invoiceNFT.ORIGINATOR_ROLE(), originator);
        invoiceNFT.grantRole(invoiceNFT.VERIFIER_ROLE(), verifier);
        invoiceNFT.grantRole(invoiceNFT.RISK_ROLE(), riskAdmin);
        invoiceNFT.grantRole(invoiceNFT.POOL_ROLE(), address(pool));
        riskManager.grantRole(riskManager.POOL_ROLE(), address(pool));
        pool.setInvoiceStatusOracle(address(oracle));
        vm.stopPrank();
    }

    function test_SetUp_DeployedCoreContractsAndLinkedPools() public view {
        assertEq(address(pool.ASSET()), address(asset));
        assertEq(address(pool.INVOICE_NFT()), address(invoiceNFT));
        assertEq(address(pool.RISK_MANAGER()), address(riskManager));
        assertEq(pool.ADMIN(), admin);
        assertEq(address(pool.SENIOR_POOL()), address(seniorPool));
        assertEq(address(pool.JUNIOR_POOL()), address(juniorPool));
        assertEq(pool.invoiceStatusOracle(), address(oracle));
        assertTrue(invoiceNFT.hasRole(invoiceNFT.ORIGINATOR_ROLE(), originator));
        assertTrue(invoiceNFT.hasRole(invoiceNFT.VERIFIER_ROLE(), verifier));
        assertTrue(invoiceNFT.hasRole(invoiceNFT.RISK_ROLE(), riskAdmin));
        assertTrue(invoiceNFT.hasRole(invoiceNFT.POOL_ROLE(), address(pool)));
        assertTrue(riskManager.hasRole(riskManager.POOL_ROLE(), address(pool)));
    }

    function _depositTranches(uint256 seniorAssets, uint256 juniorAssets) internal {
        asset.mint(seniorLP, seniorAssets);
        asset.mint(juniorLP, juniorAssets);

        vm.startPrank(seniorLP);
        asset.approve(address(pool), seniorAssets);
        pool.depositSenior(seniorAssets);
        vm.stopPrank();

        vm.startPrank(juniorLP);
        asset.approve(address(pool), juniorAssets);
        pool.depositJunior(juniorAssets);
        vm.stopPrank();
    }

    function _createVerifiedInvoice(uint256 faceValue, uint256 dueDate) internal returns (uint256 invoiceId) {
        vm.prank(originator);
        invoiceId = invoiceNFT.createInvoice(supplier, buyer, faceValue, dueDate);

        vm.prank(verifier);
        invoiceNFT.verify(invoiceId);
    }

    function _financeAsSupplier(uint256 invoiceId) internal {
        vm.prank(supplier);
        pool.financeInvoice(invoiceId);
    }

    function _submitAndFinalizeOracleStatus(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status) internal {
        vm.prank(admin);
        oracle.submitStatus(invoiceId, status);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(invoiceId);
    }

    function _settleAsBuyer(uint256 invoiceId, uint256 paidAmount) internal {
        asset.mint(buyer, paidAmount);

        vm.startPrank(buyer);
        asset.approve(address(pool), paidAmount);
        pool.settleInvoice(invoiceId, paidAmount);
        vm.stopPrank();
    }

    function _resolveDefaultAsResolver(uint256 invoiceId, uint256 recoveredAmount) internal {
        if (recoveredAmount == 0) {
            vm.prank(resolver);
            pool.resolveDefault(invoiceId, recoveredAmount);
            return;
        }

        asset.mint(resolver, recoveredAmount);

        vm.startPrank(resolver);
        asset.approve(address(pool), recoveredAmount);
        pool.resolveDefault(invoiceId, recoveredAmount);
        vm.stopPrank();
    }

    function _expectedPrincipal() internal pure returns (uint256) {
        return FACE_VALUE * ADVANCE_RATE_BPS / BPS;
    }

    function _expectedSeniorPrincipal(uint256 principal) internal pure returns (uint256) {
        return principal * SENIOR_FUNDING_SHARE_BPS / BPS;
    }

    function _expectedJuniorPrincipal(uint256 principal, uint256 seniorPrincipal) internal pure returns (uint256) {
        return principal - seniorPrincipal;
    }

    function _expectedFeeSplit(uint256 fee) internal pure returns (uint256 seniorFee, uint256 juniorFee) {
        juniorFee = fee * JUNIOR_FEE_SHARE_BPS / BPS;
        seniorFee = fee - juniorFee;
    }

    function _getPositionFinancingFee(uint256 invoiceId) internal view returns (uint256 financingFee) {
        (,,,,, financingFee,,,) = pool.financingPositions(invoiceId);
    }

    function _getPositionResolved(uint256 invoiceId) internal view returns (bool resolved) {
        (,,,,,,,, resolved) = pool.financingPositions(invoiceId);
    }

    /// @dev Assumes one active financing position exists in the scenario.
    function _assertFinancedPosition(
        uint256 invoiceId,
        uint256 expectedPrincipal,
        uint256 expectedSeniorPrincipal,
        uint256 expectedJuniorPrincipal,
        uint256 expectedDueDate
    ) internal view {
        (
            address positionSupplier,
            address positionBuyer,
            uint256 principal,
            uint256 seniorPrincipal,
            uint256 juniorPrincipal,
            uint256 financingFee,
            uint256 fundedAt,
            uint256 positionDueDate,
            bool resolved
        ) = pool.financingPositions(invoiceId);

        uint256 expectedFee = riskManager.calculateFee(expectedPrincipal, fundedAt, expectedDueDate);

        assertEq(positionSupplier, supplier);
        assertEq(positionBuyer, buyer);
        assertEq(principal, expectedPrincipal);
        assertEq(seniorPrincipal, expectedSeniorPrincipal);
        assertEq(juniorPrincipal, expectedJuniorPrincipal);
        assertEq(financingFee, expectedFee);
        assertEq(positionDueDate, expectedDueDate);
        assertFalse(resolved);
        assertEq(pool.totalLockedAssets(), expectedPrincipal);
        assertEq(riskManager.getBuyerExposure(buyer), expectedPrincipal);
        assertEq(seniorPool.lockedAssets(), expectedSeniorPrincipal);
        assertEq(juniorPool.lockedAssets(), expectedJuniorPrincipal);
    }

    function _assertActiveFinancingPosition(
        uint256 invoiceId,
        uint256 expectedPrincipal,
        uint256 expectedSeniorPrincipal,
        uint256 expectedJuniorPrincipal
    ) internal view {
        (
            address positionSupplier,
            address positionBuyer,
            uint256 principal,
            uint256 seniorPrincipal,
            uint256 juniorPrincipal,,,,
            bool resolved
        ) = pool.financingPositions(invoiceId);

        assertEq(positionSupplier, supplier);
        assertEq(positionBuyer, buyer);
        assertEq(principal, expectedPrincipal);
        assertEq(seniorPrincipal, expectedSeniorPrincipal);
        assertEq(juniorPrincipal, expectedJuniorPrincipal);
        assertFalse(resolved);

        IInvoiceNFT.Invoice memory invoice = invoiceNFT.getInvoice(invoiceId);
        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
    }

    /// @dev Assumes a single financed invoice was fully settled.
    function _assertSettledState(
        uint256 invoiceId,
        uint256 expectedSeniorFee,
        uint256 expectedJuniorFee,
        uint256 expectedTotalFee
    ) internal view {
        IInvoiceNFT.Invoice memory invoice = invoiceNFT.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertTrue(_getPositionResolved(invoiceId));
        assertEq(pool.totalLockedAssets(), 0);
        assertEq(pool.totalBadDebt(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);
        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT + expectedSeniorFee);
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT + expectedJuniorFee);
        assertEq(pool.totalPoolAssets(), SENIOR_DEPOSIT + JUNIOR_DEPOSIT + expectedTotalFee);
    }

    /// @dev Assumes a single financed invoice was fully resolved through default.
    function _assertDefaultResolvedState(
        uint256 invoiceId,
        uint256 expectedSeniorAssets,
        uint256 expectedJuniorAssets,
        uint256 expectedBadDebt
    ) internal view {
        IInvoiceNFT.Invoice memory invoice = invoiceNFT.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertTrue(_getPositionResolved(invoiceId));
        assertEq(pool.totalLockedAssets(), 0);
        assertEq(pool.totalBadDebt(), expectedBadDebt);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);
        assertEq(seniorPool.totalAssets(), expectedSeniorAssets);
        assertEq(juniorPool.totalAssets(), expectedJuniorAssets);
        assertEq(pool.totalPoolAssets(), expectedSeniorAssets + expectedJuniorAssets);
    }

    function test_FinanceInvoice_Standalone_LocksTrancheLiquidityAndIncreasesBuyerExposure() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);
        IInvoiceNFT.Invoice memory invoice = invoiceNFT.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertEq(pool.totalLockedAssets(), principal);
        assertEq(riskManager.getBuyerExposure(buyer), principal);
        assertEq(seniorPool.lockedAssets(), seniorPrincipal);
        assertEq(juniorPool.lockedAssets(), juniorPrincipal);
    }

    function test_HappyPath_FullLifecycle_SettledInvoice_DistributesFeeAndAllowsProfitableWithdrawal() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _assertFinancedPosition(invoiceId, principal, seniorPrincipal, juniorPrincipal, dueDate);

        uint256 financingFee = _getPositionFinancingFee(invoiceId);
        (uint256 seniorFee, uint256 juniorFee) = _expectedFeeSplit(financingFee);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);

        assertTrue(pool.isOracleStatusFinalized(invoiceId));
        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));

        _settleAsBuyer(invoiceId, principal + financingFee);
        _assertSettledState(invoiceId, seniorFee, juniorFee, financingFee);

        uint256 seniorWithdrawAmount = seniorPool.maxWithdraw(seniorLP);
        uint256 juniorWithdrawAmount = juniorPool.maxWithdraw(juniorLP);

        assertGt(seniorWithdrawAmount, SENIOR_DEPOSIT);
        assertGt(juniorWithdrawAmount, JUNIOR_DEPOSIT);

        uint256 seniorSharesToApprove = pool.previewSeniorWithdrawShares(seniorWithdrawAmount);
        uint256 juniorSharesToApprove = pool.previewJuniorWithdrawShares(juniorWithdrawAmount);
        uint256 seniorBalanceBefore = asset.balanceOf(seniorLP);
        uint256 juniorBalanceBefore = asset.balanceOf(juniorLP);

        vm.startPrank(seniorLP);
        seniorPool.approve(address(pool), seniorSharesToApprove);
        pool.withdrawSenior(seniorWithdrawAmount);
        vm.stopPrank();

        vm.startPrank(juniorLP);
        juniorPool.approve(address(pool), juniorSharesToApprove);
        pool.withdrawJunior(juniorWithdrawAmount);
        vm.stopPrank();

        assertEq(asset.balanceOf(seniorLP) - seniorBalanceBefore, seniorWithdrawAmount);
        assertEq(asset.balanceOf(juniorLP) - juniorBalanceBefore, juniorWithdrawAmount);
        assertLe(seniorPool.balanceOf(seniorLP), 1);
        assertLe(juniorPool.balanceOf(juniorLP), 1);
        assertLe(seniorPool.totalAssets(), 1);
        assertLe(juniorPool.totalAssets(), 1);
        assertLe(pool.totalPoolAssets(), 2);
    }

    function test_Default_PartialJuniorRecovery_SeniorPrincipalProtected() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _assertFinancedPosition(invoiceId, principal, seniorPrincipal, juniorPrincipal, dueDate);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        uint256 expectedJuniorRecovery = 4_000e18;
        uint256 recoveredAmount = seniorPrincipal + expectedJuniorRecovery;
        uint256 expectedSeniorLoss = 0;
        uint256 expectedJuniorLoss = juniorPrincipal - expectedJuniorRecovery;
        uint256 expectedTotalLoss = principal - recoveredAmount;

        assertEq(expectedJuniorLoss, 20_000e18);
        assertEq(expectedTotalLoss, expectedJuniorLoss);
        assertEq(expectedTotalLoss, expectedSeniorLoss + expectedJuniorLoss);

        _resolveDefaultAsResolver(invoiceId, recoveredAmount);

        _assertDefaultResolvedState(
            invoiceId, SENIOR_DEPOSIT - expectedSeniorLoss, JUNIOR_DEPOSIT - expectedJuniorLoss, expectedTotalLoss
        );
    }

    function test_Default_RecoveryEqualsSeniorPrincipal_JuniorIsFullyWrittenDown() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _assertFinancedPosition(invoiceId, principal, seniorPrincipal, juniorPrincipal, dueDate);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        uint256 recoveredAmount = seniorPrincipal;
        uint256 expectedTotalLoss = principal - recoveredAmount;

        assertEq(expectedTotalLoss, juniorPrincipal);

        _resolveDefaultAsResolver(invoiceId, recoveredAmount);

        _assertDefaultResolvedState(invoiceId, SENIOR_DEPOSIT, JUNIOR_DEPOSIT - juniorPrincipal, expectedTotalLoss);
    }

    function test_Default_LossExceedsJuniorBuffer_SeniorAbsorbsResidualLoss() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _assertFinancedPosition(invoiceId, principal, seniorPrincipal, juniorPrincipal, dueDate);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        uint256 recoveredAmount = 20_000e18;
        uint256 expectedSeniorRecovery = recoveredAmount < seniorPrincipal ? recoveredAmount : seniorPrincipal;
        uint256 expectedJuniorRecovery = recoveredAmount - expectedSeniorRecovery;
        uint256 expectedSeniorLoss = seniorPrincipal - expectedSeniorRecovery;
        uint256 expectedJuniorLoss = juniorPrincipal - expectedJuniorRecovery;
        uint256 expectedTotalLoss = principal - recoveredAmount;

        assertEq(expectedSeniorRecovery, 20_000e18);
        assertEq(expectedJuniorRecovery, 0);
        assertEq(expectedSeniorLoss, 36_000e18);
        assertEq(expectedJuniorLoss, 24_000e18);
        assertEq(expectedTotalLoss, expectedSeniorLoss + expectedJuniorLoss);

        _resolveDefaultAsResolver(invoiceId, recoveredAmount);

        _assertDefaultResolvedState(
            invoiceId, SENIOR_DEPOSIT - expectedSeniorLoss, JUNIOR_DEPOSIT - expectedJuniorLoss, expectedTotalLoss
        );
    }

    function test_Default_ZeroRecovery_BothTranchesAreFullyWrittenDown() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _assertFinancedPosition(invoiceId, principal, seniorPrincipal, juniorPrincipal, dueDate);
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        assertEq(principal, seniorPrincipal + juniorPrincipal);

        _resolveDefaultAsResolver(invoiceId, 0);

        _assertDefaultResolvedState(
            invoiceId, SENIOR_DEPOSIT - seniorPrincipal, JUNIOR_DEPOSIT - juniorPrincipal, principal
        );
    }

    function test_ResolveDefault_IsolatesTwoActivePositionsForSameBuyer() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 firstInvoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        uint256 secondInvoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);

        _financeAsSupplier(firstInvoiceId);
        _financeAsSupplier(secondInvoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        assertEq(pool.totalLockedAssets(), principal * 2);
        assertEq(riskManager.getBuyerExposure(buyer), principal * 2);
        assertEq(seniorPool.lockedAssets(), seniorPrincipal * 2);
        assertEq(juniorPool.lockedAssets(), juniorPrincipal * 2);

        _assertActiveFinancingPosition(firstInvoiceId, principal, seniorPrincipal, juniorPrincipal);
        _assertActiveFinancingPosition(secondInvoiceId, principal, seniorPrincipal, juniorPrincipal);

        _submitAndFinalizeOracleStatus(firstInvoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);
        _resolveDefaultAsResolver(firstInvoiceId, 0);

        IInvoiceNFT.Invoice memory firstInvoice = invoiceNFT.getInvoice(firstInvoiceId);

        assertEq(uint256(firstInvoice.status), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertTrue(_getPositionResolved(firstInvoiceId));

        _assertActiveFinancingPosition(secondInvoiceId, principal, seniorPrincipal, juniorPrincipal);

        assertEq(pool.totalLockedAssets(), principal);
        assertEq(riskManager.getBuyerExposure(buyer), principal);
        assertEq(seniorPool.lockedAssets(), seniorPrincipal);
        assertEq(juniorPool.lockedAssets(), juniorPrincipal);
        assertEq(pool.totalBadDebt(), principal);
        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT - seniorPrincipal);
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT - juniorPrincipal);
    }

    function test_FinanceInvoice_Reverts_WhenBuyerExposureLimitExceeded() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        uint256 firstInvoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(firstInvoiceId);

        uint256 principal = _expectedPrincipal();

        IRWARiskManager.RiskParams memory tighterParams = IRWARiskManager.RiskParams({
            maxExposurePerBuyer: principal,
            advanceRate: ADVANCE_RATE_BPS,
            maxInvoiceTenor: MAX_TENOR,
            minInvoiceAmount: MIN_INVOICE_AMOUNT,
            financingFeeApr: FINANCING_FEE_APR_BPS
        });

        vm.prank(admin);
        riskManager.setRiskParams(tighterParams);

        uint256 secondInvoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);

        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceNotEligible.selector, secondInvoiceId));
        vm.prank(supplier);
        pool.financeInvoice(secondInvoiceId);

        assertEq(riskManager.getBuyerExposure(buyer), principal);
        assertEq(pool.totalLockedAssets(), principal);
    }

    function test_FinanceInvoice_Reverts_WhenTenorExceedsMaxTenor() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + MAX_TENOR + 1);

        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceNotEligible.selector, invoiceId));
        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);
        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function test_FinanceInvoice_Reverts_WhenAmountBelowMinimum() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(MIN_INVOICE_AMOUNT - 1, block.timestamp + INVOICE_TENOR);

        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceNotEligible.selector, invoiceId));
        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);
        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function test_FinanceInvoice_Reverts_WhenBuyerIsDenied() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(admin);
        riskManager.setBuyerDenied(buyer, true);

        assertTrue(riskManager.isBuyerDenied(buyer));

        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceNotEligible.selector, invoiceId));
        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);
        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function test_FinanceInvoice_Reverts_WhenInvoiceAlreadyFinanced() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceAlreadyFinanced.selector, invoiceId));
        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        assertEq(pool.totalLockedAssets(), principal);
        assertEq(riskManager.getBuyerExposure(buyer), principal);
        assertEq(seniorPool.lockedAssets(), seniorPrincipal);
        assertEq(juniorPool.lockedAssets(), juniorPrincipal);
        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertFalse(_getPositionResolved(invoiceId));
    }

    function test_OracleFinalize_Reverts_BeforeDisputeWindowExpires() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(invoiceId);

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);
        uint256 earliestFinalizeAt = update.submittedAt + DISPUTE_WINDOW;

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.DisputeWindowNotElapsed.selector, invoiceId, earliestFinalizeAt)
        );
        oracle.finalize(invoiceId);

        assertFalse(pool.isOracleStatusFinalized(invoiceId));
        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertFalse(_getPositionResolved(invoiceId));
        assertEq(pool.totalLockedAssets(), _expectedPrincipal());
        assertEq(riskManager.getBuyerExposure(buyer), _expectedPrincipal());
    }

    function test_OracleFinalize_Reverts_WhenStatusUpdateIsDisputed() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(invoiceId);

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateDisputed.selector, invoiceId));
        oracle.finalize(invoiceId);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertTrue(update.disputed);
        assertFalse(update.finalized);
        assertFalse(pool.isOracleStatusFinalized(invoiceId));
        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertFalse(_getPositionResolved(invoiceId));
        assertEq(pool.totalLockedAssets(), _expectedPrincipal());
        assertEq(riskManager.getBuyerExposure(buyer), _expectedPrincipal());
    }

    function test_FinanceInvoice_Reverts_WhenVerifiedInvoiceIsFrozen() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(riskAdmin);
        invoiceNFT.freezeInvoice(invoiceId);

        IInvoiceNFT.Invoice memory frozenInvoice = invoiceNFT.getInvoice(invoiceId);
        assertEq(uint256(frozenInvoice.status), uint256(IInvoiceNFT.InvoiceStatus.FROZEN));
        assertEq(uint256(frozenInvoice.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));

        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.InvoiceNotEligible.selector, invoiceId));
        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);
    }

    function test_SettleInvoice_Reverts_WhenFundedInvoiceIsFrozen() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 financingFee = _getPositionFinancingFee(invoiceId);
        uint256 expectedRepayment = principal + financingFee;
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);

        vm.prank(riskAdmin);
        invoiceNFT.freezeInvoice(invoiceId);

        asset.mint(buyer, expectedRepayment);

        vm.startPrank(buyer);
        asset.approve(address(pool), expectedRepayment);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvoiceFrozen.selector, invoiceId));
        pool.settleInvoice(invoiceId, expectedRepayment);
        vm.stopPrank();

        assertTrue(pool.isOracleStatusFinalized(invoiceId));
        assertEq(pool.totalLockedAssets(), principal);
        assertEq(riskManager.getBuyerExposure(buyer), principal);
        assertEq(seniorPool.lockedAssets(), seniorPrincipal);
        assertEq(juniorPool.lockedAssets(), juniorPrincipal);
        assertEq(pool.totalBadDebt(), 0);
        assertFalse(_getPositionResolved(invoiceId));
    }

    function test_ResolveDefault_Reverts_WhenFundedInvoiceIsFrozen() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);
        uint256 recoveredAmount = seniorPrincipal;

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        vm.prank(riskAdmin);
        invoiceNFT.freezeInvoice(invoiceId);

        asset.mint(resolver, recoveredAmount);

        vm.startPrank(resolver);
        asset.approve(address(pool), recoveredAmount);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvoiceFrozen.selector, invoiceId));
        pool.resolveDefault(invoiceId, recoveredAmount);
        vm.stopPrank();

        assertTrue(pool.isOracleStatusFinalized(invoiceId));
        assertEq(pool.totalLockedAssets(), principal);
        assertEq(pool.totalBadDebt(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), principal);
        assertEq(seniorPool.lockedAssets(), seniorPrincipal);
        assertEq(juniorPool.lockedAssets(), juniorPrincipal);
        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT);
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT);
        assertFalse(_getPositionResolved(invoiceId));
    }

    function test_SettleInvoice_Succeeds_AfterFrozenInvoiceIsUnfrozen() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 financingFee = _getPositionFinancingFee(invoiceId);
        uint256 expectedRepayment = principal + financingFee;
        (uint256 seniorFee, uint256 juniorFee) = _expectedFeeSplit(financingFee);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED);

        vm.prank(riskAdmin);
        invoiceNFT.freezeInvoice(invoiceId);

        asset.mint(buyer, expectedRepayment);

        vm.startPrank(buyer);
        asset.approve(address(pool), expectedRepayment);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvoiceFrozen.selector, invoiceId));
        pool.settleInvoice(invoiceId, expectedRepayment);
        vm.stopPrank();

        vm.prank(riskAdmin);
        invoiceNFT.unfreezeInvoice(invoiceId);

        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));

        // The approval was set in a separate successful call and remains valid.
        // The reverted settlement transferred no tokens and consumed no allowance.
        vm.prank(buyer);
        pool.settleInvoice(invoiceId, expectedRepayment);

        _assertSettledState(invoiceId, seniorFee, juniorFee, financingFee);
    }

    function test_ResolveDefault_Succeeds_AfterFrozenInvoiceIsUnfrozen() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        _financeAsSupplier(invoiceId);

        uint256 principal = _expectedPrincipal();
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);
        uint256 recoveredAmount = seniorPrincipal;

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED);

        vm.prank(riskAdmin);
        invoiceNFT.freezeInvoice(invoiceId);

        asset.mint(resolver, recoveredAmount);

        vm.startPrank(resolver);
        asset.approve(address(pool), recoveredAmount);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.InvoiceFrozen.selector, invoiceId));
        pool.resolveDefault(invoiceId, recoveredAmount);
        vm.stopPrank();

        vm.prank(riskAdmin);
        invoiceNFT.unfreezeInvoice(invoiceId);

        assertEq(uint256(invoiceNFT.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));

        // The approval remains valid because the reverted resolution transferred
        // no recovery tokens and consumed no allowance.
        vm.prank(resolver);
        pool.resolveDefault(invoiceId, recoveredAmount);

        _assertDefaultResolvedState(invoiceId, SENIOR_DEPOSIT, JUNIOR_DEPOSIT - juniorPrincipal, juniorPrincipal);
    }
}

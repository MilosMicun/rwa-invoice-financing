// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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

contract InvoiceFinancingPoolAccountingFuzzTest is Test {
    MockERC20 internal asset;
    InvoiceNFT internal invoiceNft;
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
    address internal seniorLp = makeAddr("seniorLp");
    address internal juniorLp = makeAddr("juniorLp");

    uint256 internal constant BPS = 10_000;

    uint256 internal constant SENIOR_DEPOSIT = 700_000e18;
    uint256 internal constant JUNIOR_DEPOSIT = 300_000e18;

    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant SENIOR_FUNDING_SHARE_BPS = 7_000;
    uint256 internal constant JUNIOR_FUNDING_SHARE_BPS = 3_000;
    uint256 internal constant SENIOR_FEE_SHARE_BPS = 4_000;
    uint256 internal constant JUNIOR_FEE_SHARE_BPS = 6_000;

    uint256 internal constant MAX_TENOR = 90 days;
    uint256 internal constant MIN_INVOICE_AMOUNT = 1_000e18;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;
    uint256 internal constant MAX_EXPOSURE_PER_BUYER = 1_000_000e18;

    uint256 internal constant DISPUTE_WINDOW = 1 days;
    uint256 internal constant MAX_STALENESS = 7 days;

    uint256 internal constant MAX_FUZZ_FACE_VALUE = 1_000_000e18;
    uint256 internal constant MAX_SETTLEMENT_SURPLUS = 10_000e18;
    uint256 internal constant MAX_RECOVERY_EXCESS = 100_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20();
        invoiceNft = new InvoiceNFT(admin);

        IRWARiskManager.RiskParams memory params = IRWARiskManager.RiskParams({
            maxExposurePerBuyer: MAX_EXPOSURE_PER_BUYER,
            advanceRate: ADVANCE_RATE_BPS,
            maxInvoiceTenor: MAX_TENOR,
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

        seniorPool = pool.SENIOR_POOL();
        juniorPool = pool.JUNIOR_POOL();

        oracle = new InvoiceStatusOracle(admin, invoiceNft, pool, DISPUTE_WINDOW, MAX_STALENESS);

        vm.startPrank(admin);
        invoiceNft.grantRole(invoiceNft.ORIGINATOR_ROLE(), originator);
        invoiceNft.grantRole(invoiceNft.VERIFIER_ROLE(), verifier);
        invoiceNft.grantRole(invoiceNft.RISK_ROLE(), riskAdmin);
        invoiceNft.grantRole(invoiceNft.POOL_ROLE(), address(pool));
        riskManager.grantRole(riskManager.POOL_ROLE(), address(pool));
        pool.setInvoiceStatusOracle(address(oracle));
        vm.stopPrank();
    }

    function _depositTranches() internal {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
    }

    function _depositTranches(uint256 seniorAssets, uint256 juniorAssets) internal {
        asset.mint(seniorLp, seniorAssets);
        asset.mint(juniorLp, juniorAssets);

        vm.startPrank(seniorLp);
        asset.approve(address(pool), seniorAssets);
        pool.depositSenior(seniorAssets);
        vm.stopPrank();

        vm.startPrank(juniorLp);
        asset.approve(address(pool), juniorAssets);
        pool.depositJunior(juniorAssets);
        vm.stopPrank();
    }

    function _createVerifiedInvoice(uint256 faceValue, uint256 dueDate) internal returns (uint256 invoiceId) {
        vm.prank(originator);
        invoiceId = invoiceNft.createInvoice(supplier, buyer, faceValue, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);
    }

    function _expectedPrincipal(uint256 faceValue) internal pure returns (uint256 principal) {
        principal = faceValue * ADVANCE_RATE_BPS / BPS;
    }

    function _expectedSeniorPrincipal(uint256 principal) internal pure returns (uint256 seniorPrincipal) {
        seniorPrincipal = principal * SENIOR_FUNDING_SHARE_BPS / BPS;
    }

    function _expectedJuniorPrincipal(uint256 principal, uint256 seniorPrincipal)
        internal
        pure
        returns (uint256 juniorPrincipal)
    {
        juniorPrincipal = principal - seniorPrincipal;
    }

    function _expectedFeeSplit(uint256 fee) internal pure returns (uint256 seniorFee, uint256 juniorFee) {
        juniorFee = fee * JUNIOR_FEE_SHARE_BPS / BPS;
        seniorFee = fee - juniorFee;
    }

    function _submitAndFinalizeOracleStatus(
        uint256 invoiceId,
        IInvoiceNFT.InvoiceStatus status,
        uint256 recoveredAmount
    ) internal {
        vm.prank(admin);
        oracle.submitStatus(invoiceId, status, recoveredAmount);

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

    function _resolveDefaultAsResolver(uint256 invoiceId) internal {
        uint256 recoveredAmount = pool.finalizedRecoveryAmount(invoiceId);

        if (recoveredAmount == 0) {
            vm.prank(buyer);
            pool.resolveDefault(invoiceId);
            return;
        }

        asset.mint(buyer, recoveredAmount);

        vm.startPrank(buyer);
        asset.approve(address(pool), recoveredAmount);
        pool.resolveDefault(invoiceId);
        vm.stopPrank();
    }

    function _getPositionPrincipal(uint256 invoiceId) internal view returns (uint256 principal) {
        (,, principal,,,,,,) = pool.financingPositions(invoiceId);
    }

    function _getPositionFinancingFee(uint256 invoiceId) internal view returns (uint256 financingFee) {
        (,,,,, financingFee,,,) = pool.financingPositions(invoiceId);
    }

    function _getPositionResolved(uint256 invoiceId) internal view returns (bool resolved) {
        (,,,,,,,, resolved) = pool.financingPositions(invoiceId);
    }

    function _getPositionPrincipalSplit(uint256 invoiceId)
        internal
        view
        returns (uint256 principal, uint256 seniorPrincipal, uint256 juniorPrincipal)
    {
        (,, principal, seniorPrincipal, juniorPrincipal,,,,) = pool.financingPositions(invoiceId);
    }

    function _assertPositionCore(
        uint256 invoiceId,
        uint256 expectedPrincipal,
        uint256 expectedSeniorPrincipal,
        uint256 expectedJuniorPrincipal
    ) internal view {
        (
            address positionSupplier,
            address positionBuyer,
            uint256 positionPrincipal,
            uint256 positionSeniorPrincipal,
            uint256 positionJuniorPrincipal,,,,
        ) = pool.financingPositions(invoiceId);

        assertEq(positionSupplier, supplier);
        assertEq(positionBuyer, buyer);
        assertEq(positionPrincipal, expectedPrincipal);
        assertEq(positionSeniorPrincipal, expectedSeniorPrincipal);
        assertEq(positionJuniorPrincipal, expectedJuniorPrincipal);
    }

    function _assertPositionTerms(uint256 invoiceId, uint256 expectedPrincipal, uint256 expectedDueDate) internal view {
        (,,,,, uint256 financingFee, uint256 fundedAt, uint256 positionDueDate, bool resolved) =
            pool.financingPositions(invoiceId);

        uint256 expectedFee = riskManager.calculateFee(expectedPrincipal, fundedAt, expectedDueDate);

        assertEq(financingFee, expectedFee);
        assertEq(positionDueDate, expectedDueDate);
        assertFalse(resolved);
    }

    function _assertLockedAccounting(
        uint256 expectedPrincipal,
        uint256 expectedSeniorPrincipal,
        uint256 expectedJuniorPrincipal
    ) internal view {
        assertEq(expectedSeniorPrincipal + expectedJuniorPrincipal, expectedPrincipal);

        assertEq(pool.totalLockedAssets(), expectedPrincipal);
        assertEq(seniorPool.lockedAssets(), expectedSeniorPrincipal);
        assertEq(juniorPool.lockedAssets(), expectedJuniorPrincipal);

        assertEq(riskManager.getBuyerExposure(buyer), expectedPrincipal);
    }

    function _assertNavUnchangedAfterFinancing() internal view {
        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT);
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT);
        assertEq(pool.totalPoolAssets(), SENIOR_DEPOSIT + JUNIOR_DEPOSIT);
    }

    function _assertCashMovedToSupplier(
        uint256 supplierBalanceBefore,
        uint256 expectedPrincipal,
        uint256 expectedSeniorPrincipal,
        uint256 expectedJuniorPrincipal
    ) internal view {
        assertEq(asset.balanceOf(address(seniorPool)), SENIOR_DEPOSIT - expectedSeniorPrincipal);
        assertEq(asset.balanceOf(address(juniorPool)), JUNIOR_DEPOSIT - expectedJuniorPrincipal);
        assertEq(asset.balanceOf(supplier) - supplierBalanceBefore, expectedPrincipal);
    }

    function _assertInvoiceFunded(uint256 invoiceId, uint256 expectedDueDate) internal view {
        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        (,,,,,, uint256 fundedAt,,) = pool.financingPositions(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertEq(invoice.fundedAt, fundedAt);
        assertEq(invoice.dueDate, expectedDueDate);
    }

    function _assertSettledAccounting(
        uint256 invoiceId,
        uint256 expectedSeniorFee,
        uint256 expectedJuniorFee,
        uint256 expectedTotalFee
    ) internal view {
        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertTrue(_getPositionResolved(invoiceId));

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(pool.totalBadDebt(), 0);

        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);

        assertEq(riskManager.getBuyerExposure(buyer), 0);

        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT + expectedSeniorFee);
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT + expectedJuniorFee);
        assertEq(pool.totalPoolAssets(), SENIOR_DEPOSIT + JUNIOR_DEPOSIT + expectedTotalFee);

        assertEq(asset.balanceOf(address(seniorPool)), SENIOR_DEPOSIT + expectedSeniorFee);
        assertEq(asset.balanceOf(address(juniorPool)), JUNIOR_DEPOSIT + expectedJuniorFee);
    }

    function _assertSettledAccountingWithExistingBadDebt(
        uint256 invoiceId,
        uint256 expectedSeniorAssets,
        uint256 expectedJuniorAssets,
        uint256 expectedBadDebt
    ) internal view {
        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertTrue(_getPositionResolved(invoiceId));

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(pool.totalBadDebt(), expectedBadDebt);

        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);

        assertEq(riskManager.getBuyerExposure(buyer), 0);

        assertEq(seniorPool.totalAssets(), expectedSeniorAssets);
        assertEq(juniorPool.totalAssets(), expectedJuniorAssets);
        assertEq(pool.totalPoolAssets(), expectedSeniorAssets + expectedJuniorAssets);

        assertEq(asset.balanceOf(address(seniorPool)), expectedSeniorAssets);
        assertEq(asset.balanceOf(address(juniorPool)), expectedJuniorAssets);
    }

    function _assertDefaultResolvedAccounting(
        uint256 invoiceId,
        uint256 expectedSeniorRecovery,
        uint256 expectedJuniorRecovery,
        uint256 expectedSeniorLoss,
        uint256 expectedJuniorLoss,
        uint256 expectedTotalLoss
    ) internal view {
        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertTrue(_getPositionResolved(invoiceId));

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(pool.totalBadDebt(), expectedTotalLoss);

        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);

        assertEq(riskManager.getBuyerExposure(buyer), 0);

        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT - expectedSeniorLoss);
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT - expectedJuniorLoss);

        assertEq(asset.balanceOf(address(seniorPool)), SENIOR_DEPOSIT - expectedSeniorLoss);
        assertEq(asset.balanceOf(address(juniorPool)), JUNIOR_DEPOSIT - expectedJuniorLoss);

        assertEq(expectedSeniorRecovery + expectedJuniorRecovery + expectedTotalLoss, _getPositionPrincipal(invoiceId));
    }

    function _expectUnderfundedRecoveryRevert(
        uint256 approvedAmount,
        uint256 expectedSeniorRecovery,
        uint256 expectedJuniorRecovery
    ) internal {
        if (approvedAmount < expectedSeniorRecovery) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector,
                    address(pool),
                    approvedAmount,
                    expectedSeniorRecovery
                )
            );

            return;
        }

        uint256 remainingAllowance = approvedAmount - expectedSeniorRecovery;

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(pool),
                remainingAllowance,
                expectedJuniorRecovery
            )
        );
    }

    function _assertActiveDefaultFailureState(
        uint256 invoiceId,
        uint256 expectedPrincipal,
        uint256 expectedSeniorPrincipal,
        uint256 expectedJuniorPrincipal
    ) internal view {
        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertFalse(_getPositionResolved(invoiceId));

        assertEq(pool.totalLockedAssets(), expectedPrincipal);
        assertEq(pool.totalBadDebt(), 0);

        assertEq(seniorPool.lockedAssets(), expectedSeniorPrincipal);
        assertEq(juniorPool.lockedAssets(), expectedJuniorPrincipal);

        assertEq(riskManager.getBuyerExposure(buyer), expectedPrincipal);

        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT);
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT);

        assertEq(asset.balanceOf(address(seniorPool)), SENIOR_DEPOSIT - expectedSeniorPrincipal);
        assertEq(asset.balanceOf(address(juniorPool)), JUNIOR_DEPOSIT - expectedJuniorPrincipal);
    }

    function testFuzz_FinanceInvoice_SplitsPrincipalAndLocksTranches(uint256 faceValue, uint256 tenor) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        uint256 principal = _expectedPrincipal(faceValue);
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        uint256 supplierBalanceBefore = asset.balanceOf(supplier);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        _assertPositionCore(invoiceId, principal, seniorPrincipal, juniorPrincipal);
        _assertPositionTerms(invoiceId, principal, dueDate);
        _assertLockedAccounting(principal, seniorPrincipal, juniorPrincipal);
        _assertNavUnchangedAfterFinancing();
        _assertCashMovedToSupplier(supplierBalanceBefore, principal, seniorPrincipal, juniorPrincipal);
        _assertInvoiceFunded(invoiceId, dueDate);
    }

    function testFuzz_FinanceInvoice_Reverts_WhenSeniorLiquidityInsufficient(uint256 faceValue, uint256 tenor) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        uint256 principal = _expectedPrincipal(faceValue);
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _depositTranches(seniorPrincipal - 1, juniorPrincipal);

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.expectRevert(InvoiceFinancingPool.InsufficientSeniorLiquidity.selector);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);
        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function testFuzz_FinanceInvoice_Reverts_WhenJuniorLiquidityInsufficient(uint256 faceValue, uint256 tenor) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        uint256 principal = _expectedPrincipal(faceValue);
        uint256 seniorPrincipal = _expectedSeniorPrincipal(principal);
        uint256 juniorPrincipal = _expectedJuniorPrincipal(principal, seniorPrincipal);

        _depositTranches(seniorPrincipal, juniorPrincipal - 1);

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.expectRevert(InvoiceFinancingPool.InsufficientJuniorLiquidity.selector);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        assertEq(pool.totalLockedAssets(), 0);
        assertEq(riskManager.getBuyerExposure(buyer), 0);
        assertEq(seniorPool.lockedAssets(), 0);
        assertEq(juniorPool.lockedAssets(), 0);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);
        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function testFuzz_SettleInvoice_SplitsFeeAndUnlocksPrincipal(uint256 faceValue, uint256 tenor) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        uint256 principal = _getPositionPrincipal(invoiceId);
        uint256 financingFee = _getPositionFinancingFee(invoiceId);
        uint256 expectedRepayment = principal + financingFee;

        (uint256 seniorFee, uint256 juniorFee) = _expectedFeeSplit(financingFee);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        assertTrue(pool.isOracleStatusFinalized(invoiceId));
        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);

        _settleAsBuyer(invoiceId, expectedRepayment);

        _assertSettledAccounting(invoiceId, seniorFee, juniorFee, financingFee);
    }

    function testFuzz_SettleInvoice_ReturnsSurplusToSupplier(uint256 faceValue, uint256 tenor, uint256 surplus) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);
        surplus = bound(surplus, 1, MAX_SETTLEMENT_SURPLUS);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        uint256 principal = _getPositionPrincipal(invoiceId);
        uint256 financingFee = _getPositionFinancingFee(invoiceId);
        uint256 expectedRepayment = principal + financingFee;
        uint256 paidAmount = expectedRepayment + surplus;

        (uint256 seniorFee, uint256 juniorFee) = _expectedFeeSplit(financingFee);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        uint256 supplierBalanceBeforeSettlement = asset.balanceOf(supplier);

        _settleAsBuyer(invoiceId, paidAmount);

        assertEq(asset.balanceOf(supplier) - supplierBalanceBeforeSettlement, surplus);

        _assertSettledAccounting(invoiceId, seniorFee, juniorFee, financingFee);
    }

    function testFuzz_SettleInvoice_DoesNotChangeExistingBadDebt(uint256 faceValue, uint256 tenor) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 firstDueDate = block.timestamp + 1 days;
        uint256 firstInvoiceId = _createVerifiedInvoice(MIN_INVOICE_AMOUNT, firstDueDate);

        vm.prank(supplier);
        pool.financeInvoice(firstInvoiceId);

        (uint256 firstPrincipal, uint256 firstSeniorPrincipal, uint256 firstJuniorPrincipal) =
            _getPositionPrincipalSplit(firstInvoiceId);

        _submitAndFinalizeOracleStatus(firstInvoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);

        _resolveDefaultAsResolver(firstInvoiceId);

        uint256 existingBadDebt = pool.totalBadDebt();

        assertEq(existingBadDebt, firstPrincipal);

        uint256 secondDueDate = block.timestamp + tenor;
        uint256 secondInvoiceId = _createVerifiedInvoice(faceValue, secondDueDate);

        vm.prank(supplier);
        pool.financeInvoice(secondInvoiceId);

        uint256 secondPrincipal = _getPositionPrincipal(secondInvoiceId);
        uint256 secondFinancingFee = _getPositionFinancingFee(secondInvoiceId);
        uint256 expectedRepayment = secondPrincipal + secondFinancingFee;

        (uint256 seniorFee, uint256 juniorFee) = _expectedFeeSplit(secondFinancingFee);

        uint256 expectedSeniorAssets = SENIOR_DEPOSIT - firstSeniorPrincipal + seniorFee;
        uint256 expectedJuniorAssets = JUNIOR_DEPOSIT - firstJuniorPrincipal + juniorFee;

        _submitAndFinalizeOracleStatus(secondInvoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        _settleAsBuyer(secondInvoiceId, expectedRepayment);

        _assertSettledAccountingWithExistingBadDebt(
            secondInvoiceId, expectedSeniorAssets, expectedJuniorAssets, existingBadDebt
        );
    }

    function testFuzz_OracleFinalize_Reverts_WhenDefaultRecoveryExceedsPrincipal(
        uint256 faceValue,
        uint256 tenor,
        uint256 recoveryExcess
    ) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);
        recoveryExcess = bound(recoveryExcess, 1, MAX_RECOVERY_EXCESS);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        uint256 principal = _getPositionPrincipal(invoiceId);
        uint256 excessiveRecovery = principal + recoveryExcess;

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, excessiveRecovery);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.RecoveredAmountExceedsPrincipal.selector, invoiceId, excessiveRecovery, principal
            )
        );

        oracle.finalize(invoiceId);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertFalse(update.finalized);
        assertFalse(pool.isOracleStatusFinalized(invoiceId));
        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
        assertFalse(_getPositionResolved(invoiceId));
        assertEq(pool.totalBadDebt(), 0);
        assertEq(pool.totalLockedAssets(), principal);
    }

    function testFuzz_ResolveDefault_UsesOracleFinalizedRecovery(
        uint256 faceValue,
        uint256 tenor,
        uint256 recoveredAmount
    ) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        uint256 principal = _getPositionPrincipal(invoiceId);
        recoveredAmount = bound(recoveredAmount, 0, principal);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, recoveredAmount);

        assertTrue(pool.isOracleStatusFinalized(invoiceId));
        assertEq(uint256(pool.finalizedOracleStatus(invoiceId)), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(pool.finalizedRecoveryAmount(invoiceId), recoveredAmount);

        _resolveDefaultAsResolver(invoiceId);

        assertTrue(_getPositionResolved(invoiceId));
        assertEq(pool.totalBadDebt(), principal - recoveredAmount);
    }

    function testFuzz_ResolveDefault_SplitsRecoveryAndLossConservatively(
        uint256 faceValue,
        uint256 tenor,
        uint256 recoveredAmount
    ) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        (uint256 principal, uint256 seniorPrincipal, uint256 juniorPrincipal) = _getPositionPrincipalSplit(invoiceId);

        recoveredAmount = bound(recoveredAmount, 0, principal);

        uint256 seniorRecovery = recoveredAmount > seniorPrincipal ? seniorPrincipal : recoveredAmount;
        uint256 juniorRecovery = recoveredAmount - seniorRecovery;

        uint256 seniorLoss = seniorPrincipal - seniorRecovery;
        uint256 juniorLoss = juniorPrincipal - juniorRecovery;
        uint256 totalLoss = principal - recoveredAmount;

        assertEq(seniorRecovery + juniorRecovery, recoveredAmount);
        assertEq(seniorLoss + juniorLoss, totalLoss);

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, recoveredAmount);

        _resolveDefaultAsResolver(invoiceId);

        _assertDefaultResolvedAccounting(invoiceId, seniorRecovery, juniorRecovery, seniorLoss, juniorLoss, totalLoss);
    }

    function testFuzz_ResolveDefault_ZeroRecoveryWritesDownFullPrincipal(uint256 faceValue, uint256 tenor) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        (uint256 principal, uint256 seniorPrincipal, uint256 juniorPrincipal) = _getPositionPrincipalSplit(invoiceId);

        uint256 recoveredAmount = 0;

        uint256 seniorRecovery = 0;
        uint256 juniorRecovery = 0;

        uint256 seniorLoss = seniorPrincipal;
        uint256 juniorLoss = juniorPrincipal;
        uint256 totalLoss = principal;

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, recoveredAmount);

        assertEq(pool.finalizedRecoveryAmount(invoiceId), recoveredAmount);

        _resolveDefaultAsResolver(invoiceId);

        _assertDefaultResolvedAccounting(invoiceId, seniorRecovery, juniorRecovery, seniorLoss, juniorLoss, totalLoss);
    }

    function testFuzz_ResolveDefault_FullRecoveryCreatesNoBadDebt(uint256 faceValue, uint256 tenor) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        (uint256 principal, uint256 seniorPrincipal, uint256 juniorPrincipal) = _getPositionPrincipalSplit(invoiceId);

        uint256 recoveredAmount = principal;

        uint256 seniorRecovery = seniorPrincipal;
        uint256 juniorRecovery = juniorPrincipal;

        uint256 seniorLoss = 0;
        uint256 juniorLoss = 0;
        uint256 totalLoss = 0;

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, recoveredAmount);

        assertEq(pool.finalizedRecoveryAmount(invoiceId), recoveredAmount);

        _resolveDefaultAsResolver(invoiceId);

        _assertDefaultResolvedAccounting(invoiceId, seniorRecovery, juniorRecovery, seniorLoss, juniorLoss, totalLoss);
    }

    function testFuzz_ResolveDefault_CannotExecuteWithLessThanOracleFinalizedRecovery(
        uint256 faceValue,
        uint256 tenor,
        uint256 recoveredAmount
    ) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, MAX_FUZZ_FACE_VALUE);
        tenor = bound(tenor, 1, MAX_TENOR);

        _depositTranches();

        uint256 dueDate = block.timestamp + tenor;
        uint256 invoiceId = _createVerifiedInvoice(faceValue, dueDate);

        vm.prank(supplier);
        pool.financeInvoice(invoiceId);

        (uint256 principal, uint256 seniorPrincipal, uint256 juniorPrincipal) = _getPositionPrincipalSplit(invoiceId);

        recoveredAmount = bound(recoveredAmount, 1, principal);

        uint256 seniorRecovery = recoveredAmount > seniorPrincipal ? seniorPrincipal : recoveredAmount;
        uint256 juniorRecovery = recoveredAmount - seniorRecovery;

        uint256 seniorLoss = seniorPrincipal - seniorRecovery;
        uint256 juniorLoss = juniorPrincipal - juniorRecovery;
        uint256 totalLoss = principal - recoveredAmount;

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, recoveredAmount);

        assertEq(pool.finalizedRecoveryAmount(invoiceId), recoveredAmount);

        uint256 underfundedAmount = recoveredAmount - 1;

        asset.mint(buyer, underfundedAmount);

        vm.startPrank(buyer);
        asset.approve(address(pool), underfundedAmount);

        _expectUnderfundedRecoveryRevert(underfundedAmount, seniorRecovery, juniorRecovery);

        pool.resolveDefault(invoiceId);
        vm.stopPrank();

        _assertActiveDefaultFailureState(invoiceId, principal, seniorPrincipal, juniorPrincipal);

        asset.mint(buyer, recoveredAmount);

        vm.startPrank(buyer);
        asset.approve(address(pool), recoveredAmount);
        pool.resolveDefault(invoiceId);
        vm.stopPrank();

        _assertDefaultResolvedAccounting(invoiceId, seniorRecovery, juniorRecovery, seniorLoss, juniorLoss, totalLoss);
    }
}

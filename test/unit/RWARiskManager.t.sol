// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {InvoiceNFT} from "../../src/core/InvoiceNFT.sol";
import {RWARiskManager} from "../../src/risk/RWARiskManager.sol";
import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";
import {IRWARiskManager} from "../../src/interfaces/IRWARiskManager.sol";

contract RWARiskManagerTest is Test {
    InvoiceNFT internal invoiceNft;
    RWARiskManager internal riskManager;

    address internal admin = makeAddr("admin");
    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal pool = makeAddr("pool");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");
    address internal unauthorizedCaller = makeAddr("unauthorizedCaller");

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_EXPOSURE = 1_000_000e18;
    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant MAX_TENOR = 90 days;
    uint256 internal constant MIN_INVOICE_AMOUNT = 1_000e18;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;

    uint256 internal constant FACE_VALUE = 100_000e18;
    uint256 internal constant INVOICE_TENOR = 30 days;

    function setUp() public {
        vm.warp(1_700_000_000);

        invoiceNft = new InvoiceNFT(admin);
        riskManager = new RWARiskManager(admin, invoiceNft, _defaultRiskParams());

        vm.startPrank(admin);
        invoiceNft.grantRole(invoiceNft.ORIGINATOR_ROLE(), originator);
        invoiceNft.grantRole(invoiceNft.VERIFIER_ROLE(), verifier);
        invoiceNft.grantRole(invoiceNft.POOL_ROLE(), pool);
        riskManager.grantRole(riskManager.POOL_ROLE(), pool);
        vm.stopPrank();
    }

    function _defaultRiskParams() internal pure returns (IRWARiskManager.RiskParams memory params) {
        params = IRWARiskManager.RiskParams({
            maxExposurePerBuyer: MAX_EXPOSURE,
            advanceRate: ADVANCE_RATE_BPS,
            maxInvoiceTenor: MAX_TENOR,
            minInvoiceAmount: MIN_INVOICE_AMOUNT,
            financingFeeApr: FINANCING_FEE_APR_BPS
        });
    }

    function _createInvoice(uint256 faceValue, uint256 dueDate) internal returns (uint256 invoiceId) {
        vm.prank(originator);
        invoiceId = invoiceNft.createInvoice(supplier, buyer, faceValue, dueDate);
    }

    function _createVerifiedInvoice(uint256 faceValue, uint256 dueDate) internal returns (uint256 invoiceId) {
        invoiceId = _createInvoice(faceValue, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);
    }

    function test_Constructor_Reverts_WhenAdminIsZeroAddress() public {
        vm.expectRevert(RWARiskManager.ZeroAddress.selector);

        new RWARiskManager(address(0), invoiceNft, _defaultRiskParams());
    }

    function test_Constructor_Reverts_WhenInvoiceNFTIsZeroAddress() public {
        vm.expectRevert(RWARiskManager.ZeroAddress.selector);

        new RWARiskManager(admin, IInvoiceNFT(address(0)), _defaultRiskParams());
    }

    function test_Constructor_StoresInvoiceNFTAndGrantsAdminRoles() public view {
        assertEq(address(riskManager.INVOICE_NFT()), address(invoiceNft));
        assertTrue(riskManager.hasRole(riskManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(riskManager.hasRole(riskManager.RISK_ADMIN_ROLE(), admin));
        assertFalse(riskManager.hasRole(riskManager.POOL_ROLE(), admin));
    }

    function test_Constructor_StoresInitialRiskParams() public view {
        (
            uint256 maxExposurePerBuyer,
            uint256 advanceRate,
            uint256 maxInvoiceTenor,
            uint256 minInvoiceAmount,
            uint256 financingFeeApr
        ) = riskManager.riskParams();

        assertEq(maxExposurePerBuyer, MAX_EXPOSURE);
        assertEq(advanceRate, ADVANCE_RATE_BPS);
        assertEq(maxInvoiceTenor, MAX_TENOR);
        assertEq(minInvoiceAmount, MIN_INVOICE_AMOUNT);
        assertEq(financingFeeApr, FINANCING_FEE_APR_BPS);
    }

    function test_SetRiskParams_Reverts_WhenCallerLacksRiskAdminRole() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorizedCaller,
                riskManager.RISK_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorizedCaller);
        riskManager.setRiskParams(params);
    }

    function test_SetRiskParams_Reverts_WhenMaxExposureIsZero() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.maxExposurePerBuyer = 0;

        vm.expectRevert(RWARiskManager.InvalidRiskParams.selector);
        vm.prank(admin);
        riskManager.setRiskParams(params);
    }

    function test_SetRiskParams_Reverts_WhenAdvanceRateIsZero() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.advanceRate = 0;

        vm.expectRevert(RWARiskManager.InvalidRiskParams.selector);
        vm.prank(admin);
        riskManager.setRiskParams(params);
    }

    function test_SetRiskParams_Reverts_WhenMaxInvoiceTenorIsZero() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.maxInvoiceTenor = 0;

        vm.expectRevert(RWARiskManager.InvalidRiskParams.selector);
        vm.prank(admin);
        riskManager.setRiskParams(params);
    }

    function test_SetRiskParams_Reverts_WhenMinInvoiceAmountIsZero() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.minInvoiceAmount = 0;

        vm.expectRevert(RWARiskManager.InvalidRiskParams.selector);
        vm.prank(admin);
        riskManager.setRiskParams(params);
    }

    function test_SetRiskParams_AcceptsMaximumAdvanceRate() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.advanceRate = riskManager.MAX_ADVANCE_RATE_BPS();

        vm.prank(admin);
        riskManager.setRiskParams(params);

        (, uint256 advanceRate,,,) = riskManager.riskParams();

        assertEq(advanceRate, riskManager.MAX_ADVANCE_RATE_BPS());
    }

    function test_SetRiskParams_Reverts_WhenAdvanceRateExceedsMaximum() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.advanceRate = riskManager.MAX_ADVANCE_RATE_BPS() + 1;

        vm.expectRevert(RWARiskManager.AdvanceRateTooHigh.selector);
        vm.prank(admin);
        riskManager.setRiskParams(params);
    }

    function test_SetRiskParams_AcceptsMaximumFinancingFeeApr() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.financingFeeApr = riskManager.MAX_FINANCING_FEE_APR_BPS();

        vm.prank(admin);
        riskManager.setRiskParams(params);

        (,,,, uint256 financingFeeApr) = riskManager.riskParams();

        assertEq(financingFeeApr, riskManager.MAX_FINANCING_FEE_APR_BPS());
    }

    function test_SetRiskParams_Reverts_WhenFinancingFeeAprExceedsMaximum() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.financingFeeApr = riskManager.MAX_FINANCING_FEE_APR_BPS() + 1;

        vm.expectRevert(RWARiskManager.FinancingFeeAprTooHigh.selector);
        vm.prank(admin);
        riskManager.setRiskParams(params);
    }

    function test_SetRiskParams_AllowsZeroFinancingFeeApr() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.financingFeeApr = 0;

        vm.prank(admin);
        riskManager.setRiskParams(params);

        (,,,, uint256 financingFeeApr) = riskManager.riskParams();

        assertEq(financingFeeApr, 0);
    }

    function test_CalculateAdvance_ReturnsExpectedPrincipal() public view {
        uint256 expectedAdvance = FACE_VALUE * ADVANCE_RATE_BPS / BPS;

        assertEq(riskManager.calculateAdvance(FACE_VALUE), expectedAdvance);
    }

    function test_CalculateAdvance_ReturnsZeroForZeroFaceValue() public view {
        assertEq(riskManager.calculateAdvance(0), 0);
    }

    function test_CalculateAdvance_UsesUpdatedAdvanceRate() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.advanceRate = 5_000;

        vm.prank(admin);
        riskManager.setRiskParams(params);

        uint256 expectedAdvance = FACE_VALUE * 5_000 / BPS;

        assertEq(riskManager.calculateAdvance(FACE_VALUE), expectedAdvance);
    }

    function test_CalculateFee_ReturnsExpectedLinearAprFee() public view {
        uint256 principal = 80_000e18;
        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + INVOICE_TENOR;

        // 80,000 tokens at 12% APR for 30 days.
        uint256 expectedFee = 789_041_095_890_410_958_904;

        assertEq(riskManager.calculateFee(principal, fundedAt, dueDate), expectedFee);
    }

    function test_CalculateFee_ReturnsZero_WhenPrincipalIsZero() public view {
        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + INVOICE_TENOR;

        assertEq(riskManager.calculateFee(0, fundedAt, dueDate), 0);
    }

    function test_CalculateFee_ReturnsZero_WhenDueDateEqualsFundedAt() public view {
        uint256 fundedAt = block.timestamp;

        assertEq(riskManager.calculateFee(80_000e18, fundedAt, fundedAt), 0);
    }

    function test_CalculateFee_ReturnsZero_WhenDueDatePrecedesFundedAt() public view {
        uint256 fundedAt = block.timestamp;

        assertEq(riskManager.calculateFee(80_000e18, fundedAt, fundedAt - 1), 0);
    }

    function test_CalculateFee_ReturnsZero_WhenFinancingFeeAprIsZero() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.financingFeeApr = 0;

        vm.prank(admin);
        riskManager.setRiskParams(params);

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + INVOICE_TENOR;

        assertEq(riskManager.calculateFee(80_000e18, fundedAt, dueDate), 0);
    }

    function test_IsEligible_ReturnsFalse_WhenInvoiceDoesNotExist() public view {
        assertFalse(riskManager.isEligible(999));
    }

    function test_IsEligible_ReturnsFalse_WhenInvoiceIsNotVerified() public {
        uint256 invoiceId = _createInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        assertFalse(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsTrue_ForValidVerifiedInvoice() public {
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        assertTrue(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsTrue_WhenFaceValueEqualsMinimumAmount() public {
        uint256 invoiceId = _createVerifiedInvoice(MIN_INVOICE_AMOUNT, block.timestamp + INVOICE_TENOR);

        assertTrue(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsFalse_WhenFaceValueIsBelowMinimumAmount() public {
        uint256 invoiceId = _createVerifiedInvoice(MIN_INVOICE_AMOUNT - 1, block.timestamp + INVOICE_TENOR);

        assertFalse(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsTrue_WhenTenorEqualsMaximum() public {
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + MAX_TENOR);

        assertTrue(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsFalse_WhenTenorExceedsMaximum() public {
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + MAX_TENOR + 1);

        assertFalse(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsFalse_WhenInvoiceMaturesBeforeEligibilityCheck() public {
        uint256 dueDate = block.timestamp + 1 days;

        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);

        vm.warp(dueDate);

        assertFalse(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsFalse_WhenCalculatedAdvanceRoundsToZero() public {
        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.advanceRate = 1;
        params.minInvoiceAmount = 1;

        vm.prank(admin);
        riskManager.setRiskParams(params);

        uint256 invoiceId = _createVerifiedInvoice(1, block.timestamp + INVOICE_TENOR);

        assertEq(riskManager.calculateAdvance(1), 0);
        assertFalse(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ReturnsFalse_WhenBuyerIsDenied() public {
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(admin);
        riskManager.setBuyerDenied(buyer, true);

        assertFalse(riskManager.isEligible(invoiceId));
    }

    function test_IsEligible_ExcludesPortfolioConcentration() public {
        uint256 invoiceId = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        uint256 advance = riskManager.calculateAdvance(FACE_VALUE);

        IRWARiskManager.RiskParams memory params = _defaultRiskParams();

        params.maxExposurePerBuyer = advance;

        vm.prank(admin);
        riskManager.setRiskParams(params);

        vm.prank(pool);
        riskManager.updateBuyerExposure(buyer, advance, true);

        assertTrue(riskManager.isEligible(invoiceId));
        assertFalse(riskManager.checkConcentration(buyer, advance));
    }

    function test_SetBuyerDenied_Reverts_WhenCallerLacksRiskAdminRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorizedCaller,
                riskManager.RISK_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorizedCaller);
        riskManager.setBuyerDenied(buyer, true);
    }

    function test_SetBuyerDenied_Reverts_WhenBuyerIsZeroAddress() public {
        vm.expectRevert(RWARiskManager.ZeroAddress.selector);
        vm.prank(admin);
        riskManager.setBuyerDenied(address(0), true);
    }

    function test_SetBuyerDenied_UpdatesDenylistState() public {
        vm.prank(admin);
        riskManager.setBuyerDenied(buyer, true);

        assertTrue(riskManager.isBuyerDenied(buyer));

        vm.prank(admin);
        riskManager.setBuyerDenied(buyer, false);

        assertFalse(riskManager.isBuyerDenied(buyer));
    }

    function test_CheckConcentration_ReturnsTrue_WhenExposureEqualsMaximum() public {
        uint256 existingExposure = 600_000e18;
        uint256 newAmount = MAX_EXPOSURE - existingExposure;

        vm.prank(pool);
        riskManager.updateBuyerExposure(buyer, existingExposure, true);

        assertTrue(riskManager.checkConcentration(buyer, newAmount));
    }

    function test_CheckConcentration_ReturnsFalse_WhenExposureExceedsMaximumByOne() public {
        uint256 existingExposure = 600_000e18;
        uint256 newAmount = MAX_EXPOSURE - existingExposure + 1;

        vm.prank(pool);
        riskManager.updateBuyerExposure(buyer, existingExposure, true);

        assertFalse(riskManager.checkConcentration(buyer, newAmount));
    }

    function test_UpdateBuyerExposure_IncreasesExposure() public {
        uint256 delta = 80_000e18;

        vm.prank(pool);
        riskManager.updateBuyerExposure(buyer, delta, true);

        assertEq(riskManager.getBuyerExposure(buyer), delta);
    }

    function test_UpdateBuyerExposure_AccumulatesMultipleIncreases() public {
        uint256 firstDelta = 80_000e18;
        uint256 secondDelta = 20_000e18;

        vm.startPrank(pool);
        riskManager.updateBuyerExposure(buyer, firstDelta, true);
        riskManager.updateBuyerExposure(buyer, secondDelta, true);
        vm.stopPrank();

        assertEq(riskManager.getBuyerExposure(buyer), firstDelta + secondDelta);
    }

    function test_UpdateBuyerExposure_DecreasesExposure() public {
        uint256 initialExposure = 80_000e18;
        uint256 decrease = 30_000e18;

        vm.startPrank(pool);
        riskManager.updateBuyerExposure(buyer, initialExposure, true);
        riskManager.updateBuyerExposure(buyer, decrease, false);
        vm.stopPrank();

        assertEq(riskManager.getBuyerExposure(buyer), initialExposure - decrease);
    }

    function test_UpdateBuyerExposure_CanDecreaseExposureToZero() public {
        uint256 exposure = 80_000e18;

        vm.startPrank(pool);
        riskManager.updateBuyerExposure(buyer, exposure, true);
        riskManager.updateBuyerExposure(buyer, exposure, false);
        vm.stopPrank();

        assertEq(riskManager.getBuyerExposure(buyer), 0);
    }

    function test_UpdateBuyerExposure_Reverts_OnExposureUnderflow() public {
        uint256 existingExposure = 50_000e18;
        uint256 excessiveDecrease = existingExposure + 1;

        vm.prank(pool);
        riskManager.updateBuyerExposure(buyer, existingExposure, true);

        vm.expectRevert(RWARiskManager.ExposureUnderflow.selector);
        vm.prank(pool);
        riskManager.updateBuyerExposure(buyer, excessiveDecrease, false);

        assertEq(riskManager.getBuyerExposure(buyer), existingExposure);
    }

    function test_UpdateBuyerExposure_Reverts_WhenBuyerIsZeroAddress() public {
        vm.expectRevert(RWARiskManager.ZeroAddress.selector);
        vm.prank(pool);
        riskManager.updateBuyerExposure(address(0), 1, true);
    }

    function test_UpdateBuyerExposure_Reverts_WhenCallerLacksPoolRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedCaller, riskManager.POOL_ROLE()
            )
        );
        vm.prank(unauthorizedCaller);
        riskManager.updateBuyerExposure(buyer, 80_000e18, true);
    }
}

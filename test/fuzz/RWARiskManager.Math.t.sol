// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {InvoiceNFT} from "../../src/core/InvoiceNFT.sol";
import {RWARiskManager} from "../../src/risk/RWARiskManager.sol";
import {IRWARiskManager} from "../../src/interfaces/IRWARiskManager.sol";

contract RWARiskManagerMathFuzzTest is Test {
    InvoiceNFT internal invoiceNft;
    RWARiskManager internal riskManager;

    address internal admin = makeAddr("admin");
    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant BPS = 10_000;

    uint256 internal constant MAX_EXPOSURE = 1_000_000e18;
    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant MAX_TENOR = 90 days;
    uint256 internal constant MIN_INVOICE_AMOUNT = 1_000e18;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;

    uint256 internal constant MAX_FACE_VALUE = 100_000_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);

        invoiceNft = new InvoiceNFT(admin);
        riskManager = new RWARiskManager(admin, invoiceNft, _defaultRiskParams());

        vm.startPrank(admin);
        invoiceNft.grantRole(invoiceNft.ORIGINATOR_ROLE(), originator);
        invoiceNft.grantRole(invoiceNft.VERIFIER_ROLE(), verifier);
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

    function _createVerifiedInvoice(uint256 faceValue, uint256 dueDate) internal returns (uint256 invoiceId) {
        vm.prank(originator);
        invoiceId = invoiceNft.createInvoice(supplier, buyer, faceValue, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);
    }

    function testFuzz_CalculateAdvance_EqualsFormulaAndNeverExceedsFaceValue(uint256 faceValue) public view {
        faceValue = bound(faceValue, 0, MAX_FACE_VALUE);

        uint256 advance = riskManager.calculateAdvance(faceValue);
        uint256 expectedAdvance = faceValue * ADVANCE_RATE_BPS / BPS;

        assertEq(advance, expectedAdvance);
        assertLe(advance, faceValue);
    }

    function testFuzz_CalculateAdvance_MonotonicInFaceValue(uint256 smallerFaceValue, uint256 largerFaceValue)
        public
        view
    {
        smallerFaceValue = bound(smallerFaceValue, 0, MAX_FACE_VALUE);
        largerFaceValue = bound(largerFaceValue, smallerFaceValue, MAX_FACE_VALUE);

        uint256 smallerAdvance = riskManager.calculateAdvance(smallerFaceValue);
        uint256 largerAdvance = riskManager.calculateAdvance(largerFaceValue);

        assertLe(smallerAdvance, largerAdvance);
    }

    function testFuzz_CalculateAdvance_MonotonicInAdvanceRate(
        uint256 faceValue,
        uint256 smallerAdvanceRate,
        uint256 largerAdvanceRate
    ) public {
        faceValue = bound(faceValue, 1, MAX_FACE_VALUE);

        smallerAdvanceRate = bound(smallerAdvanceRate, 1, riskManager.MAX_ADVANCE_RATE_BPS());
        largerAdvanceRate = bound(largerAdvanceRate, smallerAdvanceRate, riskManager.MAX_ADVANCE_RATE_BPS());

        IRWARiskManager.RiskParams memory smallerParams = _defaultRiskParams();
        smallerParams.advanceRate = smallerAdvanceRate;

        vm.prank(admin);
        riskManager.setRiskParams(smallerParams);

        uint256 smallerAdvance = riskManager.calculateAdvance(faceValue);

        IRWARiskManager.RiskParams memory largerParams = _defaultRiskParams();
        largerParams.advanceRate = largerAdvanceRate;

        vm.prank(admin);
        riskManager.setRiskParams(largerParams);

        uint256 largerAdvance = riskManager.calculateAdvance(faceValue);

        assertLe(smallerAdvance, largerAdvance);
    }

    function testFuzz_CalculateAdvance_DoesNotRevert_ForFullUint256Range(uint256 faceValue) public view {
        uint256 advance = riskManager.calculateAdvance(faceValue);

        assertLe(advance, faceValue);
    }

    function testFuzz_IsEligible_DoesNotRevert_ForExtremeVerifiedFaceValue(uint256 faceValue) public {
        faceValue = bound(faceValue, MIN_INVOICE_AMOUNT, type(uint256).max);

        uint256 invoiceId = _createVerifiedInvoice(faceValue, block.timestamp + MAX_TENOR);

        bool eligible = riskManager.isEligible(invoiceId);

        assertTrue(eligible);
    }

    function testFuzz_CalculateFee_EqualsLinearAprFormula(uint256 principal, uint256 duration) public view {
        principal = bound(principal, 0, MAX_FACE_VALUE);
        duration = bound(duration, 0, MAX_TENOR);

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + duration;

        uint256 fee = riskManager.calculateFee(principal, fundedAt, dueDate);

        uint256 expectedFee = principal * FINANCING_FEE_APR_BPS * duration / (365 days * BPS);

        assertEq(fee, expectedFee);
    }

    function testFuzz_CalculateFee_ReturnsZero_WhenPrincipalIsZero(uint256 duration) public view {
        duration = bound(duration, 0, MAX_TENOR);

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + duration;

        uint256 fee = riskManager.calculateFee(0, fundedAt, dueDate);

        assertEq(fee, 0);
    }

    function testFuzz_CalculateFee_ReturnsZero_WhenDueDateIsNotAfterFundedAt(uint256 principal, uint256 timeDelta)
        public
        view
    {
        principal = bound(principal, 0, MAX_FACE_VALUE);
        timeDelta = bound(timeDelta, 0, MAX_TENOR);

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt - timeDelta;

        uint256 fee = riskManager.calculateFee(principal, fundedAt, dueDate);

        assertEq(fee, 0);
    }

    function testFuzz_CalculateFee_ReturnsZero_WhenAprIsZero(uint256 principal, uint256 duration) public {
        principal = bound(principal, 1, MAX_FACE_VALUE);
        duration = bound(duration, 1, MAX_TENOR);

        IRWARiskManager.RiskParams memory params = _defaultRiskParams();
        params.financingFeeApr = 0;

        vm.prank(admin);
        riskManager.setRiskParams(params);

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + duration;

        uint256 fee = riskManager.calculateFee(principal, fundedAt, dueDate);

        assertEq(fee, 0);
    }

    function testFuzz_CalculateFee_MonotonicInPrincipal(
        uint256 smallerPrincipal,
        uint256 largerPrincipal,
        uint256 duration
    ) public view {
        smallerPrincipal = bound(smallerPrincipal, 0, MAX_FACE_VALUE);
        largerPrincipal = bound(largerPrincipal, smallerPrincipal, MAX_FACE_VALUE);
        duration = bound(duration, 1, MAX_TENOR);

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + duration;

        uint256 smallerFee = riskManager.calculateFee(smallerPrincipal, fundedAt, dueDate);
        uint256 largerFee = riskManager.calculateFee(largerPrincipal, fundedAt, dueDate);

        assertLe(smallerFee, largerFee);
    }

    function testFuzz_CalculateFee_MonotonicInApr(
        uint256 principal,
        uint256 duration,
        uint256 smallerApr,
        uint256 largerApr
    ) public {
        principal = bound(principal, 1, MAX_FACE_VALUE);
        duration = bound(duration, 1, MAX_TENOR);

        smallerApr = bound(smallerApr, 0, riskManager.MAX_FINANCING_FEE_APR_BPS());
        largerApr = bound(largerApr, smallerApr, riskManager.MAX_FINANCING_FEE_APR_BPS());

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + duration;

        IRWARiskManager.RiskParams memory smallerParams = _defaultRiskParams();
        smallerParams.financingFeeApr = smallerApr;

        vm.prank(admin);
        riskManager.setRiskParams(smallerParams);

        uint256 smallerFee = riskManager.calculateFee(principal, fundedAt, dueDate);

        IRWARiskManager.RiskParams memory largerParams = _defaultRiskParams();
        largerParams.financingFeeApr = largerApr;

        vm.prank(admin);
        riskManager.setRiskParams(largerParams);

        uint256 largerFee = riskManager.calculateFee(principal, fundedAt, dueDate);

        assertLe(smallerFee, largerFee);
    }

    function testFuzz_CalculateFee_MonotonicInDuration(
        uint256 principal,
        uint256 smallerDuration,
        uint256 largerDuration
    ) public view {
        principal = bound(principal, 1, MAX_FACE_VALUE);

        smallerDuration = bound(smallerDuration, 0, MAX_TENOR);
        largerDuration = bound(largerDuration, smallerDuration, MAX_TENOR);

        uint256 fundedAt = block.timestamp;

        uint256 smallerFee = riskManager.calculateFee(principal, fundedAt, fundedAt + smallerDuration);
        uint256 largerFee = riskManager.calculateFee(principal, fundedAt, fundedAt + largerDuration);

        assertLe(smallerFee, largerFee);
    }

    function testFuzz_CalculateFee_DoesNotRevert_ForFullUint256PrincipalRange(uint256 principal, uint256 duration)
        public
        view
    {
        duration = bound(duration, 1, MAX_TENOR);

        uint256 fundedAt = block.timestamp;
        uint256 dueDate = fundedAt + duration;

        uint256 fee = riskManager.calculateFee(principal, fundedAt, dueDate);

        assertLe(fee, principal);
    }
}

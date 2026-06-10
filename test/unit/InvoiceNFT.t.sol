// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {InvoiceNFT} from "../../src/core/InvoiceNFT.sol";
import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";

contract InvoiceNFTTest is Test {
    InvoiceNFT internal invoiceNft;

    address internal admin = makeAddr("admin");
    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal riskAdmin = makeAddr("riskAdmin");
    address internal pool = makeAddr("pool");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant FACE_VALUE = 100_000e18;
    uint256 internal constant INVOICE_TENOR = 30 days;

    function setUp() public {
        vm.warp(1_700_000_000);

        invoiceNft = new InvoiceNFT(admin);

        vm.startPrank(admin);
        invoiceNft.grantRole(invoiceNft.ORIGINATOR_ROLE(), originator);
        invoiceNft.grantRole(invoiceNft.VERIFIER_ROLE(), verifier);
        invoiceNft.grantRole(invoiceNft.RISK_ROLE(), riskAdmin);
        invoiceNft.grantRole(invoiceNft.POOL_ROLE(), pool);
        vm.stopPrank();
    }

    function test_Constructor_Reverts_WhenAdminIsZeroAddress() public {
        vm.expectRevert(IInvoiceNFT.ZeroAddress.selector);

        new InvoiceNFT(address(0));
    }

    function test_Constructor_GrantsDefaultAdminRoleToAdmin() public view {
        assertTrue(invoiceNft.hasRole(invoiceNft.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_DoesNotGrantOperationalRolesToAdmin() public view {
        assertFalse(invoiceNft.hasRole(invoiceNft.ORIGINATOR_ROLE(), admin));
        assertFalse(invoiceNft.hasRole(invoiceNft.VERIFIER_ROLE(), admin));
        assertFalse(invoiceNft.hasRole(invoiceNft.RISK_ROLE(), admin));
        assertFalse(invoiceNft.hasRole(invoiceNft.POOL_ROLE(), admin));
    }

    function test_CreateInvoice_MintsFirstInvoiceToSupplier() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        assertEq(invoiceId, 1);
        assertEq(invoiceNft.ownerOf(invoiceId), supplier);
    }

    function test_CreateInvoice_StoresInvoiceDataInCreatedState() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(invoice.supplier, supplier);
        assertEq(invoice.buyer, buyer);
        assertEq(invoice.faceValue, FACE_VALUE);
        assertEq(invoice.dueDate, dueDate);
        assertEq(invoice.fundedAt, 0);
        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
        assertEq(uint256(invoice.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
    }

    function test_CreateInvoice_IncrementsInvoiceId() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.startPrank(originator);
        uint256 firstInvoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);
        uint256 secondInvoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);
        vm.stopPrank();

        assertEq(firstInvoiceId, 1);
        assertEq(secondInvoiceId, 2);
        assertEq(invoiceNft.ownerOf(firstInvoiceId), supplier);
        assertEq(invoiceNft.ownerOf(secondInvoiceId), supplier);
    }

    function test_CreateInvoice_Reverts_WhenCallerLacksOriginatorRole() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        address unauthorizedCaller = makeAddr("unauthorizedCaller");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorizedCaller,
                invoiceNft.ORIGINATOR_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);
    }

    function test_CreateInvoice_Reverts_WhenSupplierIsZeroAddress() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.expectRevert(IInvoiceNFT.ZeroAddress.selector);
        vm.prank(originator);
        invoiceNft.createInvoice(address(0), buyer, FACE_VALUE, dueDate);
    }

    function test_CreateInvoice_Reverts_WhenBuyerIsZeroAddress() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.expectRevert(IInvoiceNFT.ZeroAddress.selector);
        vm.prank(originator);
        invoiceNft.createInvoice(supplier, address(0), FACE_VALUE, dueDate);
    }

    function test_CreateInvoice_Reverts_WhenFaceValueIsZero() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.expectRevert(IInvoiceNFT.InvalidFaceValue.selector);
        vm.prank(originator);
        invoiceNft.createInvoice(supplier, buyer, 0, dueDate);
    }

    function test_CreateInvoice_Reverts_WhenDueDateEqualsCurrentTimestamp() public {
        vm.expectRevert(IInvoiceNFT.InvalidDueDate.selector);
        vm.prank(originator);
        invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp);
    }

    function test_CreateInvoice_Reverts_WhenDueDateIsInThePast() public {
        vm.expectRevert(IInvoiceNFT.InvalidDueDate.selector);
        vm.prank(originator);
        invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp - 1);
    }

    function test_Verify_TransitionsInvoiceFromCreatedToVerified() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function test_Verify_Reverts_WhenCallerLacksVerifierRole() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        address unauthorizedCaller = makeAddr("unauthorizedVerifier");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedCaller, invoiceNft.VERIFIER_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        invoiceNft.verify(invoiceId);
    }

    function test_Verify_Reverts_WhenInvoiceIsNotCreated() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.VERIFIED,
                IInvoiceNFT.InvoiceStatus.CREATED
            )
        );

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);
    }

    function test_Verify_Reverts_WhenInvoiceDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceDoesNotExist.selector, nonexistentInvoiceId));

        vm.prank(verifier);
        invoiceNft.verify(nonexistentInvoiceId);
    }

    function test_MarkFunded_TransitionsVerifiedInvoiceToFundedAndStoresTimestamp() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        uint256 expectedFundedAt = block.timestamp;

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertEq(invoice.fundedAt, expectedFundedAt);
    }

    function test_MarkFunded_Reverts_WhenCallerLacksPoolRole() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        address unauthorizedCaller = makeAddr("unauthorizedPool");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedCaller, invoiceNft.POOL_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        invoiceNft.markFunded(invoiceId);
    }

    function test_MarkFunded_Reverts_WhenInvoiceIsNotVerified() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.CREATED,
                IInvoiceNFT.InvoiceStatus.VERIFIED
            )
        );

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);
    }

    function test_MarkFunded_Reverts_WhenInvoiceIsAlreadyFunded() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.FUNDED,
                IInvoiceNFT.InvoiceStatus.VERIFIED
            )
        );

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);
    }

    function test_MarkFunded_Reverts_WhenInvoiceDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceDoesNotExist.selector, nonexistentInvoiceId));
        vm.prank(pool);
        invoiceNft.markFunded(nonexistentInvoiceId);
    }

    function test_MarkSettled_TransitionsFundedInvoiceToSettled() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markSettled(invoiceId);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
    }

    function test_MarkSettled_Reverts_WhenCallerLacksPoolRole() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        address unauthorizedCaller = makeAddr("unauthorizedSettler");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedCaller, invoiceNft.POOL_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        invoiceNft.markSettled(invoiceId);
    }

    function test_MarkSettled_Reverts_WhenInvoiceIsNotFunded() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.VERIFIED,
                IInvoiceNFT.InvoiceStatus.FUNDED
            )
        );

        vm.prank(pool);
        invoiceNft.markSettled(invoiceId);
    }

    function test_MarkSettled_Reverts_WhenInvoiceIsAlreadySettled() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markSettled(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.SETTLED,
                IInvoiceNFT.InvoiceStatus.FUNDED
            )
        );

        vm.prank(pool);
        invoiceNft.markSettled(invoiceId);
    }

    function test_MarkDefaulted_Reverts_WhenInvoiceIsAlreadySettled() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markSettled(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.SETTLED,
                IInvoiceNFT.InvoiceStatus.FUNDED
            )
        );

        vm.prank(pool);
        invoiceNft.markDefaulted(invoiceId);
    }

    function test_MarkDefaulted_TransitionsFundedInvoiceToDefaulted() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markDefaulted(invoiceId);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
    }

    function test_MarkDefaulted_Reverts_WhenCallerLacksPoolRole() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        address unauthorizedCaller = makeAddr("unauthorizedDefaulter");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedCaller, invoiceNft.POOL_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        invoiceNft.markDefaulted(invoiceId);
    }

    function test_MarkDefaulted_Reverts_WhenInvoiceIsNotFunded() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.VERIFIED,
                IInvoiceNFT.InvoiceStatus.FUNDED
            )
        );

        vm.prank(pool);
        invoiceNft.markDefaulted(invoiceId);
    }

    function test_MarkSettled_Reverts_WhenInvoiceIsAlreadyDefaulted() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markDefaulted(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.DEFAULTED,
                IInvoiceNFT.InvoiceStatus.FUNDED
            )
        );

        vm.prank(pool);
        invoiceNft.markSettled(invoiceId);
    }

    function test_MarkDefaulted_Reverts_WhenInvoiceIsAlreadyDefaulted() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markDefaulted(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidStatus.selector,
                invoiceId,
                IInvoiceNFT.InvoiceStatus.DEFAULTED,
                IInvoiceNFT.InvoiceStatus.FUNDED
            )
        );

        vm.prank(pool);
        invoiceNft.markDefaulted(invoiceId);
    }

    function test_MarkDefaulted_Reverts_WhenInvoiceDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceDoesNotExist.selector, nonexistentInvoiceId));

        vm.prank(pool);
        invoiceNft.markDefaulted(nonexistentInvoiceId);
    }

    function test_MarkSettled_Reverts_WhenInvoiceDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceDoesNotExist.selector, nonexistentInvoiceId));

        vm.prank(pool);
        invoiceNft.markSettled(nonexistentInvoiceId);
    }

    function test_FreezeInvoice_FreezesVerifiedInvoiceAndStoresPreviousStatus() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.FROZEN));
        assertEq(uint256(invoice.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function test_FreezeInvoice_FreezesFundedInvoiceAndPreservesInvoiceData() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        IInvoiceNFT.Invoice memory beforeFreeze = invoiceNft.getInvoice(invoiceId);

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);

        IInvoiceNFT.Invoice memory afterFreeze = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(afterFreeze.status), uint256(IInvoiceNFT.InvoiceStatus.FROZEN));
        assertEq(uint256(afterFreeze.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));

        assertEq(afterFreeze.supplier, beforeFreeze.supplier);
        assertEq(afterFreeze.buyer, beforeFreeze.buyer);
        assertEq(afterFreeze.faceValue, beforeFreeze.faceValue);
        assertEq(afterFreeze.dueDate, beforeFreeze.dueDate);
        assertEq(afterFreeze.fundedAt, beforeFreeze.fundedAt);
    }

    function test_FreezeInvoice_Reverts_WhenCallerLacksRiskRole() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        address unauthorizedCaller = makeAddr("unauthorizedRiskCaller");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedCaller, invoiceNft.RISK_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        invoiceNft.freezeInvoice(invoiceId);
    }

    function test_FreezeInvoice_Reverts_WhenInvoiceIsCreated() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidFreezeStatus.selector, invoiceId, IInvoiceNFT.InvoiceStatus.CREATED
            )
        );

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);
    }

    function test_FreezeInvoice_Reverts_WhenInvoiceIsSettled() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markSettled(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidFreezeStatus.selector, invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED
            )
        );

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);
    }

    function test_FreezeInvoice_Reverts_WhenInvoiceIsDefaulted() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        vm.prank(pool);
        invoiceNft.markDefaulted(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidFreezeStatus.selector, invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED
            )
        );

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);
    }

    function test_FreezeInvoice_Reverts_WhenInvoiceIsAlreadyFrozen() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceNFT.InvalidFreezeStatus.selector, invoiceId, IInvoiceNFT.InvoiceStatus.FROZEN
            )
        );

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);
    }

    function test_FreezeInvoice_Reverts_WhenInvoiceDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceDoesNotExist.selector, nonexistentInvoiceId));

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(nonexistentInvoiceId);
    }

    function test_UnfreezeInvoice_RestoresVerifiedStatus() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);

        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(invoiceId);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
        assertEq(uint256(invoice.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.VERIFIED));
    }

    function test_UnfreezeInvoice_RestoresFundedStatusAndPreservesFundedAt() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(pool);
        invoiceNft.markFunded(invoiceId);

        uint256 fundedAtBeforeFreeze = invoiceNft.getInvoice(invoiceId).fundedAt;

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);

        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(invoiceId);

        IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

        assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertEq(uint256(invoice.previousStatus), uint256(IInvoiceNFT.InvoiceStatus.FUNDED));
        assertEq(invoice.fundedAt, fundedAtBeforeFreeze);
    }

    function test_UnfreezeInvoice_Reverts_WhenCallerLacksRiskRole() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.prank(riskAdmin);
        invoiceNft.freezeInvoice(invoiceId);

        address unauthorizedCaller = makeAddr("unauthorizedUnfreezer");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedCaller, invoiceNft.RISK_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        invoiceNft.unfreezeInvoice(invoiceId);
    }

    function test_UnfreezeInvoice_Reverts_WhenInvoiceIsNotFrozen() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceNotFrozen.selector, invoiceId));

        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(invoiceId);
    }

    function test_UnfreezeInvoice_Reverts_WhenInvoiceDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceDoesNotExist.selector, nonexistentInvoiceId));

        vm.prank(riskAdmin);
        invoiceNft.unfreezeInvoice(nonexistentInvoiceId);
    }

    function test_TransferFrom_RevertsBecauseTransfersAreDisabled() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        address receiver = makeAddr("receiver");

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        vm.prank(supplier);
        invoiceNft.transferFrom(supplier, receiver, invoiceId);
    }

    function test_SafeTransferFrom_RevertsBecauseTransfersAreDisabled() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        address receiver = makeAddr("receiver");

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        vm.prank(supplier);
        invoiceNft.safeTransferFrom(supplier, receiver, invoiceId);
    }

    function test_Approve_RevertsBecauseApprovalsAreDisabled() public {
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        address approved = makeAddr("approved");

        vm.prank(originator);
        uint256 invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, dueDate);

        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        vm.prank(supplier);
        invoiceNft.approve(approved, invoiceId);
    }

    function test_SetApprovalForAll_RevertsBecauseApprovalsAreDisabled() public {
        address operator = makeAddr("operator");

        vm.expectRevert(IInvoiceNFT.TransfersDisabled.selector);
        vm.prank(supplier);
        invoiceNft.setApprovalForAll(operator, true);
    }

    function test_GetInvoice_Reverts_WhenInvoiceDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(abi.encodeWithSelector(IInvoiceNFT.InvoiceDoesNotExist.selector, nonexistentInvoiceId));
        invoiceNft.getInvoice(nonexistentInvoiceId);
    }
}

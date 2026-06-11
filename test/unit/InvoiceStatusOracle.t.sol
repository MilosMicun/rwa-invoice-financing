// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {InvoiceNFT} from "../../src/core/InvoiceNFT.sol";
import {InvoiceStatusOracle} from "../../src/oracle/InvoiceStatusOracle.sol";
import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";
import {IInvoiceFinancingPool} from "../../src/interfaces/IInvoiceFinancingPool.sol";
import {IInvoiceStatusOracle} from "../../src/interfaces/IInvoiceStatusOracle.sol";
import {MockInvoiceFinancingPool} from "../mocks/MockInvoiceFinancingPool.sol";

contract InvoiceStatusOracleTest is Test {
    InvoiceNFT internal invoiceNft;
    InvoiceStatusOracle internal oracle;
    MockInvoiceFinancingPool internal mockPool;

    address internal admin = makeAddr("admin");
    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal poolOperator = makeAddr("poolOperator");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");
    address internal finalizer = makeAddr("finalizer");
    address internal unauthorizedCaller = makeAddr("unauthorizedCaller");

    uint256 internal constant FACE_VALUE = 100_000e18;
    uint256 internal constant DEFAULT_RECOVERY = 40_000e18;
    uint256 internal constant UPDATED_RECOVERY = 20_000e18;
    uint256 internal constant INVOICE_TENOR = 30 days;
    uint256 internal constant DISPUTE_WINDOW = 1 days;
    uint256 internal constant MAX_STALENESS = 7 days;

    function setUp() public {
        vm.warp(1_700_000_000);

        invoiceNft = new InvoiceNFT(admin);
        mockPool = new MockInvoiceFinancingPool();

        oracle = new InvoiceStatusOracle(
            admin, invoiceNft, IInvoiceFinancingPool(address(mockPool)), DISPUTE_WINDOW, MAX_STALENESS
        );

        vm.startPrank(admin);
        invoiceNft.grantRole(invoiceNft.ORIGINATOR_ROLE(), originator);
        invoiceNft.grantRole(invoiceNft.VERIFIER_ROLE(), verifier);
        invoiceNft.grantRole(invoiceNft.POOL_ROLE(), poolOperator);
        vm.stopPrank();
    }

    function _createInvoice() internal returns (uint256 invoiceId) {
        vm.prank(originator);
        invoiceId = invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);
    }

    function _createVerifiedInvoice() internal returns (uint256 invoiceId) {
        invoiceId = _createInvoice();

        vm.prank(verifier);
        invoiceNft.verify(invoiceId);
    }

    function _createFundedInvoice() internal returns (uint256 invoiceId) {
        invoiceId = _createVerifiedInvoice();

        vm.prank(poolOperator);
        invoiceNft.markFunded(invoiceId);
    }

    function _submitStatus(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status, uint256 recoveredAmount) internal {
        vm.prank(admin);
        oracle.submitStatus(invoiceId, status, recoveredAmount);
    }

    function test_Constructor_Reverts_WhenAdminIsZeroAddress() public {
        vm.expectRevert(IInvoiceStatusOracle.ZeroAddress.selector);

        new InvoiceStatusOracle(
            address(0), invoiceNft, IInvoiceFinancingPool(address(mockPool)), DISPUTE_WINDOW, MAX_STALENESS
        );
    }

    function test_Constructor_Reverts_WhenInvoiceNFTIsZeroAddress() public {
        vm.expectRevert(IInvoiceStatusOracle.ZeroAddress.selector);

        new InvoiceStatusOracle(
            admin, IInvoiceNFT(address(0)), IInvoiceFinancingPool(address(mockPool)), DISPUTE_WINDOW, MAX_STALENESS
        );
    }

    function test_Constructor_Reverts_WhenPoolIsZeroAddress() public {
        vm.expectRevert(IInvoiceStatusOracle.ZeroAddress.selector);

        new InvoiceStatusOracle(admin, invoiceNft, IInvoiceFinancingPool(address(0)), DISPUTE_WINDOW, MAX_STALENESS);
    }

    function test_Constructor_Reverts_WhenDisputeWindowIsZero() public {
        vm.expectRevert(IInvoiceStatusOracle.InvalidDisputeWindow.selector);

        new InvoiceStatusOracle(admin, invoiceNft, IInvoiceFinancingPool(address(mockPool)), 0, MAX_STALENESS);
    }

    function test_Constructor_Reverts_WhenMaxStalenessEqualsDisputeWindow() public {
        vm.expectRevert(IInvoiceStatusOracle.InvalidMaxStaleness.selector);

        new InvoiceStatusOracle(
            admin, invoiceNft, IInvoiceFinancingPool(address(mockPool)), DISPUTE_WINDOW, DISPUTE_WINDOW
        );
    }

    function test_Constructor_Reverts_WhenMaxStalenessIsBelowDisputeWindow() public {
        vm.expectRevert(IInvoiceStatusOracle.InvalidMaxStaleness.selector);

        new InvoiceStatusOracle(
            admin, invoiceNft, IInvoiceFinancingPool(address(mockPool)), DISPUTE_WINDOW, DISPUTE_WINDOW - 1
        );
    }

    function test_Constructor_StoresDependenciesAndTimingConfiguration() public view {
        assertEq(address(oracle.INVOICE_NFT()), address(invoiceNft));
        assertEq(address(oracle.POOL()), address(mockPool));
        assertEq(oracle.disputeWindow(), DISPUTE_WINDOW);
        assertEq(oracle.maxStaleness(), MAX_STALENESS);
    }

    function test_Constructor_GrantsAdminOperationalRoles() public view {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.ORACLE_SUBMITTER_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.DISPUTE_ADMIN_ROLE(), admin));
    }

    function test_SubmitStatus_Reverts_WhenCallerLacksSubmitterRole() public {
        uint256 invoiceId = _createFundedInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorizedCaller,
                oracle.ORACLE_SUBMITTER_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
    }

    function test_SubmitStatus_Reverts_WhenStatusIsCreated() public {
        uint256 invoiceId = _createFundedInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.CREATED)
        );

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.CREATED, 0);
    }

    function test_SubmitStatus_Reverts_WhenStatusIsVerified() public {
        uint256 invoiceId = _createFundedInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceStatusOracle.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.VERIFIED
            )
        );

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.VERIFIED, 0);
    }

    function test_SubmitStatus_Reverts_WhenStatusIsFunded() public {
        uint256 invoiceId = _createFundedInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.FUNDED)
        );

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.FUNDED, 0);
    }

    function test_SubmitStatus_Reverts_WhenStatusIsFrozen() public {
        uint256 invoiceId = _createFundedInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.InvalidOracleStatus.selector, IInvoiceNFT.InvoiceStatus.FROZEN)
        );

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.FROZEN, 0);
    }

    function test_SubmitStatus_Reverts_WhenSettledRecoveryIsNonZero() public {
        uint256 invoiceId = _createFundedInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceStatusOracle.InvalidRecoveryForStatus.selector,
                IInvoiceNFT.InvoiceStatus.SETTLED,
                DEFAULT_RECOVERY
            )
        );

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertEq(update.recoveredAmount, 0);
        assertEq(update.submittedAt, 0);
        assertFalse(update.disputed);
        assertFalse(update.finalized);
    }

    function test_SubmitStatus_Reverts_WhenInvoiceIsNotFunded() public {
        uint256 invoiceId = _createVerifiedInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceStatusOracle.InvoiceNotFunded.selector, invoiceId, IInvoiceNFT.InvoiceStatus.VERIFIED
            )
        );

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
    }

    function test_SubmitStatus_StoresSettledUpdateWithZeroRecovery() public {
        uint256 invoiceId = _createFundedInvoice();
        uint256 submittedAt = block.timestamp;

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertEq(update.invoiceId, invoiceId);
        assertEq(uint256(update.newStatus), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(update.recoveredAmount, 0);
        assertEq(update.submittedAt, submittedAt);
        assertFalse(update.disputed);
        assertFalse(update.finalized);
    }

    function test_SubmitStatus_StoresDefaultedUpdateAndRecoveryAmount() public {
        uint256 invoiceId = _createFundedInvoice();
        uint256 submittedAt = block.timestamp;

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertEq(update.invoiceId, invoiceId);
        assertEq(uint256(update.newStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(update.recoveredAmount, DEFAULT_RECOVERY);
        assertEq(update.submittedAt, submittedAt);
        assertFalse(update.disputed);
        assertFalse(update.finalized);
    }

    function test_SubmitStatus_AllowsZeroRecoveryForDefault() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertEq(uint256(update.newStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(update.recoveredAmount, 0);
        assertFalse(update.disputed);
        assertFalse(update.finalized);
    }

    function test_SubmitStatus_Reverts_WhenActiveUpdateAlreadyExists() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyActive.selector, invoiceId));

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertEq(uint256(update.newStatus), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(update.recoveredAmount, 0);
    }

    function test_SubmitStatus_AllowsResubmissionAfterDisputeAndReplacesRecoveryAmount() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, UPDATED_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertEq(update.invoiceId, invoiceId);
        assertEq(uint256(update.newStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(update.recoveredAmount, UPDATED_RECOVERY);
        assertFalse(update.disputed);
        assertFalse(update.finalized);
    }

    function test_SubmitStatus_AllowsResubmissionAfterStalenessAndReplacesRecoveryAmount() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory firstUpdate = oracle.getStatusUpdate(invoiceId);

        vm.warp(firstUpdate.submittedAt + MAX_STALENESS + 1);

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, UPDATED_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory secondUpdate = oracle.getStatusUpdate(invoiceId);

        assertEq(secondUpdate.invoiceId, invoiceId);
        assertEq(uint256(secondUpdate.newStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(secondUpdate.recoveredAmount, UPDATED_RECOVERY);
        assertEq(secondUpdate.submittedAt, block.timestamp);
        assertFalse(secondUpdate.disputed);
        assertFalse(secondUpdate.finalized);
    }

    function test_DisputeStatus_Reverts_WhenCallerLacksDisputeAdminRole() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorizedCaller,
                oracle.DISPUTE_ADMIN_ROLE()
            )
        );

        vm.prank(unauthorizedCaller);
        oracle.disputeStatus(invoiceId);
    }

    function test_DisputeStatus_Reverts_WhenUpdateDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateDoesNotExist.selector, nonexistentInvoiceId)
        );

        vm.prank(admin);
        oracle.disputeStatus(nonexistentInvoiceId);
    }

    function test_DisputeStatus_MarksUpdateAsDisputedAndPreservesRecovery() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        assertEq(update.recoveredAmount, DEFAULT_RECOVERY);
        assertTrue(update.disputed);
        assertFalse(update.finalized);
    }

    function test_DisputeStatus_AllowsDisputeAtExactWindowBoundary() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);

        update = oracle.getStatusUpdate(invoiceId);

        assertTrue(update.disputed);
    }

    function test_DisputeStatus_Reverts_AfterDisputeWindowElapsed() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.DisputeWindowElapsed.selector, invoiceId));

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);
    }

    function test_DisputeStatus_Reverts_WhenUpdateAlreadyDisputed() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateDisputed.selector, invoiceId));

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);
    }

    function test_Finalize_Reverts_WhenUpdateDoesNotExist() public {
        uint256 nonexistentInvoiceId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateDoesNotExist.selector, nonexistentInvoiceId)
        );

        oracle.finalize(nonexistentInvoiceId);
    }

    function test_Finalize_Reverts_WhenUpdateIsDisputed() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateDisputed.selector, invoiceId));

        oracle.finalize(invoiceId);
    }

    function test_Finalize_Reverts_BeforeDisputeWindowElapsed() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        uint256 earliestFinalizeAt = update.submittedAt + DISPUTE_WINDOW;

        vm.expectRevert(
            abi.encodeWithSelector(IInvoiceStatusOracle.DisputeWindowNotElapsed.selector, invoiceId, earliestFinalizeAt)
        );

        oracle.finalize(invoiceId);
    }

    function test_Finalize_SucceedsAtExactDisputeWindowBoundary() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        vm.prank(finalizer);
        oracle.finalize(invoiceId);

        update = oracle.getStatusUpdate(invoiceId);

        assertTrue(update.finalized);
        assertFalse(update.disputed);
    }

    function test_Finalize_SucceedsAtExactMaxStalenessBoundary() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + MAX_STALENESS);

        vm.prank(finalizer);
        oracle.finalize(invoiceId);

        update = oracle.getStatusUpdate(invoiceId);

        assertTrue(update.finalized);
        assertFalse(update.disputed);
        assertEq(update.recoveredAmount, DEFAULT_RECOVERY);
    }

    function test_Finalize_Reverts_WhenUpdateIsStale() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        uint256 staleAfter = update.submittedAt + MAX_STALENESS;

        vm.warp(staleAfter + 1);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateStale.selector, invoiceId, staleAfter));

        oracle.finalize(invoiceId);
    }

    function test_Finalize_IsPermissionlessAndForwardsSettledOutcomeToPool() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        vm.prank(finalizer);
        oracle.finalize(invoiceId);

        assertEq(mockPool.lastInvoiceId(), invoiceId);
        assertEq(uint256(mockPool.lastStatus()), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertEq(mockPool.lastRecoveredAmount(), 0);
        assertEq(mockPool.callbackCount(), 1);
    }

    function test_Finalize_ForwardsDefaultedOutcomeAndRecoveryToPool() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        oracle.finalize(invoiceId);

        assertEq(mockPool.lastInvoiceId(), invoiceId);
        assertEq(uint256(mockPool.lastStatus()), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(mockPool.lastRecoveredAmount(), DEFAULT_RECOVERY);
        assertEq(mockPool.callbackCount(), 1);
    }

    function test_Finalize_MarksUpdateFinalizedAndPreservesOutcome() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        oracle.finalize(invoiceId);

        update = oracle.getStatusUpdate(invoiceId);

        assertEq(update.invoiceId, invoiceId);
        assertEq(uint256(update.newStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
        assertEq(update.recoveredAmount, DEFAULT_RECOVERY);
        assertTrue(update.finalized);
        assertFalse(update.disputed);
    }

    function test_Finalize_Reverts_WhenUpdateAlreadyFinalized() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        oracle.finalize(invoiceId);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyFinalized.selector, invoiceId));

        oracle.finalize(invoiceId);

        assertEq(mockPool.callbackCount(), 1);
    }

    function test_SubmitStatus_Reverts_WhenPreviousOutcomeAlreadyFinalizedAndPreservesRecovery() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, DEFAULT_RECOVERY);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        oracle.finalize(invoiceId);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyFinalized.selector, invoiceId));

        vm.prank(admin);
        oracle.submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, UPDATED_RECOVERY);

        update = oracle.getStatusUpdate(invoiceId);

        assertEq(update.recoveredAmount, DEFAULT_RECOVERY);
        assertTrue(update.finalized);
        assertEq(mockPool.callbackCount(), 1);
        assertEq(mockPool.lastRecoveredAmount(), DEFAULT_RECOVERY);
    }

    function test_DisputeStatus_Reverts_WhenUpdateAlreadyFinalized() public {
        uint256 invoiceId = _createFundedInvoice();

        _submitStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);

        IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

        vm.warp(update.submittedAt + DISPUTE_WINDOW);

        oracle.finalize(invoiceId);

        vm.expectRevert(abi.encodeWithSelector(IInvoiceStatusOracle.StatusUpdateAlreadyFinalized.selector, invoiceId));

        vm.prank(admin);
        oracle.disputeStatus(invoiceId);
    }
}


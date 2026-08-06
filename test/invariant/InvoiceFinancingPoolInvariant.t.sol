// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

import {InvoiceFinancingPool} from "../../src/core/InvoiceFinancingPool.sol";
import {InvoiceNFT} from "../../src/core/InvoiceNFT.sol";
import {InvoiceStatusOracle} from "../../src/oracle/InvoiceStatusOracle.sol";
import {RWARiskManager} from "../../src/risk/RWARiskManager.sol";
import {SeniorPool} from "../../src/pools/SeniorPool.sol";
import {JuniorPool} from "../../src/pools/JuniorPool.sol";

import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";
import {IRWARiskManager} from "../../src/interfaces/IRWARiskManager.sol";
import {IInvoiceStatusOracle} from "../../src/interfaces/IInvoiceStatusOracle.sol";

import {InvoiceFinancingPoolHandler} from "./handlers/InvoiceFinancingPoolHandler.sol";

/// @title InvoiceFinancingPoolInvariantTest
/// @notice Stateful invariant suite for the RWA Invoice Financing protocol.
/// @dev
/// The invariant fuzzer executes arbitrary sequences across:
/// - invoice creation and financing;
/// - oracle settlement/default submission;
/// - oracle finalization;
/// - paid-path settlement;
/// - default resolution;
/// - freeze and unfreeze.
///
/// The catalogue combines independently ghost-reconstructed expectations,
/// cross-storage consistency checks, direct protocol bounds, and lifecycle
/// coherence properties.
contract InvoiceFinancingPoolInvariantTest is StdInvariant, Test {
    MockERC20 internal asset;
    InvoiceNFT internal invoiceNft;
    RWARiskManager internal riskManager;
    InvoiceFinancingPool internal pool;
    InvoiceStatusOracle internal oracle;
    SeniorPool internal seniorPool;
    JuniorPool internal juniorPool;

    InvoiceFinancingPoolHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal riskAdmin = makeAddr("riskAdmin");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");
    address internal buyerTwo = makeAddr("buyerTwo");
    address internal resolver = makeAddr("resolver");
    address internal seniorLp = makeAddr("seniorLp");
    address internal juniorLp = makeAddr("juniorLp");

    uint256 internal constant MAX_EXPOSURE_PER_BUYER = 1_000_000e18;
    uint256 internal constant ADVANCE_RATE_BPS = 8_000;
    uint256 internal constant MAX_INVOICE_TENOR = 90 days;
    uint256 internal constant MIN_INVOICE_AMOUNT = 1_000e18;
    uint256 internal constant FINANCING_FEE_APR_BPS = 1_200;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant SENIOR_FUNDING_SHARE_BPS = 7_000;
    uint256 internal constant JUNIOR_FUNDING_SHARE_BPS = 3_000;
    uint256 internal constant SENIOR_FEE_SHARE_BPS = 4_000;
    uint256 internal constant JUNIOR_FEE_SHARE_BPS = 6_000;

    uint256 internal constant SENIOR_DEPOSIT = 700_000e18;
    uint256 internal constant JUNIOR_DEPOSIT = 300_000e18;

    uint256 internal constant DISPUTE_WINDOW = 1 days;
    uint256 internal constant MAX_STALENESS = 7 days;

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

        _depositInitialTrancheLiquidity();

        InvoiceFinancingPoolHandler.Actors memory actors = InvoiceFinancingPoolHandler.Actors({
            admin: admin,
            originator: originator,
            verifier: verifier,
            riskAdmin: riskAdmin,
            supplier: supplier,
            buyerOne: buyer,
            buyerTwo: buyerTwo,
            resolver: resolver
        });

        InvoiceFinancingPoolHandler.ModelConfig memory modelConfig = InvoiceFinancingPoolHandler.ModelConfig({
            maxExposurePerBuyer: MAX_EXPOSURE_PER_BUYER,
            advanceRateBps: ADVANCE_RATE_BPS,
            seniorFundingShareBps: SENIOR_FUNDING_SHARE_BPS,
            bpsDenominator: BPS_DENOMINATOR,
            maxInvoiceTenor: MAX_INVOICE_TENOR,
            minInvoiceAmount: MIN_INVOICE_AMOUNT,
            financingFeeAprBps: FINANCING_FEE_APR_BPS,
            disputeWindow: DISPUTE_WINDOW,
            maxStaleness: MAX_STALENESS
        });

        handler = new InvoiceFinancingPoolHandler(pool, oracle, actors, modelConfig);

        _targetHandlerSelectors();
    }

    /// @notice Aggregate pool lock must equal the sum of tranche locks.
    function invariant_TotalLockedAssetsEqualsTrancheLocks() public view {
        assertEq(pool.totalLockedAssets(), seniorPool.lockedAssets() + juniorPool.lockedAssets());
    }

    /// @notice Aggregate pool lock must equal independently reconstructed unresolved principal.
    function invariant_TotalLockedAssetsEqualsUnresolvedPrincipal() public view {
        uint256 expectedLockedAssets;
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            assertTrue(ghost.exists);

            if (!ghost.resolved) {
                expectedLockedAssets += ghost.principal;
            }
        }

        assertEq(pool.totalLockedAssets(), expectedLockedAssets);
    }

    /// @notice Each Buyer exposure key must equal independently reconstructed active principal.
    function invariant_BuyerExposureEqualsActivePrincipal() public view {
        uint256 buyerCount = handler.buyerCount();
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 buyerIndex; buyerIndex < buyerCount; buyerIndex++) {
            address selectedBuyer = handler.buyerAt(buyerIndex);
            uint256 expectedBuyerExposure;

            for (uint256 i; i < invoiceCount; i++) {
                uint256 invoiceId = handler.financedInvoiceIdAt(i);

                InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

                assertTrue(ghost.exists);

                if (!ghost.resolved && ghost.buyer == selectedBuyer) {
                    expectedBuyerExposure += ghost.principal;
                }
            }

            assertEq(riskManager.getBuyerExposure(selectedBuyer), expectedBuyerExposure);
        }
    }

    /// @notice Every production principal split must match its independent ghost expectation.
    function invariant_PositionPrincipalSplitConservesPrincipal() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            (,, uint256 positionPrincipal, uint256 positionSeniorPrincipal, uint256 positionJuniorPrincipal,,,,) =
                pool.financingPositions(invoiceId);

            assertTrue(ghost.exists);
            assertEq(ghost.seniorPrincipal + ghost.juniorPrincipal, ghost.principal);

            assertEq(positionPrincipal, ghost.principal);
            assertEq(positionSeniorPrincipal, ghost.seniorPrincipal);
            assertEq(positionJuniorPrincipal, ghost.juniorPrincipal);
        }
    }

    /// @notice Locked tranche assets must never exceed tranche NAV.
    function invariant_TrancheLocksNeverExceedTrancheNav() public view {
        assertLe(seniorPool.lockedAssets(), seniorPool.totalAssets());

        assertLe(juniorPool.lockedAssets(), juniorPool.totalAssets());
    }

    /// @notice Production resolution and InvoiceNFT lifecycle must match ghost resolution.
    /// @dev
    /// An unresolved ghost position remains economically active as:
    /// - FUNDED; or
    /// - FROZEN with previousStatus == FUNDED.
    ///
    /// A resolved ghost position must match its finalized terminal outcome:
    /// - SETTLED; or
    /// - DEFAULTED.
    function invariant_PositionResolutionMatchesInvoiceLifecycle() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            (,,,,,,,, bool positionResolved) = pool.financingPositions(invoiceId);

            IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

            assertTrue(ghost.exists);
            assertEq(positionResolved, ghost.resolved);

            if (ghost.resolved) {
                assertTrue(ghost.finalized);

                if (ghost.finalizedStatus == IInvoiceNFT.InvoiceStatus.SETTLED) {
                    assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
                } else {
                    assertEq(uint256(ghost.finalizedStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
                    assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
                }
            } else {
                bool isActive = invoice.status == IInvoiceNFT.InvoiceStatus.FUNDED
                    || (invoice.status == IInvoiceNFT.InvoiceStatus.FROZEN
                        && invoice.previousStatus == IInvoiceNFT.InvoiceStatus.FUNDED);

                assertTrue(isActive);
            }
        }
    }

    /// @notice Oracle and Pool finalized data must match the independent ghost outcome.
    /// @dev
    /// The pending and finalized ghost values originate from successful handler
    /// submissions rather than either production record.
    /// - SETTLED recovery is exactly zero;
    /// - DEFAULTED recovery never exceeds ghost principal;
    /// - unfinalized pool state remains the default CREATED enum value;
    /// - Oracle and Pool finalized records must match the ghost exactly.
    function invariant_FinalizedOracleDataIsCanonical() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            IInvoiceNFT.InvoiceStatus poolStatus = pool.finalizedOracleStatus(invoiceId);
            uint256 recoveredAmount = pool.finalizedRecoveryAmount(invoiceId);
            bool poolFinalized = pool.isOracleStatusFinalized(invoiceId);
            IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

            assertTrue(ghost.exists);

            if (ghost.pendingOutcomeExists) {
                assertEq(update.invoiceId, invoiceId);
                assertEq(uint256(update.newStatus), uint256(ghost.pendingStatus));
                assertEq(update.recoveredAmount, ghost.pendingRecovery);
                assertEq(update.submittedAt, ghost.pendingSubmittedAt);
                assertFalse(update.disputed);
            } else {
                assertEq(update.submittedAt, 0);
            }

            if (ghost.finalized) {
                assertTrue(poolFinalized);
                assertEq(uint256(poolStatus), uint256(ghost.finalizedStatus));
                assertEq(recoveredAmount, ghost.finalizedRecovery);

                assertTrue(update.finalized);
                assertEq(uint256(update.newStatus), uint256(ghost.finalizedStatus));
                assertEq(update.recoveredAmount, ghost.finalizedRecovery);

                if (ghost.finalizedStatus == IInvoiceNFT.InvoiceStatus.SETTLED) {
                    assertEq(ghost.finalizedRecovery, 0);
                } else {
                    assertEq(uint256(ghost.finalizedStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
                    assertLe(ghost.finalizedRecovery, ghost.principal);
                }
            } else {
                assertFalse(poolFinalized);
                assertEq(uint256(poolStatus), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
                assertEq(recoveredAmount, 0);
                assertFalse(update.finalized);
            }
        }
    }

    /// @notice Terminal InvoiceNFT lifecycle must match the ghost-finalized outcome.
    /// @dev
    /// Finalized but unresolved positions remain FUNDED, or FROZEN from FUNDED,
    /// until permissionless economic execution succeeds.
    function invariant_TerminalLifecycleMatchesOracleOutcome() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

            assertTrue(ghost.exists);

            if (ghost.resolved) {
                assertTrue(ghost.finalized);

                if (ghost.finalizedStatus == IInvoiceNFT.InvoiceStatus.SETTLED) {
                    assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
                    assertEq(ghost.finalizedRecovery, 0);
                } else {
                    assertEq(uint256(ghost.finalizedStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
                    assertEq(uint256(invoice.status), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
                }
            } else {
                assertTrue(
                    invoice.status != IInvoiceNFT.InvoiceStatus.SETTLED
                        && invoice.status != IInvoiceNFT.InvoiceStatus.DEFAULTED
                );

                bool isActive = invoice.status == IInvoiceNFT.InvoiceStatus.FUNDED
                    || (invoice.status == IInvoiceNFT.InvoiceStatus.FROZEN
                        && invoice.previousStatus == IInvoiceNFT.InvoiceStatus.FUNDED);

                assertTrue(isActive);
            }
        }
    }

    /// @notice Cumulative bad debt must equal ghost-reconstructed resolved default losses.
    /// @dev
    /// Expected principal and recovery come exclusively from successful handler
    /// actions recorded in GhostPosition.
    ///
    /// Unpaid financing fee is intentionally excluded because it was never
    /// recognized as deployed principal NAV.
    function invariant_TotalBadDebtEqualsResolvedDefaultLosses() public view {
        uint256 expectedBadDebt;
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            assertTrue(ghost.exists);

            if (ghost.resolved && ghost.finalized && ghost.finalizedStatus == IInvoiceNFT.InvoiceStatus.DEFAULTED) {
                assertLe(ghost.finalizedRecovery, ghost.principal);

                expectedBadDebt += ghost.principal - ghost.finalizedRecovery;
            }
        }

        assertEq(pool.totalBadDebt(), expectedBadDebt);
    }

    /// @notice Each tranche lock must equal independently reconstructed unresolved splits.
    /// @dev
    /// Senior and Junior expectations come from handler GhostPosition data rather
    /// than production financing-position storage.
    ///
    /// It catches:
    /// - incorrect tranche unlock amounts;
    /// - Senior/Junior lock desynchronization;
    /// - resolving one tranche without the other;
    /// - aggregate locks remaining correct while tranche-level locks are wrong.
    function invariant_TrancheLocksEqualUnresolvedPrincipalSplits() public view {
        uint256 expectedSeniorLockedAssets;
        uint256 expectedJuniorLockedAssets;

        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            assertTrue(ghost.exists);

            if (!ghost.resolved) {
                expectedSeniorLockedAssets += ghost.seniorPrincipal;
                expectedJuniorLockedAssets += ghost.juniorPrincipal;
            }
        }

        assertEq(seniorPool.lockedAssets(), expectedSeniorLockedAssets);

        assertEq(juniorPool.lockedAssets(), expectedJuniorLockedAssets);
    }

    /// @notice Each tranche's token cash must exactly back its available liquidity.
    /// @dev
    /// Exact equality relies on the current handler excluding direct donations,
    /// fee-on-transfer tokens, rebasing tokens, and untracked vault inflows or
    /// outflows.
    function invariant_TrancheCashBacksAvailableLiquidity() public view {
        assertEq(asset.balanceOf(address(seniorPool)), seniorPool.availableLiquidity());

        assertEq(asset.balanceOf(address(juniorPool)), juniorPool.availableLiquidity());
    }

    /// @notice Production position and InvoiceNFT terms must match their ghost expectations.
    /// @dev
    /// Expected identity, principal allocation, timestamps, and resolution state
    /// originate exclusively from successful handler actions.
    ///
    /// This invariant verifies:
    /// - Supplier identity;
    /// - Buyer identity;
    /// - principal and tranche allocations;
    /// - due date and funding timestamp;
    /// - production resolution state;
    /// - NFT ownership;
    /// - non-zero financed principal;
    /// - valid funded-to-due-date ordering.
    function invariant_FinancedPositionTermsRemainCanonical() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            InvoiceFinancingPoolHandler.GhostPosition memory ghost = handler.getGhostPosition(invoiceId);

            assertTrue(ghost.exists);

            _assertProductionPositionMatchesGhost(invoiceId, ghost);

            IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

            assertEq(invoice.supplier, ghost.supplier);
            assertEq(invoice.buyer, ghost.buyer);
            assertEq(invoice.dueDate, ghost.dueDate);
            assertEq(invoice.fundedAt, ghost.fundedAt);

            assertEq(invoiceNft.ownerOf(invoiceId), ghost.supplier);

            assertGt(ghost.principal, 0);
            assertGt(ghost.seniorPrincipal, 0);
            assertGt(ghost.juniorPrincipal, 0);
            assertGt(ghost.fundedAt, 0);
            assertGt(ghost.dueDate, ghost.fundedAt);
        }
    }

    function _assertProductionPositionMatchesGhost(
        uint256 invoiceId,
        InvoiceFinancingPoolHandler.GhostPosition memory ghost
    ) internal view {
        (
            address positionSupplier,
            address positionBuyer,
            uint256 positionPrincipal,
            uint256 positionSeniorPrincipal,
            uint256 positionJuniorPrincipal,,
            uint256 positionFundedAt,
            uint256 positionDueDate,
            bool positionResolved
        ) = pool.financingPositions(invoiceId);

        assertEq(positionSupplier, ghost.supplier);

        assertEq(positionBuyer, ghost.buyer);

        assertEq(positionPrincipal, ghost.principal);

        assertEq(positionSeniorPrincipal, ghost.seniorPrincipal);

        assertEq(positionJuniorPrincipal, ghost.juniorPrincipal);

        assertEq(positionFundedAt, ghost.fundedAt);

        assertEq(positionDueDate, ghost.dueDate);

        assertEq(positionResolved, ghost.resolved);
    }

    function _depositInitialTrancheLiquidity() internal {
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

    /// @dev Targets only meaningful state-changing handler actions.
    ///
    /// Public getters and inherited Test helpers are intentionally excluded so
    /// the fuzzer spends runs exploring protocol state transitions rather than
    /// calling irrelevant or reverting selectors.
    function _targetHandlerSelectors() internal {
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);

        selectors[0] = InvoiceFinancingPoolHandler.createAndFinanceInvoice.selector;

        selectors[1] = InvoiceFinancingPoolHandler.submitSettledOutcome.selector;

        selectors[2] = InvoiceFinancingPoolHandler.submitDefaultedOutcome.selector;

        selectors[3] = InvoiceFinancingPoolHandler.finalizeOutcome.selector;

        selectors[4] = InvoiceFinancingPoolHandler.settleInvoice.selector;

        selectors[5] = InvoiceFinancingPoolHandler.resolveDefault.selector;

        selectors[6] = InvoiceFinancingPoolHandler.freezeInvoice.selector;

        selectors[7] = InvoiceFinancingPoolHandler.unfreezeInvoice.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
}

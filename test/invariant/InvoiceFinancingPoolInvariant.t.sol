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
/// Global invariants then reconstruct protocol accounting from stored financing
/// positions and compare it against aggregate accounting state.
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
    address internal resolver = makeAddr("resolver");
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
            buyer: buyer,
            resolver: resolver
        });

        handler = new InvoiceFinancingPoolHandler(pool, oracle, actors);

        _targetHandlerSelectors();
    }

    /// @notice Aggregate pool lock must equal the sum of tranche locks.
    function invariant_TotalLockedAssetsEqualsTrancheLocks() public view {
        assertEq(pool.totalLockedAssets(), seniorPool.lockedAssets() + juniorPool.lockedAssets());
    }

    /// @notice Aggregate pool lock must equal unresolved financed principal.
    function invariant_TotalLockedAssetsEqualsUnresolvedPrincipal() public view {
        uint256 expectedLockedAssets;
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (,, uint256 principal,,,,,, bool resolved) = pool.financingPositions(invoiceId);

            if (!resolved) {
                expectedLockedAssets += principal;
            }
        }

        assertEq(pool.totalLockedAssets(), expectedLockedAssets);
    }

    /// @notice Buyer exposure must equal active principal for that Buyer.
    function invariant_BuyerExposureEqualsActivePrincipal() public view {
        uint256 expectedBuyerExposure;
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (, address positionBuyer, uint256 principal,,,,,, bool resolved) = pool.financingPositions(invoiceId);

            if (!resolved && positionBuyer == buyer) {
                expectedBuyerExposure += principal;
            }
        }

        assertEq(riskManager.getBuyerExposure(buyer), expectedBuyerExposure);
    }

    /// @notice Every financing position must conserve principal across tranches.
    function invariant_PositionPrincipalSplitConservesPrincipal() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (,, uint256 principal, uint256 seniorPrincipal, uint256 juniorPrincipal,,,,) =
                pool.financingPositions(invoiceId);

            assertEq(seniorPrincipal + juniorPrincipal, principal);
        }
    }

    /// @notice Locked tranche assets must never exceed tranche NAV.
    function invariant_TrancheLocksNeverExceedTrancheNav() public view {
        assertLe(seniorPool.lockedAssets(), seniorPool.totalAssets());

        assertLe(juniorPool.lockedAssets(), juniorPool.totalAssets());
    }

    /// @notice Financing position resolution must match the InvoiceNFT lifecycle.
    /// @dev
    /// An unresolved financed position must remain economically active as:
    /// - FUNDED; or
    /// - FROZEN with previousStatus == FUNDED.
    ///
    /// A resolved position must be terminal:
    /// - SETTLED; or
    /// - DEFAULTED.
    function invariant_PositionResolutionMatchesInvoiceLifecycle() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (,,,,,,,, bool resolved) = pool.financingPositions(invoiceId);

            IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

            if (resolved) {
                bool isTerminal = invoice.status == IInvoiceNFT.InvoiceStatus.SETTLED
                    || invoice.status == IInvoiceNFT.InvoiceStatus.DEFAULTED;

                assertTrue(isTerminal);
            } else {
                bool isActive = invoice.status == IInvoiceNFT.InvoiceStatus.FUNDED
                    || (invoice.status == IInvoiceNFT.InvoiceStatus.FROZEN
                        && invoice.previousStatus == IInvoiceNFT.InvoiceStatus.FUNDED);

                assertTrue(isActive);
            }
        }
    }

    /// @notice Finalized oracle data must remain canonical across Oracle and Pool.
    /// @dev
    /// Pool finalization and Oracle finalization must remain atomic and coherent.
    ///
    /// Canonical rules:
    /// - SETTLED recovery is exactly zero;
    /// - DEFAULTED recovery never exceeds stored principal;
    /// - unfinalized pool state remains the default CREATED enum value;
    /// - Oracle and Pool finalized records must match exactly.
    function invariant_FinalizedOracleDataIsCanonical() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (,, uint256 principal,,,,,,) = pool.financingPositions(invoiceId);

            IInvoiceNFT.InvoiceStatus poolStatus = pool.finalizedOracleStatus(invoiceId);

            uint256 recoveredAmount = pool.finalizedRecoveryAmount(invoiceId);

            bool poolFinalized = pool.isOracleStatusFinalized(invoiceId);

            IInvoiceStatusOracle.StatusUpdate memory update = oracle.getStatusUpdate(invoiceId);

            if (poolStatus == IInvoiceNFT.InvoiceStatus.SETTLED) {
                assertTrue(poolFinalized);
                assertEq(recoveredAmount, 0);
            } else if (poolStatus == IInvoiceNFT.InvoiceStatus.DEFAULTED) {
                assertTrue(poolFinalized);
                assertLe(recoveredAmount, principal);
            } else {
                assertEq(uint256(poolStatus), uint256(IInvoiceNFT.InvoiceStatus.CREATED));
                assertFalse(poolFinalized);
                assertEq(recoveredAmount, 0);
            }

            assertEq(update.finalized, poolFinalized);

            if (update.finalized) {
                assertEq(uint256(update.newStatus), uint256(poolStatus));
                assertEq(update.recoveredAmount, recoveredAmount);
            }
        }
    }

    /// @notice Terminal InvoiceNFT lifecycle must match the finalized oracle outcome.
    /// @dev
    /// Settlement and default execution are mutually exclusive.
    ///
    /// A SETTLED invoice must have:
    /// - resolved financing position;
    /// - finalized SETTLED oracle outcome;
    /// - zero recovered principal.
    ///
    /// A DEFAULTED invoice must have:
    /// - resolved financing position;
    /// - finalized DEFAULTED oracle outcome.
    function invariant_TerminalLifecycleMatchesOracleOutcome() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (,,,,,,,, bool resolved) = pool.financingPositions(invoiceId);

            IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

            IInvoiceNFT.InvoiceStatus oracleStatus = pool.finalizedOracleStatus(invoiceId);

            if (invoice.status == IInvoiceNFT.InvoiceStatus.SETTLED) {
                assertTrue(resolved);

                assertEq(uint256(oracleStatus), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));

                assertEq(pool.finalizedRecoveryAmount(invoiceId), 0);
            }

            if (invoice.status == IInvoiceNFT.InvoiceStatus.DEFAULTED) {
                assertTrue(resolved);

                assertEq(uint256(oracleStatus), uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED));
            }
        }
    }

    /// @notice Cumulative bad debt must equal all realized resolved default losses.
    /// @dev
    /// Expected bad debt is reconstructed from immutable financed principal and
    /// oracle-finalized recovered principal.
    ///
    /// Unpaid financing fee is intentionally excluded because it was never
    /// recognized as deployed principal NAV.
    function invariant_TotalBadDebtEqualsResolvedDefaultLosses() public view {
        uint256 expectedBadDebt;
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (,, uint256 principal,,,,,, bool resolved) = pool.financingPositions(invoiceId);

            IInvoiceNFT.InvoiceStatus oracleStatus = pool.finalizedOracleStatus(invoiceId);

            if (resolved && oracleStatus == IInvoiceNFT.InvoiceStatus.DEFAULTED) {
                uint256 recoveredAmount = pool.finalizedRecoveryAmount(invoiceId);

                assertLe(recoveredAmount, principal);

                expectedBadDebt += principal - recoveredAmount;
            }
        }

        assertEq(pool.totalBadDebt(), expectedBadDebt);
    }

    /// @notice Each tranche lock must equal the sum of its unresolved position allocations.
    /// @dev
    /// This reconstructs Senior and Junior locks independently from immutable
    /// financing-position principal splits.
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

            (,,, uint256 seniorPrincipal, uint256 juniorPrincipal,,,, bool resolved) =
                pool.financingPositions(invoiceId);

            if (!resolved) {
                expectedSeniorLockedAssets += seniorPrincipal;
                expectedJuniorLockedAssets += juniorPrincipal;
            }
        }

        assertEq(seniorPool.lockedAssets(), expectedSeniorLockedAssets);

        assertEq(juniorPool.lockedAssets(), expectedJuniorLockedAssets);
    }

    /// @notice Tranche available liquidity must equal NAV minus locked assets.
    /// @dev
    /// Locked receivable exposure remains part of tranche NAV but cannot be used
    /// for new funding or LP withdrawals.
    function invariant_TrancheAvailableLiquidityIsAccountingConsistent() public view {
        assertEq(seniorPool.availableLiquidity(), seniorPool.totalAssets() - seniorPool.lockedAssets());

        assertEq(juniorPool.availableLiquidity(), juniorPool.totalAssets() - juniorPool.lockedAssets());
    }

    /// @notice Financing positions must remain canonical against InvoiceNFT data.
    /// @dev
    /// Position terms are fixed when the invoice is financed and must remain
    /// coherent with the lifecycle registry for the entire position lifetime.
    ///
    /// This invariant verifies:
    /// - Supplier identity;
    /// - Buyer identity;
    /// - due date;
    /// - funding timestamp;
    /// - NFT ownership;
    /// - non-zero financed principal;
    /// - valid funded-to-due-date ordering.
    function invariant_FinancedPositionTermsRemainCanonical() public view {
        uint256 invoiceCount = handler.financedInvoiceCount();

        for (uint256 i; i < invoiceCount; i++) {
            uint256 invoiceId = handler.financedInvoiceIdAt(i);

            (
                address positionSupplier,
                address positionBuyer,
                uint256 principal,,,,
                uint256 fundedAt,
                uint256 dueDate,
            ) = pool.financingPositions(invoiceId);

            IInvoiceNFT.Invoice memory invoice = invoiceNft.getInvoice(invoiceId);

            assertEq(positionSupplier, invoice.supplier);
            assertEq(positionBuyer, invoice.buyer);
            assertEq(dueDate, invoice.dueDate);
            assertEq(fundedAt, invoice.fundedAt);

            assertEq(invoiceNft.ownerOf(invoiceId), positionSupplier);

            assertGt(principal, 0);
            assertGt(fundedAt, 0);
            assertGt(dueDate, fundedAt);
        }
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

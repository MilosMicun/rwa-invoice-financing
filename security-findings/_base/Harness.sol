// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

import {MockERC20, IMintableERC20} from "./MockERC20.sol";

/// @title Harness
/// @notice Shared, verified deployment + lifecycle helpers for all security PoCs.
/// @dev
/// Mirrors the wiring in test/integration/InvoiceFinancingPool.EconomicLifecycle.t.sol so PoCs
/// exercise the real protocol topology. The asset is pluggable: override `setUp` and call
/// `_deployProtocol(customAsset)` to run the whole protocol on a malicious token.
///
/// Every helper is deliberately explicit (no hidden magic) so a finding's reproduction is
/// self-evident from the test body. All fixture parameters are TEST fixtures, not protocol
/// constants.
abstract contract Harness is Test {
    // ---- Core contracts ----
    IMintableERC20 internal asset;
    InvoiceNFT internal invoiceNft;
    RWARiskManager internal riskManager;
    InvoiceFinancingPool internal pool;
    InvoiceStatusOracle internal oracle;
    SeniorPool internal seniorPool;
    JuniorPool internal juniorPool;

    // ---- Actors ----
    address internal admin = makeAddr("admin");
    address internal originator = makeAddr("originator");
    address internal verifier = makeAddr("verifier");
    address internal riskAdmin = makeAddr("riskAdmin");
    address internal supplier = makeAddr("supplier");
    address internal buyer = makeAddr("buyer");
    address internal resolver = makeAddr("resolver");
    address internal attacker = makeAddr("attacker");
    address internal seniorLp = makeAddr("seniorLp");
    address internal juniorLp = makeAddr("juniorLp");

    // ---- Fixture parameters (NOT protocol constants) ----
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

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        _deployProtocol(address(new MockERC20()));
    }

    /// @dev Deploys the full protocol on top of `assetAddr` and wires all roles.
    ///      `assetAddr` must implement IMintableERC20 for the mint helpers to work.
    function _deployProtocol(address assetAddr) internal {
        asset = IMintableERC20(assetAddr);
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
            IERC20(assetAddr),
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

    // -------------------------------------------------------------------------
    // Liquidity helpers
    // -------------------------------------------------------------------------

    function _depositTranches(uint256 seniorAssets, uint256 juniorAssets) internal {
        _depositSenior(seniorLp, seniorAssets);
        _depositJunior(juniorLp, juniorAssets);
    }

    function _depositSenior(address lp, uint256 assets) internal {
        asset.mint(lp, assets);
        vm.startPrank(lp);
        asset.approve(address(pool), assets);
        pool.depositSenior(assets);
        vm.stopPrank();
    }

    function _depositJunior(address lp, uint256 assets) internal {
        asset.mint(lp, assets);
        vm.startPrank(lp);
        asset.approve(address(pool), assets);
        pool.depositJunior(assets);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Invoice lifecycle helpers
    // -------------------------------------------------------------------------

    function _createVerifiedInvoice(uint256 faceValue, uint256 dueDate) internal returns (uint256 invoiceId) {
        invoiceId = _createVerifiedInvoiceFor(supplier, buyer, faceValue, dueDate);
    }

    function _createVerifiedInvoiceFor(address supplier_, address buyer_, uint256 faceValue, uint256 dueDate)
        internal
        returns (uint256 invoiceId)
    {
        vm.prank(originator);
        invoiceId = invoiceNft.createInvoice(supplier_, buyer_, faceValue, dueDate);
        vm.prank(verifier);
        invoiceNft.verify(invoiceId);
    }

    function _financeAsSupplier(uint256 invoiceId) internal {
        vm.prank(supplier);
        pool.financeInvoice(invoiceId);
    }

    function _financeAs(address supplier_, uint256 invoiceId) internal {
        vm.prank(supplier_);
        pool.financeInvoice(invoiceId);
    }

    function _submitAndFinalizeOracleStatus(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status, uint256 recoveredAmount)
        internal
    {
        vm.prank(admin);
        oracle.submitStatus(invoiceId, status, recoveredAmount);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(invoiceId);
    }

    function _settleAsBuyer(uint256 invoiceId, uint256 paidAmount) internal {
        _settleAs(buyer, invoiceId, paidAmount);
    }

    function _settleAs(address payer, uint256 invoiceId, uint256 paidAmount) internal {
        asset.mint(payer, paidAmount);
        vm.startPrank(payer);
        asset.approve(address(pool), paidAmount);
        pool.settleInvoice(invoiceId, paidAmount);
        vm.stopPrank();
    }

    function _resolveDefaultAsResolver(uint256 invoiceId) internal {
        uint256 recoveredAmount = pool.finalizedRecoveryAmount(invoiceId);
        if (recoveredAmount == 0) {
            vm.prank(resolver);
            pool.resolveDefault(invoiceId);
            return;
        }
        asset.mint(resolver, recoveredAmount);
        vm.startPrank(resolver);
        asset.approve(address(pool), recoveredAmount);
        pool.resolveDefault(invoiceId);
        vm.stopPrank();
    }

    /// @dev Full happy-path convenience: deposit, create+verify, finance. Returns invoiceId.
    function _bootstrapFundedInvoice() internal returns (uint256 invoiceId) {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        uint256 dueDate = block.timestamp + INVOICE_TENOR;
        invoiceId = _createVerifiedInvoice(FACE_VALUE, dueDate);
        _financeAsSupplier(invoiceId);
    }

    // -------------------------------------------------------------------------
    // Read helpers
    // -------------------------------------------------------------------------

    function _positionResolved(uint256 invoiceId) internal view returns (bool resolved) {
        (,,,,,,,, resolved) = pool.financingPositions(invoiceId);
    }

    function _positionFee(uint256 invoiceId) internal view returns (uint256 fee) {
        (,,,,, fee,,,) = pool.financingPositions(invoiceId);
    }

    function _positionPrincipal(uint256 invoiceId) internal view returns (uint256 principal) {
        (,, principal,,,,,,) = pool.financingPositions(invoiceId);
    }

    function _expectedPrincipal() internal pure returns (uint256) {
        return FACE_VALUE * ADVANCE_RATE_BPS / BPS;
    }

    function _expectedSeniorPrincipal(uint256 principal) internal pure returns (uint256) {
        return principal * SENIOR_FUNDING_SHARE_BPS / BPS;
    }
}

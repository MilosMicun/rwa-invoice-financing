// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "../../_base/Harness.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {InvoiceFinancingPool} from "../../../src/core/InvoiceFinancingPool.sol";
import {IInvoiceFinancingPool} from "../../../src/interfaces/IInvoiceFinancingPool.sol";
import {IInvoiceNFT} from "../../../src/interfaces/IInvoiceNFT.sol";
import {IRWARiskManager} from "../../../src/interfaces/IRWARiskManager.sol";
import {RWARiskManager} from "../../../src/risk/RWARiskManager.sol";
import {SeniorPool} from "../../../src/pools/SeniorPool.sol";
import {JuniorPool} from "../../../src/pools/JuniorPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Vector 04 — Access Control & Privilege Escalation
/// @notice All probes inherit the shared Harness (default setUp wires every role).
///         SAFE probes assert the guard holds (expectRevert or invariant preserved).
///         FINDING probes construct the exploit and assert the harmful outcome.
contract AccessControlTest is Harness {
    // Convenience: OZ v5 AccessControl unauthorized selector.
    bytes4 internal AC_UNAUTHORIZED = IAccessControl.AccessControlUnauthorizedAccount.selector;

    // -------------------------------------------------------------------------
    // Probe 1 — financeInvoice: only invoice.supplier may finance.
    // -------------------------------------------------------------------------
    // Hypothesis: A non-supplier can finance an invoice to redirect the advance.
    // Attack: create+verify invoice for `supplier`, call financeInvoice as `attacker`.
    // Result: reverts UnauthorizedFinancer; advance can never be redirected.
    // Verdict: SAFE.
    function test_SAFE_financeInvoice_onlySupplier() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        uint256 id = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceFinancingPool.UnauthorizedFinancer.selector, id, attacker)
        );
        pool.financeInvoice(id);

        // Legit supplier can still finance, and the cash lands on the supplier only.
        uint256 supBefore = asset.balanceOf(supplier);
        _financeAsSupplier(id);
        assertEq(asset.balanceOf(supplier) - supBefore, _expectedPrincipal(), "advance must go to supplier");
        assertEq(asset.balanceOf(attacker), 0, "attacker never receives funds");
    }

    // -------------------------------------------------------------------------
    // Probe 2 — Vault mutators are onlyInvoiceFinancingPool.
    // -------------------------------------------------------------------------
    // Hypothesis: Attacker can directly lock/unlock/fund/credit/writeDown a vault
    //             to drain cash or corrupt share price.
    // Attack: call each mutator on SeniorPool and JuniorPool from `attacker`.
    // Result: every call reverts NotInvoiceFinancingPool.
    // Verdict: SAFE.
    function test_SAFE_vaultMutators_onlyPool() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        vm.startPrank(attacker);

        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.lockAssets(1e18);
        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.unlockAssets(1e18);
        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.fundInvoice(attacker, 1e18);
        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.creditAssets(1e18);
        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.writeDown(1e18);

        vm.expectRevert(JuniorPool.NotInvoiceFinancingPool.selector);
        juniorPool.lockAssets(1e18);
        vm.expectRevert(JuniorPool.NotInvoiceFinancingPool.selector);
        juniorPool.unlockAssets(1e18);
        vm.expectRevert(JuniorPool.NotInvoiceFinancingPool.selector);
        juniorPool.fundInvoice(attacker, 1e18);
        vm.expectRevert(JuniorPool.NotInvoiceFinancingPool.selector);
        juniorPool.creditAssets(1e18);
        vm.expectRevert(JuniorPool.NotInvoiceFinancingPool.selector);
        juniorPool.writeDown(1e18);

        vm.stopPrank();

        // NAV untouched.
        assertEq(seniorPool.totalAssets(), SENIOR_DEPOSIT, "senior NAV intact");
        assertEq(juniorPool.totalAssets(), JUNIOR_DEPOSIT, "junior NAV intact");
    }

    // -------------------------------------------------------------------------
    // Probe 3 — RiskManager.updateBuyerExposure onlyPOOL_ROLE.
    // -------------------------------------------------------------------------
    // Hypothesis: Attacker can move buyerExposure to evade concentration / force underflow.
    // Attack: attacker calls updateBuyerExposure directly.
    // Result: reverts AccessControlUnauthorizedAccount; exposure unchanged.
    // Verdict: SAFE.
    function test_SAFE_updateBuyerExposure_onlyPool() public {
        uint256 before = riskManager.getBuyerExposure(buyer);
        bytes32 riskPoolRole = riskManager.POOL_ROLE();

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, riskPoolRole)
        );
        riskManager.updateBuyerExposure(buyer, 1e18, true);

        assertEq(riskManager.getBuyerExposure(buyer), before, "exposure unchanged");
    }

    // -------------------------------------------------------------------------
    // Probe 4 — RiskManager.setRiskParams / setBuyerDenied onlyRISK_ADMIN_ROLE.
    // -------------------------------------------------------------------------
    // Hypothesis: Attacker can raise advance/APR or denylist a buyer.
    // Attack: attacker calls both setters.
    // Result: both revert AccessControlUnauthorizedAccount.
    // Verdict: SAFE.
    function test_SAFE_riskSetters_onlyRiskAdmin() public {
        IRWARiskManager.RiskParams memory p = IRWARiskManager.RiskParams({
            maxExposurePerBuyer: MAX_EXPOSURE_PER_BUYER,
            advanceRate: 9_000,
            maxInvoiceTenor: MAX_TENOR,
            minInvoiceAmount: MIN_INVOICE_AMOUNT,
            financingFeeApr: 5_000
        });

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, riskManager.RISK_ADMIN_ROLE()));
        riskManager.setRiskParams(p);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, riskManager.RISK_ADMIN_ROLE()));
        riskManager.setBuyerDenied(buyer, true);
        vm.stopPrank();

        assertFalse(riskManager.isBuyerDenied(buyer), "buyer not denied");
    }

    // -------------------------------------------------------------------------
    // Probe 5 — InvoiceNFT lifecycle transitions each enforce their role.
    // -------------------------------------------------------------------------
    // Hypothesis: Attacker can drive NFT lifecycle without holding the role.
    // Attack: attacker calls create/verify/markFunded/markSettled/markDefaulted/freeze/unfreeze.
    // Result: each reverts AccessControlUnauthorizedAccount.
    // Verdict: SAFE.
    function test_SAFE_invoiceNft_lifecycleRoles() public {
        uint256 id = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, invoiceNft.ORIGINATOR_ROLE()));
        invoiceNft.createInvoice(supplier, buyer, FACE_VALUE, block.timestamp + INVOICE_TENOR);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, invoiceNft.VERIFIER_ROLE()));
        invoiceNft.verify(id);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, invoiceNft.POOL_ROLE()));
        invoiceNft.markFunded(id);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, invoiceNft.POOL_ROLE()));
        invoiceNft.markSettled(id);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, invoiceNft.POOL_ROLE()));
        invoiceNft.markDefaulted(id);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, invoiceNft.RISK_ROLE()));
        invoiceNft.freezeInvoice(id);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, invoiceNft.RISK_ROLE()));
        invoiceNft.unfreezeInvoice(id);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Probe 6 — Oracle submit/dispute role gates; finalize permissionless-by-design.
    // -------------------------------------------------------------------------
    // Hypothesis: Attacker can submit a fake outcome, dispute a legit one, or inject
    //             an outcome via the permissionless finalize().
    // Attack: attacker calls submitStatus + disputeStatus; then a keeper finalizes
    //         only what admin staged.
    // Result: submit/dispute revert AccessControlUnauthorizedAccount; finalize can
    //         only propagate a submitter-staged outcome (no injection).
    // Verdict: SAFE.
    function test_SAFE_oracle_submitDisputeRoles() public {
        uint256 id = _bootstrapFundedInvoice();

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, oracle.ORACLE_SUBMITTER_ROLE()));
        oracle.submitStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);

        vm.expectRevert(abi.encodeWithSelector(AC_UNAUTHORIZED, attacker, oracle.DISPUTE_ADMIN_ROLE()));
        oracle.disputeStatus(id);
        vm.stopPrank();

        // finalize() is intentionally permissionless, but only forwards what a
        // privileged submitter already staged. A keeper cannot inject a status.
        vm.prank(admin);
        oracle.submitStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.prank(attacker); // any keeper
        oracle.finalize(id);

        assertEq(
            uint256(pool.finalizedOracleStatus(id)),
            uint256(IInvoiceNFT.InvoiceStatus.SETTLED),
            "finalize only propagates staged outcome"
        );
    }

    // -------------------------------------------------------------------------
    // Probe 7 — pool.setInvoiceStatusOracle onlyAdmin + one-shot.
    // -------------------------------------------------------------------------
    // Hypothesis: Attacker can hijack or re-point the oracle callback source.
    // Attack: attacker calls setInvoiceStatusOracle; then admin calls it a 2nd time.
    // Result: attacker call reverts UnauthorizedAdmin; second admin call reverts OracleAlreadySet.
    // Verdict: SAFE.
    function test_SAFE_setOracle_onlyAdmin_oneShot() public {
        // Harness already set the oracle in _deployProtocol. Attacker cannot change it.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.UnauthorizedAdmin.selector, attacker));
        pool.setInvoiceStatusOracle(address(0xBEEF));

        // Even the real admin cannot re-point it (one-shot).
        vm.prank(admin);
        vm.expectRevert(IInvoiceFinancingPool.OracleAlreadySet.selector);
        pool.setInvoiceStatusOracle(address(0xBEEF));

        assertEq(pool.invoiceStatusOracle(), address(oracle), "oracle unchanged");
    }

    // -------------------------------------------------------------------------
    // Probe 8 — Oracle role-separation NOT enforced by construction.
    // -------------------------------------------------------------------------
    // Hypothesis: A single admin key holds submitter + dispute + finalize authority
    //             and can push any bounded outcome unopposed.
    // Attack: admin submits DEFAULTED with a chosen recovery, refrains from disputing,
    //         warps past the window, finalizes.
    // Result: arbitrary (bounded) outcome propagated. This is the intended trust model
    //         (docs say "deployer admin receives submitter and dispute roles").
    //         Recovery is still capped at principal and the senior-first waterfall holds.
    // Verdict: SAFE (centralization / design; not a code bug).
    function test_SAFE_oracle_roleSeparationNotEnforced_isDesign() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(id);

        // Single admin: submit a DEFAULTED outcome with recovery == principal (best case for chosen outcome).
        vm.prank(admin);
        oracle.submitStatus(id, IInvoiceNFT.InvoiceStatus.DEFAULTED, principal);
        // Admin holds DISPUTE_ADMIN_ROLE but simply refrains from disputing.
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);

        assertEq(
            uint256(pool.finalizedOracleStatus(id)),
            uint256(IInvoiceNFT.InvoiceStatus.DEFAULTED),
            "single admin can push a chosen outcome"
        );
        // Guardrail preserved: recovery cannot exceed principal (oracle callback caps it).
        assertLe(pool.finalizedRecoveryAmount(id), principal, "recovery still bounded by principal");
    }

    // -------------------------------------------------------------------------
    // Probe 9 — InvoiceNFT admin blast radius: POOL_ROLE to a rogue EOA bricks positions.
    // -------------------------------------------------------------------------
    // Hypothesis: A rogue EOA holding POOL_ROLE on InvoiceNFT can desync NFT vs pool
    //             position and, more importantly, permanently strand locked LP capital
    //             by pushing the NFT out of FUNDED so the real settle/resolve reverts.
    // Attack: admin grants POOL_ROLE to attacker; attacker markSettled() on a FUNDED
    //         invoice; oracle finalizes SETTLED; the genuine pool.settleInvoice reverts
    //         (NFT no longer FUNDED) => locked assets never released.
    // Result: locked assets stranded; NFT status != pool position resolved flag.
    // Verdict: SAFE (requires a fully-compromised DEFAULT_ADMIN; permissioned trust model).
    //          Documented as INFO/centralization — no NON-privileged actor can trigger it.
    function test_SAFE_nftAdminBlastRadius_bricksPosition_requiresAdmin() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 lockedBefore = pool.totalLockedAssets();
        assertGt(lockedBefore, 0, "assets locked after funding");

        // Oracle finalizes SETTLED while the NFT is still legitimately FUNDED.
        vm.prank(admin);
        oracle.submitStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);

        // Rogue admin grants POOL_ROLE to an arbitrary EOA.
        bytes32 nftPoolRole = invoiceNft.POOL_ROLE();
        vm.prank(admin);
        invoiceNft.grantRole(nftPoolRole, attacker);

        // Attacker mutates the NFT out-of-band: FUNDED -> SETTLED (no pool accounting run).
        vm.prank(attacker);
        invoiceNft.markSettled(id);

        // NFT now SETTLED but pool position still unresolved: desync.
        assertEq(uint256(invoiceNft.getInvoice(id).status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
        assertFalse(_positionResolved(id), "pool position still unresolved => desync");

        // Genuine settlement path is now bricked: pool.settleInvoice requires the NFT
        // status to still be FUNDED, which no longer holds => locked LP capital stranded.
        uint256 repay = _positionPrincipal(id) + _positionFee(id);
        asset.mint(buyer, repay);
        vm.startPrank(buyer);
        asset.approve(address(pool), repay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInvoiceFinancingPool.InvoiceNotFunded.selector, id, IInvoiceNFT.InvoiceStatus.SETTLED
            )
        );
        pool.settleInvoice(id, repay);
        vm.stopPrank();

        // Locked assets remain stranded — LP capital cannot be released.
        assertEq(pool.totalLockedAssets(), lockedBefore, "locked assets stranded");
    }

    // -------------------------------------------------------------------------
    // Probe 10 — RiskManager admin blast radius: POOL_ROLE to a rogue EOA moves exposure.
    // -------------------------------------------------------------------------
    // Hypothesis: A rogue EOA with POOL_ROLE can inflate buyerExposure to deny new
    //             financing (concentration DoS) or underflow-revert a legit settlement.
    // Attack: admin grants POOL_ROLE to attacker; attacker inflates a buyer's exposure to
    //         the cap; new eligible financing for that buyer then reverts BuyerConcentrationExceeded.
    // Result: financing blocked for the target buyer despite no real active exposure.
    // Verdict: SAFE (requires compromised DEFAULT_ADMIN). INFO/centralization.
    function test_SAFE_riskAdminBlastRadius_exposureDoS_requiresAdmin() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        // Rogue admin grants POOL_ROLE to attacker.
        bytes32 riskPoolRole = riskManager.POOL_ROLE();
        vm.prank(admin);
        riskManager.grantRole(riskPoolRole, attacker);

        // Attacker fills the buyer's exposure to the cap out of thin air.
        vm.prank(attacker);
        riskManager.updateBuyerExposure(buyer, MAX_EXPOSURE_PER_BUYER, true);
        assertEq(riskManager.getBuyerExposure(buyer), MAX_EXPOSURE_PER_BUYER);

        // A legitimate, eligible invoice for that buyer now cannot be financed.
        uint256 id = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        uint256 principal = _expectedPrincipal();
        vm.prank(supplier);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceFinancingPool.BuyerConcentrationExceeded.selector, id, buyer, principal
            )
        );
        pool.financeInvoice(id);
    }

    // -------------------------------------------------------------------------
    // Probe 11 — Role-revocation DoS: revoking the pool's POOL_ROLE mid-life strands funds.
    // -------------------------------------------------------------------------
    // Hypothesis: Admin revokes the pool's POOL_ROLE on InvoiceNFT after invoices are
    //             live; settlement/default then reverts because the pool cannot mutate
    //             the NFT, permanently stranding locked LP capital.
    // Attack: bootstrap FUNDED invoice, finalize SETTLED, admin revokes pool POOL_ROLE
    //         on InvoiceNFT, buyer attempts settle => revert; assets stay locked.
    // Result: settle reverts; totalLockedAssets never decreases.
    // Verdict: SAFE (requires admin action). INFO/centralization — no unprivileged path.
    function test_SAFE_roleRevocationDoS_stranding_requiresAdmin() public {
        uint256 id = _bootstrapFundedInvoice();
        uint256 lockedBefore = pool.totalLockedAssets();

        vm.prank(admin);
        oracle.submitStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);

        // Admin revokes the pool's ability to mutate the NFT.
        bytes32 nftPoolRole = invoiceNft.POOL_ROLE();
        vm.prank(admin);
        invoiceNft.revokeRole(nftPoolRole, address(pool));

        uint256 repay = _positionPrincipal(id) + _positionFee(id);
        asset.mint(buyer, repay);
        vm.startPrank(buyer);
        asset.approve(address(pool), repay);
        // pool.settleInvoice -> INVOICE_NFT.markSettled -> onlyRole(POOL_ROLE) now reverts.
        vm.expectRevert(
            abi.encodeWithSelector(AC_UNAUTHORIZED, address(pool), invoiceNft.POOL_ROLE())
        );
        pool.settleInvoice(id, repay);
        vm.stopPrank();

        assertEq(pool.totalLockedAssets(), lockedBefore, "locked assets stranded after revocation");
    }

    // -------------------------------------------------------------------------
    // Probe 11b — Role-revocation DoS on RiskManager side (same class, different contract).
    // -------------------------------------------------------------------------
    // Hypothesis: Revoking pool's POOL_ROLE on RiskManager also bricks settlement
    //             (settle calls updateBuyerExposure(decrease)).
    // Verdict: SAFE (admin action).
    function test_SAFE_roleRevocationDoS_riskManager_requiresAdmin() public {
        uint256 id = _bootstrapFundedInvoice();

        vm.prank(admin);
        oracle.submitStatus(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        oracle.finalize(id);

        bytes32 riskPoolRole = riskManager.POOL_ROLE();
        vm.prank(admin);
        riskManager.revokeRole(riskPoolRole, address(pool));

        uint256 repay = _positionPrincipal(id) + _positionFee(id);
        asset.mint(buyer, repay);
        vm.startPrank(buyer);
        asset.approve(address(pool), repay);
        vm.expectRevert(
            abi.encodeWithSelector(AC_UNAUTHORIZED, address(pool), riskManager.POOL_ROLE())
        );
        pool.settleInvoice(id, repay);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Probe 12 — Deploy footgun: pool ADMIN == msg.sender (deployer).
    // -------------------------------------------------------------------------
    // Hypothesis: If the pool is deployed by an actor other than the intended admin,
    //             that deployer alone controls the one-shot oracle wiring; the intended
    //             admin is locked out of setInvoiceStatusOracle.
    // Attack: deploy a fresh pool from `attacker`; show ADMIN==attacker, only attacker
    //         can set the oracle, and the intended admin cannot.
    // Result: deployer captures oracle wiring authority.
    // Verdict: SAFE (deployment/operational footgun, not exploitable post-correct-deploy). INFO.
    function test_SAFE_deployFootgun_adminIsDeployer() public {
        // Deploy a pool from the attacker EOA (simulating a wrong deployer).
        vm.prank(attacker);
        InvoiceFinancingPool roguePool = new InvoiceFinancingPool(
            IERC20(address(asset)),
            invoiceNft,
            riskManager,
            SENIOR_FUNDING_SHARE_BPS,
            JUNIOR_FUNDING_SHARE_BPS,
            SENIOR_FEE_SHARE_BPS,
            JUNIOR_FEE_SHARE_BPS
        );

        assertEq(roguePool.ADMIN(), attacker, "ADMIN is bound to deployer");

        // Intended admin cannot wire the oracle on this pool.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancingPool.UnauthorizedAdmin.selector, admin));
        roguePool.setInvoiceStatusOracle(address(oracle));

        // Only the deployer can.
        vm.prank(attacker);
        roguePool.setInvoiceStatusOracle(address(oracle));
        assertEq(roguePool.invoiceStatusOracle(), address(oracle), "deployer controls oracle wiring");
    }

    // -------------------------------------------------------------------------
    // Probe 13 — onStatusFinalized only callable by configured oracle (not attacker).
    // -------------------------------------------------------------------------
    // Hypothesis: Attacker can call onStatusFinalized directly to preload a fake outcome.
    // Attack: attacker calls pool.onStatusFinalized.
    // Result: reverts UnauthorizedOracle.
    // Verdict: SAFE.
    function test_SAFE_onStatusFinalized_onlyOracle() public {
        uint256 id = _bootstrapFundedInvoice();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IInvoiceFinancingPool.UnauthorizedOracle.selector, attacker));
        pool.onStatusFinalized(id, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
    }

    // -------------------------------------------------------------------------
    // Probe 14 — DEFAULT_ADMIN cannot bypass onlyInvoiceFinancingPool on vaults.
    // -------------------------------------------------------------------------
    // Hypothesis: The protocol admin (DEFAULT_ADMIN on NFT/Risk) has some backdoor into
    //             the vaults (e.g. via a role) to move NAV.
    // Attack: admin tries every vault mutator directly.
    // Result: reverts — vault gate is an immutable address check, no AccessControl role.
    // Verdict: SAFE (confirms vault privilege is NOT granted by admin; only the pool).
    function test_SAFE_admin_cannotTouchVaults() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);

        vm.startPrank(admin);
        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.writeDown(1e18);
        vm.expectRevert(SeniorPool.NotInvoiceFinancingPool.selector);
        seniorPool.fundInvoice(admin, 1e18);
        vm.expectRevert(JuniorPool.NotInvoiceFinancingPool.selector);
        juniorPool.creditAssets(1e18);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Probe 15 — financeInvoice cannot redirect funds to a third party.
    // -------------------------------------------------------------------------
    // Hypothesis: A distinct legit supplier can finance an invoice such that the advance
    //             lands somewhere other than that invoice's own supplier.
    // Attack: invoice owned by supplierA; supplierB (own separate invoice) cannot finance A's;
    //         and financing A's invoice always pays supplierA.
    // Result: cross-supplier financing reverts; advance is bound to invoice.supplier.
    // Verdict: SAFE.
    function test_SAFE_financeInvoice_noFundRedirection() public {
        _depositTranches(SENIOR_DEPOSIT, JUNIOR_DEPOSIT);
        address supplierB = makeAddr("supplierB");

        // Invoice belongs to `supplier`. supplierB attempts to finance it.
        uint256 id = _createVerifiedInvoice(FACE_VALUE, block.timestamp + INVOICE_TENOR);
        vm.prank(supplierB);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceFinancingPool.UnauthorizedFinancer.selector, id, supplierB)
        );
        pool.financeInvoice(id);

        // The rightful supplier finances; advance goes to supplier, not supplierB.
        _financeAsSupplier(id);
        assertEq(asset.balanceOf(supplierB), 0, "no redirection to third party");
        assertEq(asset.balanceOf(supplier), _expectedPrincipal(), "supplier received advance");
    }
}

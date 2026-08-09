// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness} from "./Harness.sol";
import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";
import {ReentrantToken, FeeOnTransferToken} from "./MaliciousTokens.sol";

/// @notice Sanity checks that the shared Harness deploys and drives the protocol correctly.
///         If these fail, no downstream PoC can be trusted. Not a security finding.
contract SmokeTest is Harness {
    function test_smoke_happyPathSettles() public {
        uint256 invoiceId = _bootstrapFundedInvoice();
        uint256 principal = _positionPrincipal(invoiceId);
        uint256 fee = _positionFee(invoiceId);

        assertEq(principal, _expectedPrincipal(), "principal");
        assertGt(fee, 0, "fee should be nonzero for 30d tenor");

        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.SETTLED, 0);
        _settleAsBuyer(invoiceId, principal + fee);

        assertTrue(_positionResolved(invoiceId), "resolved");
        assertEq(pool.totalLockedAssets(), 0, "locked cleared");
        assertEq(uint256(invoiceNft.getInvoice(invoiceId).status), uint256(IInvoiceNFT.InvoiceStatus.SETTLED));
    }

    function test_smoke_defaultResolves() public {
        uint256 invoiceId = _bootstrapFundedInvoice();
        _submitAndFinalizeOracleStatus(invoiceId, IInvoiceNFT.InvoiceStatus.DEFAULTED, 0);
        _resolveDefaultAsResolver(invoiceId);
        assertTrue(_positionResolved(invoiceId), "resolved");
        assertEq(pool.totalBadDebt(), _positionPrincipal(invoiceId), "bad debt = principal on zero recovery");
    }

    function test_smoke_deploysOnReentrantToken() public {
        // Re-deploy the whole protocol on an ERC777-style callback token.
        _deployProtocol(address(new ReentrantToken()));
        uint256 invoiceId = _bootstrapFundedInvoice();
        assertEq(_positionPrincipal(invoiceId), _expectedPrincipal());
    }

    function test_smoke_deploysOnFeeToken() public {
        // 1% fee-on-transfer asset. Deposit path is where it first bites; just prove deploy works.
        _deployProtocol(address(new FeeOnTransferToken(100)));
        assertEq(address(pool.ASSET()), address(asset));
    }
}

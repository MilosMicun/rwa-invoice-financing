// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";

/// @title MockInvoiceFinancingPool
/// @notice Minimal callback receiver used exclusively by InvoiceStatusOracle unit tests.
/// @dev
/// This mock implements only the callback and financing-position getter selectors
/// consumed by InvoiceStatusOracle. It is cast to IInvoiceFinancingPool during test
/// deployment to avoid coupling oracle unit tests to the full coordinator interface.
///
/// The mock records the complete finalized oracle outcome:
/// invoice identifier, terminal status, and recovered principal.
contract MockInvoiceFinancingPool {
    uint256 public lastInvoiceId;
    IInvoiceNFT.InvoiceStatus public lastStatus;
    uint256 public lastRecoveredAmount;
    uint256 public callbackCount;

    mapping(uint256 invoiceId => uint256 principal) public financedPrincipal;

    function setFinancedPrincipal(uint256 invoiceId, uint256 principal) external {
        financedPrincipal[invoiceId] = principal;
    }

    function financingPositions(uint256 invoiceId)
        external
        view
        returns (address, address, uint256, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (address(0), address(0), financedPrincipal[invoiceId], 0, 0, 0, 0, 0, false);
    }

    function onStatusFinalized(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status, uint256 recoveredAmount) external {
        lastInvoiceId = invoiceId;
        lastStatus = status;
        lastRecoveredAmount = recoveredAmount;
        callbackCount++;
    }
}

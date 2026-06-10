// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInvoiceNFT} from "../../src/interfaces/IInvoiceNFT.sol";

/// @title MockInvoiceFinancingPool
/// @notice Minimal callback receiver used exclusively by InvoiceStatusOracle unit tests.
/// @dev
/// This mock intentionally implements only the onStatusFinalized selector consumed
/// by InvoiceStatusOracle. It is cast to IInvoiceFinancingPool during test deployment
/// to avoid coupling oracle unit tests to the full protocol coordinator interface.
contract MockInvoiceFinancingPool {
    uint256 public lastInvoiceId;
    IInvoiceNFT.InvoiceStatus public lastStatus;
    uint256 public callbackCount;

    function onStatusFinalized(uint256 invoiceId, IInvoiceNFT.InvoiceStatus status) external {
        lastInvoiceId = invoiceId;
        lastStatus = status;
        callbackCount++;
    }
}

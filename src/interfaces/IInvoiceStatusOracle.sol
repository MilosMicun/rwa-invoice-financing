// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInvoiceNFT} from "./IInvoiceNFT.sol";

interface IInvoiceStatusOracle {
    struct StatusUpdate {
        uint256 invoiceId;
        IInvoiceNFT.InvoiceStatus newStatus;
        uint256 submittedAt;
        bool disputed;
        bool finalized;
    }

    error ZeroAddress();
    error InvalidDisputeWindow();
    error InvalidMaxStaleness();
    error InvalidOracleStatus(IInvoiceNFT.InvoiceStatus status);
    error InvoiceNotFunded(uint256 invoiceId, IInvoiceNFT.InvoiceStatus currentStatus);
    error StatusUpdateAlreadyActive(uint256 invoiceId);
    error StatusUpdateDoesNotExist(uint256 invoiceId);
    error StatusUpdateDisputed(uint256 invoiceId);
    error StatusUpdateAlreadyFinalized(uint256 invoiceId);
    error DisputeWindowNotElapsed(uint256 invoiceId, uint256 earliestFinalizeAt);
    error DisputeWindowElapsed(uint256 invoiceId);
    error StatusUpdateStale(uint256 invoiceId, uint256 staleAfter);

    event StatusSubmitted(
        uint256 indexed invoiceId,
        IInvoiceNFT.InvoiceStatus indexed newStatus,
        address indexed submitter,
        uint256 submittedAt
    );

    event StatusDisputed(
        uint256 indexed invoiceId, IInvoiceNFT.InvoiceStatus indexed disputedStatus, address indexed disputer
    );

    event StatusFinalized(
        uint256 indexed invoiceId, IInvoiceNFT.InvoiceStatus indexed finalizedStatus, address indexed finalizer
    );

    function submitStatus(uint256 invoiceId, IInvoiceNFT.InvoiceStatus newStatus) external;

    function disputeStatus(uint256 invoiceId) external;

    function finalize(uint256 invoiceId) external;

    function getStatusUpdate(uint256 invoiceId) external view returns (StatusUpdate memory);

    function disputeWindow() external view returns (uint256);

    function maxStaleness() external view returns (uint256);
}

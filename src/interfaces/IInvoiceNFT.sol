// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInvoiceNFT {
    enum InvoiceStatus {
        CREATED,
        VERIFIED,
        FUNDED,
        SETTLED,
        DEFAULTED,
        FROZEN
    }

    struct Invoice {
        address supplier;
        address buyer;
        uint256 faceValue;
        uint256 dueDate;
        uint256 fundedAt;
        InvoiceStatus status;
        InvoiceStatus previousStatus;
    }

    error ZeroAddress();
    error InvalidFaceValue();
    error InvalidDueDate();
    error InvoiceDoesNotExist(uint256 invoiceId);
    error InvalidStatus(uint256 invoiceId, InvoiceStatus current, InvoiceStatus expected);
    error InvalidFreezeStatus(uint256 invoiceId, InvoiceStatus current);
    error InvoiceNotFrozen(uint256 invoiceId);
    error TransfersDisabled();

    event InvoiceCreated(
        uint256 indexed invoiceId, address indexed supplier, address indexed buyer, uint256 faceValue, uint256 dueDate
    );
    event InvoiceVerified(uint256 indexed invoiceId);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAt);
    event InvoiceSettled(uint256 indexed invoiceId);
    event InvoiceDefaulted(uint256 indexed invoiceId);

    event InvoiceFrozen(uint256 indexed invoiceId, InvoiceStatus previousStatus);

    event InvoiceUnfrozen(uint256 indexed invoiceId, InvoiceStatus restoredStatus);

    function createInvoice(address supplier, address buyer, uint256 faceValue, uint256 dueDate)
        external
        returns (uint256 invoiceId);

    function verify(uint256 invoiceId) external;

    function markFunded(uint256 invoiceId) external;

    function markSettled(uint256 invoiceId) external;

    function markDefaulted(uint256 invoiceId) external;

    function freezeInvoice(uint256 invoiceId) external;

    function unfreezeInvoice(uint256 invoiceId) external;

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory);
}

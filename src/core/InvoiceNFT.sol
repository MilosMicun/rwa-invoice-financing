// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IInvoiceNFT} from "../interfaces/IInvoiceNFT.sol";

/// @title InvoiceNFT
/// @notice Non-transferable ERC721 registry for tokenized invoice receivable claims.
/// @dev
/// InvoiceNFT is the lifecycle source of truth for invoice claims.
/// It does not hold pooled liquidity, execute waterfall accounting, or recognize pool-level bad debt.
/// Those responsibilities belong to InvoiceFinancingPool and the pool accounting layer.
///
/// In v1, invoice NFTs are intentionally non-transferable because secondary trading is out of scope.
/// ERC721 is used for unique invoice identity and claim ownership, not for marketplace transferability.
contract InvoiceNFT is ERC721, AccessControl, IInvoiceNFT {
    /// @notice Role allowed to create invoice registry entries after off-chain invoice intake.
    bytes32 public constant ORIGINATOR_ROLE = keccak256("ORIGINATOR_ROLE");

    /// @notice Role allowed to verify invoice eligibility before pool funding.
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    /// @notice Role allowed to perform operational/legal risk actions such as freeze and unfreeze.
    bytes32 public constant RISK_ROLE = keccak256("RISK_ROLE");

    /// @notice Role allowed to execute accounting-driven lifecycle transitions.
    bytes32 public constant POOL_ROLE = keccak256("POOL_ROLE");

    uint256 private nextInvoiceId;

    mapping(uint256 => Invoice) private invoices;

    /// @notice Initializes the invoice registry and assigns the default admin role.
    /// @param admin Address that receives DEFAULT_ADMIN_ROLE and can grant/revoke protocol roles.
    constructor(address admin) ERC721("RWA Invoice Claim", "INV") {
        if (admin == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        nextInvoiceId = 1;
    }

    /// @notice Returns whether this contract supports a given interface.
    /// @dev Required because both ERC721 and AccessControl implement supportsInterface.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Creates a new invoice claim NFT in CREATED state.
    /// @dev
    /// Callable only by ORIGINATOR_ROLE.
    /// This function registers the invoice identity and mints a non-transferable ERC721 claim to the supplier.
    /// It does not verify eligibility, fund the invoice, or move liquidity.
    ///
    /// Uses _safeMint so supplier contracts must explicitly support ERC721 receiving.
    ///
    /// @param supplier Original creditor of the invoice receivable.
    /// @param buyer Off-chain payment obligor associated with the invoice.
    /// @param faceValue Nominal invoice amount owed by the buyer.
    /// @param dueDate Unix timestamp when the invoice is expected to mature.
    /// @return invoiceId Newly assigned invoice identifier and ERC721 tokenId.
    function createInvoice(address supplier, address buyer, uint256 faceValue, uint256 dueDate)
        external
        onlyRole(ORIGINATOR_ROLE)
        returns (uint256 invoiceId)
    {
        if (supplier == address(0) || buyer == address(0)) {
            revert ZeroAddress();
        }

        if (faceValue == 0) {
            revert InvalidFaceValue();
        }

        if (dueDate <= block.timestamp) {
            revert InvalidDueDate();
        }

        invoiceId = nextInvoiceId;
        nextInvoiceId++;

        invoices[invoiceId] = Invoice({
            supplier: supplier,
            buyer: buyer,
            faceValue: faceValue,
            dueDate: dueDate,
            fundedAt: 0,
            status: InvoiceStatus.CREATED,
            previousStatus: InvoiceStatus.CREATED // Placeholder; meaningful only after freezeInvoice().
        });

        _safeMint(supplier, invoiceId);

        emit InvoiceCreated(invoiceId, supplier, buyer, faceValue, dueDate);
    }

    /// @notice Moves an invoice from CREATED to VERIFIED.
    /// @dev
    /// Callable only by VERIFIER_ROLE.
    /// Verification confirms that the invoice is eligible for financing.
    /// No liquidity is moved and no accounting state is changed.
    ///
    /// @param invoiceId Invoice identifier to verify.
    function verify(uint256 invoiceId) external onlyRole(VERIFIER_ROLE) {
        _requireInvoiceExists(invoiceId);

        Invoice storage invoice = invoices[invoiceId];

        if (invoice.status != InvoiceStatus.CREATED) {
            revert InvalidStatus(invoiceId, invoice.status, InvoiceStatus.CREATED);
        }

        invoice.status = InvoiceStatus.VERIFIED;

        emit InvoiceVerified(invoiceId);
    }

    /// @notice Moves an invoice from VERIFIED to FUNDED.
    /// @dev
    /// Callable only by POOL_ROLE.
    /// This transition records the funding timestamp and prevents double financing
    /// because only VERIFIED invoices can become FUNDED.
    ///
    /// @param invoiceId Invoice identifier to mark as funded.
    function markFunded(uint256 invoiceId) external onlyRole(POOL_ROLE) {
        _requireInvoiceExists(invoiceId);

        Invoice storage invoice = invoices[invoiceId];

        if (invoice.status != InvoiceStatus.VERIFIED) {
            revert InvalidStatus(invoiceId, invoice.status, InvoiceStatus.VERIFIED);
        }

        uint256 fundedAt = block.timestamp;

        invoice.status = InvoiceStatus.FUNDED;
        invoice.fundedAt = fundedAt;

        emit InvoiceFunded(invoiceId, fundedAt);
    }

    /// @notice Moves an invoice from FUNDED to SETTLED.
    /// @dev
    /// Callable only by POOL_ROLE.
    /// SETTLED is a terminal state. Settlement and default are mutually exclusive
    /// because both transitions require the invoice to still be in FUNDED state.
    ///
    /// @param invoiceId Invoice identifier to mark as settled.
    function markSettled(uint256 invoiceId) external onlyRole(POOL_ROLE) {
        _requireInvoiceExists(invoiceId);

        Invoice storage invoice = invoices[invoiceId];

        if (invoice.status != InvoiceStatus.FUNDED) {
            revert InvalidStatus(invoiceId, invoice.status, InvoiceStatus.FUNDED);
        }

        invoice.status = InvoiceStatus.SETTLED;

        emit InvoiceSettled(invoiceId);
    }

    /// @notice Moves an invoice from FUNDED to DEFAULTED.
    /// @dev
    /// Callable only by POOL_ROLE.
    /// DEFAULTED is a terminal state. Default is an explicit pool/accounting decision,
    /// not an automatic consequence of dueDate passing.
    ///
    /// @param invoiceId Invoice identifier to mark as defaulted.
    function markDefaulted(uint256 invoiceId) external onlyRole(POOL_ROLE) {
        _requireInvoiceExists(invoiceId);

        Invoice storage invoice = invoices[invoiceId];

        if (invoice.status != InvoiceStatus.FUNDED) {
            revert InvalidStatus(invoiceId, invoice.status, InvoiceStatus.FUNDED);
        }

        invoice.status = InvoiceStatus.DEFAULTED;

        emit InvoiceDefaulted(invoiceId);
    }

    /// @notice Freezes an invoice from VERIFIED or FUNDED state.
    /// @dev
    /// Callable only by RISK_ROLE.
    /// FROZEN is an operational/legal overlay, not a terminal financial state.
    /// Freeze preserves the previous financial state and does not change any accounting fields.
    ///
    /// @param invoiceId Invoice identifier to freeze.
    function freezeInvoice(uint256 invoiceId) external onlyRole(RISK_ROLE) {
        _requireInvoiceExists(invoiceId);

        Invoice storage invoice = invoices[invoiceId];
        InvoiceStatus currentStatus = invoice.status;

        if (currentStatus != InvoiceStatus.VERIFIED && currentStatus != InvoiceStatus.FUNDED) {
            revert InvalidFreezeStatus(invoiceId, currentStatus);
        }

        invoice.previousStatus = currentStatus;
        invoice.status = InvoiceStatus.FROZEN;

        emit InvoiceFrozen(invoiceId, currentStatus);
    }

    /// @notice Restores a frozen invoice to its preserved previous financial state.
    /// @dev
    /// Callable only by RISK_ROLE.
    /// Unfreeze does not change supplier, buyer, faceValue, dueDate, fundedAt, or accounting fields.
    ///
    /// @param invoiceId Invoice identifier to unfreeze.
    function unfreezeInvoice(uint256 invoiceId) external onlyRole(RISK_ROLE) {
        _requireInvoiceExists(invoiceId);

        Invoice storage invoice = invoices[invoiceId];

        if (invoice.status != InvoiceStatus.FROZEN) {
            revert InvoiceNotFrozen(invoiceId);
        }

        InvoiceStatus restoredStatus = invoice.previousStatus;
        invoice.status = restoredStatus;

        emit InvoiceUnfrozen(invoiceId, restoredStatus);
    }

    /// @notice Returns the stored invoice data for an existing invoice.
    /// @dev Reverts for nonexistent invoices instead of returning default mapping values.
    /// @param invoiceId Invoice identifier to read.
    /// @return Invoice struct containing supplier, buyer, face value, due date, funding timestamp, status, and previous status.
    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        _requireInvoiceExists(invoiceId);

        return invoices[invoiceId];
    }

    /// @dev Allows minting only. Transfers and burns are disabled in v1.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        if (from != address(0)) {
            revert TransfersDisabled();
        }

        return super._update(to, tokenId, auth);
    }

    /// @notice Approvals are disabled because invoice NFTs are non-transferable in v1.
    function approve(address, uint256) public pure override {
        revert TransfersDisabled();
    }

    /// @notice Operator approvals are disabled because invoice NFTs are non-transferable in v1.
    function setApprovalForAll(address, bool) public pure override {
        revert TransfersDisabled();
    }

    /// @dev Reverts if invoiceId does not map to a minted invoice NFT.
    function _requireInvoiceExists(uint256 invoiceId) internal view {
        if (_ownerOf(invoiceId) == address(0)) {
            revert InvoiceDoesNotExist(invoiceId);
        }
    }
}

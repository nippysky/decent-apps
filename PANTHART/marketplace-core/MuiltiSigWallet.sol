// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PanthartMultiSignatureWallet is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------- Owners & Requirement ----------------------

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public required;

    uint256 public constant MAX_OWNERS = 50;

    // --------------------------- Transactions -------------------------

    struct Transaction {
        address tokenAddress; 
        address to; 
        uint256 value; 
        bool executed; 
        uint256 confirmations;
        bytes data; 
    }

    mapping(uint256 => mapping(address => bool)) public confirmations;
    Transaction[] public transactions;

    // ----------------------------- Modifiers --------------------------

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier txExists(uint256 txIndex) {
        if (txIndex >= transactions.length) revert TransactionDoesNotExist();
        _;
    }

    modifier notExecuted(uint256 txIndex) {
        if (transactions[txIndex].executed) revert TransactionAlreadyExecuted();
        _;
    }

    modifier notConfirmed(uint256 txIndex) {
        if (confirmations[txIndex][msg.sender]) revert TransactionAlreadyConfirmed();
        _;
    }

    /// @dev Calls restricted to the wallet itself (i.e., via a multisig-approved self-call).
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    // ------------------------------ Events ----------------------------

    event Deposit(address indexed sender, uint256 value);
    event SubmitTransaction(address indexed owner, uint256 indexed txIndex, address indexed to, uint256 value, address tokenAddress, bytes data);
    event ConfirmTransaction(address indexed owner, uint256 indexed txIndex);
    event RevokeConfirmation(address indexed owner, uint256 indexed txIndex);
    event ExecuteTransaction(address indexed executor, uint256 indexed txIndex);
    event ExecuteWithSignatures(address indexed executor, uint256 indexed txIndex, address[] signers);

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event OwnerReplaced(address indexed oldOwner, address indexed newOwner);
    event RequirementChanged(uint256 required);

    // ------------------------------ Errors ----------------------------

    error NotOwner();
    error OnlySelf();
    error InvalidOwners();
    error InvalidRequiredConfirmations();
    error TransactionDoesNotExist();
    error TransactionNotConfirmed();
    error TransactionAlreadyExecuted();
    error TransactionAlreadyConfirmed();
    error InsufficientConfirmations();
    error TransferFailed();
    error DuplicateSigner();
    error NotAnOwner();
    error SignatureExpired();
    error TooManyOwners();

    // ---------------------------- EIP-712 -----------------------------

    // keccak256("Confirm(uint256 txIndex,address wallet,bytes32 txFieldsHash,uint256 deadline)")
    bytes32 private constant _CONFIRM_TYPEHASH =
        keccak256("Confirm(uint256 txIndex,address wallet,bytes32 txFieldsHash,uint256 deadline)");

    constructor(address[] memory _owners, uint256 _required)
        EIP712("MultisigWallet", "1")
    {
        _initOwners(_owners, _required);
    }

    // ---------------------------- Payable -----------------------------

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    fallback() external payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value);
        }
    }

    // ----------------------- Owner Set Management ---------------------

    function _initOwners(address[] memory _owners, uint256 _required) internal {
        uint256 len = _owners.length;
        if (len == 0 || len > MAX_OWNERS) revert InvalidOwners();
        if (_required == 0 || _required > len) revert InvalidRequiredConfirmations();

        for (uint256 i = 0; i < len; i++) {
            address owner = _owners[i];
            if (owner == address(0) || isOwner[owner]) revert InvalidOwners();
            isOwner[owner] = true;
            owners.push(owner);
        }
        required = _required;
    }

    /// @notice Add a new owner. Must be called by the wallet itself.
    function addOwner(address newOwner) external onlySelf {
        if (newOwner == address(0) || isOwner[newOwner]) revert InvalidOwners();
        if (owners.length + 1 > MAX_OWNERS) revert TooManyOwners();
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);
        if (required > owners.length) {
            required = owners.length;
            emit RequirementChanged(required);
        }
    }

    /// @notice Remove an owner. Must be called by the wallet itself.
    function removeOwner(address owner) external onlySelf {
        if (!isOwner[owner]) revert InvalidOwners();
        isOwner[owner] = false;

        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[len - 1];
                owners.pop();
                break;
            }
        }

        emit OwnerRemoved(owner);

        if (required > owners.length) {
            required = owners.length;
            emit RequirementChanged(required);
        }
    }

    /// @notice Replace an owner with a new one. Must be called by the wallet itself.
    function replaceOwner(address owner, address newOwner) external onlySelf {
        if (!isOwner[owner]) revert InvalidOwners();
        if (newOwner == address(0) || isOwner[newOwner]) revert InvalidOwners();

        isOwner[owner] = false;
        isOwner[newOwner] = true;

        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (owners[i] == owner) {
                owners[i] = newOwner;
                break;
            }
        }

        emit OwnerReplaced(owner, newOwner);
    }

    /// @notice Change number of required confirmations. Must be called by the wallet itself.
    function changeRequirement(uint256 _required) external onlySelf {
        if (_required == 0 || _required > owners.length) revert InvalidRequiredConfirmations();
        required = _required;
        emit RequirementChanged(_required);
    }

    // ----------------------- Transaction Lifecycle --------------------

    function submitTransaction(
        address tokenAddress,
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (uint256 txIndex) {
        txIndex = _submitTransaction(tokenAddress, to, value, data);
        emit SubmitTransaction(msg.sender, txIndex, to, value, tokenAddress, data);
    }

    /// @notice Convenience: submit then immediately confirm in one call.
    function submitAndConfirm(
        address tokenAddress,
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (uint256 txIndex) {
        txIndex = _submitTransaction(tokenAddress, to, value, data);
        emit SubmitTransaction(msg.sender, txIndex, to, value, tokenAddress, data);
        _confirmTransaction(txIndex, msg.sender);
        if (transactions[txIndex].confirmations >= required) {
            _executeTransaction(txIndex);
        }
    }

    function _submitTransaction(
        address tokenAddress,
        address to,
        uint256 value,
        bytes calldata data
    ) internal returns (uint256 txIndex) {
        txIndex = transactions.length;
        transactions.push(
            Transaction({
                tokenAddress: tokenAddress,
                to: to,
                value: value,
                executed: false,
                confirmations: 0,
                data: data
            })
        );
    }

    function confirmTransaction(uint256 txIndex)
        external
        onlyOwner
        txExists(txIndex)
        notExecuted(txIndex)
        notConfirmed(txIndex)
    {
        _confirmTransaction(txIndex, msg.sender);
        if (transactions[txIndex].confirmations >= required) {
            _executeTransaction(txIndex);
        }
    }

    function _confirmTransaction(uint256 txIndex, address ownerAddr) internal {
        confirmations[txIndex][ownerAddr] = true;
        transactions[txIndex].confirmations += 1;
        emit ConfirmTransaction(ownerAddr, txIndex);
    }

    function revokeConfirmation(uint256 txIndex)
        external
        onlyOwner
        txExists(txIndex)
        notExecuted(txIndex)
    {
        if (!confirmations[txIndex][msg.sender]) revert TransactionNotConfirmed();
        confirmations[txIndex][msg.sender] = false;
        transactions[txIndex].confirmations -= 1;
        emit RevokeConfirmation(msg.sender, txIndex);
    }

    function executeTransaction(uint256 txIndex)
        external
        onlyOwner
        txExists(txIndex)
        notExecuted(txIndex)
        nonReentrant
    {
        if (transactions[txIndex].confirmations < required) revert InsufficientConfirmations();
        _executeTransaction(txIndex);
    }

    function _executeTransaction(uint256 txIndex) internal {
        Transaction storage txn = transactions[txIndex];
        txn.executed = true;

        if (txn.tokenAddress == address(0)) {
            (bool ok, ) = txn.to.call{value: txn.value}(txn.data);
            if (!ok) revert TransferFailed();
        } else {
            IERC20(txn.tokenAddress).safeTransfer(txn.to, txn.value);
            if (txn.data.length > 0) {
                (bool ok, ) = txn.to.call(txn.data);
                if (!ok) revert TransferFailed();
            }
        }

        emit ExecuteTransaction(msg.sender, txIndex);
    }

    // ---------------------- Off-chain Signatures -----------------------

    /// @notice Execute using off-chain owner signatures (no on-chain confirm storage).
    /// @param txIndex Transaction index to execute.
    /// @param signers Owner addresses corresponding to signatures (must be unique).
    /// @param signatures EIP-712 signatures by those owners over the Confirm struct.
    /// @param deadline Timestamp after which signatures are invalid.
    function executeWithSignatures(
        uint256 txIndex,
        address[] calldata signers,
        bytes[] calldata signatures,
        uint256 deadline
    )
        external
        txExists(txIndex)
        notExecuted(txIndex)
        nonReentrant
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (signers.length != signatures.length) revert InvalidOwners();

        bytes32 digest = _confirmDigest(txIndex, deadline);

        // Ownership, uniqueness, and signature checks
        for (uint256 i = 0; i < signers.length; i++) {
            address s = signers[i];
            if (!isOwner[s]) revert NotAnOwner();

            // ensure uniqueness among provided signers
            for (uint256 j = 0; j < i; j++) {
                if (signers[j] == s) revert DuplicateSigner();
            }

            address recovered = ECDSA.recover(digest, signatures[i]);
            if (recovered != s) revert NotAnOwner();
        }

        if (signers.length < required) revert InsufficientConfirmations();

        _executeTransaction(txIndex);

        emit ExecuteWithSignatures(msg.sender, txIndex, signers);
    }

function txFieldsHash(uint256 txIndex)
    public
    view
    txExists(txIndex)
    returns (bytes32)
{
    Transaction storage t = transactions[txIndex];
    return keccak256(abi.encode(t.tokenAddress, t.to, t.value, keccak256(t.data)));
}

    function confirmDigest(uint256 txIndex, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _confirmDigest(txIndex, deadline);
    }

    function _confirmDigest(uint256 txIndex, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(
                abi.encode(
                    _CONFIRM_TYPEHASH,
                    txIndex,
                    address(this),
                    txFieldsHash(txIndex),
                    deadline
                )
            );
        return _hashTypedDataV4(structHash);
    }

    // ------------------------------ Views ------------------------------

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function getTransaction(uint256 txIndex)
        external
        view
        txExists(txIndex)
        returns (
            address tokenAddress,
            address to,
            uint256 value,
            bool executed,
            uint256 confirmationsCount,
            bytes memory data
        )
    {
        Transaction storage txn = transactions[txIndex];
        return (txn.tokenAddress, txn.to, txn.value, txn.executed, txn.confirmations, txn.data);
    }

    function isConfirmed(uint256 txIndex, address ownerAddr)
        external
        view
        returns (bool)
    {
        return confirmations[txIndex][ownerAddr];
    }
}

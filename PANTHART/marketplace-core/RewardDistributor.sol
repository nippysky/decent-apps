// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712}          from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA}           from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RewardsDistributor
 * @notice Multi-currency pull distributor using EIP-712 signed cumulative caps.
 *         - Admin (DEFAULT_ADMIN_ROLE) manages signer, pause, and rescue.
 *         - Signer authorizes cumulative claim caps per (account, token).
 *         - Users claim up to their signed total; contract tracks amounts paid.
 */
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");

    // keccak256("Claim(address account,address token,uint256 total,uint256 deadline)")
    bytes32 private constant _CLAIM_TYPEHASH =
        keccak256("Claim(address account,address token,uint256 total,uint256 deadline)");

    address public signer; // EOA that signs claims off-chain

    // account => token => already claimed amount
    mapping(address => mapping(address => uint256)) public claimed;

    event SignerUpdated(address indexed newSigner);
    event Funded(address indexed token, address indexed from, uint256 amount);
    event Claimed(address indexed token, address indexed account, uint256 paid, uint256 newTotal);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error BadParams();
    error SignatureExpired();
    error InvalidSigner();
    error NothingToClaim();
    error InsufficientLiquidity();

    constructor(address admin, address initialSigner)
        EIP712("RewardsDistributor", "1")
    {
        require(admin != address(0), "admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FUNDER_ROLE, admin);
        if (initialSigner != address(0)) {
            signer = initialSigner;
            emit SignerUpdated(initialSigner);
        }
    }

    // --------------------- Admin / Config ---------------------

    function setSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        signer = newSigner;
        emit SignerUpdated(newSigner);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // ------------------------ Funding ------------------------

    /// Deposit native ETN.
    function depositNative() external payable whenNotPaused onlyRole(FUNDER_ROLE) {
        require(msg.value > 0, "no-value");
        emit Funded(address(0), msg.sender, msg.value);
    }

    /// Deposit ERC20; caller must approve this contract beforehand.
    function depositERC20(address token, uint256 amount)
        external
        whenNotPaused
        onlyRole(FUNDER_ROLE)
    {
        require(token != address(0) && amount > 0, "bad-deposit");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(token, msg.sender, amount);
    }

    // ------------------------ Claiming ------------------------

    /**
     * Claim up to a signed cumulative total for a given token.
     * token = address(0) for native ETN, otherwise ERC20.
     */
    function claim(
        address token,
        uint256 total,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        _claimTo(msg.sender, token, total, deadline, signature);
    }

    /// Batch version of `claim`.
    function claimMany(
        address[] calldata tokens,
        uint256[] calldata totals,
        uint256[] calldata deadlines,
        bytes[] calldata signatures
    ) external whenNotPaused nonReentrant {
        uint256 n = tokens.length;
        if (n == 0 || n != totals.length || n != deadlines.length || n != signatures.length) revert BadParams();
        for (uint256 i = 0; i < n; i++) {
            _claimTo(msg.sender, tokens[i], totals[i], deadlines[i], signatures[i]);
        }
    }

    function _claimTo(
        address account,
        address token,
        uint256 total,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (signer == address(0)) revert InvalidSigner();

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(_CLAIM_TYPEHASH, account, token, total, deadline));
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (recovered != signer) revert InvalidSigner();

        uint256 already = claimed[account][token];
        if (total <= already) revert NothingToClaim();
        uint256 pay = total - already;

        // Effects
        claimed[account][token] = total;

        // Interactions
        if (token == address(0)) {
            (bool ok, ) = account.call{value: pay}("");
            if (!ok) revert InsufficientLiquidity();
        } else {
            IERC20(token).safeTransfer(account, pay);
        }

        emit Claimed(token, account, pay, total);
    }

    // ------------------------- Views -------------------------

    /// How much is still claimable given a signed total.
    function claimable(address account, address token, uint256 signedTotal) external view returns (uint256) {
        uint256 already = claimed[account][token];
        return signedTotal > already ? (signedTotal - already) : 0;
    }

    // ------------------------- Rescue ------------------------

    /// Admin rescue native ETN or ERC20 (e.g., sweep to treasury).
    function rescue(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(to != address(0) && amount > 0, "bad-rescue");
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "native-send-failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    // ------------------------- Receive -----------------------

    receive() external payable {
        emit Funded(address(0), msg.sender, msg.value);
    }

    fallback() external payable {
        if (msg.value > 0) {
            emit Funded(address(0), msg.sender, msg.value);
        }
    }
}

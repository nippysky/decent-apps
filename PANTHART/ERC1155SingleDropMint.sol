// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title  ERC1155DropSingleToken (Cloneable)
/// @notice Cloneable 1-of-1 ERC-1155 drop with configurable supply, price, per-wallet cap,
///         immutable royalties, and one-time deployment fee.
contract ERC1155DropSingleToken is
    Initializable,
    ERC1155Upgradeable,
    ERC1155URIStorageUpgradeable,
    ERC2981Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    /// @dev Always 1 for this single-token drop
    uint256 public constant TOKEN_ID = 1;

    /// @notice Human-readable name
    string public name;
    /// @notice Short symbol
    string public symbol;

    /// @notice Maximum supply cap
    uint256 public maxSupply;
    /// @notice Price per token (wei)
    uint256 public mintPrice;
    /// @notice Per-wallet mint cap
    uint256 public maxPerWallet;
    /// @notice Base metadata URI (no trailing slash)
    string private baseTokenURI;

    /// @notice How many minted so far
    uint256 public totalMinted;
    /// @notice Per-wallet mint tracking
    mapping(address => uint256) public mintedPerWallet;

    /// @notice One-time deployment fee
    uint256 public deploymentFee;

    /// @notice Emitted on each mint
    event DropMinted(address indexed minter, uint256 indexed tokenId, uint256 quantity, string uri);
    /// @notice Emitted when owner withdraws contract balance
    event ProceedsWithdrawn(address indexed to, uint256 amount);
    /// @notice Emitted once on initialization
    event Initialized(address indexed owner, uint256 maxSupply, uint256 mintPrice, uint256 maxPerWallet);

    /// @notice Parameters for clone initialization
    struct Config {
        string   name;
        string   symbol;
        string   baseURI;          // ipfs://<CID> (NO trailing slash)
        uint256  maxSupply;
        uint256  mintPrice;
        uint256  maxPerWallet;
        address payable feeRecipient;
        uint256  feeAmount;
        address  royaltyRecipient;
        uint96   royaltyBps;       // <= 1000 (10%)
        address  initialOwner;     // injected by factory (deployer)
    }

    /// @notice Initialize the clone with its configuration. Call exactly once.
    function initialize(Config calldata cfg) external payable initializer {
        // --- OZ initializers ---
        __ERC1155_init("");
        __ERC2981_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        // --- Validate & store parameters ---
        require(bytes(cfg.name).length != 0,           "Name required");
        require(bytes(cfg.symbol).length != 0,         "Symbol required");
        require(bytes(cfg.baseURI).length != 0,        "BaseURI required");
        // enforce NO trailing slash to avoid ipfs://CID//1.json
        bytes memory b = bytes(cfg.baseURI);
        require(b[b.length - 1] != "/",                "No trailing slash");
        require(cfg.maxSupply > 0,                     "Supply>0");
        require(cfg.mintPrice > 0,                     "Price>0");
        require(cfg.maxPerWallet > 0,                  "Per-wallet>0");
        require(cfg.feeRecipient != address(0),        "Bad fee recipient");
        require(cfg.royaltyRecipient != address(0),    "Bad royalty recipient");
        require(cfg.royaltyBps <= 1000,                "Royalty<=10%");
        require(msg.value == cfg.feeAmount,            "Fee mismatch");

        // Ownership: set to injected owner if provided
        if (cfg.initialOwner != address(0) && cfg.initialOwner != owner()) {
            _transferOwnership(cfg.initialOwner);
        }

        name           = cfg.name;
        symbol         = cfg.symbol;
        baseTokenURI   = cfg.baseURI;
        maxSupply      = cfg.maxSupply;
        mintPrice      = cfg.mintPrice;
        maxPerWallet   = cfg.maxPerWallet;
        deploymentFee  = cfg.feeAmount;

        // --- Forward deployment fee ---
        (bool sent,) = cfg.feeRecipient.call{ value: cfg.feeAmount }("");
        require(sent, "Fee xfer failed");

        // --- Immutable royalties ---
        _setDefaultRoyalty(cfg.royaltyRecipient, cfg.royaltyBps);

        // --- Set token metadata URI for TOKEN_ID ---
        // uri(1) => baseTokenURI + "/1.json"
        _setURI(TOKEN_ID, string.concat(baseTokenURI, "/1.json"));

        emit Initialized(owner(), cfg.maxSupply, cfg.mintPrice, cfg.maxPerWallet);
    }

    /// @notice Public mint function
    function mint(uint256 quantity) external payable nonReentrant {
        require(quantity > 0,                              "Qty>0");
        require(totalMinted + quantity <= maxSupply,      "Exceeds supply");
        require(
            mintedPerWallet[msg.sender] + quantity <= maxPerWallet,
            "Exceeds per-wallet"
        );
        require(msg.value == quantity * mintPrice,        "Wrong value");

        unchecked {
            totalMinted += quantity;
            mintedPerWallet[msg.sender] += quantity;
        }

        _mint(msg.sender, TOKEN_ID, quantity, "");
        string memory uri_ = uri(TOKEN_ID);
        emit DropMinted(msg.sender, TOKEN_ID, quantity, uri_);
    }

    /// @notice Withdraw any residual ETH
    function withdrawProceeds(address payable to) external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "No funds");
        (bool sent,) = to.call{ value: bal }("");
        require(sent, "Withdraw failed");
        emit ProceedsWithdrawn(to, bal);
    }

    // ───── Overrides ─────────────────────────────────────────────────────────

    function uri(uint256 tokenId)
        public
        view
        override(ERC1155Upgradeable, ERC1155URIStorageUpgradeable)
        returns (string memory)
    {
        require(tokenId == TOKEN_ID, "Invalid tokenId");
        return super.uri(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

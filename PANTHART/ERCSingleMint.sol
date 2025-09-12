// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title  ERC721SingleMint (Cloneable)
/// @notice Cloneable 1-of-1 ERC-721 with immutable royalties and one-time deployment fee.
contract ERC721SingleMint is
    Initializable,
    ERC721URIStorageUpgradeable,
    ERC2981Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    /// @notice Wei forwarded as the one-time deployment fee
    uint256 public deploymentFee;

    /// @notice Emitted once the single NFT is minted
    event SingleMinted(address indexed to, uint256 indexed tokenId, string uri);
    /// @notice Emitted after successful initialize
    event SingleInitialized(address indexed owner, string name, string symbol);

    /// @notice Parameters for initialization
    struct SingleConfig {
        string  name;               // ERC-721 name (non-empty)
        string  symbol;             // ERC-721 symbol (non-empty)
        string  tokenURI;           // Metadata URI for token #1 (non-empty)
        address payable feeRecipient; // Where to forward the fee (non-zero)
        uint256 feeAmount;          // Exact wei required on init
        address royaltyRecipient;   // Immutable royalty recipient (non-zero)
        uint96  royaltyBps;         // Immutable royalty bps (<=1000 i.e. 10%)
        address initialOwner;       // Injected by factory (deployer)
    }

    /// @notice Initialize the clone. Call once.
    function initialize(SingleConfig calldata cfg) external payable initializer {
        // --- OZ initializers ---
        __ERC721_init(cfg.name, cfg.symbol);
        __ERC2981_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        // --- Validate inputs ---
        require(bytes(cfg.name).length != 0,               "Name required");
        require(bytes(cfg.symbol).length != 0,             "Symbol required");
        require(bytes(cfg.tokenURI).length != 0,           "tokenURI required");
        require(cfg.feeRecipient != address(0),            "Bad fee recipient");
        require(cfg.royaltyRecipient != address(0),        "Bad royalty recipient");
        require(cfg.royaltyBps <= 1000,                    "Royalty<=10%");
        require(msg.value == cfg.feeAmount,                "Fee mismatch");

        // --- Ownership: set to injected owner if provided ---
        if (cfg.initialOwner != address(0) && cfg.initialOwner != owner()) {
            _transferOwnership(cfg.initialOwner);
        }

        // --- Store and forward deployment fee ---
        deploymentFee = cfg.feeAmount;
        (bool sent,) = cfg.feeRecipient.call{value: cfg.feeAmount}("");
        require(sent, "Fee xfer failed");

        // --- Immutable royalties ---
        _setDefaultRoyalty(cfg.royaltyRecipient, cfg.royaltyBps);

        // --- Mint the single token (ID = 1) to OWNER ---
        address to = owner();
        _safeMint(to, 1);
        _setTokenURI(1, cfg.tokenURI);
        emit SingleMinted(to, 1, cfg.tokenURI);
        emit SingleInitialized(to, cfg.name, cfg.symbol);
    }

    // ----------------------------------------------------------------------------
    //                            Token URI Override
    // ----------------------------------------------------------------------------

    /// @notice Returns metadata URI for token #1; reverts otherwise
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        // OZ v5 `_requireOwned` is internal; `ownerOf` reverts for non-existent
        ownerOf(tokenId);
        return super.tokenURI(tokenId);
    }

    // ----------------------------------------------------------------------------
    //                          Withdraw Residual ETH
    // ----------------------------------------------------------------------------

    /// @notice Withdraw any stray ETH (should normally be zero)
    function withdraw(address payable to) external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "No funds");
        (bool sent,) = to.call{value: bal}("");
        require(sent, "Withdraw failed");
    }

    // ----------------------------------------------------------------------------
    //                         ERC165 / Interface Detection
    // ----------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorageUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

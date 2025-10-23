// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";

contract PanthartERC721Drop is
    Initializable,
    ERC721Upgradeable,
    ERC2981Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using StringsUpgradeable for uint256;

    // ───────────────────────────── Config ─────────────────────────────

    struct DropConfig {
        string name;     
        string symbol; 
        string baseURI;              // ipfs://<CID> (NO trailing slash)
        uint256 maxSupply; 
        address payable feeRecipient;
        uint256 feeAmount; 
        address royaltyRecipient; 
        uint96  royaltyBps; 
        address initialOwner; 
    }

    struct PublicSaleConfig {
        uint256 startTimestamp;   
        uint256 price;       
        uint256 maxPerWallet; 
        uint256 maxPerTx; 
    }

    struct PresaleConfig {
        uint256 startTimestamp; 
        uint256 endTimestamp; 
        uint256 price; 
        uint256 maxSupply; 
        bytes32 merkleRoot;
    }

    // ─────────────────────────── Storage ─────────────────────────────

    uint256 public maxSupply;
    string  private baseTokenURI;

    PublicSaleConfig public publicSale;
    PresaleConfig    public presale;

    uint256 public totalMinted;
    uint256 public presaleMinted;
    mapping(address => uint256) public mintedPerWallet;

    // ─────────────────────────── Events ──────────────────────────────
    event DropInitialized(address indexed owner, string name, string symbol);
    event DropMinted(address indexed minter, uint256 indexed tokenId, string uri);
    event ProceedsWithdrawn(address indexed to, uint256 amount);

    // ───────────────────────── Initializer ───────────────────────────

    function initialize(
        DropConfig calldata cfg,
        PublicSaleConfig calldata pubConfig,
        PresaleConfig calldata presaleConfig
    ) external payable initializer {
        // Core OZ init
        __ERC721_init(cfg.name, cfg.symbol);
        __ERC2981_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        // Ownership: set to injected owner if different
        if (cfg.initialOwner != address(0) && cfg.initialOwner != owner()) {
            _transferOwnership(cfg.initialOwner);
        }

        // Basic checks
        require(bytes(cfg.baseURI).length != 0, "BaseURI required");
        require(cfg.maxSupply > 0, "Supply>0");
        require(cfg.feeRecipient != address(0), "Bad fee recipient");
        require(cfg.royaltyRecipient != address(0), "Bad royalty recipient");
        require(cfg.royaltyBps <= 1000, "Royalty<=10%");

        // Persist base + supply + royalties
        baseTokenURI = cfg.baseURI;
        maxSupply = cfg.maxSupply;
        _setDefaultRoyalty(cfg.royaltyRecipient, cfg.royaltyBps);

        // Public sale checks
        require(pubConfig.startTimestamp > block.timestamp, "Pub start>now");
        require(pubConfig.price > 0, "Pub price>0");
        require(pubConfig.maxPerWallet > 0, "Per-wallet>0");
        require(pubConfig.maxPerTx > 0, "Per-tx>0");
        publicSale = pubConfig;

        // Presale (optional)
        if (presaleConfig.startTimestamp > 0) {
            require(presaleConfig.startTimestamp > block.timestamp, "Pre start>now");
            require(presaleConfig.endTimestamp > presaleConfig.startTimestamp, "Pre end>start");
            require(pubConfig.startTimestamp > presaleConfig.endTimestamp, "Pub start>pre end");
            require(presaleConfig.price > 0 && presaleConfig.price <= pubConfig.price, "Bad pre price");
            require(presaleConfig.maxSupply > 0 && presaleConfig.maxSupply <= cfg.maxSupply, "Bad pre supply");
            presale = presaleConfig;
        }

        // Forward platform fee (after state set)
        require(msg.value == cfg.feeAmount, "Fee mismatch");
        (bool sent,) = cfg.feeRecipient.call{value: msg.value}("");
        require(sent, "Fee xfer failed");

        emit DropInitialized(owner(), cfg.name, cfg.symbol);
    }

    // ─────────────────────────── Minting ─────────────────────────────

    function presaleMint(uint256 quantity, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        PresaleConfig memory p = presale;
        require(p.startTimestamp > 0, "Presale disabled");
        require(block.timestamp >= p.startTimestamp, "Presale not live");
        require(block.timestamp < p.endTimestamp, "Presale ended");

        _commonMintChecks(quantity, p.price);

        require(presaleMinted + quantity <= p.maxSupply, "Exceeds presale supply");

        // Verify Merkle (leaf = keccak256(abi.encodePacked(msg.sender)))
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verifyCalldata(proof, p.merkleRoot, leaf), "Not whitelisted");

        _batchMint(msg.sender, quantity);
        unchecked { presaleMinted += quantity; }
    }

    function mint(uint256 quantity)
        external
        payable
        nonReentrant
    {
        require(block.timestamp >= publicSale.startTimestamp, "Sale not live");
        _commonMintChecks(quantity, publicSale.price);
        _batchMint(msg.sender, quantity);
    }

    function _commonMintChecks(uint256 quantity, uint256 unitPrice) internal view {
        require(quantity > 0, "Qty>0");
        require(quantity <= publicSale.maxPerTx, "Exceeds per-tx");
        require(totalMinted + quantity <= maxSupply, "Exceeds supply");
        require(mintedPerWallet[msg.sender] + quantity <= publicSale.maxPerWallet, "Exceeds per-wallet");
        require(msg.value == quantity * unitPrice, "Wrong value");
    }

    function _batchMint(address to, uint256 quantity) internal {
        for (uint256 i; i < quantity; ) {
            unchecked {
                totalMinted++;
                mintedPerWallet[to]++;
            }
            uint256 tokenId = totalMinted; // IDs: 1..maxSupply
            _safeMint(to, tokenId);
            emit DropMinted(to, tokenId, tokenURI(tokenId));
            unchecked { ++i; }
        }
    }

    // ─────────────────────── Admin / Withdraw ────────────────────────

    function withdrawProceeds(address payable to) external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No funds");
        (bool sent,) = to.call{value: bal}("");
        require(sent, "Withdraw failed");
        emit ProceedsWithdrawn(to, bal);
    }

    // ───────────────────────────── Views ─────────────────────────────

    function totalSupply() public view returns (uint256) {
        return totalMinted;
    }

    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }

    /// tokenURI = baseURI + "/" + tokenId + ".json"
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId); // OZ v5 helper (reverts for non-existent)
        return string.concat(baseTokenURI, "/", tokenId.toString(), ".json");
    }

    function supportsInterface(bytes4 iid)
        public
        view
        override(ERC721Upgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(iid);
    }
}

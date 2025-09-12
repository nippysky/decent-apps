// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC721Drop {
    struct DropConfig {
        string name;
        string symbol;
        string baseURI;
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
    function initialize(
        DropConfig calldata cfg,
        PublicSaleConfig calldata pubConfig,
        PresaleConfig calldata presaleConfig
    ) external payable;
}

interface IERC721SingleMint {
    struct SingleConfig {
        string  name;
        string  symbol;
        string  tokenURI;
        address payable feeRecipient;
        uint256 feeAmount;
        address royaltyRecipient;
        uint96  royaltyBps;
        address initialOwner; // injected by factory
    }
    function initialize(SingleConfig calldata cfg) external payable;
}

interface IERC1155DropSingleToken {
    struct Config {
        string   name;
        string   symbol;
        string   baseURI;
        uint256  maxSupply;
        uint256  mintPrice;
        uint256  maxPerWallet;
        address payable feeRecipient;
        uint256  feeAmount;
        address  royaltyRecipient;
        uint96   royaltyBps;
        address  initialOwner; // injected by factory
    }
    function initialize(Config calldata cfg) external payable;
}

contract NFTFactory is Ownable, ReentrancyGuard {
    using Clones for address;

    address public immutable erc721DropImpl;
    address public immutable erc721SingleImpl;
    address public immutable erc1155DropImpl;

    event ERC721DropCloneCreated(address indexed deployer, address indexed cloneAddress);
    event ERC721SingleCloneCreated(address indexed deployer, address indexed cloneAddress);
    event ERC1155DropCloneCreated(address indexed deployer, address indexed cloneAddress);

    constructor(
        address _erc721DropImpl,
        address _erc721SingleImpl,
        address _erc1155DropImpl
    ) Ownable(msg.sender) {
        require(_erc721DropImpl   != address(0), "Zero ERC721Drop impl");
        require(_erc721SingleImpl != address(0), "Zero ERC721Single impl");
        require(_erc1155DropImpl  != address(0), "Zero ERC1155Drop impl");
        erc721DropImpl   = _erc721DropImpl;
        erc721SingleImpl = _erc721SingleImpl;
        erc1155DropImpl  = _erc1155DropImpl;
    }

    // -------------------- ERC721 DROP --------------------
    function createERC721Drop(
        IERC721Drop.DropConfig calldata cfg,
        IERC721Drop.PublicSaleConfig calldata pubConfig,
        IERC721Drop.PresaleConfig calldata presaleConfig
    ) external payable nonReentrant returns (address) {
        address clone = erc721DropImpl.clone();

        IERC721Drop.DropConfig memory withOwner = IERC721Drop.DropConfig({
            name: cfg.name,
            symbol: cfg.symbol,
            baseURI: cfg.baseURI,
            maxSupply: cfg.maxSupply,
            feeRecipient: cfg.feeRecipient,
            feeAmount: cfg.feeAmount,
            royaltyRecipient: cfg.royaltyRecipient,
            royaltyBps: cfg.royaltyBps,
            initialOwner: msg.sender
        });

        IERC721Drop(clone).initialize{value: msg.value}(withOwner, pubConfig, presaleConfig);
        emit ERC721DropCloneCreated(msg.sender, clone);
        return clone;
    }

    // -------------------- ERC721 SINGLE --------------------
    function createERC721Single(
        IERC721SingleMint.SingleConfig calldata cfg
    ) external payable nonReentrant returns (address) {
        address clone = erc721SingleImpl.clone();

        IERC721SingleMint.SingleConfig memory withOwner = IERC721SingleMint.SingleConfig({
            name: cfg.name,
            symbol: cfg.symbol,
            tokenURI: cfg.tokenURI,
            feeRecipient: cfg.feeRecipient,
            feeAmount: cfg.feeAmount,
            royaltyRecipient: cfg.royaltyRecipient,
            royaltyBps: cfg.royaltyBps,
            initialOwner: msg.sender
        });

        IERC721SingleMint(clone).initialize{value: msg.value}(withOwner);
        emit ERC721SingleCloneCreated(msg.sender, clone);
        return clone;
    }

    // -------------------- ERC1155 SINGLE-TOKEN DROP --------------------
    function createERC1155Drop(
        IERC1155DropSingleToken.Config calldata cfg
    ) external payable nonReentrant returns (address) {
        address clone = erc1155DropImpl.clone();

        IERC1155DropSingleToken.Config memory withOwner = IERC1155DropSingleToken.Config({
            name: cfg.name,
            symbol: cfg.symbol,
            baseURI: cfg.baseURI,
            maxSupply: cfg.maxSupply,
            mintPrice: cfg.mintPrice,
            maxPerWallet: cfg.maxPerWallet,
            feeRecipient: cfg.feeRecipient,
            feeAmount: cfg.feeAmount,
            royaltyRecipient: cfg.royaltyRecipient,
            royaltyBps: cfg.royaltyBps,
            initialOwner: msg.sender
        });

        IERC1155DropSingleToken(clone).initialize{value: msg.value}(withOwner);
        emit ERC1155DropCloneCreated(msg.sender, clone);
        return clone;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title Non-Fungible Comrades
 * @dev A simplified ERC721 contract for the Non-Fungible Comrades.
 */
contract NonFungibleComrades is ERC721Enumerable, Ownable, ReentrancyGuard {
    string public baseURI = "ipfs://bafybeiamhpjvmnjzb63derd6dkrrawfhr6eg2rwodcigwsj3myq6sxvlc4/";
    uint256 public constant MAX_SUPPLY = 5000; // Fixed total supply of 5000 Comrades
    uint256 public constant PRICE = 5000 * 10**18; // 5000 ETN
    uint256 public constant MAX_MINT_PER_WALLET = 20;
    address public FUND_RECIPIENT = 0xe785e1f0F48ee8ac4553F39618e230D8cFf45Ba3;

    mapping(uint256 => string) private _tokenURIs; // Mapping to store custom token URIs

    constructor() ERC721("Non-Fungible Comrades", "NFComrades") Ownable(msg.sender) {}

    /**
     * @dev Constructs the token URI using the base URI and token ID.
     * @param tokenId The ID of the token.
     * @return The complete token URI.
     */
    function _buildTokenURI(uint256 tokenId) private view returns (string memory) {
        return string(abi.encodePacked(baseURI, Strings.toString(tokenId), ".json"));
    }

    /**
     * @dev Public mint function allowing users to mint NFTs.
     * @param amount The number of NFTs to mint.
     */
    function mint(uint256 amount) external payable nonReentrant {
        require(amount > 0 && amount <= MAX_MINT_PER_WALLET, "Amount must be between 1 and 20");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        require(msg.value >= PRICE * amount, "Insufficient funds");

        for (uint256 i = 0; i < amount; i++) {
            uint256 tokenId = totalSupply() + 1;
            _safeMint(msg.sender, tokenId);
            _tokenURIs[tokenId] = _buildTokenURI(tokenId); // Set custom URI with .json extension
        }
    }

    /**
     * @dev Sets a new base URI for the metadata.
     * Can only be called by the contract owner.
     * @param newBaseURI The new base URI.
     */
    function setBaseURI(string memory newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
    }

    /**
     * @dev Override to return the token URI for a given token ID.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        string memory customURI = _tokenURIs[tokenId];
        if (bytes(customURI).length > 0) {
            return customURI;
        }
        return super.tokenURI(tokenId); // Fallback to the base ERC721 implementation
    }

    /**
     * @dev Withdraw the funds collected from minting.
     * Only the owner can withdraw.
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        payable(FUND_RECIPIENT).transfer(balance);
    }
}

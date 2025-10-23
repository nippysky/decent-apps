// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControl}     from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}          from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard}   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC721}           from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder}      from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {IERC1155}          from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder}     from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IERC20}            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165}           from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981}          from "@openzeppelin/contracts/interfaces/IERC2981.sol";

interface IStolenRegistry {
    function isStolen(address tokenContract, uint256 tokenId) external view returns (bool);
}

contract Panthart is AccessControl, Pausable, ReentrancyGuard, ERC721Holder, ERC1155Holder {
    // Roles
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    // Constants
    uint256 public constant BPS_DENOM   = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000; // 10%

    // Config
    uint256 public feeBps              = 250;
    uint256 public distributorShareBps = 150;
    uint256 public snipeExtension      = 300;

    address public feeRecipient;
    address public rewardsDistributor;
    IStolenRegistry public stolenRegistry;

    // currency whitelist: address(0)=native ETN, others=ERC20
    mapping(address => bool) public currencyAllowed;

    // Listings & Auctions
    enum TokenStandard { ERC721, ERC1155 }

    struct Listing {
        address seller;
        address token;
        uint256 tokenId;
        uint256 quantity;    
        TokenStandard standard;
        address currency;   
        uint256 price;
        uint64  startTime;
        uint64  endTime; 
        bool    active;
    }

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;

    // ERC-721 lock: at most one ACTIVE listing per (collection, tokenId)
    mapping(address => mapping(uint256 => uint256)) public activeListingForToken; // token=>id=>listingId

    // ERC-1155 lock: at most one ACTIVE listing per (collection, tokenId, seller)
    mapping(address => mapping(uint256 => mapping(address => uint256))) public activeListing1155BySeller;

    struct Auction {
        address seller;
        address token;
        uint256 tokenId;
        uint256 quantity;   
        TokenStandard standard;
        address currency;  
        uint256 startPrice;
        uint256 minIncrement;
        uint64  startTime;
        uint64  endTime;
        address highestBidder;
        uint256 highestBid;
        uint32  bidsCount;
        bool    settled;
    }

    uint256 public nextAuctionId = 1;
    mapping(uint256 => Auction) public auctions;

    // ERC-721 lock: at most one ACTIVE auction per (collection, tokenId)
    mapping(address => mapping(uint256 => uint256)) public activeAuctionForToken; // token=>id=>auctionId

    // ERC-1155 lock: at most one ACTIVE auction per (collection, tokenId, seller)
    mapping(address => mapping(uint256 => mapping(address => uint256))) public activeAuction1155BySeller;

    // credits[currency][account] => amount (fallback payouts/refunds)
    mapping(address => mapping(address => uint256)) public credits;

    // Events
    event ConfigUpdated(
        uint256 feeBps,
        uint256 distributorShareBps,
        address feeRecipient,
        address rewardsDistributor,
        address stolenRegistry,
        uint256 snipeExtension
    );
    event CurrencySet(address indexed currency, bool allowed);

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address indexed token,
        uint256 tokenId,
        uint256 quantity,
        address currency,
        uint256 price,
        uint64 startTime,
        uint64 endTime,
        TokenStandard standard
    );
    event ListingCancelled(uint256 indexed listingId);
    event ListingPurchased(
        uint256 indexed listingId,
        address indexed buyer,
        address currency,
        uint256 pricePaid,
        uint256 royaltyPaid,
        uint256 feePaid,
        address feeRecipient,
        uint256 distributorPaid,
        address rewardsDistributor
    );

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed token,
        uint256 tokenId,
        uint256 quantity,
        address currency,
        uint256 startPrice,
        uint256 minIncrement,
        uint64 startTime,
        uint64 endTime,
        TokenStandard standard
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        address currency,
        uint256 amount,
        uint64 newEndTime
    );
    event AuctionCancelled(uint256 indexed auctionId);
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        address currency,
        uint256 pricePaid,
        uint256 royaltyPaid,
        uint256 feePaid,
        address feeRecipient,
        uint256 distributorPaid,
        address rewardsDistributor
    );

    event CreditAdded(address indexed currency, address indexed account, uint256 amount);
    event CreditWithdrawn(address indexed currency, address indexed account, uint256 amount);

    // Errors
    error BadConfig();
    error BadParams();
    error NotSeller();
    error Inactive();
    error TimeWindow();
    error StolenAsset();
    error PriceMismatch();
    error AlreadySettled();
    error TransferFailed();
    error AssetBusy();

    constructor(
        address admin,
        address _feeRecipient,
        address _rewardsDistributor,
        address _stolenRegistry
    ) {
        require(admin != address(0), "admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);

        feeRecipient       = _feeRecipient;
        rewardsDistributor = _rewardsDistributor;
        stolenRegistry     = IStolenRegistry(_stolenRegistry);

        currencyAllowed[address(0)] = true;
        emit CurrencySet(address(0), true);

        emit ConfigUpdated(
            feeBps,
            distributorShareBps,
            feeRecipient,
            rewardsDistributor,
            _stolenRegistry,
            snipeExtension
        );
    }

    // Admin
    function setConfig(
        uint256 _feeBps,
        uint256 _distributorShareBps,
        address _feeRecipient,
        address _rewardsDistributor,
        address _stolenRegistry,
        uint256 _snipeExtension
    ) external onlyRole(CONFIG_ROLE) {
        if (_feeBps > MAX_FEE_BPS) revert BadConfig();
        if (_distributorShareBps > _feeBps) revert BadConfig();
        if (_feeRecipient == address(0) || _rewardsDistributor == address(0)) revert BadConfig();
        if (_stolenRegistry == address(0)) revert BadConfig();

        feeBps              = _feeBps;
        distributorShareBps = _distributorShareBps;
        feeRecipient        = _feeRecipient;
        rewardsDistributor  = _rewardsDistributor;
        stolenRegistry      = IStolenRegistry(_stolenRegistry);
        snipeExtension      = _snipeExtension;

        emit ConfigUpdated(
            feeBps,
            distributorShareBps,
            feeRecipient,
            rewardsDistributor,
            _stolenRegistry,
            snipeExtension
        );
    }

    function setCurrencyAllowed(address currency, bool allowed) external onlyRole(CONFIG_ROLE) {
        currencyAllowed[currency] = allowed;
        emit CurrencySet(currency, allowed);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // Internal helpers
    function _royalty(address token, uint256 tokenId, uint256 salePrice) internal view returns (address, uint256) {
        if (IERC165(token).supportsInterface(type(IERC2981).interfaceId)) {
            (address recv, uint256 amt) = IERC2981(token).royaltyInfo(tokenId, salePrice);
            if (amt > salePrice) amt = salePrice;
            return (recv, amt);
        }
        return (address(0), 0);
    }

    function _escrowIn(address token, uint256 tokenId, uint256 quantity, TokenStandard standard) internal {
        if (standard == TokenStandard.ERC721) {
            IERC721(token).safeTransferFrom(msg.sender, address(this), tokenId);
        } else {
            IERC1155(token).safeTransferFrom(msg.sender, address(this), tokenId, quantity, "");
        }
    }

    function _escrowOut(address to, address token, uint256 tokenId, uint256 quantity, TokenStandard standard) internal {
        if (standard == TokenStandard.ERC721) {
            IERC721(token).safeTransferFrom(address(this), to, tokenId);
        } else {
            IERC1155(token).safeTransferFrom(address(this), to, tokenId, quantity, "");
        }
    }

    function _addCredit(address currency, address to, uint256 amount) internal {
        credits[currency][to] += amount;
        emit CreditAdded(currency, to, amount);
    }

    function _erc20SendOrCredit(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        bool success = ok && (data.length == 0 || abi.decode(data, (bool)));
        if (!success) _addCredit(token, to, amount);
    }

    function _nativeSendOrCredit(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) _addCredit(address(0), to, amount);
    }

    // --- payout split into small helpers (stack-friendly) ---
    function _payRoyalty(
        address currency,
        address collection,
        uint256 tokenId,
        uint256 salePrice
    ) internal returns (uint256 royaltyPaid) {
        (address recv, uint256 amt) = _royalty(collection, tokenId, salePrice);
        if (recv != address(0) && amt > 0) {
            if (currency == address(0)) _nativeSendOrCredit(recv, amt);
            else _erc20SendOrCredit(currency, recv, amt);
            royaltyPaid = amt;
        }
    }

    function _payFeeAndDistributor(
        address currency,
        uint256 salePrice
    ) internal returns (uint256 feePaid, uint256 distributorPaid) {
        uint256 fee = (salePrice * feeBps) / BPS_DENOM;
        if (fee == 0) return (0, 0);

        uint256 dist = (fee * distributorShareBps) / feeBps;
        uint256 trea = fee - dist;

        if (dist > 0) {
            if (currency == address(0)) _nativeSendOrCredit(rewardsDistributor, dist);
            else _erc20SendOrCredit(currency, rewardsDistributor, dist);
            distributorPaid = dist;
        }
        if (trea > 0) {
            if (currency == address(0)) _nativeSendOrCredit(feeRecipient, trea);
            else _erc20SendOrCredit(currency, feeRecipient, trea);
        }
        feePaid = fee;
    }

    function _paySeller(
        address currency,
        uint256 salePrice,
        uint256 royaltyPaid,
        uint256 feePaid,
        address seller
    ) internal {
        uint256 proceeds = salePrice - royaltyPaid - feePaid;
        if (proceeds == 0) return;
        if (currency == address(0)) _nativeSendOrCredit(seller, proceeds);
        else _erc20SendOrCredit(currency, seller, proceeds);
    }

    function _payoutSplit(
        address currency,
        uint256 salePrice,
        address collection,
        uint256 tokenId,
        address seller
    ) internal returns (uint256 royaltyPaid, uint256 feePaid, uint256 distributorPaid) {
        royaltyPaid = _payRoyalty(currency, collection, tokenId, salePrice);
        (feePaid, distributorPaid) = _payFeeAndDistributor(currency, salePrice);
        _paySeller(currency, salePrice, royaltyPaid, feePaid, seller);
    }

    function _isLive(uint64 startTime, uint64 endTime) internal view returns (bool) {
        uint256 t = block.timestamp;
        if (t < startTime) return false;
        if (endTime != 0 && t > endTime) return false;
        return true;
    }

    // Listings
    function createListing(
        address collection,
        uint256 tokenId,
        uint256 quantity,
        address currency,
        uint256 price,
        uint64 startTime,
        uint64 endTime,
        TokenStandard standard
    ) external whenNotPaused nonReentrant returns (uint256 listingId) {
        if (!currencyAllowed[currency]) revert BadParams();
        if (price == 0) revert BadParams();
        if (standard == TokenStandard.ERC721 && quantity != 1) revert BadParams();
        if (standard == TokenStandard.ERC1155 && quantity == 0) revert BadParams();

        uint64 s = startTime == 0 ? uint64(block.timestamp) : startTime;
        if (endTime != 0 && endTime <= s) revert BadParams();

        if (stolenRegistry.isStolen(collection, tokenId)) revert StolenAsset();

        // Locking rules:
        if (standard == TokenStandard.ERC721) {
            if (activeListingForToken[collection][tokenId] != 0) revert AssetBusy();
            if (activeAuctionForToken[collection][tokenId] != 0) revert AssetBusy();
        } else {
            if (activeListing1155BySeller[collection][tokenId][msg.sender] != 0) revert AssetBusy();
            if (activeAuction1155BySeller[collection][tokenId][msg.sender] != 0) revert AssetBusy();
        }

        _escrowIn(collection, tokenId, quantity, standard);

        listingId = nextListingId++;
        Listing storage L = listings[listingId];
        L.seller    = msg.sender;
        L.token     = collection;
        L.tokenId   = tokenId;
        L.quantity  = quantity;
        L.standard  = standard;
        L.currency  = currency;
        L.price     = price;
        L.startTime = s;
        L.endTime   = endTime;
        L.active    = true;

        if (standard == TokenStandard.ERC721) {
            activeListingForToken[collection][tokenId] = listingId;
        } else {
            activeListing1155BySeller[collection][tokenId][msg.sender] = listingId;
        }

        emit ListingCreated(
            listingId, msg.sender, collection, tokenId, quantity, currency, price, s, endTime, standard
        );
    }

    function cancelListing(uint256 listingId) public whenNotPaused nonReentrant {
        Listing storage L = listings[listingId];
        if (!L.active) revert Inactive();
        if (L.seller != msg.sender) revert NotSeller();

        L.active = false;

        if (L.standard == TokenStandard.ERC721) {
            if (activeListingForToken[L.token][L.tokenId] == listingId) {
                activeListingForToken[L.token][L.tokenId] = 0;
            }
        } else {
            if (activeListing1155BySeller[L.token][L.tokenId][L.seller] == listingId) {
                activeListing1155BySeller[L.token][L.tokenId][L.seller] = 0;
            }
        }

        _escrowOut(L.seller, L.token, L.tokenId, L.quantity, L.standard);
        emit ListingCancelled(listingId);
    }

    function cleanupExpiredListing(uint256 listingId) external whenNotPaused nonReentrant {
        Listing storage L = listings[listingId];
        if (!L.active) revert Inactive();
        if (L.endTime == 0 || block.timestamp <= L.endTime) revert TimeWindow();

        L.active = false;

        if (L.standard == TokenStandard.ERC721) {
            if (activeListingForToken[L.token][L.tokenId] == listingId) {
                activeListingForToken[L.token][L.tokenId] = 0;
            }
        } else {
            if (activeListing1155BySeller[L.token][L.tokenId][L.seller] == listingId) {
                activeListing1155BySeller[L.token][L.tokenId][L.seller] = 0;
            }
        }

        _escrowOut(L.seller, L.token, L.tokenId, L.quantity, L.standard);
        emit ListingCancelled(listingId);
    }

    function buy(uint256 listingId) external payable whenNotPaused nonReentrant {
        Listing storage L = listings[listingId];
        if (!L.active) revert Inactive();
        if (!_isLive(L.startTime, L.endTime)) revert TimeWindow();
        if (stolenRegistry.isStolen(L.token, L.tokenId)) revert StolenAsset();

        if (L.currency == address(0)) {
            if (msg.value != L.price) revert PriceMismatch();
        } else {
            if (msg.value != 0) revert PriceMismatch();
            (bool ok, bytes memory data) =
                L.currency.call(abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), L.price));
            bool success = ok && (data.length == 0 || abi.decode(data, (bool)));
            if (!success) revert TransferFailed();
        }

        L.active = false;

        if (L.standard == TokenStandard.ERC721) {
            if (activeListingForToken[L.token][L.tokenId] == listingId) {
                activeListingForToken[L.token][L.tokenId] = 0;
            }
        } else {
            if (activeListing1155BySeller[L.token][L.tokenId][L.seller] == listingId) {
                activeListing1155BySeller[L.token][L.tokenId][L.seller] = 0;
            }
        }

        _escrowOut(msg.sender, L.token, L.tokenId, L.quantity, L.standard);

        (uint256 rp, uint256 fp, uint256 dp) = _payoutSplit(L.currency, L.price, L.token, L.tokenId, L.seller);

        emit ListingPurchased(listingId, msg.sender, L.currency, L.price, rp, fp, feeRecipient, dp, rewardsDistributor);
    }

    /**
     * @notice Place a bid.
     * @param auctionId The auction id.
     * @param amount    For ERC-20 auctions, the amount to bid (must be >= minReq). Ignored for native ETN.
     *
     * Native ETN path: send value >= minReq via msg.value; entire msg.value becomes your bid.
     * ERC-20 path:    call with amount >= minReq and prior approval; entire `amount` becomes your bid.
     */
    function bid(uint256 auctionId, uint256 amount) external payable whenNotPaused nonReentrant {
        Auction storage A = auctions[auctionId];
        if (A.settled) revert AlreadySettled();
        if (block.timestamp < A.startTime || block.timestamp > A.endTime) revert TimeWindow();
        if (stolenRegistry.isStolen(A.token, A.tokenId)) revert StolenAsset();

        uint256 minReq = (A.bidsCount == 0) ? A.startPrice : (A.highestBid + A.minIncrement);

        uint256 paid;
        if (A.currency == address(0)) {
            if (msg.value < minReq) revert PriceMismatch();
            paid = msg.value;
        } else {
            if (msg.value != 0) revert PriceMismatch();
            if (amount < minReq) revert PriceMismatch();
            (bool ok, bytes memory data) =
                A.currency.call(abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), amount));
            bool success = ok && (data.length == 0 || abi.decode(data, (bool)));
            if (!success) revert TransferFailed();
            paid = amount;
        }

        if (A.highestBidder != address(0) && A.highestBid > 0) {
            _addCredit(A.currency, A.highestBidder, A.highestBid);
        }

        A.highestBidder = msg.sender;
        A.highestBid    = paid;
        A.bidsCount    += 1;

        if (snipeExtension > 0) {
            uint64 extEnd = uint64(block.timestamp + snipeExtension);
            if (extEnd > A.endTime) A.endTime = extEnd;
        }

        emit BidPlaced(auctionId, msg.sender, A.currency, paid, A.endTime);
    }

    function createAuction(
        address collection,
        uint256 tokenId,
        uint256 quantity,
        address currency,
        uint256 startPrice,
        uint256 minIncrement,
        uint64 startTime,
        uint64 endTime,
        TokenStandard standard
    ) external whenNotPaused nonReentrant returns (uint256 auctionId) {
        if (!currencyAllowed[currency]) revert BadParams();
        if (startPrice == 0 || minIncrement == 0) revert BadParams();
        if (standard == TokenStandard.ERC721 && quantity != 1) revert BadParams();
        if (standard == TokenStandard.ERC1155 && quantity == 0) revert BadParams();

        uint64 s = startTime == 0 ? uint64(block.timestamp) : startTime;
        if (endTime <= s) revert BadParams();

        if (stolenRegistry.isStolen(collection, tokenId)) revert StolenAsset();

        if (standard == TokenStandard.ERC721) {
            if (activeListingForToken[collection][tokenId] != 0) revert AssetBusy();
            if (activeAuctionForToken[collection][tokenId] != 0) revert AssetBusy();
        } else {
            if (activeListing1155BySeller[collection][tokenId][msg.sender] != 0) revert AssetBusy();
            if (activeAuction1155BySeller[collection][tokenId][msg.sender] != 0) revert AssetBusy();
        }

        _escrowIn(collection, tokenId, quantity, standard);

        auctionId = nextAuctionId++;
        Auction storage A = auctions[auctionId];
        A.seller       = msg.sender;
        A.token        = collection;
        A.tokenId      = tokenId;
        A.quantity     = quantity;
        A.standard     = standard;
        A.currency     = currency;
        A.startPrice   = startPrice;
        A.minIncrement = minIncrement;
        A.startTime    = s;
        A.endTime      = endTime;

        if (standard == TokenStandard.ERC721) {
            activeAuctionForToken[collection][tokenId] = auctionId;
        } else {
            activeAuction1155BySeller[collection][tokenId][msg.sender] = auctionId;
        }

        emit AuctionCreated(
            auctionId, msg.sender, collection, tokenId, quantity, currency, startPrice, minIncrement, s, endTime, standard
        );
    }

    function finalize(uint256 auctionId) external whenNotPaused nonReentrant {
        Auction storage A = auctions[auctionId];
        if (A.settled) revert AlreadySettled();
        if (block.timestamp <= A.endTime) revert TimeWindow();

        A.settled = true;

        if (A.standard == TokenStandard.ERC721) {
            if (activeAuctionForToken[A.token][A.tokenId] == auctionId) {
                activeAuctionForToken[A.token][A.tokenId] = 0;
            }
        } else {
            if (activeAuction1155BySeller[A.token][A.tokenId][A.seller] == auctionId) {
                activeAuction1155BySeller[A.token][A.tokenId][A.seller] = 0;
            }
        }

        if (A.bidsCount == 0 || A.highestBidder == address(0)) {
            _escrowOut(A.seller, A.token, A.tokenId, A.quantity, A.standard);
            emit AuctionCancelled(auctionId);
            return;
        }

        if (stolenRegistry.isStolen(A.token, A.tokenId)) revert StolenAsset();

        _escrowOut(A.highestBidder, A.token, A.tokenId, A.quantity, A.standard);

        (uint256 rp, uint256 fp, uint256 dp) = _payoutSplit(A.currency, A.highestBid, A.token, A.tokenId, A.seller);

        emit AuctionSettled(
            auctionId, A.highestBidder, A.currency, A.highestBid, rp, fp, feeRecipient, dp, rewardsDistributor
        );
    }

    function cancelAuction(uint256 auctionId) external whenNotPaused nonReentrant {
        Auction storage A = auctions[auctionId];
        if (A.settled) revert AlreadySettled();
        if (A.seller != msg.sender) revert NotSeller();
        if (A.bidsCount != 0) revert Inactive();

        A.settled = true;

        if (A.standard == TokenStandard.ERC721) {
            if (activeAuctionForToken[A.token][A.tokenId] == auctionId) {
                activeAuctionForToken[A.token][A.tokenId] = 0;
            }
        } else {
            if (activeAuction1155BySeller[A.token][A.tokenId][A.seller] == auctionId) {
                activeAuction1155BySeller[A.token][A.tokenId][A.seller] = 0;
            }
        }

        _escrowOut(A.seller, A.token, A.tokenId, A.quantity, A.standard);
        emit AuctionCancelled(auctionId);
    }

    // Credits
    function withdrawCredits(address currency) external nonReentrant {
        uint256 amt = credits[currency][msg.sender];
        if (amt == 0) revert Inactive();
        credits[currency][msg.sender] = 0;

        if (currency == address(0)) {
            (bool ok, ) = payable(msg.sender).call{value: amt}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory data) =
                currency.call(abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amt));
            bool success = ok && (data.length == 0 || abi.decode(data, (bool)));
            if (!success) revert TransferFailed();
        }

        emit CreditWithdrawn(currency, msg.sender, amt);
    }

    // ERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // Receive
    receive() external payable {}
    fallback() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface IStolenRegistry {
    function isStolen(address tokenContract, uint256 tokenId) external view returns (bool);
}


contract PanthartStolenRegistry is IStolenRegistry, AccessControl, Pausable {
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant CLEARER_ROLE  = keccak256("CLEARER_ROLE");

    struct Report {
        address reporter;
        uint64  timestamp;
        bytes32 reasonHash; 
        string  evidenceURI; 
        bool    active;
    }

    // token-level: tokenContract => tokenId => report
    mapping(address => mapping(uint256 => Report)) private _tokenReports;

    // collection-level: tokenContract => report
    mapping(address => Report) private _collectionReports;

    /** ----------------------------- Events ----------------------------- */

    // token-level
    event ItemFlagged(
        address indexed tokenContract,
        uint256 indexed tokenId,
        address indexed reporter,
        bytes32 reasonHash,
        string evidenceURI
    );
    event ItemCleared(
        address indexed tokenContract,
        uint256 indexed tokenId,
        address indexed clearer
    );

    // collection-level
    event CollectionFlagged(
        address indexed tokenContract,
        address indexed reporter,
        bytes32 reasonHash,
        string evidenceURI
    );
    event CollectionCleared(
        address indexed tokenContract,
        address indexed clearer
    );

    // role admin convenience logs
    event ReporterGranted(address indexed account);
    event ReporterRevoked(address indexed account);
    event ClearerGranted(address indexed account);
    event ClearerRevoked(address indexed account);

    constructor(address admin) {
        require(admin != address(0), "admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /** ------------------------- Role helpers -------------------------- */
    modifier onlyReporter() {
        // Admin can always act as reporter
        require(
            hasRole(REPORTER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "not-reporter"
        );
        _;
    }
    modifier onlyClearer() {
        // Admin can always act as clearer
        require(
            hasRole(CLEARER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "not-clearer"
        );
        _;
    }

    /** ---------------------------- Admin ------------------------------ */

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function grantReporter(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(REPORTER_ROLE, account);
        emit ReporterGranted(account);
    }
    function revokeReporter(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(REPORTER_ROLE, account);
        emit ReporterRevoked(account);
    }

    function grantClearer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(CLEARER_ROLE, account);
        emit ClearerGranted(account);
    }
    function revokeClearer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(CLEARER_ROLE, account);
        emit ClearerRevoked(account);
    }

    /** ----------------------- Token-level ops ------------------------- */

    function flag(
        address tokenContract,
        uint256 tokenId,
        bytes32 reasonHash,
        string calldata evidenceURI
    ) public whenNotPaused onlyReporter {
        Report storage r = _tokenReports[tokenContract][tokenId];
        require(!r.active, "already-flagged");
        r.reporter    = msg.sender;
        r.timestamp   = uint64(block.timestamp);
        r.reasonHash  = reasonHash;
        r.evidenceURI = evidenceURI;
        r.active      = true;
        emit ItemFlagged(tokenContract, tokenId, msg.sender, reasonHash, evidenceURI);
    }

    function clear(address tokenContract, uint256 tokenId)
        public
        whenNotPaused
        onlyClearer
    {
        Report storage r = _tokenReports[tokenContract][tokenId];
        require(r.active, "not-flagged");
        r.active = false;
        emit ItemCleared(tokenContract, tokenId, msg.sender);
    }

    function flagBatch(
        address[] calldata tokenContracts,
        uint256[] calldata tokenIds,
        bytes32[] calldata reasonHashes,
        string[] calldata evidenceURIs
    ) external whenNotPaused onlyReporter {
        uint256 n = tokenContracts.length;
        require(n == tokenIds.length && n == reasonHashes.length && n == evidenceURIs.length, "length-mismatch");
        for (uint256 i = 0; i < n; i++) {
            flag(tokenContracts[i], tokenIds[i], reasonHashes[i], evidenceURIs[i]);
        }
    }

    function clearBatch(
        address[] calldata tokenContracts,
        uint256[] calldata tokenIds
    ) external whenNotPaused onlyClearer {
        uint256 n = tokenContracts.length;
        require(n == tokenIds.length, "length-mismatch");
        for (uint256 i = 0; i < n; i++) {
            clear(tokenContracts[i], tokenIds[i]);
        }
    }

    /** -------------------- Collection-level ops ---------------------- */

    function flagCollection(
        address tokenContract,
        bytes32 reasonHash,
        string calldata evidenceURI
    ) public whenNotPaused onlyReporter {
        Report storage r = _collectionReports[tokenContract];
        require(!r.active, "collection-flagged");
        r.reporter    = msg.sender;
        r.timestamp   = uint64(block.timestamp);
        r.reasonHash  = reasonHash;
        r.evidenceURI = evidenceURI;
        r.active      = true;
        emit CollectionFlagged(tokenContract, msg.sender, reasonHash, evidenceURI);
    }

    function clearCollection(address tokenContract)
        public
        whenNotPaused
        onlyClearer
    {
        Report storage r = _collectionReports[tokenContract];
        require(r.active, "collection-not-flagged");
        r.active = false;
        emit CollectionCleared(tokenContract, msg.sender);
    }

    function flagCollectionsBatch(
        address[] calldata tokenContracts,
        bytes32[] calldata reasonHashes,
        string[] calldata evidenceURIs
    ) external whenNotPaused onlyReporter {
        uint256 n = tokenContracts.length;
        require(n == reasonHashes.length && n == evidenceURIs.length, "length-mismatch");
        for (uint256 i = 0; i < n; i++) {
            flagCollection(tokenContracts[i], reasonHashes[i], evidenceURIs[i]);
        }
    }

    function clearCollectionsBatch(address[] calldata tokenContracts)
        external
        whenNotPaused
        onlyClearer
    {
        uint256 n = tokenContracts.length;
        for (uint256 i = 0; i < n; i++) {
            clearCollection(tokenContracts[i]);
        }
    }

    /** ----------------------------- Views ---------------------------- */

    /// Semantics: a token is considered stolen if either its collection or the token itself is flagged.
    function isStolen(address tokenContract, uint256 tokenId) public view override returns (bool) {
        return _collectionReports[tokenContract].active || _tokenReports[tokenContract][tokenId].active;
    }

    function isCollectionStolen(address tokenContract) external view returns (bool) {
        return _collectionReports[tokenContract].active;
    }

    function getReport(address tokenContract, uint256 tokenId) external view returns (Report memory) {
        return _tokenReports[tokenContract][tokenId];
    }

    function getCollectionReport(address tokenContract) external view returns (Report memory) {
        return _collectionReports[tokenContract];
    }

    /** ---------------------- ERC165/AccessControl -------------------- */

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return
            interfaceId == type(IStolenRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}

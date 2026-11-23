// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title Bases: synthetic chromosomes as ERC-721 tokens.
/// @notice One token is one chromosome. Its sequence is fixed once committed at mint: the chain stores
///         a commitment to the whole sequence and its length in bases, never the sequence, and neither
///         ever changes. Polymerizable means printable: `polymerize` records a physical print of the
///         committed sequence (the real-world asset). Nothing is burned or rewritten.
contract Bases is ERC721 {
    struct Chromosome {
        bytes32 root;
        uint64 length;
        uint64 prints;
        bytes32 head;
    }

    /// @notice A sealed commit must be at least this old before it can be revealed by `mint`.
    uint256 public constant MIN_COMMIT_AGE = 1 minutes;
    /// @notice A sealed commit older than this can no longer be revealed.
    uint256 public constant MAX_COMMIT_AGE = 1 days;

    string private _wiki;
    mapping(uint256 => Chromosome) private _chromosomes;
    mapping(address => mapping(bytes32 => uint256)) private _commits;

    event Sealed(bytes32 indexed seal, address indexed by);
    event Committed(uint256 indexed id, bytes32 root, uint64 length);
    event Polymerized(uint256 indexed id, address indexed by, bytes32 receipt, uint64 prints, bytes32 head);

    error EmptySequence();
    error EmptyReceipt();
    error EmptySeal();
    error AlreadySealed(bytes32 seal);
    error UnknownSeal(bytes32 seal);
    error SealTooNew(bytes32 seal, uint256 revealableAt);
    error SealExpired(bytes32 seal);

    /// @param wiki URI prefix for token metadata, e.g. "https://helix.example/wiki/dna:".
    constructor(string memory wiki) ERC721("Bases", "BASES") {
        _wiki = wiki;
    }

    /// @notice The seal a minter commits before revealing: it binds the caller, recipient, root, length and a secret.
    function sealOf(address by, address to, bytes32 root, uint64 length, bytes32 secret) public pure returns (bytes32) {
        return keccak256(abi.encode(by, to, root, length, secret));
    }

    /// @notice Step 1 of a mint: commit `sealOf(msg.sender, to, root, length, secret)` without revealing the root.
    ///         Commits are kept per caller, so a copied seal committed by someone else does not block or move
    ///         this one. An expired seal can be committed again.
    function commit(bytes32 seal) external {
        if (seal == bytes32(0)) revert EmptySeal();
        uint256 at = _commits[msg.sender][seal];
        if (at != 0 && block.timestamp <= at + MAX_COMMIT_AGE) revert AlreadySealed(seal);
        _commits[msg.sender][seal] = block.timestamp;
        emit Sealed(seal, msg.sender);
    }

    /// @notice When `by` committed `seal` (0 if unknown or already revealed).
    function committedAt(address by, bytes32 seal) external view returns (uint256) {
        return _commits[by][seal];
    }

    /// @notice Step 2 of a mint: reveal a sealed chromosome between `MIN_COMMIT_AGE` and `MAX_COMMIT_AGE` after
    ///         its commit. `root` = sha256(salt || bases), computed off-chain. The token id is its first 16 bytes.
    function mint(address to, bytes32 root, uint64 length, bytes32 secret) external returns (uint256 id) {
        if (length == 0) revert EmptySequence();
        bytes32 seal = sealOf(msg.sender, to, root, length, secret);
        uint256 at = _commits[msg.sender][seal];
        if (at == 0) revert UnknownSeal(seal);
        if (block.timestamp < at + MIN_COMMIT_AGE) revert SealTooNew(seal, at + MIN_COMMIT_AGE);
        if (block.timestamp > at + MAX_COMMIT_AGE) revert SealExpired(seal);
        delete _commits[msg.sender][seal];
        id = uint256(root) >> 128;
        _chromosomes[id] = Chromosome(root, length, 0, root);
        emit Committed(id, root, length);
        _safeMint(to, id);
    }

    /// @notice Record one print of the committed sequence. `receipt` is a digest of the off-chain print record.
    ///         Only the holder or an approved operator may call. The sequence does not change. Each print
    ///         extends the token's print chain: head = keccak256(head || receipt), starting from root.
    function polymerize(uint256 id, bytes32 receipt) external returns (uint64 prints) {
        if (receipt == bytes32(0)) revert EmptyReceipt();
        address holder = _requireOwned(id);
        _checkAuthorized(holder, msg.sender, id);
        Chromosome storage c = _chromosomes[id];
        prints = ++c.prints;
        bytes32 head = keccak256(abi.encodePacked(c.head, receipt));
        c.head = head;
        emit Polymerized(id, msg.sender, receipt, prints, head);
    }

    function rootOf(uint256 id) external view returns (bytes32) {
        _requireOwned(id);
        return _chromosomes[id].root;
    }

    function lengthOf(uint256 id) external view returns (uint64) {
        _requireOwned(id);
        return _chromosomes[id].length;
    }

    function printsOf(uint256 id) external view returns (uint64) {
        _requireOwned(id);
        return _chromosomes[id].prints;
    }

    /// @notice Tip of the print chain: equals `rootOf(id)` until the first print.
    function headOf(uint256 id) external view returns (bytes32) {
        _requireOwned(id);
        return _chromosomes[id].head;
    }

    /// @notice helix page ID reference: the 128-bit token id as 32 lowercase hex chars.
    function locus(uint256 id) public pure returns (string memory) {
        bytes memory out = new bytes(32);
        bytes16 digits = "0123456789abcdef";
        for (uint256 i = 0; i < 32; i++) {
            out[i] = digits[(id >> (124 - 4 * i)) & 0xf];
        }
        return string(out);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return string.concat(_wiki, locus(id));
    }
}

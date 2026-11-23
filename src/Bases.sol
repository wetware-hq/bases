// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title Bases: synthetic chromosomes as ERC-721 tokens.
/// @notice One token is one chromosome. The chain stores only a hash chain over the
///         chromosome's chunks and its length in bases; no sequence is ever stored.
///         A chromosome can only grow at its 3' end (polymerize). Nothing is burned or rewritten.
contract Bases is ERC721 {
    struct Chromosome {
        bytes32 root;
        uint64 length;
    }

    /// @dev root(empty) = sha256("bases/1")
    bytes32 public immutable EMPTY_ROOT = sha256("bases/1");

    string private _wiki;
    mapping(uint256 => Chromosome) private _chromosomes;

    event Polymerized(
        uint256 indexed id, bytes32 indexed parent, bytes32 root, bytes32 chunk, uint64 added, uint64 length
    );

    error EmptyChunk();

    /// @param wiki URI prefix for token metadata, e.g. "https://helix.example/wiki/dna:".
    constructor(string memory wiki) ERC721("Bases", "BASES") {
        _wiki = wiki;
    }

    /// @notice root(w . chunk) = sha256(root(w) || chunk), where chunk = sha256(bases of the chunk).
    function extend(bytes32 parent, bytes32 chunk) public pure returns (bytes32) {
        return sha256(abi.encodePacked(parent, chunk));
    }

    /// @notice Mint a new chromosome from its first chunk. The token id is the first 16 bytes of the genesis root.
    function mint(address to, bytes32 chunk, uint64 added) external returns (uint256 id) {
        if (added == 0) revert EmptyChunk();
        bytes32 root = extend(EMPTY_ROOT, chunk);
        id = uint256(root) >> 128;
        _chromosomes[id] = Chromosome(root, added);
        emit Polymerized(id, EMPTY_ROOT, root, chunk, added, added);
        _safeMint(to, id);
    }

    /// @notice Append one chunk at the 3' end. Only the holder or an approved operator may call.
    function polymerize(uint256 id, bytes32 chunk, uint64 added) external returns (bytes32 root) {
        if (added == 0) revert EmptyChunk();
        address holder = _requireOwned(id);
        _checkAuthorized(holder, msg.sender, id);
        Chromosome storage c = _chromosomes[id];
        bytes32 parent = c.root;
        root = extend(parent, chunk);
        c.root = root;
        c.length += added;
        emit Polymerized(id, parent, root, chunk, added, c.length);
    }

    function rootOf(uint256 id) external view returns (bytes32) {
        _requireOwned(id);
        return _chromosomes[id].root;
    }

    function lengthOf(uint256 id) external view returns (uint64) {
        _requireOwned(id);
        return _chromosomes[id].length;
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

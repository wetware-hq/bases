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
    }

    string private _wiki;
    mapping(uint256 => Chromosome) private _chromosomes;

    event Committed(uint256 indexed id, bytes32 root, uint64 length);
    event Polymerized(uint256 indexed id, address indexed by, bytes32 receipt, uint64 prints);

    error EmptySequence();
    error EmptyReceipt();

    /// @param wiki URI prefix for token metadata, e.g. "https://helix.example/wiki/dna:".
    constructor(string memory wiki) ERC721("Bases", "BASES") {
        _wiki = wiki;
    }

    /// @notice Commit a chromosome. `root` = sha256(salt || bases), computed off-chain. The token id is its first 16 bytes.
    function mint(address to, bytes32 root, uint64 length) external returns (uint256 id) {
        if (length == 0) revert EmptySequence();
        id = uint256(root) >> 128;
        _chromosomes[id] = Chromosome(root, length, 0);
        emit Committed(id, root, length);
        _safeMint(to, id);
    }

    /// @notice Record one print of the committed sequence. `receipt` is a digest of the off-chain print record.
    ///         Only the holder or an approved operator may call. The sequence does not change.
    function polymerize(uint256 id, bytes32 receipt) external returns (uint64 prints) {
        if (receipt == bytes32(0)) revert EmptyReceipt();
        address holder = _requireOwned(id);
        _checkAuthorized(holder, msg.sender, id);
        prints = ++_chromosomes[id].prints;
        emit Polymerized(id, msg.sender, receipt, prints);
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

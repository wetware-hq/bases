// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Bases} from "../src/Bases.sol";

contract BasesTest is Test {
    Bases bases;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant A = keccak256("chunk A");
    bytes32 constant B = keccak256("chunk B");

    function setUp() public {
        bases = new Bases("https://helix.example/wiki/dna:");
    }

    function _mint(address to) internal returns (uint256) {
        vm.prank(to);
        return bases.mint(to, A, 4);
    }

    function test_EmptyRoot() public view {
        assertEq(bases.EMPTY_ROOT(), sha256("bases/1"));
    }

    function test_MintStoresGenesis() public {
        uint256 id = _mint(alice);
        bytes32 genesis = sha256(abi.encodePacked(sha256("bases/1"), A));
        assertEq(id, uint256(genesis));
        assertEq(bases.ownerOf(id), alice);
        assertEq(bases.rootOf(id), genesis);
        assertEq(bases.lengthOf(id), 4);
    }

    function test_MintEmits() public {
        bytes32 genesis = bases.extend(bases.EMPTY_ROOT(), A);
        vm.expectEmit(address(bases));
        emit Bases.Polymerized(uint256(genesis), bases.EMPTY_ROOT(), genesis, A, 4, 4);
        _mint(alice);
    }

    function test_DuplicateMintReverts() public {
        uint256 id = _mint(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        bases.mint(bob, A, 4);
        assertEq(bases.ownerOf(id), alice);
    }

    function test_ZeroLengthReverts() public {
        vm.expectRevert(Bases.EmptyChunk.selector);
        bases.mint(alice, A, 0);
        uint256 id = _mint(alice);
        vm.prank(alice);
        vm.expectRevert(Bases.EmptyChunk.selector);
        bases.polymerize(id, B, 0);
    }

    function test_PolymerizeExtendsPrefix() public {
        uint256 id = _mint(alice);
        bytes32 parent = bases.rootOf(id);
        vm.prank(alice);
        bytes32 root = bases.polymerize(id, B, 8);
        assertEq(root, sha256(abi.encodePacked(parent, B)));
        assertEq(bases.rootOf(id), root);
        assertEq(bases.lengthOf(id), 12);
        assertEq(id, uint256(parent), "id stays the genesis root");
    }

    function test_NonHolderCannotPolymerize() public {
        uint256 id = _mint(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, id));
        bases.polymerize(id, B, 8);
    }

    function test_ApprovedCanPolymerize() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bases.approve(bob, id);
        vm.prank(bob);
        bases.polymerize(id, B, 8);
        assertEq(bases.lengthOf(id), 12);
    }

    function test_TransferMovesPolymerizeRight() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bases.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, id));
        bases.polymerize(id, B, 8);
        vm.prank(bob);
        bases.polymerize(id, B, 8);
        assertEq(bases.ownerOf(id), bob);
    }

    function test_UnknownTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        bases.rootOf(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        bases.polymerize(1, B, 8);
    }

    function test_TokenURIIsHelixPage() public {
        uint256 id = _mint(alice);
        string memory hexId = vm.toString(bytes32(id));
        string memory want = string.concat("https://helix.example/wiki/dna:", _slice(hexId, 2, 34));
        assertEq(bases.tokenURI(id), want);
        assertEq(bytes(bases.locus(id)).length, 32);
    }

    function test_MintToNonReceiverReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(this)));
        bases.mint(address(this), A, 4);
    }

    function test_Metadata() public view {
        assertEq(bases.name(), "Bases");
        assertEq(bases.symbol(), "BASES");
    }

    function testFuzz_RootIsFoldOverChunks(bytes32[] calldata chunks, uint64 seed) public {
        vm.assume(chunks.length > 0 && chunks.length <= 16);
        uint64 n = (seed % 1000) + 1;
        vm.prank(alice);
        uint256 id = bases.mint(alice, chunks[0], n);
        bytes32 r = sha256(abi.encodePacked(sha256("bases/1"), chunks[0]));
        for (uint256 i = 1; i < chunks.length; i++) {
            vm.prank(alice);
            bases.polymerize(id, chunks[i], n);
            r = sha256(abi.encodePacked(r, chunks[i]));
        }
        assertEq(bases.rootOf(id), r);
        assertEq(bases.lengthOf(id), n * chunks.length);
    }

    function _slice(string memory s, uint256 from, uint256 to) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(to - from);
        for (uint256 i = from; i < to; i++) {
            out[i - from] = b[i];
        }
        return string(out);
    }
}

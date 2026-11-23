// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Bases} from "../src/Bases.sol";

contract BasesTest is Test {
    Bases bases;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant ROOT = keccak256("salt || ACGT");
    bytes32 constant RECEIPT = keccak256("print record 1");

    function setUp() public {
        bases = new Bases("https://helix.example/wiki/dna:");
    }

    function _mint(address to) internal returns (uint256) {
        vm.prank(to);
        return bases.mint(to, ROOT, 4);
    }

    function test_MintCommitsSequence() public {
        uint256 id = _mint(alice);
        assertEq(id, uint256(ROOT) >> 128);
        assertEq(bases.ownerOf(id), alice);
        assertEq(bases.rootOf(id), ROOT);
        assertEq(bases.lengthOf(id), 4);
        assertEq(bases.printsOf(id), 0);
    }

    function test_MintEmits() public {
        vm.expectEmit(address(bases));
        emit Bases.Committed(uint256(ROOT) >> 128, ROOT, 4);
        _mint(alice);
    }

    function test_DuplicateMintReverts() public {
        uint256 id = _mint(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        bases.mint(bob, ROOT, 8);
        assertEq(bases.ownerOf(id), alice);
        assertEq(bases.lengthOf(id), 4);
    }

    function test_ZeroLengthReverts() public {
        vm.expectRevert(Bases.EmptySequence.selector);
        bases.mint(alice, ROOT, 0);
    }

    function test_EmptyReceiptReverts() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        vm.expectRevert(Bases.EmptyReceipt.selector);
        bases.polymerize(id, bytes32(0));
    }

    function test_PolymerizeRecordsPrintAndKeepsSequence() public {
        uint256 id = _mint(alice);
        vm.expectEmit(address(bases));
        emit Bases.Polymerized(id, alice, RECEIPT, 1);
        vm.prank(alice);
        assertEq(bases.polymerize(id, RECEIPT), 1);
        vm.prank(alice);
        assertEq(bases.polymerize(id, keccak256("print record 2")), 2);
        assertEq(bases.printsOf(id), 2);
        assertEq(bases.rootOf(id), ROOT, "sequence is fixed");
        assertEq(bases.lengthOf(id), 4, "length is fixed");
    }

    function test_NonHolderCannotPolymerize() public {
        uint256 id = _mint(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, id));
        bases.polymerize(id, RECEIPT);
    }

    function test_ApprovedCanPolymerize() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bases.approve(bob, id);
        vm.expectEmit(address(bases));
        emit Bases.Polymerized(id, bob, RECEIPT, 1);
        vm.prank(bob);
        bases.polymerize(id, RECEIPT);
    }

    function test_TransferMovesPrintRightAndKeepsState() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bases.polymerize(id, RECEIPT);
        vm.prank(alice);
        bases.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, id));
        bases.polymerize(id, RECEIPT);
        vm.prank(bob);
        bases.polymerize(id, RECEIPT);
        assertEq(bases.ownerOf(id), bob);
        assertEq(bases.printsOf(id), 2);
        assertEq(bases.rootOf(id), ROOT);
    }

    function test_UnknownTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        bases.rootOf(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        bases.printsOf(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        bases.polymerize(1, RECEIPT);
    }

    function test_TokenURIIsHelixPage() public {
        uint256 id = _mint(alice);
        string memory hexId = vm.toString(bytes32(id));
        string memory want = string.concat("https://helix.example/wiki/dna:", _slice(hexId, 34, 66));
        assertEq(bases.tokenURI(id), want);
        assertEq(bytes(bases.locus(id)).length, 32);
    }

    function test_MintToNonReceiverReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(this)));
        bases.mint(address(this), ROOT, 4);
    }

    function test_Metadata() public view {
        assertEq(bases.name(), "Bases");
        assertEq(bases.symbol(), "BASES");
    }

    function testFuzz_SequenceFixedUnderPrints(bytes32 root, uint64 length, bytes32[] calldata receipts) public {
        vm.assume(length > 0 && receipts.length <= 16);
        vm.prank(alice);
        uint256 id = bases.mint(alice, root, length);
        uint64 n;
        for (uint256 i = 0; i < receipts.length; i++) {
            if (receipts[i] == bytes32(0)) continue;
            vm.prank(alice);
            bases.polymerize(id, receipts[i]);
            n++;
        }
        assertEq(bases.rootOf(id), root);
        assertEq(bases.lengthOf(id), length);
        assertEq(bases.printsOf(id), n);
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

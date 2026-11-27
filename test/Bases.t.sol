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
    bytes32 constant SECRET = keccak256("secret");

    function setUp() public {
        bases = new Bases("https://helix.example/wiki/dna:");
    }

    function _mintAs(address by, address to, bytes32 root, uint64 length) internal returns (uint256) {
        _seal(by, to, root, length);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        vm.prank(by);
        return bases.mint(to, root, length, SECRET);
    }

    function _seal(address by, address to, bytes32 root, uint64 length) internal returns (bytes32 seal) {
        seal = bases.sealOf(by, to, root, length, SECRET);
        vm.prank(by);
        bases.commit(seal);
    }

    function _mint(address to) internal returns (uint256) {
        return _mintAs(to, to, ROOT, 4);
    }

    /// tmap1 bytes of the minted ROOT token, written by wetware-hq/web ref/tensor.py `pack`, and their sha256.
    bytes constant TENSOR =
        hex"746d61703105746f6b656e05000468656164040120000000df47caf7386c472bb184f0f24c1728b80ddb649513a36a58aa53e2622c2b5a8e026964040110000000df47caf7386c472bb184f0f24c1728b8066c656e67746817000400000000000000067072696e74731700000000000000000004726f6f74040120000000df47caf7386c472bb184f0f24c1728b80ddb649513a36a58aa53e2622c2b5a8e";
    bytes32 constant TENSOR_ROOT = 0x09901c6e1cf5a24598dbcaa6d2a6e1b1fa4b1a37928a11c9df72f4782e2b4887;

    function test_TensorMapIsWebTmap1() public {
        uint256 id = _mint(alice);
        assertEq(bases.tensorOf(id), TENSOR);
        assertEq(sha256(bases.tensorOf(id)), TENSOR_ROOT);
    }

    function test_TensorMapFollowsPrints() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bases.polymerize(id, RECEIPT);
        bytes memory t = bases.tensorOf(id);
        assertEq(t.length, TENSOR.length);
        bytes32 head = keccak256(abi.encodePacked(ROOT, RECEIPT));
        bytes32 got;
        assembly {
            got := mload(add(t, add(32, 24)))
        }
        assertEq(got, head);
        assertEq(uint8(t[107]), 1); // prints = 1, little-endian, after "prints" dtype 23 rank 0
        assertTrue(sha256(t) != TENSOR_ROOT);
    }

    function test_TensorOfUnknownTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 7));
        bases.tensorOf(7);
    }

    function testFuzz_TensorMapCounts(uint64 length, uint8 prints) public {
        vm.assume(length > 0);
        uint256 id = _mintAs(alice, alice, ROOT, length);
        for (uint256 i = 0; i < prints; i++) {
            vm.prank(alice);
            bases.polymerize(id, bytes32(i + 1));
        }
        bytes memory t = bases.tensorOf(id);
        uint64 len;
        uint64 pr;
        for (uint256 i = 0; i < 8; i++) {
            len |= uint64(uint8(t[90 + i])) << uint64(8 * i);
            pr |= uint64(uint8(t[107 + i])) << uint64(8 * i);
        }
        assertEq(len, length);
        assertEq(pr, prints);
    }

    function test_EventTopicsMatchSolanaIssuer() public pure {
        assertEq(Bases.Committed.selector, 0x8e3584d232d0e22e18aa185ea690a639a6c0f6830722f402e250130cfeae923d);
        assertEq(Bases.Polymerized.selector, 0xd4d8d095c60c0dfb06f4fedf3c8ad252c56c26cb7d7e77a9ac7d1fe077b28428);
    }

    function test_MintCommitsSequence() public {
        uint256 id = _mint(alice);
        assertEq(id, uint256(ROOT) >> 128);
        assertEq(bases.ownerOf(id), alice);
        assertEq(bases.rootOf(id), ROOT);
        assertEq(bases.lengthOf(id), 4);
        assertEq(bases.printsOf(id), 0);
        assertEq(bases.headOf(id), ROOT);
    }

    function test_MintEmits() public {
        _seal(alice, alice, ROOT, 4);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        vm.expectEmit(address(bases));
        emit Bases.Committed(uint256(ROOT) >> 128, ROOT, 4);
        vm.prank(alice);
        bases.mint(alice, ROOT, 4, SECRET);
    }

    function test_DuplicateMintReverts() public {
        uint256 id = _mint(alice);
        _seal(bob, bob, ROOT, 8);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        bases.mint(bob, ROOT, 8, SECRET);
        assertEq(bases.ownerOf(id), alice);
        assertEq(bases.lengthOf(id), 4);
    }

    function test_ZeroLengthReverts() public {
        _seal(alice, alice, ROOT, 0);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        vm.prank(alice);
        vm.expectRevert(Bases.EmptySequence.selector);
        bases.mint(alice, ROOT, 0, SECRET);
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
        emit Bases.Polymerized(id, alice, RECEIPT, 1, keccak256(abi.encodePacked(ROOT, RECEIPT)));
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
        emit Bases.Polymerized(id, bob, RECEIPT, 1, keccak256(abi.encodePacked(ROOT, RECEIPT)));
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
        _seal(address(this), address(this), ROOT, 4);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(this)));
        bases.mint(address(this), ROOT, 4, SECRET);
    }

    function test_Metadata() public view {
        assertEq(bases.name(), "Bases");
        assertEq(bases.symbol(), "BASES");
    }

    function test_CommitEmitsAndRecordsTime() public {
        bytes32 seal = bases.sealOf(alice, alice, ROOT, 4, SECRET);
        vm.expectEmit(address(bases));
        emit Bases.Sealed(seal, alice);
        vm.prank(alice);
        bases.commit(seal);
        assertEq(bases.committedAt(alice, seal), block.timestamp);
    }

    function test_EmptyOrRepeatSealReverts() public {
        vm.expectRevert(Bases.EmptySeal.selector);
        bases.commit(bytes32(0));
        bytes32 seal = _seal(alice, alice, ROOT, 4);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Bases.AlreadySealed.selector, seal));
        bases.commit(seal);
    }

    function test_ThirdPartyCommitDoesNotBlockMinter() public {
        bytes32 seal = bases.sealOf(alice, alice, ROOT, 4, SECRET);
        vm.prank(bob);
        bases.commit(seal);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(alice);
        bases.commit(seal);
        assertEq(bases.committedAt(alice, seal), vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE() - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Bases.SealTooNew.selector, seal, vm.getBlockTimestamp() + 1));
        bases.mint(alice, ROOT, 4, SECRET);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        assertEq(bases.mint(alice, ROOT, 4, SECRET), uint256(ROOT) >> 128);
    }

    function test_ExpiredSealCanBeRecommitted() public {
        bytes32 seal = _seal(alice, alice, ROOT, 4);
        vm.warp(vm.getBlockTimestamp() + bases.MAX_COMMIT_AGE());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Bases.AlreadySealed.selector, seal));
        bases.commit(seal);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        bases.commit(seal);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        vm.prank(alice);
        bases.mint(alice, ROOT, 4, SECRET);
        assertEq(bases.committedAt(alice, seal), 0);
    }

    function test_MintWithoutCommitReverts() public {
        bytes32 seal = bases.sealOf(alice, alice, ROOT, 4, SECRET);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Bases.UnknownSeal.selector, seal));
        bases.mint(alice, ROOT, 4, SECRET);
    }

    function test_RevealTooSoonReverts() public {
        bytes32 seal = _seal(alice, alice, ROOT, 4);
        uint256 at = vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE();
        vm.warp(at - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Bases.SealTooNew.selector, seal, at));
        bases.mint(alice, ROOT, 4, SECRET);
    }

    function test_RevealAfterExpiryReverts() public {
        bytes32 seal = _seal(alice, alice, ROOT, 4);
        vm.warp(vm.getBlockTimestamp() + bases.MAX_COMMIT_AGE() + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Bases.SealExpired.selector, seal));
        bases.mint(alice, ROOT, 4, SECRET);
    }

    function test_CopiedRevealCannotFrontRun() public {
        _seal(alice, alice, ROOT, 4);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        // bob copies alice's pending reveal; the seal binds the caller, so bob's copy has no commit
        bytes32 bobSeal = bases.sealOf(bob, bob, ROOT, 4, SECRET);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Bases.UnknownSeal.selector, bobSeal));
        bases.mint(bob, ROOT, 4, SECRET);
        // and redirecting alice's own seal to bob fails too
        bytes32 redirected = bases.sealOf(bob, alice, ROOT, 4, SECRET);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Bases.UnknownSeal.selector, redirected));
        bases.mint(alice, ROOT, 4, SECRET);
        vm.prank(alice);
        uint256 id = bases.mint(alice, ROOT, 4, SECRET);
        assertEq(bases.ownerOf(id), alice);
    }

    function test_SealIsSpentOnMint() public {
        bytes32 seal = _seal(alice, alice, ROOT, 4);
        vm.warp(vm.getBlockTimestamp() + bases.MIN_COMMIT_AGE());
        vm.prank(alice);
        bases.mint(alice, ROOT, 4, SECRET);
        assertEq(bases.committedAt(alice, seal), 0);
    }

    function test_MintToOtherRecipient() public {
        uint256 id = _mintAs(alice, bob, ROOT, 4);
        assertEq(bases.ownerOf(id), bob);
    }

    function test_PrintChainSurvivesTransfer() public {
        uint256 id = _mint(alice);
        bytes32 r2 = keccak256("print record 2");
        vm.prank(alice);
        bases.polymerize(id, RECEIPT);
        vm.prank(alice);
        bases.transferFrom(alice, bob, id);
        vm.prank(bob);
        bases.polymerize(id, r2);
        bytes32 want = keccak256(abi.encodePacked(keccak256(abi.encodePacked(ROOT, RECEIPT)), r2));
        assertEq(bases.headOf(id), want);
    }

    function testFuzz_SequenceFixedUnderPrints(bytes32 root, uint64 length, bytes32[] calldata receipts) public {
        vm.assume(length > 0 && receipts.length <= 16);
        uint256 id = _mintAs(alice, alice, root, length);
        uint64 n;
        bytes32 head = root;
        for (uint256 i = 0; i < receipts.length; i++) {
            if (receipts[i] == bytes32(0)) continue;
            vm.prank(alice);
            bases.polymerize(id, receipts[i]);
            head = keccak256(abi.encodePacked(head, receipts[i]));
            n++;
        }
        assertEq(bases.headOf(id), head, "print chain replays from receipts");
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

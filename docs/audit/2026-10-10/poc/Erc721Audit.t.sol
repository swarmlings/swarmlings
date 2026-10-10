// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {SwarmlingsMirror, ICreatorToken} from "../../src/SwarmlingsMirror.sol";

/// @dev Logo with every awkward character.
contract NastyLogoRenderer {
    string public svg;

    constructor(string memory s) {
        svg = s;
    }

    function logoSVG() external view returns (string memory) {
        return svg;
    }

    function tokenURI(uint256) external pure returns (string memory) {
        return "x";
    }
}

contract RecordingValidator {
    address public lastCaller;
    address public lastFrom;
    address public lastTo;
    uint256 public lastId;
    uint256 public n;

    // staticcall-compatible: record via a non-view fallback is impossible, so use the mirror's call data in a revert-less way
    function validateTransfer(address caller, address from, address to, uint256 id) external view {
        // encode the observed args into a revert only when `id` has a magic high bit set (test hook)
        if (id == 0xdead) revert(string(abi.encodePacked(caller, from, to)));
    }
}

contract Receiver {
    bytes4 constant OK = 0x150b7a02;
    address public op;
    address public from_;
    uint256 public id_;

    function onERC721Received(address o, address f, uint256 i, bytes calldata) external returns (bytes4) {
        op = o;
        from_ = f;
        id_ = i;
        return OK;
    }
}

contract NoReceiver {}

contract Erc721AuditTest is Test {
    address launcher = makeAddr("launcher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    Swarmlings ling;
    SwarmlingsMirror mirror;
    uint256 UNIT;

    function setUp() public {
        vm.prank(launcher);
        ling = new Swarmlings();
        mirror = SwarmlingsMirror(payable(ling.mirrorERC721()));
        UNIT = ling.UNIT();
        vm.warp(1_800_000_000);
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(launcher);
        ling.transfer(to, amount);
    }

    // ---------------------------------------------------------------- ERC-165
    function test_interfaceIds() public view {
        bytes4 id = type(ICreatorToken).interfaceId;
        bytes4 manual = bytes4(keccak256("getTransferValidator()")) ^ bytes4(keccak256("getTransferValidationFunction()"))
            ^ bytes4(keccak256("setTransferValidator(address)"));
        assertEq(id, manual);
        assertEq(id, bytes4(0xad0d7f6c), "LimitBreak ICreatorToken id");
        assertTrue(mirror.supportsInterface(0x2a55205a));
        assertTrue(mirror.supportsInterface(0xad0d7f6c));
        assertTrue(mirror.supportsInterface(0x80ac58cd));
        assertTrue(mirror.supportsInterface(0x5b5e139f));
        assertTrue(mirror.supportsInterface(0x01ffc9a7));
        assertFalse(mirror.supportsInterface(0xffffffff));
        assertEq(bytes4(keccak256("validateTransfer(address,address,address,uint256)")), bytes4(0xcaee23ea));
    }

    // ---------------------------------------------------------------- contractURI
    function _etchLogo(string memory s) internal {
        vm.etch(ling.RENDERER(), address(new NastyLogoRenderer(s)).code);
        // storage of the immutable-less contract: set svg via storage write
        // slot 0 holds the string; easier: deploy then copy storage
    }

    function _deployLogo(string memory s) internal {
        NastyLogoRenderer r = new NastyLogoRenderer(s);
        vm.etch(ling.RENDERER(), address(r).code);
        // copy string storage (slot 0) — long string layout handled by copying len slot and data slots
        bytes32 lenSlot = vm.load(address(r), bytes32(uint256(0)));
        vm.store(ling.RENDERER(), bytes32(uint256(0)), lenSlot);
        uint256 len = bytes(s).length;
        if (len > 31) {
            uint256 base = uint256(keccak256(abi.encode(uint256(0))));
            for (uint256 i; i < (len + 31) / 32; ++i) {
                vm.store(ling.RENDERER(), bytes32(base + i), vm.load(address(r), bytes32(base + i)));
            }
        }
    }

    event log_bytes_(bytes b);

    function test_contractURI_nastyLogo() public {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect fill="#fff" width="100%" height="110%"/>',
            "<text>a < b && c > d \xc3\xa9 \xe2\x9c\x93 'q'</text></svg>"
        );
        _deployLogo(svg);
        string memory uri = mirror.contractURI();
        emit log_named_bytes("URI_NASTY", bytes(uri));
        emit log_named_bytes("SVG_NASTY", bytes(svg));
    }

    function test_contractURI_controlChars() public {
        string memory svg = string.concat('<svg a="1">\n\t<g id="x\\y"/></svg>');
        _deployLogo(svg);
        string memory uri = mirror.contractURI();
        emit log_named_bytes("URI_CTRL", bytes(uri));
        emit log_named_bytes("SVG_CTRL", bytes(svg));
    }

    function test_contractURI_noRenderer_reverts() public {
        assertEq(ling.RENDERER().code.length, 0);
        vm.expectRevert();
        mirror.contractURI();
        // tokenURI by contrast survives
        _give(alice, UNIT);
        assertGt(bytes(mirror.tokenURI(1)).length, 0);
    }

    function test_contractURI_rendererWithEmptyReturn_reverts() public {
        vm.etch(ling.RENDERER(), hex"00");
        // code of 0x00 (STOP): call succeeds with empty return -> decode failure in caller, NOT caught
        vm.expectRevert();
        mirror.contractURI();
    }

    function test_tokenURIFallback() public {
        _give(alice, UNIT);
        string memory u = mirror.tokenURI(1);
        emit log_named_bytes("FALLBACK", bytes(u));
    }

    // ---------------------------------------------------------------- approvals
    function test_staleApprovalClearedOnBalanceBurnAndRemint() public {
        _give(alice, UNIT * 3);
        uint256[] memory ids = ling.ownedIds(alice, 0, 3);
        uint256 target = ids[2]; // last: burned first
        vm.prank(alice);
        mirror.approve(bob, target);
        assertEq(mirror.getApproved(target), bob);
        // alice sells one unit -> burns `target`
        vm.prank(alice);
        ling.transfer(carol, 0); // noop
        vm.prank(alice);
        ling.burn(UNIT);
        vm.expectRevert();
        mirror.ownerOf(target);
        // DN404 hands out ids in a cycle: push the cycle around (3333 ids) until `target` is minted again
        address[] memory sink = new address[](6);
        for (uint256 i; i < sink.length && mirror.ownerAt(target) == address(0); ++i) {
            sink[i] = makeAddr(string.concat("sink", vm.toString(i)));
            uint256 avail = ling.balanceOf(launcher) / UNIT;
            _give(sink[i], UNIT * (avail > 700 ? 700 : avail));
        }
        address o = mirror.ownerAt(target);
        assertTrue(o != address(0), "id re-minted");
        assertTrue(o != alice);
        assertEq(mirror.getApproved(target), address(0), "approval cleared");
        vm.prank(bob);
        vm.expectRevert();
        mirror.transferFrom(o, bob, target);
        // and the new owner is not exposed to bob in any way
        assertFalse(mirror.isApprovedForAll(o, bob));
    }

    function test_staleApprovalClearedOnDirectTransfer() public {
        _give(alice, UNIT * 2);
        uint256[] memory ids = ling.ownedIds(alice, 0, 2);
        vm.prank(alice);
        mirror.approve(bob, ids[1]);
        vm.prank(alice);
        ling.transfer(carol, UNIT); // direct transfer of last id
        assertEq(mirror.ownerOf(ids[1]), carol);
        assertEq(mirror.getApproved(ids[1]), address(0));
        vm.prank(bob);
        vm.expectRevert();
        mirror.transferFrom(carol, bob, ids[1]);
    }

    function test_approvalClearedOnNftTransfer() public {
        _give(alice, UNIT);
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        vm.startPrank(alice);
        mirror.approve(bob, id);
        mirror.transferFrom(alice, carol, id);
        vm.stopPrank();
        assertEq(mirror.getApproved(id), address(0));
        vm.prank(carol);
        mirror.transferFrom(carol, alice, id);
        assertEq(mirror.getApproved(id), address(0));
    }

    // ---------------------------------------------------------------- msg.sender propagation
    function test_approvedOperatorAndNonOperator() public {
        _give(alice, UNIT);
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(bob);
        vm.expectRevert();
        mirror.transferFrom(alice, bob, id);
        vm.prank(alice);
        mirror.approve(bob, id);
        vm.prank(bob);
        mirror.safeTransferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
    }

    function test_safeTransferPassesOriginalCallerToValidator() public {
        RecordingValidator v = new RecordingValidator();
        vm.etch(mirror.TRANSFER_VALIDATOR(), address(v).code);
        _give(alice, UNIT);
        // id 0xdead does not exist -> validator reverts with caller/from/to packed
        vm.prank(bob);
        try mirror.safeTransferFrom(alice, carol, 0xdead) {
            fail();
        } catch Error(string memory reason) {
            bytes memory b = bytes(reason);
            assertEq(address(bytes20(b)), bob, "caller");
            bytes memory fromB = new bytes(20);
            for (uint256 i; i < 20; ++i) fromB[i] = b[20 + i];
            assertEq(address(bytes20(fromB)), alice);
        }
    }

    function test_safeTransferToContracts() public {
        _give(alice, UNIT * 2);
        uint256[] memory ids = ling.ownedIds(alice, 0, 2);
        Receiver r = new Receiver();
        vm.prank(alice);
        mirror.safeTransferFrom(alice, address(r), ids[0], "hi");
        assertEq(r.op(), alice);
        assertEq(r.id_(), ids[0]);
        NoReceiver nr = new NoReceiver();
        vm.prank(alice);
        vm.expectRevert();
        mirror.safeTransferFrom(alice, address(nr), ids[1]);
        // plain transferFrom to a non receiver is allowed (ERC-721 permits)
        vm.prank(alice);
        mirror.transferFrom(alice, address(nr), ids[1]);
        assertEq(mirror.ownerOf(ids[1]), address(nr));
        // contract holding an NFT is counted for rewards
        assertEq(ling.activeNFTs(), 2);
    }

    // ---------------------------------------------------------------- events
    function test_eventsOnMintBurnTransfer() public {
        vm.recordLogs();
        _give(alice, UNIT * 2); // mint 2
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 mintLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(mirror) && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) {
                assertEq(logs[i].topics[1], bytes32(0));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
                ++mintLogs;
            }
        }
        assertEq(mintLogs, 2);
        uint256 id = ling.ownedIds(alice, 0, 2)[1];

        vm.recordLogs();
        vm.prank(alice);
        mirror.transferFrom(alice, bob, id);
        logs = vm.getRecordedLogs();
        uint256 nft;
        uint256 erc20;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(mirror) && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) ++nft;
            if (logs[i].emitter == address(ling) && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) ++erc20;
        }
        assertEq(nft, 1, "single 721 Transfer on NFT transfer");
        assertEq(erc20, 1);

        vm.recordLogs();
        vm.prank(alice);
        ling.burn(UNIT);
        logs = vm.getRecordedLogs();
        uint256 burnLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(mirror) && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice);
                assertEq(logs[i].topics[2], bytes32(0));
                ++burnLogs;
            }
        }
        assertEq(burnLogs, 1);
    }

    // ---------------------------------------------------------------- keep consistency
    function _checkList(address who) internal view {
        uint256 n = mirror.balanceOf(who);
        uint256[] memory ids = ling.ownedIds(who, 0, n + 5);
        assertEq(ids.length, n);
        for (uint256 i; i < n; ++i) {
            assertEq(mirror.ownerOf(ids[i]), who);
            for (uint256 j; j < i; ++j) assertTrue(ids[i] != ids[j]);
        }
    }

    function testFuzz_keepThenOps(uint256 seed) public {
        _give(alice, UNIT * 12);
        _give(bob, UNIT * 3);
        for (uint256 step; step < 12; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 5;
            address who = (seed >> 8) % 2 == 0 ? alice : bob;
            uint256 n = mirror.balanceOf(who);
            if (n == 0) continue;
            uint256[] memory ids = ling.ownedIds(who, 0, n);
            if (op == 0) {
                uint256 k = 1 + (seed >> 16) % n;
                uint256[] memory pick = new uint256[](k);
                uint256 start = (seed >> 32) % n;
                for (uint256 i; i < k; ++i) pick[i] = ids[(start + i * 7 + i) % n];
                // dedupe check by trying; revert is fine for duplicates
                vm.prank(who);
                try ling.keep(pick) {
                    uint256[] memory after_ = ling.ownedIds(who, 0, k);
                    for (uint256 i; i < k; ++i) assertEq(after_[i], pick[i], "keep order");
                } catch {}
            } else if (op == 1) {
                vm.prank(who);
                mirror.transferFrom(who, who == alice ? bob : alice, ids[(seed >> 16) % n]);
            } else if (op == 2) {
                uint256 amt = _min(ling.balanceOf(who), UNIT * (1 + (seed >> 16) % 2));
                vm.prank(who);
                ling.transfer(who == alice ? bob : alice, amt);
            } else if (op == 3) {
                uint256 amt2 = _min(ling.balanceOf(who), UNIT / 2 + (seed >> 16) % UNIT);
                vm.prank(who);
                ling.burn(amt2);
            } else {
                vm.prank(who);
                mirror.transferFrom(who, who, ids[(seed >> 16) % n]);
            }
            _checkList(alice);
            _checkList(bob);
            assertEq(mirror.totalSupply(), mirror.balanceOf(alice) + mirror.balanceOf(bob));
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function test_keepProtectsFromBurn() public {
        _give(alice, UNIT * 4);
        uint256[] memory ids = ling.ownedIds(alice, 0, 4);
        uint256[] memory k = new uint256[](2);
        k[0] = ids[3];
        k[1] = ids[2];
        vm.prank(alice);
        ling.keep(k);
        vm.prank(alice);
        ling.burn(UNIT * 2);
        assertEq(mirror.ownerAt(ids[3]), alice);
        assertEq(mirror.ownerAt(ids[2]), alice);
        assertEq(mirror.ownerAt(ids[0]), address(0));
        assertEq(mirror.ownerAt(ids[1]), address(0));
    }

    function test_keepBogusIds() public {
        _give(alice, UNIT * 2);
        uint256[] memory k = new uint256[](1);
        k[0] = (1 << 32) + ling.ownedIds(alice, 0, 1)[0]; // masks to... check
        vm.prank(alice);
        try ling.keep(k) {
            emit log("keep accepted a >32-bit id");
        } catch {
            emit log("keep rejected >32-bit id");
        }
        _checkList(alice);
        k[0] = 0;
        vm.prank(alice);
        try ling.keep(k) {
            emit log("keep accepted id 0");
        } catch {
            emit log("keep rejected id 0");
        }
        _checkList(alice);
    }

    // ---------------------------------------------------------------- misc
    function test_burnedIdViews() public {
        _give(alice, UNIT);
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(alice);
        ling.burn(UNIT);
        vm.expectRevert();
        mirror.ownerOf(id);
        assertEq(mirror.ownerAt(id), address(0));
        vm.expectRevert();
        mirror.tokenURI(id);
        vm.expectRevert();
        mirror.getApproved(id);
        assertEq(mirror.balanceOf(address(0)), 0);
    }

    function test_royaltyHugePriceReverts() public {
        vm.expectRevert();
        mirror.royaltyInfo(1, type(uint256).max);
    }

    function test_royaltyTwoThousandThreeHundredGasReceive() public {
        // 2300-gas stipend sender (WETH9.withdraw uses transfer)
        Sender s = new Sender();
        vm.deal(address(s), 1 ether);
        s.pay(address(ling));
        assertEq(address(ling).balance, 1 ether + 0);
    }

    function test_ownerLiveAndUnlinkedMirror() public {
        assertEq(mirror.owner(), ling.DEV());
        // a standalone mirror (unlinked) reverts NotLinked on owner()
        SwarmlingsMirror m2 = new SwarmlingsMirror(address(this));
        vm.expectRevert();
        m2.owner();
        vm.expectRevert();
        m2.contractURI();
    }

    function test_nftToTokenContractIsDeadWeight() public {
        _give(alice, UNIT);
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(alice);
        mirror.transferFrom(alice, address(ling), id);
        assertEq(mirror.ownerOf(id), address(ling));
        assertEq(ling.activeNFTs(), 1);
    }

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function test_noOwnershipEventAtLaunchButPullOwnerWorks() public {
        // stored owner is empty (the base could not answer during construction); `owner()` is live anyway
        vm.recordLogs();
        mirror.pullOwner();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "first pullOwner emits OwnershipTransferred(0, DEV)");
        assertEq(logs[0].topics[0], OwnershipTransferred.selector);
    }

    function test_directLingTransferEmitsErc721Logs() public {
        _give(alice, UNIT * 2);
        uint256[] memory ids = ling.ownedIds(alice, 0, 2);
        vm.recordLogs();
        vm.prank(alice);
        ling.transfer(bob, UNIT * 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(mirror)) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), bob);
                ++n;
            }
        }
        assertEq(n, 2);
        assertEq(mirror.ownerOf(ids[0]), bob);
    }
}

contract Sender {
    function pay(address to) external {
        payable(to).transfer(1 ether);
    }
}

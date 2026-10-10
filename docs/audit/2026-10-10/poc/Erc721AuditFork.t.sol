// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {SwarmlingsMirror} from "../../src/SwarmlingsMirror.sol";

interface IRegistry {
    function beforeAuthorizedTransfer(address token, uint256 tokenId) external;
    function afterAuthorizedTransfer(address token, uint256 tokenId) external;
    function setTransferSecurityLevelOfCollection(address collection, uint8 level) external;
    function getAuthorizerAccountsByCollection(address collection) external view returns (address[] memory);
    function isAccountAuthorizerOfCollection(address collection, address account) external view returns (bool);
}

interface IWETH {
    function balanceOf(address) external view returns (uint256);
}

contract Receiver721 {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}

contract Plain {}

/// @dev Mainnet fork (MAINNET_RPC_URL): real OpenSea registry, real renderer, real WETH.
contract Erc721AuditForkTest is Test {
    address constant REG = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100; // OpenSea SignedZone
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    Swarmlings ling;
    SwarmlingsMirror mirror;
    address alice = address(uint160(uint256(keccak256("audit fork alice"))));
    address bob = address(uint160(uint256(keccak256("audit fork bob"))));
    address market = address(uint160(uint256(keccak256("audit fork market"))));
    bool live;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        ling = new Swarmlings();
        mirror = SwarmlingsMirror(payable(ling.mirrorERC721()));
        ling.transfer(alice, ling.UNIT() * 3);
    }

    function test_fork_realContractURI_and_tokenURI() public {
        if (!live) return;
        assertGt(ling.RENDERER().code.length, 0);
        emit log_named_bytes("REAL_URI", bytes(mirror.contractURI()));
        emit log_named_bytes("REAL_TOKEN_URI", bytes(mirror.tokenURI(ling.ownedIds(alice, 0, 1)[0])));
        (bool ok, bytes memory ret) = ling.RENDERER().staticcall(abi.encodeWithSignature("logoSVG()"));
        assertTrue(ok);
        emit log_named_bytes("REAL_SVG", abi.decode(ret, (bytes)));
    }

    function test_fork_zoneAuthorizedSale() public {
        if (!live) return;
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        assertTrue(IRegistry(REG).isAccountAuthorizerOfCollection(address(mirror), ZONE), "default list has SignedZone");
        vm.prank(alice);
        mirror.setApprovalForAll(market, true);
        // not authorized: blocked
        vm.prank(market);
        vm.expectRevert();
        mirror.transferFrom(alice, bob, id);
        // zone attests (as Seaport + SignedZone do around fulfillment), operator transfers, zone clears
        vm.prank(ZONE);
        IRegistry(REG).beforeAuthorizedTransfer(address(mirror), id);
        vm.prank(market);
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
        vm.prank(ZONE);
        IRegistry(REG).afterAuthorizedTransfer(address(mirror), id);
        // another id of alice is still protected
        uint256 id2 = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(market);
        vm.expectRevert();
        mirror.transferFrom(alice, bob, id2);
        // flag for id does not authorise id2
        vm.prank(ZONE);
        IRegistry(REG).beforeAuthorizedTransfer(address(mirror), id);
        vm.prank(market);
        vm.expectRevert();
        mirror.transferFrom(alice, bob, id2);
    }

    function test_fork_ownersToContractsAndSafe() public {
        if (!live) return;
        uint256[] memory ids = ling.ownedIds(alice, 0, 3);
        Receiver721 r = new Receiver721();
        Plain p = new Plain();
        vm.startPrank(alice);
        mirror.safeTransferFrom(alice, address(r), ids[0]);
        mirror.transferFrom(alice, address(p), ids[1]);
        mirror.safeTransferFrom(alice, bob, ids[2], "x");
        vm.stopPrank();
        assertEq(mirror.ownerOf(ids[0]), address(r));
        assertEq(mirror.ownerOf(ids[1]), address(p));
        // contract holder can send onward as `from == caller`
        vm.prank(address(p));
        mirror.transferFrom(address(p), alice, ids[1]);
    }

    function test_fork_devCanReconfigureCollectionPolicy() public {
        if (!live) return;
        address dev = ling.DEV();
        assertEq(mirror.owner(), dev);
        uint256[] memory ids = ling.ownedIds(alice, 0, 3);
        uint256 blockedLevels;
        for (uint8 lvl = 0; lvl <= 9; ++lvl) {
            uint256 snap = vm.snapshotState();
            vm.prank(dev);
            (bool set,) = REG.call(abi.encodeCall(IRegistry.setTransferSecurityLevelOfCollection, (address(mirror), lvl)));
            if (set) {
                vm.prank(alice);
                (bool ok,) = address(mirror).call(abi.encodeCall(mirror.transferFrom, (alice, bob, ids[0])));
                emit log_named_uint(ok ? "level allows owner transfer" : "level BLOCKS owner transfer", lvl);
                if (!ok) ++blockedLevels;
            } else {
                emit log_named_uint("setLevel failed", lvl);
            }
            vm.revertToState(snap);
        }
        // a non-owner cannot
        vm.prank(alice);
        (bool s2,) = REG.call(abi.encodeCall(IRegistry.setTransferSecurityLevelOfCollection, (address(mirror), 1)));
        assertFalse(s2, "only the collection owner");
        emit log_named_uint("levels blocking owner transfers", blockedLevels);
    }

    function test_fork_wethCreatorFeeIsUnwrapped() public {
        if (!live) return;
        vm.deal(WETH, WETH.balance + 1 ether);
        uint256 devBefore = ling.devOwed();
        deal(WETH, address(ling), 1 ether);
        ling.syncEth();
        assertEq(IWETH(WETH).balanceOf(address(ling)), 0, "unwrapped via 2300-gas receive()");
        assertGe(ling.devOwed() - devBefore, 0.5 ether);
    }

    function test_fork_otherCurrenciesAreStuck() public {
        if (!live) return;
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        deal(usdc, address(ling), 1000e6);
        ling.syncEth();
        // nothing in Swarmlings can move it out (no rescue / arbitrary-call function exists)
        assertEq(IWETH(usdc).balanceOf(address(ling)), 1000e6);
    }

    function test_fork_levels78BlockSelfTransfer() public {
        if (!live) return;
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        for (uint8 lvl = 7; lvl <= 8; ++lvl) {
            uint256 snap = vm.snapshotState();
            vm.prank(ling.DEV());
            IRegistry(REG).setTransferSecurityLevelOfCollection(address(mirror), lvl);
            vm.prank(alice);
            vm.expectRevert();
            mirror.transferFrom(alice, alice, id);
            // LING path still works
            vm.prank(alice);
            ling.transfer(bob, ling.UNIT());
            assertEq(mirror.balanceOf(bob), 1);
            vm.revertToState(snap);
        }
    }

    function test_fork_devCanSwitchEnforcementOff() public {
        if (!live) return;
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(alice);
        mirror.setApprovalForAll(market, true);
        vm.prank(market);
        vm.expectRevert(); // default: unauthorised operator is stopped
        mirror.transferFrom(alice, bob, id);
        vm.prank(ling.DEV());
        IRegistry(REG).setTransferSecurityLevelOfCollection(address(mirror), 1);
        vm.prank(market); // after DEV flips the level, any approved operator moves the NFT with no creator fee
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
    }
}

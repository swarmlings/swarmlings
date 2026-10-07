// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {SwarmlingsMirror} from "../../src/SwarmlingsMirror.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Against the real OpenSea registry and the real IMD on an Ethereum mainnet fork. Skipped unless
/// MAINNET_RPC_URL is set:  MAINNET_RPC_URL=https://... forge test --match-path test/fork/*
contract ValidatorForkTest is Test {
    Swarmlings ling;
    SwarmlingsMirror mirror;
    // fresh addresses: the usual test names are EIP-7702 delegated on mainnet, so they would skip NFTs
    address alice = address(uint160(uint256(keccak256("swarmlings fork alice"))));
    address bob = address(uint160(uint256(keccak256("swarmlings fork bob"))));
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

    function test_fork_ownersMoveTheirOwnNfts() public {
        if (!live) return;
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(alice);
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
        uint256 next = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(alice);
        mirror.safeTransferFrom(alice, alice, next); // self-transfer: the "keep" trick
    }

    function test_fork_unauthorizedOperatorsAreStopped() public {
        if (!live) return;
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        address market = makeAddr("some other market");
        vm.prank(alice);
        mirror.setApprovalForAll(market, true);
        vm.prank(market);
        vm.expectRevert();
        mirror.transferFrom(alice, bob, id);
        vm.prank(alice); // the LING path always works
        ling.transfer(bob, ling.UNIT());
        assertEq(mirror.balanceOf(bob), 1);
    }

    function test_fork_marketplaceView() public {
        if (!live) return;
        assertEq(mirror.owner(), ling.DEV());
        assertEq(ling.rewardCurrency(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        (address r, uint256 fee) = mirror.royaltyInfo(1, 1 ether);
        assertEq(r, address(ling));
        assertEq(fee, 0.05 ether);
    }

    function test_fork_realImdRewards() public {
        if (!live) return;
        address imd = ling.IMD();
        deal(imd, address(ling), 100e18);
        ling.syncToken();
        skip(1 days);
        vm.prank(alice);
        (, uint256 t) = ling.claim();
        assertApproxEqAbs(t, 100e18, 1e6);
        assertEq(IERC20(imd).balanceOf(alice), t);
    }
}

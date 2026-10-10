// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {SwarmlingsMirror} from "../../src/SwarmlingsMirror.sol";

/// @dev Exposes DN404's private-ish indexes so the owned-list / owned-index pairing can be checked.
contract Harness is Swarmlings {
    function ooIdx(uint256 id) external view returns (uint256) {
        DN404Storage storage $ = _getDN404Storage();
        return _get($.oo, _ownedIndex(id));
    }

    function nextTokenId() external view returns (uint256) {
        return _getDN404Storage().nextTokenId;
    }
}

/// @dev A reward token with switchable transfer behaviour.
contract FlexToken {
    mapping(address => uint256) public balanceOf;
    uint8 public mode; // 0 returns true, 1 returns nothing, 2 returns false, 3 reverts

    function setMode(uint8 m) external {
        mode = m;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (mode == 3) revert("nope");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (mode == 1) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == 2) return false;
        return true;
    }
}

contract ReenterTransfer {
    Harness immutable ling;
    address immutable sink;
    uint256 public hits;
    bool public secondClaimReverted;

    constructor(Harness l, address s) {
        ling = l;
        sink = s;
        l.setSkipNFT(false);
    }

    function claim() external {
        ling.claim();
    }

    receive() external payable {
        ++hits;
        // move everything away mid-claim and try to claim again
        ling.transfer(sink, ling.balanceOf(address(this)));
        try ling.claim() {}
        catch {
            secondClaimReverted = true;
        }
    }
}

contract ERC20AuditBase is Test {
    address launcher = makeAddr("launcher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    Harness ling;
    SwarmlingsMirror mirror;
    uint256 UNIT;
    uint256 DAY;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function _deploy() internal {
        vm.prank(launcher);
        ling = new Harness();
        mirror = SwarmlingsMirror(payable(ling.mirrorERC721()));
        UNIT = ling.UNIT();
        DAY = ling.EPOCH();
        vm.warp(1_800_000_000);
        vm.deal(address(this), 1_000 ether);
    }

    function setUp() public virtual {
        _deploy();
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(launcher);
        ling.transfer(to, amount);
    }

    function _paidOut() internal {
        vm.warp((block.timestamp / DAY + 2) * DAY);
    }
}

// ============================================================================================================
// E-1: nextMintIds uses MAX_NFTS as the wrap limit; DN404 wraps at totalSupply / UNIT, which shrinks with burns.
// E-2: nextMintIds never terminates once all 3,333 ids exist.
// ============================================================================================================
contract NextMintIdsAudit is ERC20AuditBase {
    function test_E1_nextMintIdsDisagreesWithMintAfterSupplyBurn() public {
        _give(alice, UNIT * 10); // ids 1..10, DN404's nextTokenId is now 11
        // the launcher burns down to 100k LING: totalSupply = 10 units + 100k LING => floor(supply/UNIT) = 10
        uint256 lb = ling.balanceOf(launcher);
        vm.prank(launcher);
        ling.burn(lb - 100_000e18);
        assertEq(ling.totalSupply() / UNIT, 10);
        // alice sells one unit back: id 10 burns, ids 1..9 remain
        vm.prank(alice);
        ling.transfer(launcher, UNIT);
        assertEq(mirror.ownerAt(10), address(0));
        // now a mint must reuse id 10 (11 is beyond floor(totalSupply/UNIT) = 10), but the view says 11
        uint256[] memory predicted = ling.nextMintIds(1);
        _give(bob, UNIT);
        uint256 actual = ling.ownedIds(bob, 0, 1)[0];
        console2.log("nextMintIds(1)[0] =", predicted[0]);
        console2.log("id actually minted =", actual);
        assertEq(actual, 10, "DN404 wraps at totalSupply/UNIT");
        assertEq(predicted[0], 11, "the view predicts an id that can no longer be minted");
        assertTrue(predicted[0] != actual);
    }

    function test_E2_nextMintIdsNeverReturnsWhenAllIdsExist() public {
        // 3,333 NFTs spread over 5 wallets (each step <= 800 units, so no auto skip)
        address[5] memory w = [alice, bob, carol, makeAddr("d"), makeAddr("e")];
        uint256[5] memory units = [uint256(800), 800, 800, 800, 133];
        for (uint256 i; i < 5; ++i) {
            _give(w[i], UNIT * units[i]);
        }
        assertEq(ling.activeNFTs(), 3333);
        // every id exists: the view's `while (_exists(id))` cycles forever
        (bool ok,) = address(ling).staticcall{gas: 30_000_000}(abi.encodeCall(ling.nextMintIds, (1)));
        assertFalse(ok, "out of gas: eth_call can never answer");
        // also true for n = 0? (no loop) and works when one id is free
        assertEq(ling.nextMintIds(0).length, 0);
        vm.prank(w[0]);
        ling.transfer(launcher, UNIT);
        (ok,) = address(ling).staticcall{gas: 30_000_000}(abi.encodeCall(ling.nextMintIds, (1)));
        assertTrue(ok);
    }
}

// ============================================================================================================
// Stuck assets: no rescue path for anything but ETH and (mainnet) WETH / IMD.
// ============================================================================================================
contract StuckAssetsAudit is ERC20AuditBase {
    address constant L2_WETH = 0x4200000000000000000000000000000000000006;

    function test_E3_wethRoyaltyOnL2IsNotUnwrapped() public {
        vm.chainId(8453);
        _deploy();
        vm.etch(L2_WETH, address(new FlexToken()).code);
        _give(alice, UNIT);
        // a Seaport collection-offer sale pays the 5% royalty in WETH to royaltyInfo().receiver == the token
        (address receiver,) = mirror.royaltyInfo(1, 100 ether);
        assertEq(receiver, address(ling));
        FlexToken(L2_WETH).mint(address(ling), 5 ether);
        ling.syncEth();
        vm.prank(alice);
        ling.claim();
        (,,, uint256 total,,) = ling.stream(0);
        assertEq(total, 0, "WETH royalty never counted");
        assertEq(ling.devOwed(), 0);
        assertEq(FlexToken(L2_WETH).balanceOf(address(ling)), 5 ether, "5 WETH sit in the token forever");
        // the ABI has no sweep / rescue: only the selectors below move value out
        assertEq(address(ling).balance, 0);
    }

    function test_E3_mainnetOnlyHandlesWeth_otherTokensAreStuck() public {
        vm.chainId(1);
        _deploy();
        // LING sent to the token itself (or to the mirror) is unrecoverable
        _give(alice, UNIT);
        vm.prank(alice);
        ling.transfer(address(ling), UNIT);
        assertEq(ling.balanceOf(address(ling)), UNIT);
        assertEq(mirror.balanceOf(alice), 0, "the NFT burned with it");
        // the token has no function that can spend its own LING balance
        (bool ok,) = address(ling).call(abi.encodeWithSignature("rescue(address,uint256)", address(ling), UNIT));
        assertFalse(ok);
    }
}

// ============================================================================================================
// keep(): bad ids, aliasing and a stateful fuzz over the DN404 owned list / owned index.
// ============================================================================================================
contract KeepAudit is ERC20AuditBase {
    function test_keepRejectsOutOfRangeAndAliasedIds() public {
        _give(alice, UNIT * 3);
        uint256[] memory x = new uint256[](1);
        uint256[4] memory bad = [uint256(0), 3334, 1 << 32, (1 << 32) + 1];
        for (uint256 i; i < bad.length; ++i) {
            x[0] = bad[i];
            vm.prank(alice);
            vm.expectRevert(Swarmlings.NotYours.selector);
            ling.keep(x);
        }
        // more ids than owned => necessarily a duplicate
        uint256[] memory many = new uint256[](4);
        many[0] = 1;
        many[1] = 2;
        many[2] = 3;
        many[3] = 1;
        vm.prank(alice);
        vm.expectRevert(Swarmlings.NotYours.selector);
        ling.keep(many);
    }

    function test_keepThenEveryOperationKeepsListsConsistent() public {
        _give(alice, UNIT * 6);
        _give(bob, UNIT * 2);
        uint256[] memory f = new uint256[](3);
        f[0] = 4;
        f[1] = 1;
        f[2] = 6;
        vm.prank(alice);
        ling.keep(f);
        _assertConsistent(alice);
        // NFT transfer out of the middle, LING sale (burn), LING buy (mint + direct transfer)
        vm.prank(alice);
        mirror.transferFrom(alice, bob, 4);
        _assertConsistent(alice);
        _assertConsistent(bob);
        vm.prank(alice);
        ling.transfer(carol, UNIT * 2); // direct transfers of the tail to carol
        _assertConsistent(alice);
        _assertConsistent(carol);
        vm.prank(alice);
        ling.burn(UNIT);
        _assertConsistent(alice);
    }

    function _assertConsistent(address a) internal view {
        uint256 n = mirror.balanceOf(a);
        uint256[] memory ids = ling.ownedIds(a, 0, n);
        assertEq(ids.length, n);
        for (uint256 i; i < n; ++i) {
            assertEq(mirror.ownerAt(ids[i]), a, "owner alias");
            assertEq(ling.ooIdx(ids[i]), i, "owned index");
            for (uint256 j; j < i; ++j) {
                assertTrue(ids[j] != ids[i], "duplicate id");
            }
        }
        assertLe(n, ling.balanceOf(a) / UNIT);
    }
}

contract KeepHandler is Test {
    Harness public ling;
    SwarmlingsMirror public mirror;
    address public launcher;
    address[3] public actors;
    uint256 public UNIT;
    uint256 public nftMoves;
    uint256 public keeps;
    uint256 public burns;

    constructor(Harness l, address lau, address[3] memory a) {
        ling = l;
        mirror = SwarmlingsMirror(payable(l.mirrorERC721()));
        launcher = lau;
        actors = a;
        UNIT = l.UNIT();
    }

    function _a(uint256 s) internal view returns (address) {
        return actors[s % 3];
    }

    function give(uint256 who, uint256 amt) external {
        amt = bound(amt, 0, 5 * UNIT + 12345);
        if (amt > ling.balanceOf(launcher)) return;
        vm.prank(launcher);
        ling.transfer(_a(who), amt);
    }

    function move(uint256 from, uint256 to, uint256 amt) external {
        address f = _a(from);
        amt = bound(amt, 0, ling.balanceOf(f));
        vm.prank(f);
        ling.transfer(_a(to), amt);
    }

    function moveNft(uint256 from, uint256 to, uint256 idx) external {
        address f = _a(from);
        uint256 n = mirror.balanceOf(f);
        if (n == 0) return;
        uint256[] memory ids = ling.ownedIds(f, idx % n, idx % n + 1);
        ++nftMoves;
        vm.prank(f);
        mirror.transferFrom(f, _a(to), ids[0]);
    }

    function keep(uint256 who, uint256 seed) external {
        address f = _a(who);
        uint256 n = mirror.balanceOf(f);
        if (n == 0) return;
        uint256[] memory ids = ling.ownedIds(f, 0, n);
        uint256 c = seed % (n + 1);
        uint256[] memory pick = new uint256[](c);
        for (uint256 i; i < c; ++i) {
            uint256 j = i + uint256(keccak256(abi.encode(seed, i))) % (n - i);
            (ids[i], ids[j]) = (ids[j], ids[i]);
            pick[i] = ids[i];
        }
        ++keeps;
        vm.prank(f);
        ling.keep(pick);
    }

    function burn(uint256 who, uint256 amt) external {
        address f = _a(who);
        amt = bound(amt, 0, ling.balanceOf(f));
        ++burns;
        vm.prank(f);
        ling.burn(amt);
    }

    function skip(uint256 who, bool s) external {
        vm.prank(_a(who));
        ling.setSkipNFT(s);
    }
}

contract KeepInvariantAudit is ERC20AuditBase {
    KeepHandler h;

    function setUp() public override {
        super.setUp();
        h = new KeepHandler(ling, launcher, [alice, bob, carol]);
        targetContract(address(h));
    }

    function invariant_ownedListsAndIndexesStayConsistent() public view {
        uint256 total;
        uint256 supply = ling.balanceOf(launcher);
        for (uint256 k; k < 3; ++k) {
            address a = h.actors(k);
            uint256 n = mirror.balanceOf(a);
            total += n;
            supply += ling.balanceOf(a);
            uint256[] memory ids = ling.ownedIds(a, 0, n);
            assertEq(ids.length, n);
            for (uint256 i; i < n; ++i) {
                assertEq(mirror.ownerAt(ids[i]), a, "owner alias");
                assertEq(ling.ooIdx(ids[i]), i, "owned index");
                assertTrue(ids[i] >= 1 && ids[i] <= 3333);
                for (uint256 j; j < i; ++j) {
                    assertTrue(ids[j] != ids[i], "duplicate id in a list");
                }
            }
            assertLe(n, ling.balanceOf(a) / UNIT, "more NFTs than units");
        }
        assertEq(total, ling.activeNFTs());
        assertEq(supply, ling.totalSupply());
    }
}

// ============================================================================================================
// skipNFT default / EIP-7702 detection
// ============================================================================================================
contract SkipDefaultAudit is ERC20AuditBase {
    function test_7702PrefixVariants() public {
        address x = makeAddr("x");
        vm.etch(x, abi.encodePacked(hex"ef0100", address(0x1234)));
        assertFalse(ling.getSkipNFT(x), "valid designator => wallet");
        vm.etch(x, abi.encodePacked(hex"ff0100", address(0x1234)));
        assertTrue(ling.getSkipNFT(x), "23 bytes, other prefix => contract");
        vm.etch(x, hex"");
        assertFalse(ling.getSkipNFT(x));
    }

    function test_explicitFlagBeatsTheDefaultBothWays() public {
        address x = makeAddr("x");
        vm.etch(x, abi.encodePacked(hex"ef0100", address(0x1234)));
        vm.prank(x);
        ling.setSkipNFT(true);
        assertTrue(ling.getSkipNFT(x));
        address c = address(new FlexToken());
        vm.prank(c);
        ling.setSkipNFT(false);
        assertFalse(ling.getSkipNFT(c));
        _give(x, UNIT);
        assertEq(mirror.balanceOf(x), 0);
        _give(c, UNIT);
        assertEq(mirror.balanceOf(c), 1);
    }

    /// @dev extcodecopy writes scratch memory 0x00..0x02; make sure the free pointer and surrounding state survive.
    function test_scratchMemoryUseDoesNotBreakTransfers() public {
        address x = makeAddr("x");
        vm.etch(x, abi.encodePacked(hex"ef0100", address(0x1234)));
        _give(x, UNIT * 3 + 77);
        assertEq(mirror.balanceOf(x), 3);
        assertEq(ling.balanceOf(x), UNIT * 3 + 77);
    }

    /// @dev Address staining: LING sent to an address before its contract exists mints NFTs the contract can never move.
    function test_E5_counterfactualContractCanBeStainedWithNfts() public {
        address future = makeAddr("futureSink");
        _give(future, UNIT); // no code yet => treated as a wallet
        assertEq(mirror.balanceOf(future), 1);
        vm.etch(future, address(new FlexToken()).code); // the sink is deployed later
        assertTrue(ling.getSkipNFT(future));
        // it holds an NFT it cannot move and whose rewards it cannot claim
        assertEq(mirror.balanceOf(future), 1);
        ling.addRewards{value: 1 ether}();
        _paidOut();
        (uint256 e,) = ling.pending(future);
        assertGt(e, 0.99 ether, "all rewards accrue to a contract with no claim()");
    }
}

// ============================================================================================================
// Auto skip edges
// ============================================================================================================
contract AutoSkipAudit is ERC20AuditBase {
    function test_edges() public {
        uint256 lim = ling.MAX_MINT_PER_TRANSFER();
        // exactly at the limit with an existing balance: have 800, +800 => 1600 == have + limit => allowed
        _give(alice, UNIT * lim);
        _give(alice, UNIT * lim);
        assertEq(mirror.balanceOf(alice), 2 * lim);
        // one more than the limit => skip
        _give(alice, UNIT * (lim + 1));
        assertTrue(ling.getSkipNFT(alice));
        assertEq(mirror.balanceOf(alice), 2 * lim, "existing NFTs stay");
        // a skipped holder keeps all NFTs it has; self transfer keeps the flag and does not mint
        vm.prank(alice);
        ling.transfer(alice, 5);
        assertEq(mirror.balanceOf(alice), 2 * lim);
        // zero transfer to a normal wallet is fine
        vm.prank(bob);
        ling.transfer(carol, 0);
        // self transfer of a non-skip whale below the limit
        _give(bob, UNIT * 10 + 1);
        vm.prank(bob);
        ling.transfer(bob, UNIT * 10 + 1);
        assertEq(mirror.balanceOf(bob), 10);
        assertFalse(ling.getSkipNFT(bob));
        // transfers to address(0) revert and leave no flag behind
        vm.prank(bob);
        vm.expectRevert();
        ling.transfer(address(0), 1);
        // sender side is not bounded: measure selling many NFTs at once into a contract (skip) receiver
    }

    function test_burnSideGas() public {
        address pool = address(new FlexToken()); // a contract => skip by default
        _give(alice, UNIT * 800);
        _give(alice, UNIT * 800);
        uint256 g = gasleft();
        vm.prank(alice);
        ling.transfer(pool, UNIT * 800);
        uint256 used800 = g - gasleft();
        g = gasleft();
        vm.prank(alice);
        ling.transfer(pool, UNIT * 800);
        uint256 used800b = g - gasleft();
        console2.log("gas to sell 800 NFTs into a contract:", used800);
        console2.log("gas to sell next 800 NFTs:", used800b);
        assertLt(used800, 16_777_216);
    }
}

// ============================================================================================================
// ERC-20 surface
// ============================================================================================================
contract Erc20SurfaceAudit is ERC20AuditBase {
    function test_permitAndDomainSeparatorRevertNotPhantom() public {
        (bool ok,) = address(ling).call(
            abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                alice,
                bob,
                1,
                block.timestamp,
                uint8(27),
                bytes32(0),
                bytes32(0)
            )
        );
        assertFalse(ok, "permit is not implemented and does not silently succeed");
        (ok,) = address(ling).call(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertFalse(ok);
        (ok,) = address(ling).call{value: 1}(hex"deadbeef");
        assertFalse(ok);
    }

    function test_permit2IsInfinitelyApprovedByDefault() public {
        assertEq(ling.allowance(alice, PERMIT2), type(uint256).max);
        _give(alice, 10e18);
        vm.prank(PERMIT2);
        ling.transferFrom(alice, bob, 10e18); // no approval by alice at all
        assertEq(ling.balanceOf(bob), 10e18);
        // revoking works, and flips the override flag
        _give(alice, 10e18);
        vm.prank(alice);
        ling.approve(PERMIT2, 0);
        assertEq(ling.allowance(alice, PERMIT2), 0);
        vm.prank(PERMIT2);
        vm.expectRevert();
        ling.transferFrom(alice, bob, 1);
    }

    function test_zeroAndSelfAndExactAmounts() public {
        _give(alice, UNIT + 5);
        vm.prank(alice);
        assertTrue(ling.transfer(bob, 0));
        vm.prank(alice);
        ling.approve(bob, 7);
        vm.prank(bob);
        ling.transferFrom(alice, bob, 7);
        assertEq(ling.allowance(alice, bob), 0);
        assertEq(ling.balanceOf(bob), 7);
        vm.prank(alice);
        ling.approve(bob, type(uint256).max);
        vm.prank(bob);
        ling.transferFrom(alice, bob, 1);
        assertEq(ling.allowance(alice, bob), type(uint256).max);
        assertEq(ling.totalSupply(), 1e27);
    }
}

// ============================================================================================================
// Reward token handling on mainnet (IMD) and reentrancy through claim
// ============================================================================================================
contract RewardTokenAudit is ERC20AuditBase {
    FlexToken imd;

    function setUp() public override {
        vm.chainId(1);
        vm.etch(IMD, address(new FlexToken()).code);
        imd = FlexToken(IMD);
        _deploy();
        assertEq(ling.rewardCurrency(), IMD);
    }

    function _earn() internal {
        _give(alice, UNIT);
        imd.mint(address(ling), 100e18);
        ling.syncToken();
        ling.addRewards{value: 1 ether}();
        _paidOut();
    }

    function test_noReturnTokenIsAccepted() public {
        _earn();
        imd.setMode(1);
        vm.prank(alice);
        (uint256 e, uint256 t) = ling.claim();
        assertApproxEqAbs(e, 1 ether, 1e6);
        assertApproxEqAbs(t, 100e18, 1e6);
        assertEq(imd.balanceOf(alice), t);
    }

    function test_E4_failingRewardTokenBlocksTheEthClaimToo() public {
        _earn();
        imd.setMode(2); // transfer returns false (or 3: reverts)
        vm.prank(alice);
        vm.expectRevert(Swarmlings.PayFailed.selector);
        ling.claim();
        (uint256 e,) = ling.pending(alice);
        assertGt(e, 0.99 ether);
        // there is no way to claim ETH alone
        uint256 b = alice.balance;
        vm.prank(alice);
        vm.expectRevert(Swarmlings.PayFailed.selector);
        ling.claim();
        assertEq(alice.balance, b);
    }

    function test_E4_balanceBelowAccountedBricksClaimForEveryone() public {
        _earn();
        // any event that leaves the token's IMD balance below the ledger (rebase down, admin burn, bug)
        imd.setBalance(address(ling), 10e18);
        vm.prank(alice);
        vm.expectRevert(); // Panic(0x11) in _syncToken
        ling.claim();
        vm.expectRevert();
        ling.syncToken();
        // ETH sync alone still works, but every holder's ETH is locked behind claim()
        ling.syncEth();
    }

    function test_reentrantTransferInsideClaimCannotDoubleSpend() public {
        address sink = makeAddr("sink");
        ReenterTransfer r = new ReenterTransfer(ling, sink);
        _give(address(r), UNIT);
        imd.mint(address(ling), 50e18);
        ling.syncToken();
        ling.addRewards{value: 2 ether}();
        _paidOut();
        (uint256 e, uint256 t) = ling.pending(address(r));
        uint256 ethBefore = address(ling).balance;
        r.claim();
        assertEq(r.hits(), 1);
        assertTrue(r.secondClaimReverted(), "second claim hit the lock");
        assertEq(address(r).balance, e);
        assertEq(imd.balanceOf(address(r)), t);
        assertEq(ethBefore - address(ling).balance, e);
        // the NFT left with the LING; later rewards do not flow to the claimer
        assertEq(mirror.balanceOf(address(r)), 0);
        assertEq(mirror.balanceOf(sink), 1);
    }

    function test_burnKeepsEarnedRewards() public {
        _give(alice, UNIT * 3);
        ling.addRewards{value: 3 ether}();
        _paidOut();
        (uint256 e0,) = ling.pending(alice);
        vm.prank(alice);
        ling.burn(UNIT + UNIT / 2); // 1.5 units => 2 NFTs burn
        assertEq(mirror.balanceOf(alice), 1);
        (uint256 e1,) = ling.pending(alice);
        assertEq(e1, e0, "earnings before the burn are untouched");
        uint256 over = ling.balanceOf(alice) + 1;
        vm.prank(alice);
        vm.expectRevert();
        ling.burn(over);
    }
}

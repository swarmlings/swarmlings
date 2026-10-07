// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {DN404Mirror} from "dn404/DN404Mirror.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {SwarmlingsHook} from "../src/SwarmlingsHook.sol";
import {SwarmlingsBase} from "./utils/SwarmlingsBase.sol";

/// @dev Random buys, sells, LING and NFT transfers, claims, distributions and donations by three wallets.
contract Handler is Test {
    Swarmlings ling;
    DN404Mirror mirror;
    SwarmlingsHook hook;
    PoolSwapTest router;
    PoolKey key;
    address[3] public actors;
    uint256 public claimed;
    uint256 public devClaimed;
    uint256 public calls;
    uint256 public swapsOk;
    uint256 public exactInBuys;
    uint256 public distributions;

    constructor(Swarmlings l, SwarmlingsHook h, PoolSwapTest r, PoolKey memory k, address[3] memory a) {
        ling = l;
        mirror = DN404Mirror(payable(l.mirrorERC721()));
        hook = h;
        router = r;
        key = k;
        actors = a;
        for (uint256 i; i < 3; ++i) {
            vm.prank(a[i]);
            l.approve(address(r), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function buy(uint256 who, uint256 eth, bool exactOut) external {
        address a = _actor(who);
        ++calls;
        vm.prank(a);
        if (exactOut) {
            uint256 out = bound(eth, 1e18, 30_000_000e18);
            try router.swap{value: 5 ether}(
                key, SwapParams(true, int256(out), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
            ) {
                ++swapsOk;
            } catch {}
        } else {
            uint256 amt = bound(eth, 1e12, 0.5 ether);
            ++exactInBuys;
            try router.swap{value: amt}(
                key, SwapParams(true, -int256(amt), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
            ) {
                ++swapsOk;
            } catch {}
        }
    }

    function sell(uint256 who, uint256 frac, bool exactOut) external {
        address a = _actor(who);
        uint256 bal = ling.balanceOf(a);
        if (bal < 1e18) return;
        ++calls;
        vm.prank(a);
        if (exactOut) {
            uint256 out = bound(frac, 1e12, 0.05 ether);
            try router.swap(
                key, SwapParams(false, int256(out), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
            ) {
                ++swapsOk;
            } catch {}
        } else {
            uint256 amt = bound(frac, 1, bal);
            try router.swap(
                key, SwapParams(false, -int256(amt), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
            ) {
                ++swapsOk;
            } catch {}
        }
    }

    function sendLing(uint256 from, uint256 to, uint256 amount) external {
        address a = _actor(from);
        uint256 bal = ling.balanceOf(a);
        if (bal == 0) return;
        ++calls;
        vm.prank(a);
        ling.transfer(_actor(to), bound(amount, 0, bal));
    }

    function sendNft(uint256 from, uint256 to) external {
        address a = _actor(from);
        uint256[] memory ids = ling.ownedIds(a, 0, 1);
        if (ids.length == 0) return;
        ++calls;
        vm.prank(a);
        mirror.transferFrom(a, _actor(to), ids[0]);
    }

    function claim(uint256 who) external {
        address a = _actor(who);
        ++calls;
        uint256 before = a.balance;
        vm.prank(a);
        ling.claim();
        claimed += a.balance - before;
    }

    function distribute() external {
        if (hook.pendingFees() < hook.minDistribute()) return;
        ++calls;
        ++distributions;
        hook.distribute();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        ++calls;
        vm.deal(address(this), amount);
        ling.addRewards{value: amount}();
    }

    function creatorFee(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        ++calls;
        vm.deal(address(this), amount);
        (bool ok,) = address(ling).call{value: amount}("");
        require(ok);
        ling.syncEth();
    }

    function wait(uint256 dt) external {
        ++calls;
        skip(bound(dt, 1, 2 days));
    }

    function devClaim() external {
        ++calls;
        uint256 before = ling.DEV().balance;
        ling.claimDev();
        devClaimed += ling.DEV().balance - before;
    }
}

contract InvariantTest is SwarmlingsBase {
    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(ling, hook, swapRouter, launchKey, [alice, bob, carol]);
        for (uint256 i; i < 3; ++i) vm.deal([alice, bob, carol][i], 1e9 ether);
        targetContract(address(handler));
    }

    function _owedToEveryone() internal view returns (uint256 s) {
        for (uint256 i; i < 3; ++i) {
            (uint256 e,) = ling.pending(handler.actors(i));
            s += e;
        }
    }

    /// @dev The run must have traded for real; and once every stream has run out, everything added for holders
    /// is either claimed or claimable (up to rounding dust).
    function afterInvariant() public {
        // exact-out buys may legitimately fail once the price has run away; exact-in buys never should
        if (handler.exactInBuys() > 0) assertGt(handler.swapsOk(), 0, "no swap ever succeeded");
        vm.warp((block.timestamp / 1 days + 3) * 1 days); // every queued day has paid out
        (,,, uint256 total, uint256 claimed, uint256 unpaid) = ling.stream(0);
        uint256 owed = _owedToEveryone();
        assertLe(claimed + owed, total);
        assertLe(total - claimed - owed - unpaid, 1e9, "nothing lost but dust: claimed, claimable or still waiting");
    }

    function invariant_hookLedger() public view {
        assertEq(hook.totalFees(), hook.distributed() + hook.pendingFees());
        assertEq(address(hook).balance, 0, "the hook never keeps ETH");
    }

    function invariant_claimsAreCounted() public view {
        (,,, uint256 total, uint256 claimed,) = ling.stream(0);
        assertEq(claimed, handler.claimed(), "every claim is booked");
        assertEq(ling.devPaid(), handler.devClaimed());
        assertLe(claimed, total);
    }

    function invariant_rewardsAreSolvent() public view {
        assertLe(_owedToEveryone() + ling.devOwed(), address(ling).balance, "solvent");
    }

    function invariant_nftsMatchBalances() public view {
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            address a = handler.actors(i);
            uint256 n = mirror.balanceOf(a);
            assertEq(n, ling.getSkipNFT(a) ? 0 : ling.balanceOf(a) / UNIT);
            total += n;
        }
        assertEq(ling.activeNFTs(), total, "only wallets hold NFTs");
        assertLe(total, ling.MAX_NFTS());
    }

    /// @dev One fixed walk through the handler to show the actions do trade, distribute and claim.
    function test_handlerTradesForReal() public {
        for (uint256 i; i < 40; ++i) {
            handler.buy(i, 0.3 ether + i * 1e15, i % 2 == 0);
            handler.sell(i + 1, (i * 7919) % 1e24, i % 3 == 0);
            if (i % 5 == 0) handler.sendNft(i, i + 1);
            if (i % 7 == 0) handler.distribute();
            if (i % 9 == 0) handler.claim(i);
        }
        assertGt(handler.swapsOk(), 60);
        assertGt(handler.distributions() + (hook.distributed() > 0 ? 1 : 0), 0);
        assertGt(hook.distributed(), 0);
        vm.warp((block.timestamp / 1 days + 3) * 1 days);
        handler.claim(1);
        handler.claim(2);
        (,,,, uint256 claimed,) = ling.stream(0);
        assertGt(claimed, 0);
        invariant_rewardsAreSolvent();
        invariant_claimsAreCounted();
        invariant_nftsMatchBalances();
    }
}

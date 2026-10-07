// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {SwarmlingsHook} from "../src/SwarmlingsHook.sol";
import {SwarmlingsBase} from "./utils/SwarmlingsBase.sol";

/// @dev Every test runs for each pairing; see the three contracts at the bottom.
abstract contract HookSuite is SwarmlingsBase {
    // ------------------------------------------------------------------ wiring

    function test_permissionsAndLaunchPool() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x3FFF);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.ling(), address(ling));
        assertTrue(hook.reward() == reward);
        assertTrue(hook.launchPoolSet());
        assertEq(PoolId.unwrap(hook.launchPool()), PoolId.unwrap(launchKey.toId()));
        assertEq(hook.rewardIsCurrency0(), rewardFirst);
        assertEq(hook.HOLDER_FEE_BPS(), 125);
        assertEq(hook.feeBps(), 125);
        assertEq(hook.LAUNCH_LP_FEE(), FEE);
        assertEq(hook.minDistribute(), native ? 0.01 ether : 5e18);
    }

    function test_onlyTheFirstLaunchPairPays() public {
        PoolKey memory other = launchKey;
        other.fee = 3000;
        other.tickSpacing = 60;
        manager.initialize(other, TickMath.getSqrtPriceAtTick(startTick));
        assertEq(
            PoolId.unwrap(hook.launchPool()), PoolId.unwrap(launchKey.toId()), "launch pool never changes"
        );
    }

    function test_callbacksOnlyFromManager() public {
        vm.expectRevert(SwarmlingsHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(this), launchKey, 0, 0);
        vm.expectRevert(SwarmlingsHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), launchKey, SwapParams(true, -1, 0), "");
        vm.expectRevert(SwarmlingsHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "the hook accepts no ETH");
    }

    function test_unsolicitedUnlockCallbackReverts() public {
        vm.prank(address(manager));
        vm.expectRevert(SwarmlingsHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    // ------------------------------------------------------------------ the four fee modes

    function test_buyExactIn() public {
        uint256 before = _rbal(alice);
        _buyExactIn(alice, BIG);
        assertEq(before - _rbal(alice), BIG, "trader pays exactly what they specified");
        assertEq(hook.totalFees(), BIG * 125 / 10000);
        assertEq(hook.pendingFees(), BIG * 125 / 10000);
        assertGt(ling.balanceOf(alice), 0);
    }

    function test_buyExactOut() public {
        uint256 before = _rbal(alice);
        _buyExactOut(alice, UNIT);
        assertEq(ling.balanceOf(alice), UNIT, "trader gets exactly what they specified");
        uint256 paid = before - _rbal(alice);
        uint256 fee = hook.totalFees();
        assertEq(fee, (paid - fee) * 125 / 9875, "1.25% of everything the trader spent");
        assertEq(_nfts(alice), 1);
    }

    function test_sellExactIn() public {
        _give(alice, UNIT * 2);
        uint256 before = _rbal(alice);
        _sellExactIn(alice, UNIT);
        uint256 got = _rbal(alice) - before;
        uint256 fee = hook.totalFees();
        assertEq(fee, (got + fee) * 125 / 10000, "1.25% of the pool's gross amount");
        assertEq(ling.balanceOf(alice), UNIT);
        assertEq(_nfts(alice), 1, "selling a unit burns one");
    }

    function test_sellExactOut() public {
        _give(alice, UNIT * 20);
        uint256 out = BIG / 100;
        uint256 before = _rbal(alice);
        _sellExactOut(alice, out);
        assertEq(_rbal(alice) - before, out, "trader gets exactly what they specified");
        assertEq(hook.totalFees(), out * 125 / 9875, "1.25% of what the pool paid out");
    }

    function testFuzz_feeModes(uint256 amount, uint8 mode) public {
        mode = mode % 4;
        if (mode == 0) _buyExactIn(alice, bound(amount, 1e9, 5 * BIG));
        if (mode == 1) _buyExactOut(alice, bound(amount, 1e18, 100_000_000e18));
        if (mode >= 2) {
            _give(alice, 200_000_000e18);
            if (mode == 2) _sellExactIn(alice, bound(amount, 1e18, 200_000_000e18));
            else _sellExactOut(alice, bound(amount, 1e9, BIG / 4)); // the pool holds about 2 BIG
        }
        assertEq(hook.totalFees(), hook.distributed() + hook.pendingFees(), "ledger");
        assertEq(_nfts(alice), ling.getSkipNFT(alice) ? 0 : ling.balanceOf(alice) / UNIT);
    }

    function test_partialFillRevertsWhenFeeWasTakenUpFront() public {
        bool zeroForOne = rewardFirst; // a buy
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? startTick - 10 : startTick + 10);
        vm.prank(alice);
        vm.expectRevert(); // PartialFill, wrapped by the manager
        swapRouter.swap{value: native ? 50 * BIG : 0}(
            launchKey,
            SwapParams(zeroForOne, -int256(50 * BIG), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function test_otherPoolsPayNoFee() public {
        PoolKey memory other = launchKey;
        other.fee = 3000;
        other.tickSpacing = 60;
        manager.initialize(other, TickMath.getSqrtPriceAtTick(startTick));
        int24 lo = (startTick / 60 - 10) * 60;
        _dealReward(launcher, 100 * BIG);
        vm.prank(launcher);
        modifyLiquidityRouter.modifyLiquidity{value: native ? 10 * BIG : 0}(
            other, ModifyLiquidityParams(lo, lo + 1200, 1e20, 0), ""
        );
        bool zeroForOne = rewardFirst;
        vm.prank(alice);
        swapRouter.swap{value: native ? BIG / 100 : 0}(
            other,
            SwapParams(
                zeroForOne,
                -int256(BIG / 100),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(hook.totalFees(), 0);
    }

    // ------------------------------------------------------------------ NFTs through the pool

    function test_poolAndRoutersNeverHoldNfts() public {
        _buyExactIn(alice, BIG / 2);
        _sellExactIn(alice, ling.balanceOf(alice) / 2);
        assertEq(_nfts(address(manager)), 0);
        assertEq(_nfts(address(hook)), 0);
        assertEq(_nfts(address(swapRouter)), 0);
        assertEq(_nfts(launcher), 0);
        assertEq(_nfts(alice), ling.balanceOf(alice) / UNIT);
    }

    function test_whaleBuyMintsManyNfts() public {
        uint256 g = gasleft();
        _buyExactOut(alice, UNIT * 100);
        console.log("gas, exact-out buy minting 100 NFTs:", g - gasleft());
        assertEq(_nfts(alice), 100);
        assertEq(ling.activeNFTs(), 100);
    }

    // ------------------------------------------------------------------ distribution

    function test_distributeNeedsMinimum() public {
        _buyExactIn(alice, BIG / 10);
        vm.expectRevert(SwarmlingsHook.BelowMinimum.selector);
        hook.distribute();
    }

    function test_distributeStreamsEverythingToHolders() public {
        _buyExactOut(alice, UNIT * 2);
        _buyExactIn(bob, BIG);
        uint256 fees = hook.pendingFees();
        assertGe(fees, hook.minDistribute());
        hook.distribute();
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.distributed(), fees);
        assertEq(_rbal(address(ling)), fees);
        assertEq(_pend(alice), 0, "queued for tomorrow, not dropped");
        _paidOut();
        uint256 nfts = ling.activeNFTs();
        assertApproxEqAbs(_pend(alice), fees * _nfts(alice) / nfts, 1e6);
        assertApproxEqAbs(_pend(bob), fees * _nfts(bob) / nfts, 1e6);
    }

    /// @dev The reviewer's attack: borrow LING from the manager inside an unlock, hold NFTs during the swap that
    /// hands fees over, give it back. With streaming that moment is worth nothing.
    function test_flashBorrowedNftsEarnNothing() public {
        _buyExactOut(alice, UNIT * 30);
        _buyExactOut(bob, UNIT * 30);
        _buyExactIn(carol, 5 * BIG);
        assertGe(hook.pendingFees(), hook.minDistribute());
        FlashSniper sniper = new FlashSniper(manager, ling, launchKey, rewardFirst, native);
        _dealReward(address(sniper), BIG);
        sniper.attack(UNIT * 500);
        assertGt(hook.distributed(), 0, "the hand-over happened inside the attack");
        assertEq(_nfts(address(sniper)), 0);
        _paidOut();
        assertEq(_pend(address(sniper)), 0, "nothing for zero seconds held");
        vm.prank(address(sniper));
        (uint256 e, uint256 t) = ling.claim();
        assertEq(e + t, 0);
    }

    /// @dev Syncing the reward currency before paying turns the in-swap hand-over off; it no longer matters.
    function test_skippedHandOverGivesALateBuyerNoBackPay() public {
        if (native) return;
        _buyExactOut(alice, UNIT * 10);
        _buyExactIn(carol, 5 * BIG);
        uint256 earlier = hook.pendingFees();
        SyncBuyer buyer = new SyncBuyer(manager, ling, launchKey, rewardFirst);
        _dealReward(address(buyer), 1000 * BIG);
        buyer.buy(500 * UNIT);
        assertGe(hook.pendingFees(), earlier, "hand-over skipped");
        hook.distribute();
        assertEq(_pend(address(buyer)), 0, "no back pay at the moment of distribution");
    }

    function test_rewardsFollowTimeHeld() public {
        _buyExactOut(alice, UNIT * 10);
        _buyExactIn(carol, 5 * BIG);
        uint256 carols = ling.balanceOf(carol);
        vm.prank(carol);
        ling.transfer(launcher, carols); // carol leaves: only alice holds
        hook.distribute();
        uint256 f = hook.distributed();
        _nextDay(); // payout day starts
        skip(12 hours);
        _give(bob, UNIT * 10); // bob holds the second half, alongside alice
        skip(13 hours);
        assertApproxEqRel(_pend(alice), f * 3 / 4, 0.01e18);
        assertApproxEqRel(_pend(bob), f / 4, 0.01e18);
    }

    function test_feesWithNoHoldersWaitForTheFirstNft() public {
        vm.prank(alice);
        ling.setSkipNFT(true);
        _buyExactIn(alice, 2 * BIG); // nobody holds an NFT
        hook.distribute();
        uint256 first = hook.distributed();
        skip(3 days); // the payout day passes with no NFT: it goes back to the queue
        _buyExactOut(bob, UNIT);
        vm.prank(carol);
        ling.setSkipNFT(true);
        _buyExactIn(carol, BIG); // pending >= minimum again
        hook.distribute();
        _paidOut();
        assertGt(_pend(bob), first, "the only NFT gets everything, including what waited");
    }

    function test_holdersClaim() public {
        _buyExactOut(alice, UNIT * 3);
        for (uint256 i; i < 5; ++i) {
            _buyExactIn(bob, BIG);
            _sellExactIn(bob, ling.balanceOf(bob));
        }
        if (hook.pendingFees() >= hook.minDistribute()) hook.distribute();
        _paidOut();
        uint256 due = _pend(alice);
        assertGt(due, 0);
        uint256 before = _rbal(alice);
        vm.prank(alice);
        ling.claim();
        assertEq(_rbal(alice) - before, due);
        assertEq(hook.totalFees(), hook.distributed() + hook.pendingFees());
        assertEq(_rbal(address(hook)), 0, "the hook never keeps the reward currency");
        assertEq(ling.devOwed(), 0, "swap fees never go to the dev");
    }

    /// @dev The reviewer's hijack: a pool initialized with the hook before the launch pool, at another tier.
    function test_launchPoolCannotBeHijacked() public {
        vm.prank(makeAddr("launcher2"));
        Swarmlings l2 = new Swarmlings();
        address hookAddr = address(HOOK_FLAGS | (uint160(0x5555) << 144));
        deployCodeTo("SwarmlingsHook.sol:SwarmlingsHook", abi.encode(manager, address(l2)), hookAddr);
        SwarmlingsHook h2 = SwarmlingsHook(payable(hookAddr));
        Currency r = Currency.wrap(l2.rewardCurrency());
        bool rf = native || Currency.unwrap(r) < address(l2);
        (Currency c0, Currency c1) = rf ? (r, Currency.wrap(address(l2))) : (Currency.wrap(address(l2)), r);
        manager.initialize(PoolKey(c0, c1, 0x800000, 1, IHooks(hookAddr)), TickMath.getSqrtPriceAtTick(0));
        manager.initialize(PoolKey(c0, c1, 3000, SPACING, IHooks(hookAddr)), TickMath.getSqrtPriceAtTick(0));
        assertFalse(h2.launchPoolSet(), "other tiers and dynamic fees are ignored");
        PoolKey memory real = PoolKey(c0, c1, FEE, SPACING, IHooks(hookAddr));
        manager.initialize(real, TickMath.getSqrtPriceAtTick(rf ? startTick : -startTick));
        assertEq(PoolId.unwrap(h2.launchPool()), PoolId.unwrap(real.toId()));
    }
}

/// @dev Flash-borrows LING from the PoolManager inside an unlock, holds NFTs during a dust swap that triggers the
/// hand-over, then returns the LING.
contract FlashSniper is IUnlockCallback {
    IPoolManager immutable pm;
    Swarmlings immutable ling;
    PoolKey key;
    bool rewardFirst;
    bool native;

    constructor(IPoolManager _pm, Swarmlings _ling, PoolKey memory _key, bool _rewardFirst, bool _native) {
        pm = _pm;
        ling = _ling;
        key = _key;
        rewardFirst = _rewardFirst;
        native = _native;
        _ling.setSkipNFT(false);
    }

    receive() external payable {}

    function attack(uint256 lingAmount) external {
        pm.unlock(abi.encode(lingAmount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 amt = abi.decode(data, (uint256));
        Currency L = Currency.wrap(address(ling));
        Currency R = Currency.wrap(ling.rewardCurrency());
        pm.take(L, address(this), amt);
        BalanceDelta d = pm.swap(
            key,
            SwapParams(
                rewardFirst,
                -int256(1e6),
                rewardFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 lingDelta = rewardFirst ? d.amount1() : d.amount0();
        int128 rewDelta = rewardFirst ? d.amount0() : d.amount1();
        pm.sync(L);
        ling.transfer(address(pm), amt - uint256(int256(lingDelta)));
        pm.settle();
        uint256 pay = uint256(-int256(rewDelta));
        if (native) {
            pm.settle{value: pay}();
        } else {
            pm.sync(R);
            MockERC20(Currency.unwrap(R)).transfer(address(pm), pay);
            pm.settle();
        }
        return "";
    }
}

/// @dev Buys exact-out after `sync`ing the reward currency, the usual order for paying an ERC-20.
contract SyncBuyer is IUnlockCallback {
    IPoolManager immutable pm;
    Swarmlings immutable ling;
    PoolKey key;
    bool rewardFirst;

    constructor(IPoolManager _pm, Swarmlings _ling, PoolKey memory _key, bool _rf) {
        pm = _pm;
        ling = _ling;
        key = _key;
        rewardFirst = _rf;
        _ling.setSkipNFT(false);
    }

    function buy(uint256 lingOut) external {
        pm.unlock(abi.encode(lingOut));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 lingOut = abi.decode(data, (uint256));
        Currency R = Currency.wrap(ling.rewardCurrency());
        pm.sync(R);
        BalanceDelta d = pm.swap(
            key,
            SwapParams(
                rewardFirst,
                int256(lingOut),
                rewardFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 rewDelta = rewardFirst ? d.amount0() : d.amount1();
        MockERC20(Currency.unwrap(R)).transfer(address(pm), uint256(-int256(rewDelta)));
        pm.settle();
        pm.take(Currency.wrap(address(ling)), address(this), lingOut);
        return "";
    }
}

contract NativeHookTest is HookSuite {}

contract ImdFirstHookTest is HookSuite {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.ImdFirst;
    }
}

contract LingFirstHookTest is HookSuite {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.LingFirst;
    }
}

/// @dev Like an IMD launch: the pool is seeded with LING only, so the manager holds no ETH until buyers settle.
contract TokenOnlySeedTest is SwarmlingsBase {
    function _seedLiquidity() internal override {
        vm.startPrank(launcher);
        ling.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            launchKey, ModifyLiquidityParams(TickMath.minUsableTick(SPACING), startTick, 1e23, 0), ""
        );
        vm.stopPrank();
    }

    function test_firstBuysWorkWithAnEmptyManager() public {
        assertEq(address(manager).balance, 0);
        _buyExactIn(alice, 0.5 ether);
        assertEq(hook.totalFees(), 0.00625 ether);
        _buyExactOut(bob, UNIT);
        _buyExactIn(carol, 0.5 ether);
        assertGe(hook.pendingFees() + hook.distributed(), 0.0125 ether);
        _buyExactIn(alice, 0.1 ether); // fees >= minimum and the manager now holds ETH: handed over here
        assertGt(hook.distributed(), 0);
        assertEq(hook.totalFees(), hook.distributed() + hook.pendingFees());
        _sellExactIn(alice, ling.balanceOf(alice));
        assertEq(_nfts(alice), 0);
    }
}

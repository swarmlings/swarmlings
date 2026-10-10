// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";
import {ISwarmlingsHook, Callbacks} from "../../src/interfaces/IHive.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {TwapOracle} from "../../src/modules/TwapOracle.sol";
import {VolatilityFee} from "../../src/modules/VolatilityFee.sol";
import {MaxBuy} from "../../src/modules/MaxBuy.sol";
import {HiveBase} from "../Hive.t.sol";

/// @dev Flash-borrows LING from the manager, then in ONE unlock: claims, distributes, swaps, returns the LING.
contract FlashClaimer is IUnlockCallback {
    IPoolManager immutable pm;
    Swarmlings immutable ling;
    SwarmlingsHook immutable hook;
    PoolKey key;
    bool rewardFirst;
    bool native;
    uint256 public claimedEth;
    uint256 public claimedTok;

    constructor(IPoolManager _pm, Swarmlings _ling, SwarmlingsHook _hook, PoolKey memory _key, bool _rf, bool _n) {
        pm = _pm;
        ling = _ling;
        hook = _hook;
        key = _key;
        rewardFirst = _rf;
        native = _n;
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
        // hand-over inside the unlock (swap path) and via the public entry points
        try hook.distribute() {} catch {}
        try ling.syncEth() {} catch {}
        (claimedEth, claimedTok) = ling.claim();
        BalanceDelta d = pm.swap(
            key,
            SwapParams(
                rewardFirst, -int256(1e6), rewardFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        (uint256 e2, uint256 t2) = ling.claim();
        claimedEth += e2;
        claimedTok += t2;
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

/// @dev Advances the NFT id counter by flash-minting and burning, then keeps what it wants.
contract IdCycler is IUnlockCallback {
    IPoolManager immutable pm;
    Swarmlings immutable ling;
    uint256 public lastGas;

    constructor(IPoolManager _pm, Swarmlings _ling) {
        pm = _pm;
        ling = _ling;
        _ling.setSkipNFT(false);
    }

    function cycle(uint256 units) external {
        uint256 g = gasleft();
        pm.unlock(abi.encode(units));
        lastGas = g - gasleft();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 amt = abi.decode(data, (uint256)) * ling.UNIT();
        Currency L = Currency.wrap(address(ling));
        pm.take(L, address(this), amt);
        pm.sync(L);
        ling.transfer(address(pm), amt);
        pm.settle();
        return "";
    }
}

contract FlashAtomicTest is HiveBase {
    using StateLibrary for IPoolManager;

    function _day() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    // ---------------------------------------------------------------- (a) rewards

    function test_a_flashNftsEarnNothing_claimAndDistributeInsideUnlock() public {
        _buyExactOut(alice, UNIT * 30);
        _buyExactOut(bob, UNIT * 30);
        _buyExactIn(carol, 5 * BIG);
        FlashClaimer f = new FlashClaimer(manager, ling, hook, launchKey, rewardFirst, native);
        _dealReward(address(f), BIG);
        f.attack(UNIT * 500);
        assertGt(hook.distributed(), 0, "hand-over ran inside the attacker's unlock");
        assertEq(f.claimedEth() + f.claimedTok(), 0, "claim inside the unlock pays nothing");
        assertEq(_nfts(address(f)), 0, "NFTs are back to zero");
        _paidOut();
        assertEq(_pend(address(f)), 0);
        console.log("OK: 500 flash NFTs, hand-over + 2x claim in one unlock => 0 reward");
    }

    function test_a_dayBoundaryNumbers() public {
        vm.prank(bob);
        ling.setSkipNFT(true);
        _buyExactOut(alice, UNIT * 10); // alice: 10 NFTs, the only holder
        _buyExactIn(carol, 5 * BIG);
        hook.distribute();
        uint256 R = hook.distributed();
        console.log("queued on day D (wei):", R);
        // payout day D+1 starts at the next midnight; rate = R / 86400 per second, split over all NFTs
        uint256 d1 = (_day() + 1) * 1 days;
        vm.warp(d1 - 1); // 23:59:59 of D: nothing is being paid yet
        _give(bob, UNIT * 10); // bob would match alice: 10 vs 10 NFTs
        vm.prank(bob);
        ling.setSkipNFT(false); // flag only; NFTs are minted on the next transfer INTO bob
        vm.prank(bob);
        ling.transfer(launcher, 1); // no NFT effect
        // bob entered via _give while skipNFT was true (no NFTs). Mint them properly: transfer from launcher.
        _give(bob, UNIT); // now bob has NFTs (balance 11 units)
        uint256 bobNfts = _nfts(bob);
        assertGt(bobNfts, 0);
        vm.warp(d1); // payout day starts, bob has held 1 second of D, 0 seconds of D+1
        assertEq(_pend(bob), 0, "a second before the payout day earns nothing");
        vm.warp(d1 + 1); // 1 second of the payout day
        uint256 N = ling.activeNFTs();
        uint256 expect = R / 86400 * bobNfts / N;
        uint256 got = _pend(bob);
        console.log("bob NFTs / total NFTs:", bobNfts, N);
        console.log("bob pending after 1s of payout day / ideal 1s share:", got, expect);
        assertApproxEqAbs(got, expect, expect / 100 + 2);
        // leaving immediately: transfers everything back
        uint256 b = ling.balanceOf(bob);
        vm.prank(bob);
        ling.transfer(launcher, b);
        uint256 locked = _pend(bob);
        vm.warp(d1 + 1 days);
        assertEq(_pend(bob), locked, "nothing more after leaving");
        console.log("bob total for holding 1 second:", locked, " of day payout R:", R);
    }

    // ---------------------------------------------------------------- (b) creator fee ETH

    function test_b_syncEthDonationAndClaimDevFrontrun() public {
        _buyExactOut(alice, UNIT * 10);
        vm.deal(address(this), 10 ether);
        // anyone can inflate "fresh" by sending ETH; it is split 50/50 and cannot be undone
        (bool ok,) = address(ling).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 devBefore = dev.balance;
        // an attacker front-runs claimDev: DEV still gets exactly its half, to DEV only
        vm.prank(bob);
        uint256 paid = ling.claimDev();
        assertEq(paid, 0.5 ether);
        assertEq(dev.balance - devBefore, 0.5 ether);
        assertEq(bob.balance, 1000 ether, "no value went to the caller");
        // accounted can never exceed the balance: claim everything after the payout day
        _paidOut();
        _paidOut();
        vm.prank(alice);
        ling.claim();
        assertGe(address(ling).balance, 0);
        console.log("ETH left in token after full claim (dust):", address(ling).balance);
    }

    // ---------------------------------------------------------------- (f) snipe tax

    function test_f_snipeAppliesToExactOutAndSecondPool() public {
        vm.warp(hook.launchedAt()); // t = 0 : 40%
        uint256 f0 = hook.totalFees();
        uint256 before = _rbal(alice);
        _buyExactOut(alice, UNIT);
        uint256 paid = before - _rbal(alice);
        uint256 fee = hook.totalFees() - f0;
        // exact-out: fee = gross * bps / (10000 - bps); trader pays gross + fee
        assertEq(fee, (paid - fee) * 4125 / (10000 - 4125), "exact-out buy pays the full snipe tax");

        // second pool, other tier, same hook
        PoolKey memory other = launchKey;
        other.fee = 3000;
        other.tickSpacing = 60;
        manager.initialize(other, TickMath.getSqrtPriceAtTick(startTick));
        _dealReward(launcher, 100 * BIG);
        vm.prank(launcher);
        modifyLiquidityRouter.modifyLiquidity{value: native ? 10 * BIG : 0}(
            other,
            ModifyLiquidityParams(TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e20, 0),
            ""
        );
        f0 = hook.totalFees();
        vm.prank(alice);
        swapRouter.swap{value: native ? BIG / 100 : 0}(
            other,
            SwapParams(rewardFirst, -int256(BIG / 100), rewardFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(hook.totalFees() - f0, BIG / 100 * 4125 / 10000, "second pool pays snipe tax too");
    }

    // ---------------------------------------------------------------- MaxBuy: per-swap cap vs atomic splitting

    function test_maxBuyIsPerSwapSoSplittingBypassesIt() public {
        MaxBuy g = new MaxBuy(hook, UNIT, 1 hours, block.timestamp);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(g), Callbacks.AFTER_SWAP, true))));
        assertEq(g.cap(), UNIT);
        vm.expectRevert();
        _buyExactOut(alice, UNIT * 5);
        vm.prank(alice);
        ling.setSkipNFT(true);
        uint256 before = ling.balanceOf(alice);
        for (uint256 i; i < 20; ++i) {
            _buyExactOut(alice, UNIT); // each swap is exactly at the cap
        }
        console.log("LING bought in one block by 20 capped swaps (units):", (ling.balanceOf(alice) - before) / UNIT);
        assertEq(ling.balanceOf(alice) - before, 20 * UNIT, "20x the cap in one block/tx");
    }

    function test_maxBuyDoesNotApplyToAnotherTierPool() public {
        MaxBuy g = new MaxBuy(hook, UNIT, 1 hours, block.timestamp);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(g), Callbacks.AFTER_SWAP, true))));
        PoolKey memory other = launchKey;
        other.fee = 3000;
        other.tickSpacing = 60;
        manager.initialize(other, TickMath.getSqrtPriceAtTick(startTick));
        _dealReward(launcher, 100 * BIG);
        vm.prank(launcher);
        modifyLiquidityRouter.modifyLiquidity{value: native ? 50 * BIG : 0}(
            other,
            ModifyLiquidityParams(TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 5e22, 0),
            ""
        );
        vm.prank(alice);
        ling.setSkipNFT(true);
        uint256 before = ling.balanceOf(alice);
        vm.prank(alice);
        swapRouter.swap{value: native ? BIG / 10 : 0}(
            other,
            SwapParams(rewardFirst, -int256(BIG / 10), rewardFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 got = ling.balanceOf(alice) - before;
        console.log("LING (units) bought in ONE swap on the second pool while cap = 1 unit:", got / UNIT);
        assertGt(got, UNIT * 5);
    }

    // ---------------------------------------------------------------- NFT id cycling with flash LING

    function test_idCyclingFlash() public {
        IdCycler c = new IdCycler(manager, ling);
        uint256[] memory a = ling.nextMintIds(1);
        c.cycle(300);
        uint256[] memory b = ling.nextMintIds(1);
        console.log("next mint id before / after one flash cycle of 300 units:", a[0], b[0]);
        console.log("gas of the cycle:", c.lastGas());
        assertEq(b[0], a[0] + 300, "the id counter moved by 300 for gas only");
        assertEq(ling.activeNFTs(), 0, "nothing is left over");
    }
}

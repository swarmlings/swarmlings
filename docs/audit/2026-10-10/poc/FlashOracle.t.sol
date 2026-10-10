// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {ISwarmlingsHook, Callbacks} from "../../src/interfaces/IHive.sol";
import {TwapOracle} from "../../src/modules/TwapOracle.sol";
import {VolatilityFee} from "../../src/modules/VolatilityFee.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {HiveBase} from "../Hive.t.sol";

contract FlashOracleTest is HiveBase {
    using StateLibrary for IPoolManager;

    TwapOracle o;
    VolatilityFee v;

    function _attach() internal {
        o = new TwapOracle(hook);
        v = new VolatilityFee(hook, o, 1 hours, 50, 375);
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](2);
        m[0] = ISwarmlingsHook.Module(address(o), Callbacks.BEFORE_SWAP, false);
        m[1] = ISwarmlingsHook.Module(address(v), Callbacks.QUOTE, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(launchKey.toId());
        if (rewardFirst) t = -t;
    }

    /// @dev (e) The observation stores the block's OPENING tick and the oracle extrapolates it forward over the
    /// next gap, so a swap's own price move is not seen until the next observation.
    function test_e_twapUsesStaleOpeningTickAcrossQuietGaps() public {
        _attach();
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(alice, 1e9);
            skip(10 minutes);
        }
        int24 p0 = o.lastTick();
        _give(bob, 40_000_000e18);
        _sellExactIn(bob, 40_000_000e18); // block b: price falls
        int24 p1 = _tick();
        console.log("tick before / after the dump (LING terms):");
        console.logInt(p0);
        console.logInt(p1);
        skip(50 minutes); // quiet: nobody swaps, nobody records
        int24 mean = o.consult(1 hours);
        // true mean: 10 minutes at p0 ... 50 minutes at p1 (the pool really sat at p1)
        int256 trueMean = (int256(p0) * 10 + int256(p1) * 50) / 60;
        console.log("on-chain 1h mean / true 1h mean / spot:");
        console.logInt(mean);
        console.logInt(trueMean);
        console.logInt(p1);
        console.log("surcharge now (bps) / surcharge with the true mean (bps):");
        console.log(v.extraNow());
        uint256 drop = uint256(int256(trueMean) - int256(p1));
        console.log(drop * 50 / 100);
    }

    /// @dev (e) one swap's own impact is not part of its surcharge: the quote reads spot BEFORE the swap.
    function test_e_singleSwapDumpPaysNoSurcharge() public {
        _attach();
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(alice, 1e9);
            skip(10 minutes);
        }
        // a slow bleed first so that spot is below the average: prove the surcharge exists for a normal sell
        _give(bob, 150_000_000e18);
        uint256 f0 = hook.totalFees();
        uint256 r0 = _rbal(bob);
        _sellExactIn(bob, 140_000_000e18); // one huge swap, spot == mean at quote time
        uint256 fee1 = hook.totalFees() - f0;
        uint256 got1 = _rbal(bob) - r0;
        console.log("giant dump: gross out / fee / fee bps:", got1 + fee1, fee1, fee1 * 10000 / (got1 + fee1));
        skip(12);
        f0 = hook.totalFees();
        r0 = _rbal(bob);
        _sellExactIn(bob, 1_000_000e18); // the next, tiny sell pays the surcharge
        uint256 fee2 = hook.totalFees() - f0;
        uint256 got2 = _rbal(bob) - r0;
        console.log("next small sell: fee bps:", fee2 * 10000 / (got2 + fee2));
        assertApproxEqAbs(fee1 * 10000 / (got1 + fee1), 125, 1, "the dump that caused the drop paid only the base fee");
        assertGt(fee2 * 10000 / (got2 + fee2), 125);
    }

    /// @dev (e) a sink poke() moves the price outside the hook's callbacks, so the block-opening tick can be
    /// the post-poke tick, not the previous block's close.
    function test_e_pokeMovesPriceBeforeTheOpeningTickIsRecorded() public {
        _attach();
        BuybackBurn b = new BuybackBurn(hook, 1);
        ISwarmlingsHook.Slice[] memory sl = new ISwarmlingsHook.Slice[](1);
        sl[0] = ISwarmlingsHook.Slice(address(b), 375, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (sl)));
        vm.prank(alice);
        ling.setSkipNFT(true);
        for (uint256 i; i < 10; ++i) {
            _buyExactIn(alice, 3 ether);
            _sellExactIn(alice, ling.balanceOf(alice));
        }
        skip(12);
        int24 closeOfPrevBlock = _tick();
        for (uint256 i; i < 30; ++i) {
            try b.poke() {} catch {}
        }
        int24 afterPokes = _tick();
        _buyExactIn(alice, 1e9); // first swap of the block: records the opening tick
        console.log("previous block close tick / recorded 'opening' tick / pokes moved ticks by:");
        console.logInt(closeOfPrevBlock);
        console.logInt(o.lastTick());
        console.logInt(afterPokes - closeOfPrevBlock);
        assertEq(o.lastTick(), afterPokes);
        assertTrue(o.lastTick() != closeOfPrevBlock);
    }
}

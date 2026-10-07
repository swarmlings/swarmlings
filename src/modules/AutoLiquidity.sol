// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HiveSink} from "./HiveSink.sol";
import {ISwarmlingsHook} from "../interfaces/IHive.sol";

/// @title AutoLiquidity
/// @notice Protocol-owned liquidity. Once its fee share reaches `threshold`, it buys LING with half and adds
/// both sides to a full-range position in the launch pool that the hook owns and nothing can ever remove. The
/// position's fees in the reward currency go to NFT holders; its LING fees come back here and are added again.
contract AutoLiquidity is HiveSink {
    using StateLibrary for IPoolManager;

    uint256 public immutable threshold;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint256 public batches;
    uint256 public rewardAdded;
    uint256 public lingAdded;

    event Added(uint128 liquidity, uint256 rewardAmount, uint256 lingAmount);

    constructor(ISwarmlingsHook hook_, uint256 threshold_) HiveSink(hook_) {
        threshold = threshold_;
        PoolKey memory key = hook_.launchKey();
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);
    }

    function due() external view returns (bool) {
        return claims(reward) >= threshold;
    }

    function poke() external {
        uint256 r = claims(reward);
        if (r < threshold) return;
        uint256 half = r / 2;
        if (half > uint256(uint128(type(int128).max))) half = uint256(uint128(type(int128).max));
        hook.buy(half, _buyLimit());
        (uint160 price,,,) = poolManager.getSlot0(launchPool);
        uint256 rl = claims(reward);
        uint256 ll = claims(lingCurrency);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            rewardIsCurrency0 ? rl : ll,
            rewardIsCurrency0 ? ll : rl
        );
        // leave a little slack for the manager's upward rounding; the rest stays as claims for the next batch
        liquidity = liquidity - liquidity / 1000;
        if (liquidity == 0) return;
        (uint256 a0, uint256 a1) = hook.addLiquidity(tickLower, tickUpper, liquidity);
        (uint256 ra, uint256 la) = rewardIsCurrency0 ? (a0, a1) : (a1, a0);
        ++batches;
        rewardAdded += ra;
        lingAdded += la;
        emit Added(liquidity, ra, la);
    }

    /// @notice Collects the position's fees: reward to holders, LING back here.
    function collect() external {
        if (batches == 0) return;
        hook.collectFees(tickLower, tickUpper);
    }
}

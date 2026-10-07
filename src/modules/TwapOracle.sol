// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ISwarmlingsHook} from "../interfaces/IHive.sol";

/// @title TwapOracle
/// @notice A time-weighted average price for the launch pool, kept by the Hive. Observer module on
/// `BEFORE_SWAP`: the first swap of each block records the tick the block started with, so a trade cannot move
/// the price it is measured against. Ticks are in LING terms: higher means LING is dearer in the reward currency.
contract TwapOracle {
    using StateLibrary for IPoolManager;

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        int24 tick; // valid from blockTimestamp on
    }

    uint16 public constant CARDINALITY = 2048;

    ISwarmlingsHook public immutable hook;
    IPoolManager public immutable poolManager;
    PoolId public immutable launchPool;
    bool public immutable rewardIsCurrency0;

    Observation[CARDINALITY] public observations;
    uint16 public index;
    uint16 public count;

    error OnlyHook();
    error NoData();
    error TooOld();

    constructor(ISwarmlingsHook hook_) {
        hook = hook_;
        poolManager = hook_.poolManager();
        launchPool = hook_.launchPool();
        rewardIsCurrency0 = hook_.rewardIsCurrency0();
    }

    /// @dev Called by the hook before every swap in the launch pool.
    function onBeforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external {
        if (msg.sender != address(hook)) revert OnlyHook();
        _record();
    }

    /// @notice Anyone may record the current block's opening tick (useful in quiet markets).
    function record() external {
        _record();
    }

    function _record() private {
        (, int24 poolTick,,) = poolManager.getSlot0(launchPool);
        int24 tick = rewardIsCurrency0 ? -poolTick : poolTick;
        uint32 now_ = uint32(block.timestamp);
        if (count == 0) {
            observations[0] = Observation(now_, 0, tick);
            count = 1;
            return;
        }
        Observation memory last = observations[index];
        if (last.blockTimestamp == now_) return; // only the block's first observation counts
        int56 cumulative = last.tickCumulative + int56(last.tick) * int56(uint56(now_ - last.blockTimestamp));
        uint16 next = (index + 1) % CARDINALITY;
        observations[next] = Observation(now_, cumulative, tick);
        index = next;
        if (count < CARDINALITY) ++count;
    }

    /// @notice The current tick in LING terms, as last observed.
    function lastTick() public view returns (int24) {
        if (count == 0) revert NoData();
        return observations[index].tick;
    }

    /// @notice The arithmetic mean tick over the last `secondsAgo` seconds.
    function consult(uint32 secondsAgo) external view returns (int24 meanTick) {
        if (count == 0 || secondsAgo == 0) revert NoData();
        uint32 now_ = uint32(block.timestamp);
        int56 nowCum = _cumulativeAt(now_);
        int56 thenCum = _cumulativeAt(now_ - secondsAgo);
        int56 mean = (nowCum - thenCum) / int56(uint56(secondsAgo));
        return int24(mean);
    }

    /// @dev Tick-seconds accumulated up to `t`, from the latest observation at or before `t`.
    function _cumulativeAt(uint32 t) private view returns (int56) {
        Observation memory last = observations[index];
        if (t >= last.blockTimestamp) {
            return last.tickCumulative + int56(last.tick) * int56(uint56(t - last.blockTimestamp));
        }
        // binary search over the ring, oldest first
        uint256 n = count;
        uint256 oldest = n < CARDINALITY ? 0 : (uint256(index) + 1) % CARDINALITY;
        if (observations[oldest].blockTimestamp > t) revert TooOld();
        uint256 lo;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            Observation memory o = observations[(oldest + mid) % CARDINALITY];
            if (o.blockTimestamp <= t) lo = mid;
            else hi = mid - 1;
        }
        Observation memory a = observations[(oldest + lo) % CARDINALITY];
        return a.tickCumulative + int56(a.tick) * int56(uint56(t - a.blockTimestamp));
    }
}

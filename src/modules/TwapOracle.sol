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
/// `BEFORE_SWAP`: the first swap of each block records the tick the block started with, which is the tick that
/// held since the previous observation (Uniswap v3 semantics), so a trade cannot move the price it is measured
/// against. Time after the last observation is weighted with the pool's live tick. Ticks are in LING terms:
/// higher means LING is dearer in the reward currency.
contract TwapOracle {
    using StateLibrary for IPoolManager;

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative; // tick-seconds accumulated up to blockTimestamp
        int24 tick; // the tick that held from the previous observation up to this one
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
        // `tick` held from the last observation until now
        int56 cumulative = last.tickCumulative + int56(tick) * int56(uint56(now_ - last.blockTimestamp));
        uint16 next = (index + 1) % CARDINALITY;
        observations[next] = Observation(now_, cumulative, tick);
        index = next;
        if (count < CARDINALITY) ++count;
    }

    /// @notice The pool's tick right now, in LING terms.
    function lastTick() public view returns (int24) {
        if (count == 0) revert NoData();
        return _liveTick();
    }

    function _liveTick() private view returns (int24) {
        (, int24 poolTick,,) = poolManager.getSlot0(launchPool);
        return rewardIsCurrency0 ? -poolTick : poolTick;
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

    /// @dev Tick-seconds accumulated up to `t`: after the last observation the live tick holds; between two
    /// observations the later one's tick held.
    function _cumulativeAt(uint32 t) private view returns (int56) {
        Observation memory last = observations[index];
        if (t >= last.blockTimestamp) {
            return last.tickCumulative + int56(_liveTick()) * int56(uint56(t - last.blockTimestamp));
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
        Observation memory b = observations[(oldest + lo + 1) % CARDINALITY]; // exists: t < last.blockTimestamp
        return a.tickCumulative + int56(b.tick) * int56(uint56(t - a.blockTimestamp));
    }
}

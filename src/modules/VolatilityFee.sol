// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ISwarmlingsHook} from "../interfaces/IHive.sol";
import {TwapOracle} from "./TwapOracle.sol";

/// @title VolatilityFee
/// @notice A dynamic sell fee that goes to NFT holders. When LING trades below its `window`-second average, a
/// sell pays an extra `bpsPerPercent` bps for every percent of the drop (100 ticks), capped at `capBps`; the
/// hook caps the total at its `MAX_FEE_BPS`. Buys never pay extra. Quoter module (`QUOTE`); it fails open: with
/// no usable average the extra is zero.
contract VolatilityFee {
    using StateLibrary for IPoolManager;

    ISwarmlingsHook public immutable hook;
    IPoolManager public immutable poolManager;
    PoolId public immutable launchPool;
    bool public immutable rewardIsCurrency0;
    TwapOracle public immutable oracle;
    uint32 public immutable window;
    uint256 public immutable bpsPerPercent;
    uint256 public immutable capBps;

    constructor(
        ISwarmlingsHook hook_,
        TwapOracle oracle_,
        uint32 window_,
        uint256 bpsPerPercent_,
        uint256 capBps_
    ) {
        hook = hook_;
        poolManager = hook_.poolManager();
        launchPool = hook_.launchPool();
        rewardIsCurrency0 = hook_.rewardIsCurrency0();
        oracle = oracle_;
        window = window_;
        bpsPerPercent = bpsPerPercent_;
        capBps = capBps_;
    }

    /// @notice Extra bps for a swap: the current drop below the average, for sells only.
    function quoteFee(address, PoolKey calldata, SwapParams calldata, bool buy, bytes calldata)
        external
        view
        returns (uint256)
    {
        if (buy) return 0;
        return extraNow();
    }

    /// @notice What a sell would pay extra right now.
    function extraNow() public view returns (uint256) {
        (, int24 poolTick,,) = poolManager.getSlot0(launchPool);
        int256 now_ = rewardIsCurrency0 ? -int256(poolTick) : int256(poolTick);
        int24 mean;
        try oracle.consult(window) returns (int24 m) {
            mean = m;
        } catch {
            return 0;
        }
        if (now_ >= int256(mean)) return 0;
        uint256 dropTicks = uint256(int256(mean) - now_);
        uint256 extra = dropTicks * bpsPerPercent / 100;
        return extra > capBps ? capBps : extra;
    }
}

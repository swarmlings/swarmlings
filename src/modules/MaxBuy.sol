// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ISwarmlingsHook} from "../interfaces/IHive.sol";

/// @title MaxBuy
/// @notice An anti-snipe guard: for `ramp` seconds from `startAt` (set to the moment the council's proposal can
/// take effect), one swap may buy at most `cap()` LING, a limit that grows from `startCap` to ten times that
/// and then disappears. Guard module on `AFTER_SWAP`; it
/// only ever sees buys with the power to revert (the hook never lets a module block a sell).
contract MaxBuy {
    using BalanceDeltaLibrary for BalanceDelta;

    ISwarmlingsHook public immutable hook;
    bool public immutable rewardIsCurrency0;
    uint256 public immutable startCap;
    uint256 public immutable ramp;
    uint256 public immutable startAt;

    error OnlyHook();
    error BuyTooLarge(uint256 got, uint256 cap);

    constructor(ISwarmlingsHook hook_, uint256 startCap_, uint256 ramp_, uint256 startAt_) {
        hook = hook_;
        rewardIsCurrency0 = hook_.rewardIsCurrency0();
        startCap = startCap_;
        ramp = ramp_;
        startAt = startAt_;
    }

    /// @notice The most LING one swap may buy right now; `type(uint256).max` once the ramp is over.
    function cap() public view returns (uint256) {
        if (block.timestamp < startAt) return startCap;
        uint256 t = block.timestamp - startAt;
        if (t >= ramp) return type(uint256).max;
        return startCap + startCap * 9 * t / ramp;
    }

    function onAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        view
    {
        if (msg.sender != address(hook)) revert OnlyHook();
        (bool buy,,) = hook.currentSwap();
        if (!buy) return;
        int128 l = rewardIsCurrency0 ? delta.amount1() : delta.amount0();
        uint256 got = l > 0 ? uint256(uint128(l)) : 0;
        uint256 c = cap();
        if (got > c) revert BuyTooLarge(got, c);
    }
}

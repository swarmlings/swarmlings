// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHiveSink, ISwarmlingsHook} from "../interfaces/IHive.sol";

/// @notice Shared base of fee sinks: knows the hook and the launch pool, holds its fee share as ERC-6909 claims
/// and lets the hook spend them. A sink has no owner and no withdrawal path other than what its code does.
abstract contract HiveSink is IHiveSink {
    using StateLibrary for IPoolManager;

    ISwarmlingsHook public immutable hook;
    IPoolManager public immutable poolManager;
    Currency public immutable reward;
    Currency public immutable lingCurrency;
    address public immutable ling;
    bool public immutable rewardIsCurrency0;
    PoolId public immutable launchPool;

    error OnlyHook();

    constructor(ISwarmlingsHook hook_) {
        hook = hook_;
        poolManager = hook_.poolManager();
        reward = hook_.reward();
        ling = hook_.ling();
        lingCurrency = Currency.wrap(ling);
        rewardIsCurrency0 = hook_.rewardIsCurrency0();
        launchPool = hook_.launchPool();
        poolManager.setOperator(address(hook_), true);
    }

    /// @notice This sink's claims in `c`, held inside the PoolManager.
    function claims(Currency c) public view returns (uint256) {
        return poolManager.balanceOf(address(this), c.toId());
    }

    /// @dev A price limit about 1% past the current price in the buying direction; a thin market leaves the
    /// unspent budget as claims for later.
    function _buyLimit() internal view returns (uint160) {
        (uint160 price,,,) = poolManager.getSlot0(launchPool);
        if (rewardIsCurrency0) {
            uint256 l = uint256(price) * 995 / 1000;
            return l <= TickMath.MIN_SQRT_PRICE ? TickMath.MIN_SQRT_PRICE + 1 : uint160(l);
        }
        uint256 h = uint256(price) * 1005 / 1000;
        return h >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE - 1 : uint160(h);
    }
}

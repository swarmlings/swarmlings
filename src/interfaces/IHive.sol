// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Callback bits a module can subscribe to (`Module.callbacks`).
library Callbacks {
    uint16 internal constant AFTER_INITIALIZE = 1 << 0;
    uint16 internal constant BEFORE_SWAP = 1 << 1;
    uint16 internal constant AFTER_SWAP = 1 << 2;
    uint16 internal constant BEFORE_ADD_LIQUIDITY = 1 << 3;
    uint16 internal constant AFTER_ADD_LIQUIDITY = 1 << 4;
    uint16 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 5;
    uint16 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 6;
    uint16 internal constant BEFORE_DONATE = 1 << 7;
    uint16 internal constant AFTER_DONATE = 1 << 8;
    /// @dev The module prices an extra fee for each swap (`quoteFee`).
    uint16 internal constant QUOTE = 1 << 9;
}

/// @notice A module is a plain contract the hook calls from the launch pool's callbacks. It implements only the
/// functions for the bits it subscribes to. A *guard* module may revert buys, liquidity additions and donations;
/// an *observer* module runs with a gas cap and can never block anything. No module is ever called on a sell
/// with the power to revert it.
interface IHiveModule {
    function onAfterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external;
    /// @dev Same arguments as the manager's callback; `ISwarmlingsHook.currentSwap()` tells buy/sell, bps and fee.
    function onBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external;
    function onAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external;
    function onBeforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external;
    function onAfterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external;
    function onBeforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external;
    function onAfterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external;
    function onBeforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external;
    function onAfterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external;
    /// @notice Extra fee, in bps of the swap's reward-currency amount, on top of the configured fee. The hook caps
    /// the total at `MAX_FEE_BPS`; the extra goes to NFT holders. Same arguments as the manager's `beforeSwap`
    /// (`ISwarmlingsHook.currentSwap()` tells whether it is a buy); must return exactly one word.
    function quoteFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external view returns (uint256 extraBps);
}

/// @notice A sink receives a slice of every swap fee as ERC-6909 claims in the PoolManager and spends them
/// through the hook's services (`buy`, `addLiquidity`, `collectFees`, `take`). It must make the hook its
/// ERC-6909 operator. `poke` is called after a swap when `due()` is true and the slice has `poke` set.
interface IHiveSink {
    function due() external view returns (bool);
    function poke() external;
}

interface ISwarmlingsHook {
    struct Slice {
        address sink;
        uint16 bps;
        bool poke;
    }

    struct Module {
        address addr;
        uint16 callbacks;
        bool guard;
    }

    function poolManager() external view returns (IPoolManager);
    function ling() external view returns (address);
    function reward() external view returns (Currency);
    function rewardIsCurrency0() external view returns (bool);
    function launchPool() external view returns (PoolId);
    function launchPoolSet() external view returns (bool);
    function launchKey() external view returns (PoolKey memory);
    function feeBps() external view returns (uint256);
    function isSink(address) external view returns (bool);
    function council() external view returns (address);
    function currentSwap() external view returns (bool buy, uint256 bps, uint256 fee);

    function buy(uint256 budget, uint160 sqrtPriceLimitX96) external returns (uint256 spent, uint256 got);
    function addLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (uint256 amount0, uint256 amount1);
    function collectFees(int24 tickLower, int24 tickUpper) external returns (uint256 amount0, uint256 amount1);
    function take(Currency currency, address to, uint256 amount) external;

    function setSlices(Slice[] calldata slices) external;
    function setModules(Module[] calldata modules) external;
    function disableModule(address module) external;
    function setCouncil(address newCouncil) external;
}

interface ISwarmlingsToken {
    function rewardCurrency() external view returns (address);
    function addRewards() external payable;
    function syncToken() external;
    function burn(uint256 amount) external;
}

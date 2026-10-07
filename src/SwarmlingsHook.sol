// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

interface ISwarmlings {
    function rewardCurrency() external view returns (address);
    function addRewards() external payable;
    function syncToken() external;
}

/// @title SwarmlingsHook
/// @notice Takes a fixed 1.25% fee on every buy and sell in the Swarmlings launch pool, in the currency LING is
/// paired with (native ETH, or IMD on mainnet), and gives all of it to Swarmling NFT holders. The hook keeps
/// nothing and has no owner, admin, treasury or setter.
/// @dev Flags 0x10CC. Built with the launch token; the first pool that pairs LING with the token's
/// `rewardCurrency` at the launch tier (static 1.25% LP fee, any tick spacing) becomes `launchPool`, every other
/// pool trades fee-free. Buys pay 1.25% of what they spend, sells 1.25% of what the pool pays out, in every
/// swap mode. Fees are minted as ERC-6909 claims during the swap; once `minDistribute` has accrued, the next
/// swap hands them to the token, which streams them to NFT holders over a day (so the moment of hand-over
/// gives nobody an edge). `distribute()` does the same for anyone, outside swaps.
contract SwarmlingsHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant FEE_BPS = 125;
    /// @notice The IMD policy tier; dynamic-fee and other tiers never become the launch pool.
    uint24 public constant LAUNCH_LP_FEE = 12500;
    uint256 public constant MIN_DISTRIBUTE_NATIVE = 0.01 ether;
    uint256 public constant MIN_DISTRIBUTE_IMD = 5e18;

    IPoolManager public immutable poolManager;
    /// @notice The Swarmlings token.
    address public immutable ling;
    /// @notice The fee currency: the token's reward currency, address(0) for native ETH.
    Currency public immutable reward;
    /// @notice Smallest pending amount that is handed over.
    uint256 public immutable minDistribute;

    PoolId public launchPool;
    bool public launchPoolSet;
    /// @notice Whether the reward currency is currency0 of the launch pool (always true for native ETH).
    bool public rewardIsCurrency0;
    /// @notice Fees ever collected, and fees ever handed to the token. totalFees == distributed + claims held.
    uint256 public totalFees;
    uint256 public distributed;

    error OnlyPoolManager();
    error NotLaunched();
    error BelowMinimum();
    error PartialFill();
    error ReentrantCall();
    error UnexpectedUnlock();

    event LaunchPool(PoolId indexed id, bool rewardIsCurrency0);
    event FeeCollected(bool indexed buy, uint256 fee);
    event Distributed(uint256 amount, bool duringSwap);

    constructor(IPoolManager manager, address token) {
        poolManager = manager;
        ling = token;
        address r = ISwarmlings(token).rewardCurrency();
        reward = Currency.wrap(r);
        minDistribute = r == address(0) ? MIN_DISTRIBUTE_NATIVE : MIN_DISTRIBUTE_IMD;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    /// @dev Transient slot 1 locks `distribute`; slot 2 authorizes exactly one unlock callback.
    modifier nonReentrant() {
        uint256 locked;
        assembly ("memory-safe") { locked := tload(1) }
        if (locked != 0) revert ReentrantCall();
        assembly ("memory-safe") { tstore(1, 1) }
        _;
        assembly ("memory-safe") { tstore(1, 0) }
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    // ------------------------------------------------------------------ pool callbacks

    /// @dev Never rejects a pool. Only the first LING / reward pool at the launch tier is charged.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!launchPoolSet && key.fee == LAUNCH_LP_FEE) {
            bool r0 = key.currency0 == reward && Currency.unwrap(key.currency1) == ling;
            bool r1 = key.currency1 == reward && Currency.unwrap(key.currency0) == ling;
            if (r0 || r1) {
                launchPool = key.toId();
                launchPoolSet = true;
                rewardIsCurrency0 = r0;
                emit LaunchPool(launchPool, r0);
            }
        }
        return IHooks.afterInitialize.selector;
    }

    /// @dev When the reward currency is the specified side (exact-in buys, exact-out sells) the fee is taken here.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_isLaunch(key)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        _distributeDuringSwap();
        if (_rewardSpecified(params)) {
            uint256 fee = _specifiedFee(params);
            _collect(fee, _isBuy(params));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Otherwise (exact-out buys, exact-in sells) the fee is taken here, on the pool's gross reward amount.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!_isLaunch(key)) return (IHooks.afterSwap.selector, 0);
        int256 rewardDelta = rewardIsCurrency0 ? delta.amount0() : delta.amount1();
        if (_rewardSpecified(params)) {
            // The manager passes its raw delta, before the hook's specified fee is subtracted. A price limit
            // that stops the swap early would leave the fee charged on an amount that was never swapped.
            if (rewardDelta != params.amountSpecified + int256(_specifiedFee(params))) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 gross = uint256(rewardDelta < 0 ? -rewardDelta : rewardDelta);
        // exact-in sell: 1.25% of the pool's output; exact-out buy: 1.25% of what the trader spends in total
        uint256 fee = _isBuy(params) ? gross * FEE_BPS / (10000 - FEE_BPS) : gross * FEE_BPS / 10000;
        _collect(fee, _isBuy(params));
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    // ------------------------------------------------------------------ distribution

    /// @notice Fees collected and not yet handed to NFT holders (plus any claims donated to the hook).
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), reward.toId());
    }

    /// @notice Hands every pending fee to NFT holders now. Open to anyone; reverts below `minDistribute`.
    function distribute() external nonReentrant {
        if (!launchPoolSet) revert NotLaunched();
        uint256 amount = pendingFees();
        if (amount < minDistribute) revert BelowMinimum();
        assembly ("memory-safe") { tstore(2, 1) }
        poolManager.unlock(abi.encode(amount));
        uint256 open;
        assembly ("memory-safe") { open := tload(2) }
        if (open != 0) revert UnexpectedUnlock();
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 open;
        assembly ("memory-safe") {
            open := tload(2)
            tstore(2, 0)
        }
        if (open == 0) revert UnexpectedUnlock();
        _handOver(abi.decode(data, (uint256)), false);
        return "";
    }

    /// @dev Inside a swap the manager is already unlocked. Skipped when the manager holds too little of the
    /// reward currency right now (for example before the first trader has settled), or when an ERC-20 reward is
    /// mid-settlement (synced), since taking it then would shrink that payer's credit. The fees then wait for
    /// a later swap or `distribute()`.
    function _distributeDuringSwap() private {
        uint256 amount = pendingFees();
        if (amount < minDistribute || reward.balanceOf(address(poolManager)) < amount) return;
        if (!reward.isAddressZero() && poolManager.getSyncedCurrency() == reward) return;
        _handOver(amount, true);
    }

    /// @dev Burning the claims credits the hook exactly what `take` debits, so the hook's delta stays zero.
    /// Native ETH comes to the hook and is passed on with `addRewards` (holders only; plain ETH sent to the token
    /// would count as a creator fee). An ERC-20 goes straight to the token and is counted by `syncToken`; if that
    /// call ever failed the reward would still sit in the token and count at the next sync, so a swap never
    /// depends on it.
    function _handOver(uint256 amount, bool duringSwap) private {
        poolManager.burn(address(this), reward.toId(), amount);
        distributed += amount;
        if (reward.isAddressZero()) {
            poolManager.take(reward, address(this), amount);
            ISwarmlings(ling).addRewards{value: amount}();
        } else {
            poolManager.take(reward, ling, amount);
            try ISwarmlings(ling).syncToken() {} catch {}
        }
        emit Distributed(amount, duringSwap);
    }

    /// @dev Native ETH arrives only from the manager's `take`.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    // ------------------------------------------------------------------ helpers

    function _isLaunch(PoolKey calldata key) private view returns (bool) {
        return launchPoolSet && PoolId.unwrap(key.toId()) == PoolId.unwrap(launchPool);
    }

    /// @dev A buy pays the reward currency into the pool.
    function _isBuy(SwapParams calldata params) private view returns (bool) {
        return params.zeroForOne == rewardIsCurrency0;
    }

    /// @dev The specified currency is currency0 exactly when zeroForOne == exact-in.
    function _rewardSpecified(SwapParams calldata params) private view returns (bool) {
        return (params.zeroForOne == (params.amountSpecified < 0)) == rewardIsCurrency0;
    }

    /// @dev exact-in buy: 1.25% of what the trader spends; exact-out sell: 1.25% of what the pool pays out
    /// (the trader's amount plus the fee).
    function _specifiedFee(SwapParams calldata params) private pure returns (uint256) {
        // Covers the whole int256 range, including its negative endpoint.
        uint256 magnitude = params.amountSpecified < 0
            ? uint256(-(params.amountSpecified + 1)) + 1
            : uint256(params.amountSpecified);
        return FullMath.mulDiv(magnitude, FEE_BPS, params.amountSpecified < 0 ? 10000 : 10000 - FEE_BPS);
    }

    function _collect(uint256 fee, bool buy) private {
        if (fee == 0) return;
        totalFees += fee;
        poolManager.mint(address(this), reward.toId(), fee);
        emit FeeCollected(buy, fee);
    }
}

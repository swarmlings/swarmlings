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
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHiveModule, IHiveSink, ISwarmlingsHook, ISwarmlingsToken, Callbacks} from "./interfaces/IHive.sol";

/// @title SwarmlingsHook ("the Hive")
/// @notice The Uniswap v4 hook of the Swarmlings launch pool, and the one place new financial behaviour can be
/// attached after launch. It does two fixed things itself: it takes `HOLDER_FEE_BPS` (1.25%) of every buy and
/// sell in the reward currency for Swarmling NFT holders, and it hands that fee to the token. Everything else is a
/// module:
/// - **slices** route an additional fee (at most `MAX_FEE_BPS - HOLDER_FEE_BPS` in total) to *sinks*: buyback
///   and burn, protocol-owned liquidity, project funding, or anything else that spends ERC-6909 claims through
///   the services below;
/// - **modules** subscribe to the pool's callbacks: guards (may revert buys, liquidity additions and donations),
///   observers (gas-capped, can never block a trade) and fee quoters (price an extra fee that goes to holders).
/// Only `council` can change slices and modules. The holder floor, the hand-over path, the `MAX_FEE_BPS` cap,
/// the launch snipe tax and the rule that nothing can ever block a sell are constants.
/// @dev All 14 hook flags are set so later modules can use any callback. Fees are minted as ERC-6909 claims
/// during the swap; the holders' part waits at the hook until `minDistribute` has accrued and is then handed to
/// the token, which pays it out day by day. Sinks spend their claims only through the hook, which acts as the
/// PoolManager caller: v4 skips a hook's own callbacks for its own swaps and liquidity changes, so nothing
/// re-enters.
contract SwarmlingsHook is IHooks, IUnlockCallback, ISwarmlingsHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice The fixed part of the fee: 1.25% of every buy and sell, always to NFT holders.
    uint256 public constant HOLDER_FEE_BPS = 125;
    /// @notice The most any swap can ever pay to this hook, slices and quoted extras included (5%).
    uint256 public constant MAX_FEE_BPS = 500;
    /// @notice The IMD policy tier; dynamic-fee and other tiers never become the launch pool.
    uint24 public constant LAUNCH_LP_FEE = 12500;
    uint256 public constant MIN_DISTRIBUTE_NATIVE = 0.01 ether;
    uint256 public constant MIN_DISTRIBUTE_IMD = 5e18;
    uint256 public constant MAX_SLICES = 8;
    uint256 public constant MAX_MODULES = 8;
    /// @notice Gas given to each observer and quoter call; a swap must bring at least this much per call.
    uint256 public constant MODULE_GAS = 200_000;
    /// @notice Gas given to a sink's `poke` after a swap, when the sink says it is due.
    uint256 public constant POKE_GAS = 1_000_000;
    /// @notice Snipe tax: for `SNIPE_WINDOW` seconds after the launch pool opens, buys pay an extra fee that
    /// starts at `SNIPE_MAX_BPS` and falls linearly to zero. It goes to NFT holders, sits outside the council's
    /// cap, and never applies to sells.
    uint256 public constant SNIPE_WINDOW = 60;
    uint256 public constant SNIPE_MAX_BPS = 4000;
    /// @notice The council, deployed with CREATE2 at the same address on every chain (see docs).
    address public constant COUNCIL = 0x4d0b3507D80f678d9e658Fd5482Ca6a96636A032;

    IPoolManager public immutable poolManager;
    /// @notice The Swarmlings token.
    address public immutable ling;
    /// @notice The fee currency: the token's reward currency, address(0) for native ETH.
    Currency public immutable reward;
    uint256 internal immutable rewardId;
    uint256 internal immutable lingId;
    /// @notice Smallest pending holder amount that is handed over.
    uint256 public immutable minDistribute;

    PoolId public launchPool;
    bool public launchPoolSet;
    /// @notice Whether the reward currency is currency0 of the launch pool (always true for native ETH).
    bool public rewardIsCurrency0;
    /// @notice When the launch pool was initialized; the snipe window counts from here.
    uint64 public launchedAt;
    PoolKey internal _launchKey;

    /// @notice Who may change slices and modules. address(0) freezes the configuration forever.
    address public council;
    Slice[] internal _slices;
    Module[] internal _modules;
    /// @notice Every address that was ever a sink; they keep access to the services for their earmarked claims.
    mapping(address => bool) public isSink;

    /// @notice Holder fees ever collected, and holder fees ever handed to the token.
    /// totalFees == distributed + claims held by the hook.
    uint256 public totalFees;
    uint256 public distributed;
    /// @notice Fees ever minted to sinks.
    uint256 public sinkFees;

    error OnlyPoolManager();
    error OnlyCouncil();
    error OnlySink();
    error NotLaunched();
    error BelowMinimum();
    error PartialFill();
    error ReentrantCall();
    error UnexpectedUnlock();
    error InsufficientGas();
    error TooMany();
    error BadEntry();
    error Duplicate();
    error FeeTooHigh();
    error Unknown();
    error Synced();

    event LaunchPool(PoolId indexed id, bool rewardIsCurrency0);
    event FeeCollected(bool indexed buy, uint256 fee, uint256 toHolders, uint256 bps);
    event Distributed(uint256 amount, bool duringSwap);
    event SlicesSet(Slice[] slices);
    event ModulesSet(Module[] modules);
    event ModuleDisabled(address indexed module);
    event CouncilSet(address indexed council);
    event ModuleFailed(address indexed module, bytes4 selector);
    event SinkFailed(address indexed sink);
    event SinkBought(address indexed sink, uint256 spent, uint256 got);
    event LiquidityAdded(
        address indexed sink,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event PositionFees(address indexed sink, uint256 toHolders, uint256 toSink);
    event Taken(address indexed sink, Currency indexed currency, address to, uint256 amount);

    uint8 private constant OP_DISTRIBUTE = 1;
    uint8 private constant OP_BUY = 2;
    uint8 private constant OP_ADD = 3;
    uint8 private constant OP_COLLECT = 4;
    uint8 private constant OP_TAKE = 5;

    constructor(IPoolManager manager, address token) {
        poolManager = manager;
        ling = token;
        address r = ISwarmlingsToken(token).rewardCurrency();
        reward = Currency.wrap(r);
        rewardId = reward.toId();
        lingId = Currency.wrap(token).toId();
        minDistribute = r == address(0) ? MIN_DISTRIBUTE_NATIVE : MIN_DISTRIBUTE_IMD;
        council = COUNCIL;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyCouncil() {
        if (msg.sender != council) revert OnlyCouncil();
        _;
    }

    modifier onlySink() {
        if (!isSink[msg.sender]) revert OnlySink();
        _;
    }

    /// @dev Transient slot 1 locks the services; slot 2 authorizes exactly one unlock callback; slot 3 carries
    /// the current swap's total fee bps (and buy flag in the top bit) from beforeSwap to afterSwap; slot 4 the
    /// fee while after-swap modules run.
    modifier nonReentrant() {
        uint256 locked;
        assembly ("memory-safe") { locked := tload(1) }
        if (locked != 0) revert ReentrantCall();
        assembly ("memory-safe") { tstore(1, 1) }
        _;
        assembly ("memory-safe") { tstore(1, 0) }
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeAddLiquidity = true;
        p.afterAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeDonate = true;
        p.afterDonate = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
        p.afterAddLiquidityReturnDelta = true;
        p.afterRemoveLiquidityReturnDelta = true;
    }

    // ------------------------------------------------------------------ views

    function launchKey() external view returns (PoolKey memory) {
        return _launchKey;
    }

    /// @notice The configured fee: the holder floor plus every slice. Quoters may add to it per swap.
    function feeBps() public view returns (uint256 bps) {
        bps = HOLDER_FEE_BPS;
        uint256 n = _slices.length;
        for (uint256 i; i < n; ++i) {
            bps += _slices[i].bps;
        }
    }

    function slices() external view returns (Slice[] memory) {
        return _slices;
    }

    function modules() external view returns (Module[] memory) {
        return _modules;
    }

    /// @notice Inside a swap callback: whether the swap is a buy, its total fee bps and (after the swap) the fee.
    function currentSwap() external view returns (bool buy, uint256 bps, uint256 fee) {
        assembly ("memory-safe") {
            bps := tload(3)
            fee := tload(4)
        }
        buy = bps >> 255 == 1;
        bps &= type(uint128).max;
    }

    /// @notice The extra bps a buy pays right now because of the snipe tax; zero after `SNIPE_WINDOW`.
    function snipeBps() public view returns (uint256) {
        if (!launchPoolSet) return 0;
        uint256 t = block.timestamp - launchedAt;
        if (t >= SNIPE_WINDOW) return 0;
        return SNIPE_MAX_BPS * (SNIPE_WINDOW - t) / SNIPE_WINDOW;
    }

    /// @notice Holder fees collected and not yet handed to the token.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), rewardId);
    }

    // ------------------------------------------------------------------ pool callbacks

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Never rejects a pool. Only the first LING / reward pool at the launch tier is charged.
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
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
                launchedAt = uint64(block.timestamp);
                _launchKey = key;
                emit LaunchPool(launchPool, r0);
            }
        }
        if (_isLaunch(key)) {
            _runModules(Callbacks.AFTER_INITIALIZE, _relay(IHiveModule.onAfterInitialize.selector), false);
        }
        return IHooks.afterInitialize.selector;
    }

    /// @dev When the reward currency is the specified side (exact-in buys, exact-out sells) the fee is taken here.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (!_isLaunch(key)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        bool buy = _isBuy(params);
        _distributeDuringSwap();
        uint256 bps = _quote(sender, key, params, buy, hookData);
        _runModules(Callbacks.BEFORE_SWAP, _relay(IHiveModule.onBeforeSwap.selector), buy);
        if (_rewardSpecified(params)) {
            uint256 fee = _specifiedFee(params, bps);
            _collect(fee, bps, buy);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Otherwise (exact-out buys, exact-in sells) the fee is taken here, on the pool's gross reward amount.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!_isLaunch(key)) return (IHooks.afterSwap.selector, 0);
        uint256 bps;
        assembly ("memory-safe") { bps := tload(3) }
        bps &= type(uint128).max;
        bool buy = _isBuy(params);
        int256 rewardDelta = rewardIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 fee;
        int128 returned;
        if (_rewardSpecified(params)) {
            // The manager passes its raw delta, before the hook's specified fee is subtracted. A price limit
            // that stops the swap early would leave the fee charged on an amount that was never swapped.
            fee = _specifiedFee(params, bps);
            if (rewardDelta != params.amountSpecified + int256(fee)) revert PartialFill();
        } else {
            uint256 gross = uint256(rewardDelta < 0 ? -rewardDelta : rewardDelta);
            // exact-in sell: bps of the pool's output; exact-out buy: bps of what the trader spends in total
            fee = buy ? gross * bps / (10000 - bps) : gross * bps / 10000;
            _collect(fee, bps, buy);
            returned = fee.toInt128();
        }
        assembly ("memory-safe") { tstore(4, fee) }
        _runModules(Callbacks.AFTER_SWAP, _relay(IHiveModule.onAfterSwap.selector), buy);
        assembly ("memory-safe") { tstore(4, 0) }
        _pokeSinks();
        assembly ("memory-safe") { tstore(3, 0) }
        return (IHooks.afterSwap.selector, returned);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        if (_isLaunch(key)) {
            _runModules(
                Callbacks.BEFORE_ADD_LIQUIDITY, _relay(IHiveModule.onBeforeAddLiquidity.selector), true
            );
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (_isLaunch(key)) {
            _runModules(Callbacks.AFTER_ADD_LIQUIDITY, _relay(IHiveModule.onAfterAddLiquidity.selector), true);
        }
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Removing liquidity can never be blocked: observers only.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        if (_isLaunch(key)) {
            _runModules(
                Callbacks.BEFORE_REMOVE_LIQUIDITY, _relay(IHiveModule.onBeforeRemoveLiquidity.selector), false
            );
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (_isLaunch(key)) {
            _runModules(
                Callbacks.AFTER_REMOVE_LIQUIDITY, _relay(IHiveModule.onAfterRemoveLiquidity.selector), false
            );
        }
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        if (_isLaunch(key)) {
            _runModules(Callbacks.BEFORE_DONATE, _relay(IHiveModule.onBeforeDonate.selector), true);
        }
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        if (_isLaunch(key)) {
            _runModules(Callbacks.AFTER_DONATE, _relay(IHiveModule.onAfterDonate.selector), true);
        }
        return IHooks.afterDonate.selector;
    }

    // ------------------------------------------------------------------ modules

    /// @dev Asks every quoter for an extra fee and stores the swap's total bps in transient slot 3.
    function _quote(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bool buy,
        bytes calldata hookData
    ) private returns (uint256 bps) {
        bps = feeBps();
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            Module memory m = _modules[i];
            if (m.callbacks & Callbacks.QUOTE == 0) continue;
            _requireGas();
            try IHiveModule(m.addr).quoteFee{gas: MODULE_GAS}(sender, key, params, buy, hookData) returns (
                uint256 extra
            ) {
                bps += extra;
            } catch {
                emit ModuleFailed(m.addr, IHiveModule.quoteFee.selector);
            }
        }
        if (bps > MAX_FEE_BPS) bps = MAX_FEE_BPS;
        if (buy) bps += snipeBps();
        uint256 packed = bps | (buy ? uint256(1) << 255 : 0);
        assembly ("memory-safe") { tstore(3, packed) }
    }

    /// @dev The module callbacks for initialize, liquidity and donate take exactly the arguments the manager sent
    /// us, so the calldata is forwarded under the module's selector.
    function _relay(bytes4 selector) private pure returns (bytes memory) {
        return abi.encodePacked(selector, msg.data[4:]);
    }

    /// @dev Calls every module subscribed to `bit`. A guard's revert is passed through when `mayRevert`; every
    /// other call is gas-capped and its failure only logged.
    function _runModules(uint16 bit, bytes memory data, bool mayRevert) private {
        uint256 n = _modules.length;
        if (n == 0) return;
        bytes4 selector;
        assembly ("memory-safe") { selector := mload(add(data, 32)) }
        for (uint256 i; i < n; ++i) {
            Module memory m = _modules[i];
            if (m.callbacks & bit == 0) continue;
            if (m.guard && mayRevert) {
                (bool ok, bytes memory ret) = m.addr.call(data);
                if (!ok) {
                    assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
                }
            } else {
                _requireGas();
                (bool ok,) = m.addr.call{gas: MODULE_GAS}(data);
                if (!ok) emit ModuleFailed(m.addr, selector);
            }
        }
    }

    /// @dev A capped call must really get its cap, or a trader could starve observers of gas on purpose.
    function _requireGas() private view {
        if (gasleft() < MODULE_GAS + MODULE_GAS / 63 + 30_000) revert InsufficientGas();
    }

    /// @dev After a swap, sinks that say they are due get to spend their claims. Never blocks the trade.
    function _pokeSinks() private {
        uint256 n = _slices.length;
        for (uint256 i; i < n; ++i) {
            Slice memory s = _slices[i];
            if (!s.poke) continue;
            bool due;
            try IHiveSink(s.sink).due{gas: 50_000}() returns (bool d) {
                due = d;
            } catch {}
            if (!due) continue;
            if (gasleft() < POKE_GAS + POKE_GAS / 63 + 30_000) revert InsufficientGas();
            try IHiveSink(s.sink).poke{gas: POKE_GAS}() {}
            catch {
                emit SinkFailed(s.sink);
            }
        }
    }

    // ------------------------------------------------------------------ fee split

    /// @dev Splits `fee` (charged at `bps`) between the sinks, pro rata to their slice, and the holders, who get
    /// the rest (their floor and any quoted extra).
    function _collect(uint256 fee, uint256 bps, bool buy) private {
        if (fee == 0) return;
        uint256 toSinks;
        uint256 n = _slices.length;
        for (uint256 i; i < n; ++i) {
            Slice memory s = _slices[i];
            uint256 part = fee * s.bps / bps;
            if (part == 0) continue;
            toSinks += part;
            poolManager.mint(s.sink, rewardId, part);
        }
        sinkFees += toSinks;
        uint256 holders = fee - toSinks;
        totalFees += holders;
        poolManager.mint(address(this), rewardId, holders);
        emit FeeCollected(buy, fee, holders, bps);
    }

    // ------------------------------------------------------------------ distribution

    /// @notice Hands every pending holder fee to the token now. Open to anyone; reverts below `minDistribute`.
    function distribute() external nonReentrant {
        if (!launchPoolSet) revert NotLaunched();
        if (pendingFees() < minDistribute) revert BelowMinimum();
        _run(abi.encode(OP_DISTRIBUTE, ""));
    }

    /// @dev Inside a swap the manager is already unlocked. Skipped when the manager holds too little of the
    /// reward currency right now (for example before the first trader has settled), or when an ERC-20 reward is
    /// mid-settlement (synced), since taking it then would shrink that payer's credit.
    function _distributeDuringSwap() private {
        uint256 amount = pendingFees();
        if (amount < minDistribute || reward.balanceOf(address(poolManager)) < amount) return;
        if (!reward.isAddressZero() && poolManager.getSyncedCurrency() == reward) return;
        _handOver(amount, true);
    }

    /// @dev Burning the claims credits the hook exactly what `take` debits, so the hook's delta stays zero.
    /// Native ETH comes to the hook and is passed on with `addRewards` (holders only; plain ETH sent to the token
    /// would count as a creator fee). An ERC-20 goes straight to the token and is counted by `syncToken`; if that
    /// call ever failed the reward would still sit in the token and count at the next sync.
    function _handOver(uint256 amount, bool duringSwap) private {
        poolManager.burn(address(this), rewardId, amount);
        distributed += amount;
        if (reward.isAddressZero()) {
            poolManager.take(reward, address(this), amount);
            ISwarmlingsToken(ling).addRewards{value: amount}();
        } else {
            poolManager.take(reward, ling, amount);
            try ISwarmlingsToken(ling).syncToken() {} catch {}
        }
        emit Distributed(amount, duringSwap);
    }

    /// @dev Native ETH arrives only from the manager's `take`.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    // ------------------------------------------------------------------ services for sinks

    /// @notice Spends `budget` of the caller's reward claims buying LING in the launch pool, up to
    /// `sqrtPriceLimitX96`. LING arrives as claims of the caller; unspent budget is returned as claims.
    function buy(uint256 budget, uint160 sqrtPriceLimitX96)
        external
        onlySink
        nonReentrant
        returns (uint256 spent, uint256 got)
    {
        bytes memory r = _run(abi.encode(OP_BUY, abi.encode(msg.sender, budget, sqrtPriceLimitX96)));
        (spent, got) = abi.decode(r, (uint256, uint256));
    }

    /// @notice Adds `liquidity` to the launch pool from the caller's claims, in a position the hook owns under the
    /// caller's salt. Nothing in this contract can ever remove it. Position fees in the reward currency go to NFT
    /// holders; LING fees return to the caller as claims.
    function addLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        onlySink
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory r = _run(abi.encode(OP_ADD, abi.encode(msg.sender, tickLower, tickUpper, liquidity)));
        (amount0, amount1) = abi.decode(r, (uint256, uint256));
    }

    /// @notice Collects the fees of the caller's position without changing it.
    function collectFees(int24 tickLower, int24 tickUpper)
        external
        onlySink
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory r = _run(abi.encode(OP_COLLECT, abi.encode(msg.sender, tickLower, tickUpper)));
        (amount0, amount1) = abi.decode(r, (uint256, uint256));
    }

    /// @notice Withdraws `amount` of the caller's claims in `currency` to `to`.
    function take(Currency currency, address to, uint256 amount) external onlySink nonReentrant {
        _run(abi.encode(OP_TAKE, abi.encode(msg.sender, currency, to, amount)));
    }

    /// @dev Runs `data` with the manager unlocked: directly when it already is (inside a swap), else through
    /// our own unlock. Slot 2 authorizes exactly one callback.
    function _run(bytes memory data) private returns (bytes memory) {
        if (!launchPoolSet) revert NotLaunched();
        if (poolManager.isUnlocked()) return _dispatch(data);
        assembly ("memory-safe") { tstore(2, 1) }
        bytes memory r = poolManager.unlock(data);
        uint256 open;
        assembly ("memory-safe") { open := tload(2) }
        if (open != 0) revert UnexpectedUnlock();
        return r;
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 open;
        assembly ("memory-safe") {
            open := tload(2)
            tstore(2, 0)
        }
        if (open == 0) revert UnexpectedUnlock();
        return _dispatch(data);
    }

    function _dispatch(bytes memory data) private returns (bytes memory) {
        (uint8 op, bytes memory args) = abi.decode(data, (uint8, bytes));
        if (op == OP_DISTRIBUTE) {
            _handOver(pendingFees(), false);
            return "";
        }
        if (op == OP_BUY) {
            (address sink, uint256 budget, uint160 limit) = abi.decode(args, (address, uint256, uint160));
            return _buy(sink, budget, limit);
        }
        if (op == OP_ADD) {
            (address sink, int24 lo, int24 hi, uint128 liquidity) =
                abi.decode(args, (address, int24, int24, uint128));
            return _modify(sink, lo, hi, liquidity);
        }
        if (op == OP_COLLECT) {
            (address sink, int24 lo, int24 hi) = abi.decode(args, (address, int24, int24));
            return _modify(sink, lo, hi, 0);
        }
        if (op == OP_TAKE) {
            (address sink, Currency currency, address to, uint256 amount) =
                abi.decode(args, (address, Currency, address, uint256));
            // Taking an ERC-20 that another party is mid-settlement with would shrink their credit and fail
            // their transaction later; refuse here, inside the sink's try/catch.
            if (!currency.isAddressZero() && poolManager.getSyncedCurrency() == currency) revert Synced();
            poolManager.burn(sink, currency.toId(), amount);
            poolManager.take(currency, to, amount);
            emit Taken(sink, currency, to, amount);
            return "";
        }
        revert Unknown();
    }

    /// @dev The hook is the swap's caller, so v4 runs none of this hook's callbacks for it: no fee, no modules.
    function _buy(address sink, uint256 budget, uint160 limit) private returns (bytes memory) {
        poolManager.burn(sink, rewardId, budget);
        BalanceDelta d =
            poolManager.swap(_launchKey, SwapParams(rewardIsCurrency0, -int256(budget), limit), "");
        int128 r = rewardIsCurrency0 ? d.amount0() : d.amount1();
        int128 l = rewardIsCurrency0 ? d.amount1() : d.amount0();
        uint256 spent = uint256(uint128(-r));
        uint256 got = uint256(uint128(l));
        if (spent < budget) poolManager.mint(sink, rewardId, budget - spent);
        if (got != 0) poolManager.mint(sink, lingId, got);
        emit SinkBought(sink, spent, got);
        return abi.encode(spent, got);
    }

    /// @dev Adds `liquidity` (or, with 0, only collects fees) to the sink's position. Principal is paid from the
    /// sink's claims; reward-currency fees go to the holders' pending claims, LING fees back to the sink.
    function _modify(address sink, int24 lo, int24 hi, uint128 liquidity) private returns (bytes memory) {
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(
            _launchKey,
            ModifyLiquidityParams(lo, hi, int256(uint256(liquidity)), bytes32(uint256(uint160(sink)))),
            ""
        );
        uint256 a0 = _settleSide(sink, _launchKey.currency0, callerDelta.amount0(), fees.amount0());
        uint256 a1 = _settleSide(sink, _launchKey.currency1, callerDelta.amount1(), fees.amount1());
        if (liquidity != 0) emit LiquidityAdded(sink, lo, hi, liquidity, a0, a1);
        return abi.encode(a0, a1);
    }

    function _settleSide(address sink, Currency c, int128 callerAmount, int128 feeAmount)
        private
        returns (uint256 principal)
    {
        int256 p = int256(callerAmount) - int256(feeAmount);
        uint256 id = c.toId();
        if (p < 0) {
            principal = uint256(-p);
            poolManager.burn(sink, id, principal);
        } else if (p > 0) {
            poolManager.mint(sink, id, uint256(p));
        }
        uint256 fee = uint256(uint128(feeAmount));
        if (fee != 0) {
            if (c == reward) {
                totalFees += fee;
                poolManager.mint(address(this), id, fee);
                emit PositionFees(sink, fee, 0);
            } else {
                poolManager.mint(sink, id, fee);
                emit PositionFees(sink, 0, fee);
            }
        }
    }

    // ------------------------------------------------------------------ governance

    /// @notice Replaces the slice table. Total slice bps are capped so the whole fee never exceeds `MAX_FEE_BPS`.
    function setSlices(Slice[] calldata s) external onlyCouncil {
        if (s.length > MAX_SLICES) revert TooMany();
        delete _slices;
        uint256 sum;
        for (uint256 i; i < s.length; ++i) {
            if (s[i].sink.code.length == 0 || s[i].bps == 0) revert BadEntry();
            for (uint256 j; j < i; ++j) {
                if (s[j].sink == s[i].sink) revert Duplicate();
            }
            sum += s[i].bps;
            _slices.push(s[i]);
            isSink[s[i].sink] = true;
        }
        if (sum > MAX_FEE_BPS - HOLDER_FEE_BPS) revert FeeTooHigh();
        emit SlicesSet(s);
    }

    /// @notice Replaces the module list.
    function setModules(Module[] calldata m) external onlyCouncil {
        if (m.length > MAX_MODULES) revert TooMany();
        delete _modules;
        for (uint256 i; i < m.length; ++i) {
            if (m[i].addr.code.length == 0 || m[i].callbacks == 0) revert BadEntry();
            for (uint256 j; j < i; ++j) {
                if (m[j].addr == m[i].addr) revert Duplicate();
            }
            _modules.push(m[i]);
        }
        emit ModulesSet(m);
    }

    /// @notice Removes one module.
    function disableModule(address module) external onlyCouncil {
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            if (_modules[i].addr == module) {
                _modules[i] = _modules[n - 1];
                _modules.pop();
                emit ModuleDisabled(module);
                return;
            }
        }
        revert Unknown();
    }

    /// @notice Hands governance to another contract, or to address(0) to freeze the configuration forever.
    function setCouncil(address newCouncil) external onlyCouncil {
        council = newCouncil;
        emit CouncilSet(newCouncil);
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

    /// @dev exact-in buy: bps of what the trader spends; exact-out sell: bps of what the pool pays out (the
    /// trader's amount plus the fee).
    function _specifiedFee(SwapParams calldata params, uint256 bps) private pure returns (uint256) {
        // Covers the whole int256 range, including its negative endpoint.
        uint256 magnitude = params.amountSpecified < 0
            ? uint256(-(params.amountSpecified + 1)) + 1
            : uint256(params.amountSpecified);
        return FullMath.mulDiv(magnitude, bps, params.amountSpecified < 0 ? 10000 : 10000 - bps);
    }
}

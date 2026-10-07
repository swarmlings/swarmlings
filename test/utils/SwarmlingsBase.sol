// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DN404Mirror} from "dn404/DN404Mirror.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";

/// @dev A real v4 PoolManager, the token deployed by a stand-in launcher, the hook at a 0x10CC address and the
/// launch pool at the IMD policy tier (1.25%). Three pairings: native ETH (testnets), IMD as currency0 and IMD as
/// currency1 (mainnet; which one depends on LING's address). Amounts are written in "reward units": BIG is a
/// sizeable buy in the reward currency (1 ETH, or 1,000 IMD).
abstract contract SwarmlingsBase is Test, Deployers {
    enum Pairing {
        Native,
        ImdFirst,
        LingFirst
    }

    uint24 internal constant FEE = 12500;
    int24 internal constant SPACING = 60;
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    address internal launcher = makeAddr("launcher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    Swarmlings internal ling;
    DN404Mirror internal mirror;
    SwarmlingsHook internal hook;
    PoolKey internal launchKey;
    Currency internal reward;
    bool internal native;
    bool internal rewardFirst;
    int24 internal startTick;
    uint256 internal UNIT;
    uint256 internal BIG;

    function pairing() internal pure virtual returns (Pairing) {
        return Pairing.Native;
    }

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        deployFreshManagerAndRouters();
        Pairing p = pairing();
        native = p == Pairing.Native;
        if (!native) {
            vm.chainId(1); // the token picks IMD on mainnet
            deployCodeTo("lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("Identity.md", "IMD", uint8(18)), IMD);
        }
        _deployLing(p);
        mirror = DN404Mirror(payable(ling.mirrorERC721()));
        UNIT = ling.UNIT();
        reward = Currency.wrap(ling.rewardCurrency());
        rewardFirst = native || IMD < address(ling);
        BIG = native ? 1 ether : 1_000e18;

        address hookAddr = address(HOOK_FLAGS | (uint160(0x4444) << 144));
        deployCodeTo("SwarmlingsHook.sol:SwarmlingsHook", abi.encode(manager, address(ling)), hookAddr);
        hook = SwarmlingsHook(payable(hookAddr));

        // ~49.6M LING per ETH (a 20 ETH cap), or ~400,000 LING per IMD (a 2,500 IMD cap)
        int24 lingPerReward = native ? int24(177_180) : int24(129_000);
        startTick = rewardFirst ? lingPerReward : -lingPerReward;
        launchKey = rewardFirst
            ? PoolKey(reward, Currency.wrap(address(ling)), FEE, SPACING, IHooks(hookAddr))
            : PoolKey(Currency.wrap(address(ling)), reward, FEE, SPACING, IHooks(hookAddr));
        manager.initialize(launchKey, TickMath.getSqrtPriceAtTick(startTick));
        _seedLiquidity();

        address[3] memory traders = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            _dealReward(traders[i], native ? 1_000 ether : 10_000_000e18);
            vm.startPrank(traders[i]);
            ling.approve(address(swapRouter), type(uint256).max);
            if (!native) MockERC20(IMD).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Searches the launcher's nonce for a LING address on the wanted side of IMD.
    function _deployLing(Pairing p) internal {
        for (uint64 n = 1;; ++n) {
            vm.setNonce(launcher, n);
            address next = vm.computeCreateAddress(launcher, n);
            if (p == Pairing.Native || (p == Pairing.ImdFirst) == (IMD < next)) break;
        }
        vm.prank(launcher);
        ling = new Swarmlings();
    }

    /// @dev Full-range position with 10 ETH (or 25,000 IMD) and the matching LING, provided by the launcher.
    function _seedLiquidity() internal virtual {
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        uint256 r = native ? 10 ether : 25_000e18;
        uint256 l = 800_000_000e18;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(startTick),
            TickMath.getSqrtPriceAtTick(lo),
            TickMath.getSqrtPriceAtTick(hi),
            rewardFirst ? r : l,
            rewardFirst ? l : r
        );
        _dealReward(launcher, r + r / 10);
        vm.startPrank(launcher);
        ling.approve(address(modifyLiquidityRouter), type(uint256).max);
        if (!native) MockERC20(IMD).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: native ? r + r / 10 : 0}(
            launchKey, ModifyLiquidityParams(lo, hi, int256(uint256(liq)), 0), ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ reward currency

    function _dealReward(address to, uint256 amount) internal {
        if (native) vm.deal(to, to.balance + amount);
        else MockERC20(IMD).mint(to, amount);
    }

    function _rbal(address who) internal view returns (uint256) {
        return reward.balanceOf(who);
    }

    // ------------------------------------------------------------------ swaps, in reward units

    function _swap(address who, bool buy, int256 amountSpecified, uint256 value) internal returns (BalanceDelta d) {
        bool zeroForOne = buy == rewardFirst;
        vm.prank(who);
        d = swapRouter.swap{value: native ? value : 0}(
            launchKey,
            SwapParams(zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _buyExactIn(address who, uint256 rewardIn) internal returns (BalanceDelta) {
        return _swap(who, true, -int256(rewardIn), rewardIn);
    }

    function _buyExactOut(address who, uint256 lingOut) internal returns (BalanceDelta) {
        return _swap(who, true, int256(lingOut), 100 * BIG);
    }

    function _sellExactIn(address who, uint256 lingIn) internal returns (BalanceDelta) {
        return _swap(who, false, -int256(lingIn), 0);
    }

    function _sellExactOut(address who, uint256 rewardOut) internal returns (BalanceDelta) {
        return _swap(who, false, int256(rewardOut), 0);
    }

    /// @dev LING straight from the launcher's allocation, like a Merkle claim or an OTC transfer.
    function _give(address to, uint256 amount) internal {
        vm.prank(launcher);
        ling.transfer(to, amount);
    }

    /// @dev What `who` can claim in the swap-fee currency right now.
    function _pend(address who) internal view returns (uint256) {
        (uint256 e, uint256 t) = ling.pending(who);
        return native ? e : t;
    }

    function _nextDay() internal {
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
    }

    function _paidOut() internal {
        vm.warp((block.timestamp / 1 days + 2) * 1 days);
    }

    function _nfts(address who) internal view returns (uint256) {
        return mirror.balanceOf(who);
    }
}

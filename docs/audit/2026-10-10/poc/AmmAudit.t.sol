// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";
import {ISwarmlingsHook, Callbacks} from "../../src/interfaces/IHive.sol";
import {TreasurySink} from "../../src/modules/TreasurySink.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {HiveBase} from "../Hive.t.sol";

// ---------------------------------------------------------------------------------------------------------------
// helper contracts
// ---------------------------------------------------------------------------------------------------------------

/// @dev A quoter whose extra fee makes `bps += extra` overflow in the hook.
contract OverflowQuoter {
    function quoteFee(address, PoolKey calldata, SwapParams calldata, bool, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return type(uint256).max;
    }
}

/// @dev A "quoter" that accepts every call and returns nothing (e.g. a proxy to a missing implementation).
contract SilentQuoter {
    fallback() external {}
}

/// @dev A sink whose `due()` returns a non-boolean word.
contract DirtySink {
    function due() external pure returns (uint256) {
        return 2;
    }

    function poke() external {}
}

/// @dev Gives ERC-6909 reward claims to a sink, from the donor's own funds (what anyone can do).
contract Donor is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function donate(address sink, Currency c, uint256 amt) external {
        pm.unlock(abi.encode(sink, c, amt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address sink, Currency c, uint256 amt) = abi.decode(data, (address, Currency, uint256));
        if (Currency.unwrap(c) == address(0)) {
            pm.settle{value: amt}();
        } else {
            pm.sync(c);
            MockERC20(Currency.unwrap(c)).transfer(address(pm), amt);
            pm.settle();
        }
        pm.mint(sink, c.toId(), amt);
        return "";
    }
}

/// @dev An observer on BEFORE_SWAP that, once per outer swap, performs a dust buy in a *second* charged pool.
contract Nester is IUnlockCallback {
    IPoolManager immutable pm;
    address immutable hook;
    PoolKey other;
    bool rewardFirst;
    bool busy;
    uint256 public nested;

    constructor(IPoolManager _pm, address _hook, PoolKey memory _other, bool _rewardFirst) {
        pm = _pm;
        hook = _hook;
        other = _other;
        rewardFirst = _rewardFirst;
    }

    receive() external payable {}

    function onBeforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external {
        require(msg.sender == hook);
        if (busy) return;
        busy = true;
        BalanceDelta d = pm.swap(
            other,
            SwapParams(
                rewardFirst,
                -int256(1000),
                rewardFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 r = rewardFirst ? d.amount0() : d.amount1();
        int128 l = rewardFirst ? d.amount1() : d.amount0();
        Currency rc = rewardFirst ? other.currency0 : other.currency1;
        Currency lc = rewardFirst ? other.currency1 : other.currency0;
        uint256 pay = uint256(uint128(-r));
        if (Currency.unwrap(rc) == address(0)) {
            pm.settle{value: pay}();
        } else {
            pm.sync(rc);
            MockERC20(Currency.unwrap(rc)).transfer(address(pm), pay);
            pm.settle();
        }
        if (l > 0) pm.take(lc, address(this), uint256(uint128(l)));
        ++nested;
        busy = false;
    }

    function unlockCallback(bytes calldata) external pure returns (bytes memory) {
        return "";
    }
}


/// @dev A liquidity router that accepts mixed-sign deltas (the stock test router asserts against them).
contract LpRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function modify(PoolKey memory key, ModifyLiquidityParams memory p) external payable {
        pm.unlock(abi.encode(msg.sender, key, p));
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok);
        }
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (address user, PoolKey memory key, ModifyLiquidityParams memory p) =
            abi.decode(raw, (address, PoolKey, ModifyLiquidityParams));
        pm.modifyLiquidity(key, p, "");
        _square(user, key.currency0);
        _square(user, key.currency1);
        return "";
    }

    function _square(address user, Currency c) private {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            uint256 amt = uint256(-d);
            if (Currency.unwrap(c) == address(0)) {
                pm.settle{value: amt}();
            } else {
                pm.sync(c);
                MockERC20(Currency.unwrap(c)).transferFrom(user, address(pm), amt);
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(c, user, uint256(d));
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// the suite
// ---------------------------------------------------------------------------------------------------------------

abstract contract AmmAuditSuite is HiveBase {
    using StateLibrary for IPoolManager;

    function _skipNfts(address who) internal {
        vm.prank(who);
        ling.setSkipNFT(true);
    }

    function _rawSwap(address who, bool buy, int256 amt, uint256 gasLimit) internal returns (bool ok) {
        bool zeroForOne = buy == rewardFirst;
        vm.prank(who);
        try swapRouter.swap{value: native && buy ? 100 * BIG : 0, gas: gasLimit}(
            launchKey,
            SwapParams(
                zeroForOne, amt, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    // ------------------------------------------------------------------ A-1: JIT penalty bypass

    bytes32 constant SALT = bytes32(uint256(1));

    LpRouter lpRouter;

    function _lpAdd(address lp, uint128 liq) internal {
        vm.prank(lp);
        lpRouter.modify{value: native ? 5 * BIG : 0}(
            launchKey,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(uint256(liq)), SALT
            )
        );
    }

    function _lpRemove(address lp, uint128 liq) internal {
        vm.prank(lp);
        lpRouter.modify(
            launchKey,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), -int256(uint256(liq)), SALT
            )
        );
    }

    /// @return penalty reward currency forfeited to holders by the JIT guard; got reward currency the LP ended with
    function _jit(bool dustAdd) internal returns (uint256 penalty, uint256 got) {
        address lp = makeAddr("jit");
        _skipNfts(lp);
        _give(lp, 150_000_000e18);
        _dealReward(lp, 10 * BIG);
        lpRouter = new LpRouter(manager);
        vm.startPrank(lp);
        ling.approve(address(lpRouter), type(uint256).max);
        if (!native) MockERC20(IMD).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();

        uint128 liq = manager.getLiquidity(launchKey.toId()) / 8;
        uint256 r0 = _rbal(lp);
        _lpAdd(lp, liq);
        uint256 feesBefore = hook.totalFees();
        _buyExactIn(alice, BIG); // victim's buy pays a 1.25% LP fee in the reward currency
        uint256 swapFee = BIG * 125 / 10000;
        if (dustAdd) _lpAdd(lp, 1e6); // a dust top-up of the same position collects every fee, penalty-free
        _lpRemove(lp, dustAdd ? liq + 1e6 : liq);
        penalty = hook.totalFees() - feesBefore - swapFee;
        got = _rbal(lp) + (native ? 0 : 0);
        // report the LP's net reward-currency result
        got = _rbal(lp) > r0 ? _rbal(lp) - r0 : 0;
    }

    function test_A1_jitPenaltyBypassedByDustTopUp() public {
        uint256 snap = vm.snapshotState();
        (uint256 honestPenalty, uint256 honestGot) = _jit(false);
        vm.revertToState(snap);
        (uint256 attackPenalty, uint256 attackGot) = _jit(true);
        emit log_named_uint("penalty, plain add/remove in the same block", honestPenalty);
        emit log_named_uint("penalty, add + dust top-up + remove", attackPenalty);
        emit log_named_uint("LP net reward, plain", honestGot);
        emit log_named_uint("LP net reward, with dust top-up", attackGot);
        assertGt(honestPenalty, 0, "control: the guard bites a plain JIT remove");
        assertEq(attackPenalty, 0, "the dust top-up collects the fees before the penalty can see them");
        assertGt(attackGot, honestGot, "the JIT LP keeps the fees it should have forfeited");
    }

    // ------------------------------------------------------------------ A-2: modules/sinks can block sells

    function _sellSetup() internal {
        _skipNfts(alice);
        _buyExactIn(alice, BIG / 10);
    }

    function test_A2_overflowingQuoterBlocksSells() public {
        _sellSetup();
        uint256 amt = ling.balanceOf(alice) / 2;
        OverflowQuoter q = new OverflowQuoter();
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        // not a guard, "observers and quoters can never block a trade": yet every swap, sells included, reverts
        assertFalse(_rawSwap(alice, false, -int256(amt), 5_000_000), "sell reverts");
        assertFalse(_rawSwap(alice, true, -int256(BIG / 100), 5_000_000), "buy reverts");
        // only the council can undo it
        _govern(abi.encodeCall(ISwarmlingsHook.disableModule, (address(q))));
        assertTrue(_rawSwap(alice, false, -int256(amt), 5_000_000), "sell works again once disabled");
    }

    function test_A2_silentQuoterBlocksSells() public {
        _sellSetup();
        uint256 amt = ling.balanceOf(alice) / 2;
        SilentQuoter q = new SilentQuoter();
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        assertFalse(_rawSwap(alice, false, -int256(amt), 5_000_000), "ABI-decode failure is not caught by try/catch");
    }

    function test_A2_dirtySinkDueBlocksSells() public {
        _sellSetup();
        uint256 amt = ling.balanceOf(alice) / 2;
        DirtySink s = new DirtySink();
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(s), 100, true))));
        assertFalse(_rawSwap(alice, false, -int256(amt), 5_000_000), "bool decode failure reverts the swap");
    }

    // ------------------------------------------------------------------ A-3: InsufficientGas on sells

    function test_A3_dueSinkMakesLowGasSellsRevert() public {
        _sellSetup();
        TreasurySink t = new TreasurySink(hook, dev, BIG / 10);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 100, true))));
        uint256 amt = ling.balanceOf(alice) / 8;

        // control: sink not due. Find the least gas the sell needs (what eth_estimateGas would return), cold.
        uint256 snap = vm.snapshotState();
        uint256 minGas;
        for (uint256 gl = 200_000; gl <= 1_200_000; gl += 10_000) {
            bool ok = _rawSwap(alice, false, -int256(amt), gl);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            if (ok) {
                minGas = gl;
                break;
            }
        }
        // wallets add a buffer to the estimate; use +20%
        uint256 limit = minGas * 12 / 10;
        emit log_named_uint("least gas a plain sell needs (cold, 10k steps)", minGas);
        emit log_named_uint("limit a wallet would set (+20%)", limit);
        assertLt(limit, 600_000);
        assertTrue(_rawSwap(alice, false, -int256(amt), limit), "control: sell passes with the buffered estimate");
        vm.revertToState(snap);
        snap = vm.snapshotState();

        // anyone can make the sink due by giving it claims worth its minimum (a donation, 0.1 reward units here)
        Donor donor = new Donor(manager);
        _dealReward(address(donor), BIG);
        donor.donate(address(t), reward, BIG / 10);
        assertTrue(t.due(), "sink is due");

        assertFalse(_rawSwap(alice, false, -int256(amt), limit), "same sell, same gas limit: InsufficientGas");
        assertTrue(_rawSwap(alice, false, -int256(amt), 1_500_000), "with 1.5M gas it passes and pokes the sink");
        assertFalse(t.due());
    }

    // ------------------------------------------------------------------ A-4: launch pool binding ignores tick spacing

    function test_A4_firstPoolAtTheTierBindsWhateverTheTickSpacing() public {
        vm.prank(makeAddr("launcher2"));
        Swarmlings l2 = new Swarmlings();
        address hookAddr = address(uint160(0x3FFF) | (uint160(0x6666) << 144));
        deployCodeTo("SwarmlingsHook.sol:SwarmlingsHook", abi.encode(manager, address(l2)), hookAddr);
        SwarmlingsHook h2 = SwarmlingsHook(payable(hookAddr));
        Currency r = Currency.wrap(l2.rewardCurrency());
        bool rf = native || Currency.unwrap(r) < address(l2);
        (Currency c0, Currency c1) = rf ? (r, Currency.wrap(address(l2))) : (Currency.wrap(address(l2)), r);
        // anybody, with any price and tick spacing 32767, at fee 12500
        manager.initialize(PoolKey(c0, c1, 12500, 32767, IHooks(hookAddr)), TickMath.getSqrtPriceAtTick(0));
        PoolKey memory real = PoolKey(c0, c1, 12500, 60, IHooks(hookAddr));
        manager.initialize(real, TickMath.getSqrtPriceAtTick(rf ? startTick : -startTick));
        assertEq(h2.launchKey().tickSpacing, 32767, "the attacker's pool is the launch pool");
        assertTrue(PoolId.unwrap(h2.launchPool()) != PoolId.unwrap(real.toId()), "the intended pool is not");
    }

    // ------------------------------------------------------------------ A-5: transient slot 3 is shared scratch

    function _secondPool() internal returns (PoolKey memory other) {
        other = launchKey;
        other.fee = 3000;
        other.tickSpacing = 60;
        manager.initialize(other, TickMath.getSqrtPriceAtTick(startTick));
        _dealReward(launcher, 100 * BIG);
        vm.prank(launcher);
        modifyLiquidityRouter.modifyLiquidity{value: native ? 10 * BIG : 0}(
            other,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e20, 0),
            ""
        );
    }

    function test_A5_nestedSwapInASecondPoolZeroesTheOuterFee() public {
        _sellSetup();
        PoolKey memory other = _secondPool();
        uint256 amt = ling.balanceOf(alice) / 2;

        // control: a normal sell pays the holders their 1.25%
        uint256 snap = vm.snapshotState();
        uint256 before = hook.totalFees();
        assertTrue(_rawSwap(alice, false, -int256(amt), 3_000_000));
        uint256 normalFee = hook.totalFees() - before;
        assertGt(normalFee, 0, "control fee");
        vm.revertToState(snap);

        Nester n = new Nester(manager, address(hook), other, rewardFirst);
        _dealReward(address(n), 10 * BIG);
        _give(address(n), 1e18); // nothing needed, but keeps the module a plain contract with a balance
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(n), Callbacks.BEFORE_SWAP, false))));

        before = hook.totalFees();
        assertTrue(_rawSwap(alice, false, -int256(amt), 3_000_000), "sell still goes through");
        emit log_named_uint("nested swaps executed by the module", n.nested());
        emit log_named_uint("holder fee, normal sell", normalFee);
        emit log_named_uint("holder fee, sell with the module", hook.totalFees() - before);
        assertEq(n.nested(), 1, "module managed its nested swap inside its gas cap");
        // the only fee collected is the module's own 1000-wei dust buy in the second pool (12 wei)
        assertEq(hook.totalFees() - before, uint256(1000) * 125 / 10000, "the outer sell paid the holders nothing");
    }

    // ------------------------------------------------------------------ A-6 (info): sandwiching the buyback does not pay

    function test_A6_sandwichingTheBuybackLosesToFees() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(b), 375, false))));
        _skipNfts(alice);
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(bob, 10 * BIG); // fills the buyback budget
        }
        uint256 budget = _claims(address(b), reward);
        assertGt(budget, 0);
        uint256 r0 = _rbal(alice);
        _buyExactIn(alice, 5 * BIG); // front-run
        b.poke(); // the victim: buys up to the 1% band above the attacker's price
        _sellExactIn(alice, ling.balanceOf(alice)); // back-run
        uint256 r1 = _rbal(alice);
        emit log_named_uint("buyback budget", budget);
        emit log_named_uint("buyback spent", b.spent());
        emit log_named_uint("attacker reward before", r0);
        emit log_named_uint("attacker reward after", r1);
        assertLt(r1, r0, "the sandwich loses money: two 2.5% legs against a <=1% band");
    }

    // ------------------------------------------------------------------ A-7: a sink that stays due starves the others

    function test_A7_stuckFirstSinkStarvesLaterSinks() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        TreasurySink t = new TreasurySink(hook, dev, 1);
        ISwarmlingsHook.Slice[] memory sl = new ISwarmlingsHook.Slice[](2);
        sl[0] = ISwarmlingsHook.Slice(address(b), 275, true);
        sl[1] = ISwarmlingsHook.Slice(address(t), 100, true);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (sl)));
        _skipNfts(bob);
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(bob, 10 * BIG); // each swap pokes the buyback (first due sink) and then returns
        }
        // the 1% band stops the buyback every time, so it stays due, and the treasury never gets its turn
        assertTrue(b.due(), "buyback still has budget");
        assertGt(_claims(address(t), reward), 0, "treasury claims are sitting there");
        assertEq(t.collected(), 0, "treasury was never poked by a swap");
    }
}

contract NativeAmmAudit is AmmAuditSuite {}

contract ImdFirstAmmAudit is AmmAuditSuite {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.ImdFirst;
    }
}

contract LingFirstAmmAudit is AmmAuditSuite {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.LingFirst;
    }
}

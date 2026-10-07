// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {SwarmlingsHook} from "../src/SwarmlingsHook.sol";
import {SwarmlingsCouncil} from "../src/SwarmlingsCouncil.sol";
import {ISwarmlingsHook, Callbacks} from "../src/interfaces/IHive.sol";
import {TreasurySink} from "../src/modules/TreasurySink.sol";
import {BuybackBurn} from "../src/modules/BuybackBurn.sol";
import {AutoLiquidity} from "../src/modules/AutoLiquidity.sol";
import {TwapOracle} from "../src/modules/TwapOracle.sol";
import {MaxBuy} from "../src/modules/MaxBuy.sol";
import {VolatilityFee} from "../src/modules/VolatilityFee.sol";
import {SwarmlingsBase} from "./utils/SwarmlingsBase.sol";

/// @dev A module for tests: counts calls, optionally reverts, optionally quotes a fixed extra.
contract FlexModule {
    uint256 public calls;
    bool public revertAlways;
    uint256 public extra;
    bytes4 public lastSelector;

    error Nope();

    function setRevert(bool r) external {
        revertAlways = r;
    }

    function setExtra(uint256 e) external {
        extra = e;
    }

    function quoteFee(address, PoolKey calldata, SwapParams calldata, bool, bytes calldata)
        external
        view
        returns (uint256)
    {
        if (revertAlways) revert Nope();
        return extra;
    }

    fallback() external {
        ++calls;
        lastSelector = msg.sig;
        if (revertAlways) revert Nope();
    }
}

contract Nobody {}

abstract contract HiveBase is SwarmlingsBase {
    using StateLibrary for IPoolManager;

    SwarmlingsCouncil council;
    address dev;

    function setUp() public virtual override {
        super.setUp();
        dev = ling.DEV();
        deployCodeTo("SwarmlingsCouncil.sol:SwarmlingsCouncil", abi.encode(dev), hook.COUNCIL());
        council = SwarmlingsCouncil(hook.COUNCIL());
    }

    /// @dev Proposes `data` on the hook, waits out the delay and executes it.
    function _govern(bytes memory data) internal {
        vm.prank(dev);
        bytes32 id = council.propose(address(hook), data, "test");
        skip(council.DELAY());
        council.execute(id, data);
    }

    function _slice(address sink, uint16 bps, bool poke)
        internal
        pure
        returns (ISwarmlingsHook.Slice[] memory s)
    {
        s = new ISwarmlingsHook.Slice[](1);
        s[0] = ISwarmlingsHook.Slice(sink, bps, poke);
    }

    function _module(address addr, uint16 callbacks, bool guard)
        internal
        pure
        returns (ISwarmlingsHook.Module[] memory m)
    {
        m = new ISwarmlingsHook.Module[](1);
        m[0] = ISwarmlingsHook.Module(addr, callbacks, guard);
    }

    function _claims(address who, Currency c) internal view returns (uint256) {
        return manager.balanceOf(who, c.toId());
    }

    function _positionLiquidity(address sink, int24 lo, int24 hi) internal view returns (uint128) {
        bytes32 key = Position.calculatePositionKey(address(hook), lo, hi, bytes32(uint256(uint160(sink))));
        return manager.getPositionLiquidity(launchKey.toId(), key);
    }
}

abstract contract HiveSuite is HiveBase {
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ governance

    function test_councilLivesAtTheConstant() public view {
        bytes memory initCode = abi.encodePacked(type(SwarmlingsCouncil).creationCode, abi.encode(dev));
        address expected = vm.computeCreate2Address(
            keccak256("swarmlings.council.v1"),
            keccak256(initCode),
            0x4e59b44847b379578588920cA78FbF26c0B4956C
        );
        assertEq(expected, hook.COUNCIL(), "CREATE2 address of the council");
        assertEq(hook.council(), address(council));
        assertEq(council.owner(), dev);
        assertEq(hook.feeBps(), 125);
        assertEq(hook.slices().length, 0);
        assertEq(hook.modules().length, 0);
    }

    function test_onlyTheCouncilConfigures() public {
        TreasurySink t = new TreasurySink(hook, dev, 1);
        vm.expectRevert(SwarmlingsHook.OnlyCouncil.selector);
        hook.setSlices(_slice(address(t), 100, false));
        vm.prank(dev);
        vm.expectRevert(SwarmlingsHook.OnlyCouncil.selector);
        hook.setSlices(_slice(address(t), 100, false)); // not even the owner directly
        vm.expectRevert(SwarmlingsHook.OnlyCouncil.selector);
        hook.setCouncil(alice);
    }

    function test_timelock() public {
        TreasurySink t = new TreasurySink(hook, dev, 1);
        bytes memory data = abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 100, false)));
        vm.expectRevert(SwarmlingsCouncil.OnlyOwner.selector);
        council.propose(address(hook), data, "no");
        vm.prank(dev);
        bytes32 id = council.propose(address(hook), data, "treasury 1%");
        vm.expectRevert(SwarmlingsCouncil.TooEarly.selector);
        council.execute(id, data);
        skip(council.DELAY() - 1);
        vm.expectRevert(SwarmlingsCouncil.TooEarly.selector);
        council.execute(id, data);
        skip(1);
        vm.expectRevert(SwarmlingsCouncil.Mismatch.selector);
        council.execute(id, abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 300, false))));
        council.execute(id, data);
        assertEq(hook.feeBps(), 225);
        vm.expectRevert(SwarmlingsCouncil.UnknownProposal.selector);
        council.execute(id, data);

        vm.prank(dev);
        bytes32 id2 = council.propose(address(hook), data, "again");
        skip(council.DELAY() + council.GRACE() + 1);
        vm.expectRevert(SwarmlingsCouncil.Lapsed.selector);
        council.execute(id2, data);

        vm.prank(dev);
        bytes32 id3 = council.propose(address(hook), data, "cancelled");
        vm.prank(dev);
        council.cancel(id3);
        skip(council.DELAY());
        vm.expectRevert(SwarmlingsCouncil.UnknownProposal.selector);
        council.execute(id3, data);
    }

    function test_ownerChangesOnlyThroughTheTimelock() public {
        vm.prank(dev);
        vm.expectRevert(SwarmlingsCouncil.OnlySelf.selector);
        council.setOwner(alice);
        bytes memory data = abi.encodeCall(SwarmlingsCouncil.setOwner, (alice));
        vm.prank(dev);
        bytes32 id = council.propose(address(council), data, "hand over");
        skip(council.DELAY());
        council.execute(id, data);
        assertEq(council.owner(), alice);
    }

    function test_frozenCouncil() public {
        _govern(abi.encodeCall(ISwarmlingsHook.setCouncil, (address(0))));
        assertEq(hook.council(), address(0));
        TreasurySink t = new TreasurySink(hook, dev, 1);
        bytes memory data = abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 100, false)));
        vm.prank(dev);
        bytes32 id = council.propose(address(hook), data, "too late");
        skip(council.DELAY());
        vm.expectRevert(SwarmlingsHook.OnlyCouncil.selector);
        council.execute(id, data);
    }

    function test_sliceValidation() public {
        TreasurySink t = new TreasurySink(hook, dev, 1);
        BuybackBurn b = new BuybackBurn(hook, 1);
        ISwarmlingsHook.Slice[] memory s = new ISwarmlingsHook.Slice[](2);
        s[0] = ISwarmlingsHook.Slice(address(t), 200, false);
        s[1] = ISwarmlingsHook.Slice(address(b), 176, false);
        vm.prank(address(council));
        vm.expectRevert(SwarmlingsHook.FeeTooHigh.selector);
        hook.setSlices(s);
        s[1].bps = 175;
        vm.prank(address(council));
        hook.setSlices(s);
        assertEq(hook.feeBps(), 500);
        s[1].sink = address(t);
        vm.prank(address(council));
        vm.expectRevert(SwarmlingsHook.Duplicate.selector);
        hook.setSlices(s);
        s[1].sink = alice;
        vm.prank(address(council));
        vm.expectRevert(SwarmlingsHook.BadEntry.selector);
        hook.setSlices(s);
        ISwarmlingsHook.Slice[] memory many = new ISwarmlingsHook.Slice[](9);
        vm.prank(address(council));
        vm.expectRevert(SwarmlingsHook.TooMany.selector);
        hook.setSlices(many);
        vm.prank(address(council));
        hook.setSlices(new ISwarmlingsHook.Slice[](0));
        assertEq(hook.feeBps(), 125);
        assertTrue(hook.isSink(address(t)), "a former sink keeps its access");
    }

    function test_moduleValidationAndEmergencyDisable() public {
        FlexModule m = new FlexModule();
        vm.prank(address(council));
        vm.expectRevert(SwarmlingsHook.BadEntry.selector);
        hook.setModules(_module(address(m), 0, false));
        vm.prank(address(council));
        vm.expectRevert(SwarmlingsHook.BadEntry.selector);
        hook.setModules(_module(alice, Callbacks.AFTER_SWAP, false));
        _govern(
            abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(m), Callbacks.AFTER_SWAP, false)))
        );
        assertEq(hook.modules().length, 1);
        _buyExactIn(alice, BIG / 10);
        assertEq(m.calls(), 1);
        vm.prank(dev);
        council.disableModule(address(hook), address(m)); // no delay
        assertEq(hook.modules().length, 0);
        _buyExactIn(alice, BIG / 10);
        assertEq(m.calls(), 1);
        vm.prank(dev);
        vm.expectRevert(SwarmlingsHook.Unknown.selector);
        council.disableModule(address(hook), address(m));
    }

    // ------------------------------------------------------------------ fee split

    function testFuzz_feeSplitsAcrossModes(uint256 amount, uint8 mode) public {
        TreasurySink t = new TreasurySink(hook, dev, type(uint256).max);
        BuybackBurn b = new BuybackBurn(hook, type(uint256).max);
        ISwarmlingsHook.Slice[] memory s = new ISwarmlingsHook.Slice[](2);
        s[0] = ISwarmlingsHook.Slice(address(t), 100, false);
        s[1] = ISwarmlingsHook.Slice(address(b), 50, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (s)));
        assertEq(hook.feeBps(), 275);

        mode = mode % 4;
        uint256 before = _rbal(alice);
        uint256 fee;
        if (mode == 0) {
            uint256 a = bound(amount, 1e9, 5 * BIG);
            _buyExactIn(alice, a);
            fee = a * 275 / 10000;
        } else if (mode == 1) {
            _buyExactOut(alice, bound(amount, 1e18, 100_000_000e18));
            uint256 paid = before - _rbal(alice);
            fee = hook.totalFees() + hook.sinkFees();
            assertEq(fee, (paid - fee) * 275 / 9725, "2.75% of everything spent");
        } else if (mode == 2) {
            _give(alice, 200_000_000e18);
            _sellExactIn(alice, bound(amount, 1e18, 200_000_000e18));
            uint256 got = _rbal(alice) - before;
            fee = hook.totalFees() + hook.sinkFees();
            assertEq(fee, (got + fee) * 275 / 10000, "2.75% of the pool's gross output");
        } else {
            _give(alice, 200_000_000e18);
            uint256 out = bound(amount, 1e9, BIG / 4);
            _sellExactOut(alice, out);
            fee = out * 275 / 9725;
        }
        uint256 tClaims = _claims(address(t), reward);
        uint256 bClaims = _claims(address(b), reward);
        assertEq(tClaims, fee * 100 / 275, "treasury slice");
        assertEq(bClaims, fee * 50 / 275, "buyback slice");
        assertEq(hook.sinkFees(), tClaims + bClaims);
        assertEq(hook.totalFees(), fee - tClaims - bClaims, "holders get the rest");
        assertEq(hook.totalFees(), hook.distributed() + hook.pendingFees(), "ledger");
    }

    function test_quotedExtraGoesToHoldersAndIsCapped() public {
        FlexModule q = new FlexModule();
        q.setExtra(100);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        _buyExactIn(alice, BIG);
        assertEq(hook.totalFees(), BIG * 225 / 10000, "1.25% + 1% quoted, all to holders");
        q.setExtra(10_000);
        uint256 before = hook.totalFees();
        _buyExactIn(alice, BIG);
        assertEq(hook.totalFees() - before, BIG * 500 / 10000, "capped at MAX_FEE_BPS");
        q.setRevert(true);
        before = hook.totalFees();
        vm.expectEmit(true, false, false, true);
        emit SwarmlingsHook.ModuleFailed(address(q), FlexModule.quoteFee.selector);
        _buyExactIn(alice, BIG);
        assertEq(hook.totalFees() - before, BIG * 125 / 10000, "a failing quoter adds nothing");
    }

    // ------------------------------------------------------------------ guards and observers

    function test_guardsRevertBuysNeverSells() public {
        FlexModule g = new FlexModule();
        g.setRevert(true);
        _govern(
            abi.encodeCall(
                ISwarmlingsHook.setModules,
                (_module(
                        address(g),
                        Callbacks.BEFORE_SWAP | Callbacks.AFTER_SWAP | Callbacks.BEFORE_REMOVE_LIQUIDITY,
                        true
                    ))
            )
        );
        _give(alice, UNIT * 5);
        vm.expectRevert();
        _buyExactIn(alice, BIG / 10);
        vm.expectRevert();
        _buyExactOut(alice, UNIT);
        vm.expectEmit(true, false, false, false);
        emit SwarmlingsHook.ModuleFailed(address(g), bytes4(0)); // called on the sell as an observer, and ignored
        _sellExactIn(alice, UNIT); // a reverting guard cannot stop a sell
        _sellExactOut(alice, BIG / 1000);
        assertLt(ling.balanceOf(alice), UNIT * 4);
        assertEq(_nfts(alice), ling.balanceOf(alice) / UNIT);
        // nor removing liquidity
        vm.prank(launcher);
        modifyLiquidityRouter.modifyLiquidity(
            launchKey,
            ModifyLiquidityParamsLib.remove(
                TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e6
            ),
            ""
        );
    }

    function test_observersNeverBlock() public {
        FlexModule o = new FlexModule();
        o.setRevert(true);
        _govern(
            abi.encodeCall(
                ISwarmlingsHook.setModules,
                (_module(
                        address(o),
                        Callbacks.BEFORE_SWAP | Callbacks.AFTER_SWAP | Callbacks.BEFORE_ADD_LIQUIDITY,
                        false
                    ))
            )
        );
        vm.expectEmit(true, false, false, true);
        emit SwarmlingsHook.ModuleFailed(
            address(o),
            bytes4(
                keccak256(
                    "onBeforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)"
                )
            )
        );
        _buyExactIn(alice, BIG / 10);
        assertGt(ling.balanceOf(alice), 0);
        assertEq(hook.totalFees(), BIG / 10 * 125 / 10000);
    }

    function test_swapsMustBringGasForObservers() public {
        FlexModule o = new FlexModule();
        _govern(
            abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(o), Callbacks.BEFORE_SWAP, false)))
        );
        vm.prank(address(manager));
        vm.expectRevert(SwarmlingsHook.InsufficientGas.selector);
        hook.beforeSwap{gas: 150_000}(alice, launchKey, SwapParams(rewardFirst, -1e9, 0), "");
    }

    function test_maxBuyGuard() public {
        MaxBuy g = new MaxBuy(hook, UNIT, 1 hours, block.timestamp + council.DELAY());
        assertEq(g.cap(), UNIT, "flat until it starts");
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(g), Callbacks.AFTER_SWAP, true))));
        assertEq(g.cap(), UNIT);
        vm.expectRevert();
        _buyExactOut(alice, UNIT * 2);
        _buyExactOut(alice, UNIT);
        _give(bob, UNIT * 20);
        _sellExactIn(bob, UNIT * 20); // sells are never capped
        skip(30 minutes);
        assertEq(g.cap(), UNIT * 11 / 2);
        _buyExactOut(alice, UNIT * 5);
        skip(30 minutes);
        assertEq(g.cap(), type(uint256).max);
        _buyExactOut(alice, UNIT * 50);
    }

    // ------------------------------------------------------------------ sinks

    function test_treasurySinkForwardsToTheRecipient() public {
        TreasurySink t = new TreasurySink(hook, dev, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 100, true))));
        uint256 before = _rbal(dev);
        _buyExactIn(alice, BIG); // the fee is taken before the swap, so the sink is due and poked right after it
        uint256 first = BIG * 100 / 10000;
        assertEq(_rbal(dev) - before, first, "poked inside the swap");
        assertEq(_claims(address(t), reward), 0);
        _buyExactOut(alice, UNIT); // fee taken after the swap, and poked straight away as well
        uint256 second = _rbal(dev) - before - first;
        assertGt(second, 0);
        assertEq(_claims(address(t), reward), 0);
        t.poke(); // nothing left: a no-op
        assertEq(t.collected(), first + second);
        // below the minimum nothing moves
        TreasurySink big = new TreasurySink(hook, dev, 1000 * BIG);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(big), 100, true))));
        _buyExactIn(alice, BIG);
        assertEq(_claims(address(big), reward), BIG * 100 / 10000, "waits for the minimum");
        assertFalse(big.due());
    }

    function test_servicesOnlyForSinks() public {
        vm.expectRevert(SwarmlingsHook.OnlySink.selector);
        hook.buy(1, 0);
        vm.expectRevert(SwarmlingsHook.OnlySink.selector);
        hook.take(reward, alice, 1);
        vm.expectRevert(SwarmlingsHook.OnlySink.selector);
        hook.addLiquidity(0, 60, 1);
        TreasurySink t = new TreasurySink(hook, dev, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 100, false))));
        _buyExactIn(alice, BIG);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (new ISwarmlingsHook.Slice[](0))));
        uint256 before = _rbal(dev);
        t.poke(); // removed, but still able to move what it earned
        assertEq(_rbal(dev) - before, BIG * 100 / 10000);
    }

    function test_buybackBurnsSupply() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(b), 200, false))));
        _buyExactIn(alice, BIG / 10);
        uint256 budget = _claims(address(b), reward);
        assertEq(budget, BIG / 10 * 200 / 10000);
        uint256 supply = ling.totalSupply();
        (uint160 p0,,,) = manager.getSlot0(launchKey.toId());
        b.poke();
        (uint160 p1,,,) = manager.getSlot0(launchKey.toId());
        assertGt(b.burned(), 0);
        assertEq(supply - ling.totalSupply(), b.burned(), "burned for real");
        assertEq(b.spent(), budget, "a small buyback fits within the 1% price band");
        assertEq(_claims(address(b), reward), 0);
        assertEq(_claims(address(b), Currency.wrap(address(ling))), 0);
        assertEq(ling.balanceOf(address(b)), 0);
        assertEq(_nfts(address(b)), 0, "contracts skip NFTs");
        uint256 moved = p1 > p0 ? uint256(p1) * 1e6 / p0 - 1e6 : 1e6 - uint256(p1) * 1e6 / p0;
        assertLe(moved, 5_100, "sqrt price moved at most ~0.5% (price ~1%)");
        assertEq(hook.totalFees(), hook.distributed() + hook.pendingFees(), "no fee on the hook's own swap");
    }

    function test_buybackLeavesTheRestWhenTheBandIsHit() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(b), 375, false))));
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(alice, 10 * BIG);
        }
        uint256 budget = _claims(address(b), reward);
        b.poke();
        assertLt(b.spent(), budget, "the 1% band stopped it");
        assertEq(_claims(address(b), reward), budget - b.spent(), "the rest waits as claims");
        assertGt(b.burned(), 0);
    }

    function test_autoLiquidityBuildsAPermanentPosition() public {
        AutoLiquidity a = new AutoLiquidity(hook, BIG / 100);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(a), 200, true))));
        _buyExactIn(alice, BIG); // 2% = BIG/50 > threshold: due, and poked inside this very swap
        assertEq(a.batches(), 1);
        // from here on, poke by hand so the position's fees are visible when collected
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(a), 200, false))));
        uint128 liq = _positionLiquidity(address(a), a.tickLower(), a.tickUpper());
        assertGt(liq, 0, "the hook owns a position under the sink's salt");
        assertGt(a.rewardAdded(), 0);
        assertGt(a.lingAdded(), 0);
        uint256 holdersBefore = hook.totalFees();
        for (uint256 i; i < 3; ++i) {
            _give(carol, UNIT * 3);
            _sellExactIn(carol, UNIT * 3);
            _buyExactIn(carol, BIG / 5);
        }
        uint256 lingClaimsBefore = _claims(address(a), Currency.wrap(address(ling)));
        uint256 h = hook.totalFees();
        a.collect();
        assertGt(hook.totalFees(), h, "the position's reward fees go to holders");
        assertGt(
            _claims(address(a), Currency.wrap(address(ling))), lingClaimsBefore, "its LING fees come back"
        );
        holdersBefore;
        assertEq(hook.totalFees(), hook.distributed() + hook.pendingFees(), "ledger");
        assertEq(
            _positionLiquidity(address(a), a.tickLower(), a.tickUpper()), liq, "collecting changes nothing"
        );
    }

    function test_twapAndVolatilityFee() public {
        TwapOracle o = new TwapOracle(hook);
        VolatilityFee v = new VolatilityFee(hook, o, 1 hours, 50, 375);
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](2);
        m[0] = ISwarmlingsHook.Module(address(o), Callbacks.BEFORE_SWAP, false);
        m[1] = ISwarmlingsHook.Module(address(v), Callbacks.QUOTE, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        assertEq(v.extraNow(), 0, "no data yet: fails open");
        // a quiet hour at the opening price
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(alice, 1e9);
            skip(10 minutes);
        }
        int24 before = o.lastTick();
        assertApproxEqAbs(o.consult(1 hours), before, 2);
        // a dump
        _give(bob, 150_000_000e18);
        _sellExactIn(bob, 150_000_000e18);
        skip(12);
        o.record();
        assertLt(o.lastTick(), before, "LING is cheaper now");
        uint256 extra = v.extraNow();
        assertGt(extra, 0);
        assertLe(extra, 375);
        _give(carol, UNIT);
        uint256 h = hook.totalFees();
        uint256 r = _rbal(carol);
        _sellExactIn(carol, UNIT);
        uint256 got = _rbal(carol) - r;
        uint256 fee = hook.totalFees() - h;
        assertEq(fee, (got + fee) * (125 + extra) / 10000, "the sell paid the surcharge, to holders");
        h = hook.totalFees();
        _buyExactIn(alice, BIG / 10);
        assertEq(hook.totalFees() - h, BIG / 10 * 125 / 10000, "buys pay no extra");
    }

    function test_journal() public {
        vm.prank(dev);
        vm.expectEmit(false, false, false, true);
        emit SwarmlingsCouncil.Journal("Day one.");
        council.post("Day one.");
        vm.expectRevert(SwarmlingsCouncil.OnlyOwner.selector);
        council.post("not mine");
    }
}

library ModifyLiquidityParamsLib {
    function remove(int24 lo, int24 hi, uint256 liq) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(lo, hi, -int256(liq), 0);
    }
}

contract NativeHiveTest is HiveSuite {}

contract ImdFirstHiveTest is HiveSuite {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.ImdFirst;
    }
}

contract LingFirstHiveTest is HiveSuite {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.LingFirst;
    }
}

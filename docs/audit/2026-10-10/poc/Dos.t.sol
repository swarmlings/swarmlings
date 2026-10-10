// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";
import {ISwarmlingsHook, Callbacks} from "../../src/interfaces/IHive.sol";
import {TreasurySink} from "../../src/modules/TreasurySink.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {AutoLiquidity} from "../../src/modules/AutoLiquidity.sol";
import {TwapOracle} from "../../src/modules/TwapOracle.sol";
import {VolatilityFee} from "../../src/modules/VolatilityFee.sol";
import {HiveBase} from "../Hive.t.sol";

/// @dev Burns (almost) all the gas it is given on every callback and on quoteFee.
contract Burner {
    function quoteFee(address, PoolKey calldata, SwapParams calldata, bool, bytes calldata)
        external
        view
        returns (uint256)
    {
        uint256 x;
        while (gasleft() > 4000) ++x;
        return x == type(uint256).max ? 1 : 0;
    }

    fallback() external {
        uint256 x;
        while (gasleft() > 4000) ++x;
    }
}

/// @dev A sink that is always due and burns its whole poke allowance.
contract GasSinkBurner {
    constructor(ISwarmlingsHook h) {
        h.poolManager().setOperator(address(h), true);
    }

    function due() external pure returns (bool) {
        return true;
    }

    function poke() external view {
        uint256 x;
        while (gasleft() > 3000) ++x;
    }
}

contract HugeQuoter {
    function quoteFee(address, PoolKey calldata, SwapParams calldata, bool, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return type(uint256).max;
    }

    fallback() external {}
}

/// @dev Has code, accepts every call, returns nothing.
contract SilentModule {
    fallback() external {}
}

/// @dev Quoter that returns 1 byte of return data.
contract ShortReturnQuoter {
    fallback() external {
        assembly {
            mstore(0, 0x01)
            return(31, 1)
        }
    }
}

/// @dev A sink whose due() returns the word 2 (not a valid bool).
contract WeirdSink {
    fallback() external {
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// @dev Returns ~`size` bytes of return data from every call.
contract Bomb {
    uint256 public size;

    constructor(uint256 s) {
        size = s;
    }

    fallback() external {
        uint256 s = size;
        assembly {
            return(0, s)
        }
    }
}

abstract contract DosSuite is HiveBase {
    uint16 constant ALL3 = Callbacks.QUOTE | Callbacks.BEFORE_SWAP | Callbacks.AFTER_SWAP;

    function _swapGas(address who, bool buy, int256 amt, uint256 value, uint256 gasLimit)
        internal
        returns (uint256 used, bool ok)
    {
        bool zeroForOne = buy == rewardFirst;
        vm.prank(who);
        uint256 g = gasleft();
        try swapRouter.swap{value: native ? value : 0, gas: gasLimit}(
            launchKey,
            SwapParams(
                zeroForOne, amt, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            ok = true;
        } catch {}
        used = g - gasleft();
    }

    function _maxModules() internal {
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](8);
        for (uint256 i; i < 8; ++i) {
            m[i] = ISwarmlingsHook.Module(address(new Burner()), ALL3, false);
        }
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
    }

    function _eightSlices(address first, bool pokeFirst) internal {
        ISwarmlingsHook.Slice[] memory s = new ISwarmlingsHook.Slice[](8);
        s[0] = ISwarmlingsHook.Slice(first, 46, pokeFirst);
        for (uint256 i = 1; i < 8; ++i) {
            s[i] = ISwarmlingsHook.Slice(address(new TreasurySink(hook, dev, type(uint256).max)), 46, false);
        }
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (s)));
    }

    // ------------------------------------------------------------------ gas vs EIP-7825

    uint256 snap;

    function test_gas_oracleAndQuoter() public {
        TwapOracle o = new TwapOracle(hook);
        VolatilityFee v = new VolatilityFee(hook, o, 5 minutes, 50, 375);
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](2);
        m[0] = ISwarmlingsHook.Module(address(o), Callbacks.BEFORE_SWAP, false);
        m[1] = ISwarmlingsHook.Module(address(v), Callbacks.QUOTE, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        vm.prank(alice);
        ling.setSkipNFT(true);
        (uint256 base,) = _swapGas(alice, true, -int256(BIG / 100), BIG / 100, 30_000_000);
        console.log("first swap with oracle+quoter (cold ring)", base);
        for (uint256 i; i < 40; ++i) {
            skip(12);
            (uint256 gg,) = _swapGas(alice, true, -int256(BIG / 1000), BIG / 1000, 30_000_000);
            if (i == 39) console.log("steady swap with oracle+quoter           ", gg);
        }
        // direct cost of the pieces
        uint256 g = gasleft();
        o.consult(5 minutes);
        console.log("consult(1h) gas                          ", g - gasleft());
    }

    // ------------------------------------------------------------------ whale burns / moves

    function _whale() internal returns (uint256 units) {
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            ling.setSkipNFT(false);
            (, bool okb) = _swapGas(alice, true, int256(UNIT * 800), 900 ether, 30_000_000);
            console.log("whale buy ok", okb, _nfts(alice));
        }
        _give(alice, UNIT * 600);
        units = _nfts(alice);
    }

    // ------------------------------------------------------------------ _advance after a long quiet period


    // ---- isolated measurements: one swap per test so every access is cold, as in a real transaction

    function _log(string memory what, uint256 g) internal view {
        console.log(what, g);
    }

    function test_iso_buy800_none() public {
        (uint256 g, bool ok) = _swapGas(alice, true, int256(UNIT * 800), 100 * BIG, 30_000_000);
        assertTrue(ok);
        _log("buy 800 NFTs, router, no config:", g);
    }

    function test_iso_buy800_maxConfig() public {
        _maxModules();
        AutoLiquidity a = new AutoLiquidity(hook, 1);
        _eightSlices(address(a), true);
        (uint256 g, bool ok) = _swapGas(alice, true, int256(UNIT * 800), 100 * BIG, 30_000_000);
        assertTrue(ok);
        assertEq(a.batches(), 1);
        _log("buy 800 NFTs, 8 burners(24 calls)+8 slices+AutoLiquidity poke:", g);
        console.log("  headroom to EIP-7825 cap:", 16_777_216 - g);
    }

    function test_iso_buy800_maxConfig_worstPoke() public {
        // as above, but the poked sink burns its entire 1M gas allowance
        _maxModules();
        GasSinkBurner a = new GasSinkBurner(hook);
        _eightSlices(address(a), true);
        (uint256 g, bool ok) = _swapGas(alice, true, int256(UNIT * 800), 100 * BIG, 30_000_000);
        assertTrue(ok);
        _log("buy 800 NFTs, 8 burners + 8 slices + sink burning 1M gas poke:", g);
        console.log("  headroom to EIP-7825 cap:", g > 16_777_216 ? 0 : 16_777_216 - g);
    }

    function test_iso_poke_none() public {
        vm.prank(alice);
        ling.setSkipNFT(true);
        (uint256 g,) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
        _log("exact-in buy, no config (skipNFT buyer):", g);
    }

    function test_iso_poke_treasury() public {
        vm.prank(alice);
        ling.setSkipNFT(true);
        TreasurySink t = new TreasurySink(hook, dev, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 100, true))));
        (uint256 g,) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
        _log("exact-in buy + TreasurySink poke:", g);
    }

    function test_iso_poke_buyback() public {
        vm.prank(alice);
        ling.setSkipNFT(true);
        BuybackBurn b = new BuybackBurn(hook, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(b), 100, true))));
        (uint256 g,) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
        _log("exact-in buy + BuybackBurn poke:", g);
    }

    function test_iso_poke_autoliq_first() public {
        vm.prank(alice);
        ling.setSkipNFT(true);
        AutoLiquidity a = new AutoLiquidity(hook, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(a), 100, true))));
        (uint256 g,) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
        _log("exact-in buy + AutoLiquidity poke (first, ticks init):", g);
        assertEq(a.batches(), 1);
    }

    function test_iso_poke_autoliq_exactOut() public {
        vm.prank(alice);
        ling.setSkipNFT(true);
        AutoLiquidity a = new AutoLiquidity(hook, 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(a), 100, true))));
        _buyExactIn(alice, BIG); // first batch (ticks init)
        vm.cool(address(hook));
        vm.cool(address(a));
        vm.cool(address(manager));
        vm.cool(address(ling));
        (uint256 g,) = _swapGas(alice, true, int256(UNIT * 10), 50 * BIG, 30_000_000);
        _log("exact-out buy + AutoLiquidity poke (later batch, cooled):", g);
    }

    function _whaleRun(uint256 mode) internal {
        if (!native) return;
        // mode 0: none, 1: max modules, 2: direct transfer
        vm.deal(alice, 1e9 ether);
        for (uint256 i; i < 40; ++i) {
            (, bool okb) = _swapGas(alice, true, int256(UNIT * 100), 5e8 ether, 30_000_000);
            if (!okb) break;
        }
        uint256 left = ling.balanceOf(launcher) / UNIT;
        while (left != 0) {
            uint256 c = left > 700 ? 700 : left;
            _give(alice, UNIT * c);
            left -= c;
        }
        uint256 w = _nfts(alice);
        console.log("whale NFTs", w);
        console.log("whale LING units", ling.balanceOf(alice) / UNIT);
        console.log("launcher units", ling.balanceOf(launcher) / UNIT);
        vm.cool(address(ling));
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(mirror));
        if (mode == 1) _maxModules();
        if (mode == 2) {
            address sk = makeAddr("skipper");
            vm.prank(sk);
            ling.setSkipNFT(true);
            vm.prank(alice);
            uint256 g0 = gasleft();
            ling.transfer(sk, UNIT * w);
            console.log("direct transfer burning all NFTs:", g0 - gasleft());
            return;
        }
        (uint256 g, bool ok) = _swapGas(alice, false, -int256(UNIT * w), 0, 30_000_000);
        require(ok);
        console.log(mode == 0 ? "sell all NFTs, no config:" : "sell all NFTs, 8 burner modules:", g);
        console.log("NFTs left", _nfts(alice));
    }

    function test_iso_whaleSell_none() public {
        _whaleRun(0);
    }

    function test_iso_whaleSell_max() public {
        _whaleRun(1);
    }

    function test_iso_whaleTransfer() public {
        _whaleRun(2);
    }

    function test_iso_keep() public {
        if (!native) return;
        vm.deal(alice, 1e9 ether);
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            ling.setSkipNFT(false);
            (, bool okb) = _swapGas(alice, true, int256(UNIT * 800), 5e8 ether, 30_000_000);
            require(okb);
        }
        uint256 w = _nfts(alice);
        uint256[] memory ids = ling.ownedIds(alice, 0, w);
        uint256 k = 300;
        uint256[] memory sub = new uint256[](k);
        for (uint256 i; i < k; ++i) sub[i] = ids[w - 1 - i];
        vm.cool(address(ling));
        vm.prank(alice);
        uint256 g = gasleft();
        ling.keep(sub);
        console.log("keep(300 ids, reverse order) total:", g - gasleft());
        console.log("  per id:", (g - gasleft()) / k);
    }

    function test_iso_bomb_none() public {
        _give(bob, UNIT * 2);
        (uint256 g,) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
        _log("sell 1 NFT, no modules:", g);
    }

    function _oneModuleSell(address m) internal returns (uint256 g) {
        _give(bob, UNIT * 2);
        _govern(
            abi.encodeCall(
                ISwarmlingsHook.setModules, (_module(m, Callbacks.BEFORE_SWAP | Callbacks.AFTER_SWAP, false))
            )
        );
        (g,) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
    }

    function test_iso_bomb_silent() public {
        _log("sell 1 NFT, 1 silent observer (2 calls):", _oneModuleSell(address(new SilentModule())));
    }

    function test_iso_bomb_burner() public {
        _log("sell 1 NFT, 1 gas-burning observer (2 calls):", _oneModuleSell(address(new Burner())));
    }

    function test_iso_bomb_200k() public {
        _log("sell 1 NFT, 1 observer returning 200kB (2 calls):", _oneModuleSell(address(new Bomb(200_000))));
    }

    function test_iso_bomb_burnerAndBomb() public {
        // the largest return data a callee can still afford inside the 200k cap
        _log("sell 1 NFT, 1 observer returning 300kB (2 calls):", _oneModuleSell(address(new Bomb(300_000))));
    }

    function test_iso_bomb_1M() public {
        // 1 MB return data costs the callee more than its cap and fails, so nothing is copied
        _log("sell 1 NFT, 1 observer returning 1MB (2 calls):", _oneModuleSell(address(new Bomb(1_000_000))));
    }

    function _bombSell(uint256 count, uint256 size) internal returns (uint256 g, bool ok) {
        _give(bob, UNIT * 2);
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](count);
        for (uint256 i; i < count; ++i) {
            m[i] = ISwarmlingsHook.Module(address(new Bomb(size)), ALL3, false);
        }
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        (g, ok) = _swapGas(bob, false, -int256(UNIT), 0, 100_000_000);
    }

    function test_iso_bombN_1() public {
        (uint256 g, bool ok) = _bombSell(1, 300_000);
        console.log("sell, 1 bomb module(300kB, 3 callbacks):", g, ok);
    }

    function test_iso_bombN_2() public {
        (uint256 g, bool ok) = _bombSell(2, 300_000);
        console.log("sell, 2 bomb modules:", g, ok);
    }

    function test_iso_bombN_4() public {
        (uint256 g, bool ok) = _bombSell(4, 300_000);
        console.log("sell, 4 bomb modules:", g, ok);
    }

    function test_iso_bombN_8() public {
        (uint256 g, bool ok) = _bombSell(8, 300_000);
        console.log("sell, 8 bomb modules:", g, ok);
        console.log("  cap 16777216, over by", g > 16_777_216 ? g - 16_777_216 : 0);
    }

    function test_iso_bombN_8_small() public {
        (uint256 g, bool ok) = _bombSell(8, 100_000);
        console.log("sell, 8 bomb modules of 100kB:", g, ok);
    }

    function test_iso_bomb_quoter() public {
        _give(bob, UNIT * 2);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(new Bomb(300_000)), Callbacks.QUOTE, false))));
        (uint256 g, bool ok) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
        console.log("sell with a quoter returning 300kB, ok:", ok);
        _log("  gas (no-module baseline 206k):", g);
    }

    function test_iso_bomb_guardBuy() public {
        // a guard on a buy runs uncapped and its returndata (a revert reason) is copied in full
        Bomb b = new Bomb(300_000);
        _govern(
            abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(b), Callbacks.AFTER_SWAP, true)))
        );
        vm.prank(alice);
        ling.setSkipNFT(true);
        (uint256 g, bool ok) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
        console.log("buy with a guard returning 300kB, ok:", ok);
        _log("  gas:", g);
    }

    // ---- _advance after a long quiet period (each in a fresh transaction)

    function _quietYears(uint256 yrs) internal returns (uint256 g) {
        _buyExactIn(alice, BIG);
        _buyExactIn(alice, BIG / 10);
        skip(365 days * yrs);
        vm.cool(address(ling));
        vm.cool(address(hook));
        vm.cool(address(manager));
        (g,) = _swapGas(alice, true, -int256(BIG / 100), BIG / 100, 30_000_000);
    }

    function test_iso_quiet_0() public {
        _log("swap after 1 day (control):", _quietYearsDays(1));
    }

    function _quietYearsDays(uint256 d) internal returns (uint256 g) {
        _buyExactIn(alice, BIG);
        _buyExactIn(alice, BIG / 10);
        skip(1 days * d);
        vm.cool(address(ling));
        vm.cool(address(hook));
        vm.cool(address(manager));
        (g,) = _swapGas(alice, true, -int256(BIG / 100), BIG / 100, 30_000_000);
    }

    function test_iso_quiet_10y() public {
        _log("first swap after 10 quiet years:", _quietYears(10));
    }

    function test_iso_quiet_500y() public {
        _log("first swap after 500 quiet years:", _quietYears(500));
    }

    function test_iso_quiet_claim() public {
        _buyExactIn(alice, BIG);
        _buyExactIn(alice, BIG / 10);
        skip(365 days * 3);
        vm.cool(address(ling));
        vm.prank(alice);
        uint256 g = gasleft();
        ling.claim();
        _log("claim() after 3 quiet years:", g - gasleft());
    }

    // ------------------------------------------------------------------ failure propagation

    function test_sellBrick_hugeQuoter() public {
        HugeQuoter q = new HugeQuoter();
        _give(bob, UNIT);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        (, bool okSell) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
        (, bool okBuy) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
        console.log("sell ok with quoter returning uint max:", okSell);
        console.log("buy  ok with quoter returning uint max:", okBuy);
        assertFalse(okSell);
        assertFalse(okBuy);
    }

    function test_sellBrick_silentQuoter() public {
        SilentModule q = new SilentModule();
        _give(bob, UNIT);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        (, bool okSell) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
        console.log("sell ok with quoter returning no data  :", okSell);
        assertFalse(okSell);
        ShortReturnQuoter s = new ShortReturnQuoter();
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(s), Callbacks.QUOTE, false))));
        (, okSell) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
        console.log("sell ok with quoter returning 1 byte   :", okSell);
        assertFalse(okSell);
    }

    function test_sellBrick_weirdSinkDue() public {
        WeirdSink w = new WeirdSink();
        _give(bob, UNIT);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(w), 100, true))));
        (, bool okSell) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
        (, bool okBuy) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
        console.log("sell ok, sink.due() returns 2:", okSell);
        console.log("buy  ok, sink.due() returns 2:", okBuy);
        assertFalse(okSell);
        assertFalse(okBuy);
        SilentModule sm = new SilentModule();
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(sm), 100, true))));
        (, okSell) = _swapGas(bob, false, -int256(UNIT), 0, 30_000_000);
        console.log("sell ok, sink.due() returns no data:", okSell);
        assertFalse(okSell);
    }

    /// @dev A swap that happens to cross a sink's threshold needs ~1.05M gas left after the swap or reverts.
    function test_pokeGasTrap() public {
        uint256 s = BIG * 100 / 10000; // the sink's share of one BIG exact-in buy
        TreasurySink t = new TreasurySink(hook, dev, 2 * s + 1);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(t), 100, true))));
        _buyExactIn(alice, BIG);
        _buyExactIn(alice, BIG);
        assertFalse(t.due());
        snap = vm.snapshotState();
        (uint256 u1, bool ok1) = _swapGas(alice, true, -int256(BIG), BIG, 500_000);
        console.log("buy crossing threshold, gas limit 500k: ok", ok1);
        console.log("   gas burned", u1);
        vm.revertToState(snap);
        (uint256 u2, bool ok2) = _swapGas(alice, true, -int256(BIG), BIG, 3_000_000);
        console.log("buy crossing threshold, gas limit 3M  : ok", ok2);
        console.log("   gas used", u2);
        vm.revertToState(snap);
        _give(bob, UNIT * 5);
        (uint256 u3, bool ok3) = _swapGas(bob, false, -int256(UNIT * 5), 0, 500_000);
        console.log("SELL crossing threshold, gas limit 500k: ok", ok3);
        console.log("   gas burned", u3);
        assertFalse(ok1);
        assertTrue(ok2);
    }

    function test_observerGasFloor() public {
        // with one observer attached, how low can a sell's gas limit go before InsufficientGas?
        _give(bob, UNIT * 10);
        _govern(
            abi.encodeCall(
                ISwarmlingsHook.setModules, (_module(address(new SilentModule()), Callbacks.BEFORE_SWAP, false))
            )
        );
        snap = vm.snapshotState();
        uint256 lo = 100_000;
        for (uint256 gl = lo; gl < 1_000_000; gl += 10_000) {
            (, bool ok) = _swapGas(bob, false, -int256(UNIT), 0, gl);
            vm.revertToState(snap);
            if (ok) {
                console.log("min gas limit for a sell with 1 observer:", gl);
                break;
            }
        }
    }
}


contract RejectsEth {}

abstract contract DosSuite2 is DosSuite {
    /// @dev A sink whose poke always reverts (recipient cannot receive native ETH) stays due forever, is retried
    /// on every swap and keeps every later sink from being poked inside swaps.
    function test_failingSinkStarvesOthers() public {
        if (!native) return;
        vm.prank(alice);
        ling.setSkipNFT(true);
        TreasurySink bad = new TreasurySink(hook, address(new RejectsEth()), 1);
        TreasurySink good = new TreasurySink(hook, dev, 1);
        ISwarmlingsHook.Slice[] memory sl = new ISwarmlingsHook.Slice[](2);
        sl[0] = ISwarmlingsHook.Slice(address(bad), 100, true);
        sl[1] = ISwarmlingsHook.Slice(address(good), 100, true);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (sl)));
        uint256 devBefore = dev.balance;
        for (uint256 i; i < 5; ++i) {
            (uint256 g,) = _swapGas(alice, true, -int256(BIG), BIG, 30_000_000);
            console.log("swap", i, "gas", g);
        }
        console.log("bad sink claims (never paid)", _claims(address(bad), reward));
        console.log("good sink claims (never poked in a swap)", _claims(address(good), reward));
        console.log("dev received", dev.balance - devBefore);
        assertGt(_claims(address(good), reward), 0);
        assertEq(dev.balance, devBefore);
    }

    /// @dev A sink that stays due while its poke makes little progress starves the later sinks and taxes every swap.
    function test_headOfLineSink() public {
        vm.prank(alice);
        ling.setSkipNFT(true);
        BuybackBurn b = new BuybackBurn(hook, 1);
        TreasurySink t = new TreasurySink(hook, dev, 1);
        ISwarmlingsHook.Slice[] memory sl = new ISwarmlingsHook.Slice[](2);
        sl[0] = ISwarmlingsHook.Slice(address(b), 250, false); // not poked in swaps while the pile builds
        sl[1] = ISwarmlingsHook.Slice(address(t), 100, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (sl)));
        for (uint256 i; i < 6; ++i) {
            _buyExactIn(alice, 10 * BIG);
        }
        sl[0].poke = true;
        sl[1].poke = true;
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (sl)));
        uint256 tBefore = _claims(address(t), reward);
        console.log("buyback pile (claims)", _claims(address(b), reward));
        console.log("treasury pile (claims)", tBefore);
        uint256 lastGas;
        for (uint256 i; i < 4; ++i) {
            (uint256 g,) = _swapGas(alice, true, -int256(BIG / 100), BIG / 100, 30_000_000);
            lastGas = g;
            console.log("swap", i, "gas", g);
            console.log("   buyback still due", b.due(), "treasury unpoked claims", _claims(address(t), reward));
        }
        assertTrue(b.due(), "buyback is still due after 4 pokes");
    }
}

contract NativeDosTest is DosSuite2 {}

contract ImdFirstDosTest is DosSuite2 {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.ImdFirst;
    }
}
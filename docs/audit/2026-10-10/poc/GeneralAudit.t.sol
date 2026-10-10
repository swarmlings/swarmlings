// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TwapOracle} from "../../src/modules/TwapOracle.sol";
import {VolatilityFee} from "../../src/modules/VolatilityFee.sol";
import {TreasurySink} from "../../src/modules/TreasurySink.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {ISwarmlingsHook, Callbacks} from "../../src/interfaces/IHive.sol";
import {SwarmlingsCouncil} from "../../src/SwarmlingsCouncil.sol";
import {SwarmlingsBase} from "../utils/SwarmlingsBase.sol";

/// @dev A quoter that answers with one byte of return data (e.g. a proxy with a broken implementation).
contract ShortReturnQuoter {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

/// @dev A sink whose due() answers with an out-of-range bool.
contract BadDueSink {
    constructor(IPoolManager pm, address hook) {
        pm.setOperator(hook, true);
    }

    function due() external pure returns (bool b) {
        assembly ("memory-safe") {
            mstore(0, 2)
            return(0, 32)
        }
    }

    function poke() external {}
}

/// @dev An observer that answers with a very large return payload (bounded only by its own gas cap).
contract BombModule {
    uint256 public size;

    constructor(uint256 size_) {
        size = size_;
    }

    fallback() external {
        uint256 n = size;
        assembly ("memory-safe") {
            return(0, n)
        }
    }
}

contract QuietModule {
    fallback() external {}
}

/// @dev Rejects ETH, so a TreasurySink paying it in native ETH always fails.
contract NoEth {}

contract GeneralAuditTest is SwarmlingsBase {
    using StateLibrary for IPoolManager;

    SwarmlingsCouncil council;
    address dev;

    function setUp() public override {
        super.setUp();
        dev = ling.DEV();
        deployCodeTo("SwarmlingsCouncil.sol:SwarmlingsCouncil", abi.encode(dev), hook.COUNCIL());
        council = SwarmlingsCouncil(hook.COUNCIL());
    }

    function _govern(bytes memory data) internal {
        vm.prank(dev);
        council.execute(address(hook), data, "audit");
    }

    // G: TwapOracle integrates the *previous* observation's tick over each interval, so the average lags
    function test_twapLagsAfterAPriceMove() public {
        TwapOracle o = new TwapOracle(hook);
        VolatilityFee v = new VolatilityFee(hook, o, 1 hours, 50, 375);
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](2);
        m[0] = ISwarmlingsHook.Module(address(o), Callbacks.BEFORE_SWAP, false);
        m[1] = ISwarmlingsHook.Module(address(v), Callbacks.QUOTE, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        // a quiet 2 hours at the opening price
        for (uint256 i; i < 12; ++i) {
            _buyExactIn(alice, 1e9);
            skip(10 minutes);
        }
        int24 p0 = o.lastTick();
        // one dump; the oracle records the OPENING tick (p0) of this block
        _give(bob, 150_000_000e18);
        _sellExactIn(bob, 150_000_000e18);
        (, int24 spot,,) = manager.getSlot0(launchKey.toId());
        int24 p1 = rewardFirst ? -spot : spot;
        assertLt(p1, p0, "price fell");
        // then nothing trades for 2 hours: the price has been p1 for the entire window
        skip(2 hours);
        int24 mean = o.consult(1 hours);
        emit log_named_int("opening tick p0   ", p0);
        emit log_named_int("true price over window p1", p1);
        emit log_named_int("oracle mean over last hour", mean);
        assertGt(mean, p1 + 100, "oracle still reports the pre-dump price after 2 quiet hours");
        // consequence: VolatilityFee still surcharges sells although the price has been flat for 2 hours
        uint256 extra = v.extraNow();
        emit log_named_uint("sell surcharge bps after 2 flat hours", extra);
        assertGt(extra, 0);
    }

    // G: a quoter / sink that returns malformed data reverts the swap outside any try/catch -> sells blocked
    function test_malformedQuoterBlocksSells() public {
        ShortReturnQuoter q = new ShortReturnQuoter();
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](1);
        m[0] = ISwarmlingsHook.Module(address(q), Callbacks.QUOTE, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        _give(alice, UNIT);
        vm.expectRevert();
        _sellExactIn(alice, UNIT);
        // council can recover by removing the module
        _govern(abi.encodeCall(ISwarmlingsHook.disableModule, (address(q))));
        _sellExactIn(alice, UNIT);
    }

    function test_malformedDueBlocksSells() public {
        BadDueSink s = new BadDueSink(manager, address(hook));
        ISwarmlingsHook.Slice[] memory sl = new ISwarmlingsHook.Slice[](1);
        sl[0] = ISwarmlingsHook.Slice(address(s), 100, true);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (sl)));
        _give(alice, UNIT);
        vm.expectRevert();
        _sellExactIn(alice, UNIT);
    }

    // G: first due slice always consumes the single poke; a due-but-failing sink starves the others
    function test_failingDueSinkStarvesLaterSinks() public {
        NoEth bad = new NoEth();
        TreasurySink t = new TreasurySink(ISwarmlingsHook(address(hook)), address(bad), 1);
        BuybackBurn b = new BuybackBurn(ISwarmlingsHook(address(hook)), 1);
        ISwarmlingsHook.Slice[] memory sl = new ISwarmlingsHook.Slice[](2);
        sl[0] = ISwarmlingsHook.Slice(address(t), 100, true);
        sl[1] = ISwarmlingsHook.Slice(address(b), 100, true);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (sl)));
        for (uint256 i; i < 5; ++i) {
            _buyExactIn(alice, BIG / 10);
        }
        assertEq(t.collected(), 0, "treasury payout fails every time");
        assertTrue(t.due(), "but stays due");
        assertEq(b.spent(), 0, "buyback never poked from swaps");
        assertGt(b.claims(reward), 0, "its fee share just piles up");
    }

    function _swapGas(address mod) internal returns (uint256 g) {
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](1);
        m[0] = ISwarmlingsHook.Module(mod, Callbacks.BEFORE_SWAP, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        _give(alice, 2 * UNIT);
        _sellExactIn(alice, UNIT); // warm
        uint256 g0 = gasleft();
        _sellExactIn(alice, UNIT / 2);
        g = g0 - gasleft();
    }

    function test_returnBombCostsExtraGas() public {
        uint256 quiet = _swapGas(address(new QuietModule()));
        uint256 bomb = _swapGas(address(new BombModule(250_000)));
        emit log_named_uint("sell gas, quiet observer", quiet);
        emit log_named_uint("sell gas, return-bomb observer", bomb);
    }
}

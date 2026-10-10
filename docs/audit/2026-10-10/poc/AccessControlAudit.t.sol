// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";
import {SwarmlingsCouncil} from "../../src/SwarmlingsCouncil.sol";
import {ISwarmlingsHook, Callbacks} from "../../src/interfaces/IHive.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TreasurySink} from "../../src/modules/TreasurySink.sol";
import {BuybackBurn} from "../../src/modules/BuybackBurn.sol";
import {HiveBase, FlexModule, ModifyLiquidityParamsLib} from "../Hive.t.sol";

/// @dev Quoter that behaves on buys and misbehaves on sells. mode 1: absurd extra, mode 2: success with empty
/// return data.
contract EvilQuoter {
    uint8 public mode;

    function setMode(uint8 m) external {
        mode = m;
    }

    function quoteFee(address, PoolKey calldata, SwapParams calldata, bool buy, bytes calldata)
        external
        view
        returns (uint256)
    {
        if (buy || mode == 0) return 0;
        if (mode == 1) return type(uint256).max;
        assembly {
            return(0, 0)
        }
    }
}

/// @dev "Sink" whose `due()` succeeds with empty return data, but only while a sell is being processed.
contract EvilSink {
    ISwarmlingsHook public immutable hook;

    constructor(ISwarmlingsHook h) {
        hook = h;
    }

    function due() external view returns (bool) {
        (bool buy,,) = hook.currentSwap();
        if (buy) return false;
        assembly {
            return(0, 0)
        }
    }

    function poke() external {}
}

/// @dev Observer that answers every callback with ~280 kB of return data (fits its 200k gas stipend).
contract BombModule {
    fallback() external {
        assembly {
            return(0, 280000)
        }
    }
}

contract NoEth {
    receive() external payable {
        revert();
    }
}

contract Plain {
    fallback() external {}
}

abstract contract AccessControlAudit is HiveBase {
    // --------------------------------------------------------------- C-1: sells can be blocked by the council

    function test_poc_quoterOverflowBlocksEverySell() public {
        EvilQuoter q = new EvilQuoter();
        q.setMode(1);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        _give(alice, UNIT * 5);
        _buyExactIn(bob, BIG / 10); // buys still work
        vm.expectRevert(); // Panic(0x11): `bps += extra` overflows, outside any try/catch
        _sellExactIn(alice, UNIT);
        vm.expectRevert();
        _sellExactOut(alice, BIG / 1000);
        // reversible only while the council still exists
        _govern(abi.encodeCall(ISwarmlingsHook.disableModule, (address(q))));
        _sellExactIn(alice, UNIT);
    }

    function test_poc_quoterMalformedReturnBlocksSells() public {
        EvilQuoter q = new EvilQuoter();
        q.setMode(2);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        _give(alice, UNIT * 5);
        _buyExactIn(bob, BIG / 10);
        vm.expectRevert(); // ABI-decoding of the quoter's reply fails in the hook: try/catch does not catch it
        _sellExactIn(alice, UNIT);
        // and once frozen it is forever
        _govern(abi.encodeCall(ISwarmlingsHook.setCouncil, (address(0))));
        vm.expectRevert();
        _sellExactIn(alice, UNIT);
    }

    function test_poc_sinkDueMalformedBlocksSells() public {
        EvilSink s = new EvilSink(hook);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(s), 100, true))));
        _give(alice, UNIT * 5);
        _buyExactIn(bob, BIG / 10);
        vm.expectRevert();
        _sellExactIn(alice, UNIT);
    }

    // --------------------------------------------------------------- C-2: gas inflation beyond MODULE_GAS

    function _bombs(uint256 n, uint16 bits) internal {
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = ISwarmlingsHook.Module(address(new BombModule()), bits, false);
        }
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
    }

    function test_poc_returndataBombInflatesSwapGas() public {
        _give(alice, UNIT * 50);
        _buyExactIn(bob, BIG / 10);
        _sellExactIn(alice, UNIT); // warm things up
        uint256 g0 = gasleft();
        _sellExactIn(alice, UNIT);
        uint256 base = g0 - gasleft();

        // 6 / 7 / 8 observers on beforeSwap + afterSwap, each answering with 280 kB (its own cost fits MODULE_GAS)
        for (uint256 n = 6; n <= 8; ++n) {
            _bombs(n, Callbacks.BEFORE_SWAP | Callbacks.AFTER_SWAP);
            g0 = gasleft();
            _sellExactIn(alice, UNIT);
            emit log_named_uint(string.concat("sell gas with ", vm.toString(n), " bomb observers"), g0 - gasleft());
        }
        emit log_named_uint("sell gas, no modules", base);
        g0 = gasleft();
        _sellExactIn(alice, UNIT);
        assertGt(g0 - gasleft(), 16_777_216, "above the EIP-7825 per-transaction gas cap");

        // the same sell with a transaction-sized gas limit is impossible
        vm.startPrank(alice);
        SwapParams memory p = SwapParams(
            !rewardFirst, -int256(UNIT), rewardFirst ? 4295128740 : 1461446703485210103287273052203988822378723970341
        );
        vm.expectRevert();
        swapRouter.swap{gas: 16_777_216}(
            launchKey, p, PoolSwapTest.TestSettings(false, false), ""
        );
        vm.stopPrank();
    }

    function test_poc_returndataBombBlocksLiquidityRemoval() public {
        _bombs(8, Callbacks.BEFORE_REMOVE_LIQUIDITY | Callbacks.AFTER_REMOVE_LIQUIDITY);
        vm.prank(launcher);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{gas: 16_777_216}(
            launchKey,
            ModifyLiquidityParamsLib.remove(TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e6),
            ""
        );
        // with unlimited gas it would go through: the revert above is purely the gas cost
        vm.prank(launcher);
        uint256 g0 = gasleft();
        modifyLiquidityRouter.modifyLiquidity(
            launchKey,
            ModifyLiquidityParamsLib.remove(TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e6),
            ""
        );
        emit log_named_uint("removal gas with 8 bomb observers", g0 - gasleft());
        assertGt(g0 - gasleft(), 16_777_216);
    }

    // --------------------------------------------------------------- what the owner can and cannot do

    function test_poc_councilAsSinkTakesOnlyItsSlice() public {
        // owner routes the maximum 3.75% to the council itself and withdraws it
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(council), 375, false))));
        vm.prank(dev);
        council.execute(
            address(manager), abi.encodeWithSignature("setOperator(address,bool)", address(hook), true), "op"
        );
        _buyExactIn(alice, BIG);
        uint256 mine = _claims(address(council), reward);
        assertEq(mine, BIG * 375 / 10000, "3.75% of volume");
        assertEq(hook.totalFees(), BIG * 125 / 10000, "holders keep exactly the floor");
        uint256 pendingBefore = hook.pendingFees();
        // cannot take a wei more than its own claims, so holders' pending claims are out of reach
        vm.prank(dev);
        vm.expectRevert();
        council.execute(address(hook), abi.encodeCall(ISwarmlingsHook.take, (reward, dev, mine + 1)), "greedy");
        uint256 before = _rbal(dev);
        vm.prank(dev);
        council.execute(address(hook), abi.encodeCall(ISwarmlingsHook.take, (reward, dev, mine)), "own slice");
        assertEq(_rbal(dev) - before, mine);
        assertEq(hook.pendingFees(), pendingBefore, "pending holder claims untouched");
        // stop routing: nothing more accrues, and past volume was never at risk
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (new ISwarmlingsHook.Slice[](0))));
        _buyExactIn(alice, BIG);
        assertEq(_claims(address(council), reward), 0);
    }

    function test_poc_sellerQuoterCannotPayTheOwner() public {
        FlexModule q = new FlexModule();
        q.setExtra(10_000);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (_module(address(q), Callbacks.QUOTE, false))));
        _give(alice, UNIT * 5);
        uint256 h = hook.totalFees();
        uint256 r = _rbal(alice);
        _sellExactIn(alice, UNIT);
        uint256 got = _rbal(alice) - r;
        uint256 fee = hook.totalFees() - h;
        assertEq(fee, (got + fee) * 500 / 10000, "5% surcharge goes wholly to holders");
        assertEq(hook.sinkFees(), 0);
    }

    function test_poc_sinkEqualHookBreaksLedger() public {
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (_slice(address(hook), 100, false))));
        _buyExactIn(alice, BIG);
        assertGt(hook.pendingFees(), hook.totalFees() - hook.distributed(), "sink share is mixed into holders' pending");
    }

    function test_poc_singleStepOwnershipFootguns() public {
        // no-code target: call "succeeds" and logs Executed
        vm.recordLogs();
        vm.prank(dev);
        council.execute(address(0xdead), abi.encodeCall(ISwarmlingsHook.setCouncil, (alice)), "typo target");
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(hook.council(), address(council), "nothing happened");
        // setOwner(0) / typo: no way back
        vm.prank(dev);
        council.setOwner(address(0));
        vm.prank(dev);
        vm.expectRevert(SwarmlingsCouncil.OnlyOwner.selector);
        council.post("locked");
        // hook.setCouncil(wrong address) is equally final
    }

    function test_poc_failingDueSinkStarvesLaterPokes() public {
        if (!native) return; // needs a recipient that rejects the reward currency (native ETH)
        TreasurySink t = new TreasurySink(hook, address(new NoEth()), 1); // poke always reverts, due() always true
        BuybackBurn b = new BuybackBurn(hook, 1);
        ISwarmlingsHook.Slice[] memory s = new ISwarmlingsHook.Slice[](2);
        s[0] = ISwarmlingsHook.Slice(address(t), 100, true);
        s[1] = ISwarmlingsHook.Slice(address(b), 100, true);
        _govern(abi.encodeCall(ISwarmlingsHook.setSlices, (s)));
        for (uint256 i; i < 3; ++i) {
            _buyExactIn(alice, BIG / 10);
        }
        assertEq(b.burned(), 0, "buyback never poked automatically");
        assertGt(_claims(address(b), reward), 0);
        assertTrue(t.due());
    }

    function test_poc_disableModuleReorders() public {
        ISwarmlingsHook.Module[] memory m = new ISwarmlingsHook.Module[](3);
        address a = address(new Plain());
        address b = address(new Plain());
        address c = address(new Plain());
        m[0] = ISwarmlingsHook.Module(a, Callbacks.AFTER_SWAP, false);
        m[1] = ISwarmlingsHook.Module(b, Callbacks.AFTER_SWAP, false);
        m[2] = ISwarmlingsHook.Module(c, Callbacks.AFTER_SWAP, false);
        _govern(abi.encodeCall(ISwarmlingsHook.setModules, (m)));
        _govern(abi.encodeCall(ISwarmlingsHook.disableModule, (a)));
        ISwarmlingsHook.Module[] memory now_ = hook.modules();
        assertEq(now_.length, 2);
        assertEq(now_[0].addr, c, "last module moved into the hole");
        assertEq(now_[1].addr, b);
    }
}

contract NativeAccessAudit is AccessControlAudit {}

contract ImdFirstAccessAudit is AccessControlAudit {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.ImdFirst;
    }
}

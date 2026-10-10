// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwarmlingsBase} from "../utils/SwarmlingsBase.sol";

/// @dev Native pairing: JIT liquidity added and removed in the same block around one victim swap.
contract FlashJitTest is SwarmlingsBase {
    using StateLibrary for IPoolManager;

    address jit = makeAddr("jit");
    uint160 sp0;
    uint160 sp1;
    int256 ethDelta;
    int256 lingDelta;
    uint256 penalty;
    uint256 victimFee;

    function _jitRange() internal view returns (int24 lo, int24 hi) {
        (, int24 t,,) = manager.getSlot0(launchKey.toId());
        int24 base = (t / SPACING) * SPACING;
        lo = base - 6 * SPACING;
        hi = base + 7 * SPACING;
    }

    function _run(bool victimSells) internal {
        _give(jit, 100_000_000e18);
        vm.deal(jit, 200 ether);
        vm.startPrank(jit);
        ling.setSkipNFT(true);
        ling.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
        (int24 lo, int24 hi) = _jitRange();
        uint256 e0 = jit.balance;
        uint256 l0 = ling.balanceOf(jit);
        int256 add = int256(uint256(manager.getLiquidity(launchKey.toId()))) * 5; // 5x the active liquidity
        vm.prank(jit);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(launchKey, ModifyLiquidityParams(lo, hi, add, 0), "");
        uint256 fees0 = hook.totalFees();
        (sp0,,,) = manager.getSlot0(launchKey.toId());
        if (victimSells) {
            _give(bob, UNIT * 200);
            _sellExactIn(bob, UNIT * 200);
        } else {
            _buyExactIn(bob, 0.1 ether);
        }
        (sp1,,,) = manager.getSlot0(launchKey.toId());
        uint256 feesMid = hook.totalFees();
        victimFee = feesMid - fees0;
        vm.prank(jit);
        modifyLiquidityRouter.modifyLiquidity(launchKey, ModifyLiquidityParams(lo, hi, -add, 0), "");
        penalty = hook.totalFees() - feesMid;
        ethDelta = int256(jit.balance) - int256(e0);
        lingDelta = int256(ling.balanceOf(jit)) - int256(l0);
        _log(victimSells);
    }

    function _lingPerEth(uint160 sp) internal pure returns (int256) {
        return int256(uint256(sp) * uint256(sp) / (1 << 192));
    }

    function _log(bool victimSells) internal view {
        console.log(victimSells ? "== victim SELLS LING (LP fee in LING)" : "== victim BUYS LING (LP fee in ETH)");
        console.log("hook fee on the victim swap (wei):", victimFee);
        console.log("JIT penalty minted to holders (wei):", penalty);
        console.log("JIT net ETH / net LING (wei):");
        console.logInt(ethDelta);
        console.logInt(lingDelta);
        console.log("net value at PRE-trade price (hedge at old price) / at POST-trade price, wei:");
        console.logInt(ethDelta + lingDelta / _lingPerEth(sp0));
        console.logInt(ethDelta + lingDelta / _lingPerEth(sp1));
    }

    function test_g_jitAroundSell_lingFeeUntouched() public {
        _run(true);
        assertEq(penalty, 0, "no penalty: the LP fee of a sell is in LING and only reward fees are penalized");
        assertGt(lingDelta, 0);
    }

    function test_g_jitAroundBuy_rewardFeePenalised() public {
        _run(false);
        assertGt(penalty, 0);
    }
}

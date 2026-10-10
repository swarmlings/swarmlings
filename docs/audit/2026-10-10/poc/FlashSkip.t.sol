// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {SwarmlingsBase} from "../utils/SwarmlingsBase.sol";
import {SyncBuyer} from "../SwarmlingsHook.t.sol";

/// @dev (i) syncing IMD before a swap skips the in-swap hand-over for THAT swap only.
contract FlashSkipImdTest is SwarmlingsBase {
    function pairing() internal pure override returns (Pairing) {
        return Pairing.ImdFirst;
    }

    function test_i_skipIsPerTransactionOnly() public {
        _buyExactOut(alice, UNIT * 10);
        _buyExactIn(carol, 5 * BIG);
        uint256 pending = hook.pendingFees();
        assertGe(pending, hook.minDistribute());
        // the attacker "syncs" in front of every swap: its own swap skips the hand-over ...
        SyncBuyer buyer = new SyncBuyer(manager, ling, launchKey, rewardFirst);
        _dealReward(address(buyer), 1000 * BIG);
        buyer.buy(5 * UNIT);
        assertEq(hook.distributed(), 0, "attacker's own swap: hand-over skipped");
        // ... but the next ordinary swap (any other trader) hands over everything pending
        _buyExactIn(bob, BIG / 10);
        assertGt(hook.distributed(), 0, "next normal swap: handed over");
        console.log("skip lasted one transaction; distributed after next swap:", hook.distributed());
        // and distribute() is permissionless and cannot be blocked from outside the attacker's own tx
        _buyExactIn(carol, 5 * BIG);
        hook.distribute();
    }
}

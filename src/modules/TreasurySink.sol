// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HiveSink} from "./HiveSink.sol";
import {ISwarmlingsHook} from "../interfaces/IHive.sol";

/// @title TreasurySink
/// @notice Project funding: forwards its fee share, in the reward currency, to one fixed recipient. Anyone may
/// trigger the transfer; nobody can change where it goes.
contract TreasurySink is HiveSink {
    address public immutable recipient;
    /// @notice Smallest amount worth a transfer.
    uint256 public immutable minCollect;
    uint256 public collected;

    event Collected(uint256 amount);

    constructor(ISwarmlingsHook hook_, address recipient_, uint256 minCollect_) HiveSink(hook_) {
        recipient = recipient_;
        minCollect = minCollect_;
    }

    function due() external view returns (bool) {
        return claims(reward) >= minCollect;
    }

    function poke() external {
        uint256 amount = claims(reward);
        if (amount < minCollect) return;
        collected += amount;
        hook.take(reward, recipient, amount);
        emit Collected(amount);
    }
}

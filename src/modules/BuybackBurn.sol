// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HiveSink} from "./HiveSink.sol";
import {ISwarmlingsHook, ISwarmlingsToken} from "../interfaces/IHive.sol";

/// @title BuybackBurn
/// @notice Spends its fee share buying LING in the launch pool and burns it. Each buyback moves the price at
/// most about 1%; what the market does not absorb waits for the next one. Anyone may trigger it.
contract BuybackBurn is HiveSink {
    /// @notice Smallest budget worth a buyback.
    uint256 public immutable minBudget;
    uint256 public spent;
    uint256 public burned;

    event Burned(uint256 spent, uint256 burned);

    constructor(ISwarmlingsHook hook_, uint256 minBudget_) HiveSink(hook_) {
        minBudget = minBudget_;
    }

    function due() external view returns (bool) {
        return claims(reward) >= minBudget;
    }

    function poke() external {
        uint256 budget = claims(reward);
        if (budget < minBudget) return;
        if (budget > uint256(uint128(type(int128).max))) budget = uint256(uint128(type(int128).max));
        (uint256 s, uint256 got) = hook.buy(budget, _buyLimit());
        uint256 have = claims(lingCurrency);
        if (have != 0) {
            hook.take(lingCurrency, address(this), have);
            ISwarmlingsToken(ling).burn(have);
        }
        spent += s;
        burned += have;
        emit Burned(s, have);
        got; // the LING bought now; `have` also includes LING left from an earlier, partly burned round
    }
}

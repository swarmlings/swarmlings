// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {SwarmlingsBase} from "./utils/SwarmlingsBase.sol";

/// @dev Worst-case gas of the NFT-heavy paths against Fusaka's 16,777,216 per-transaction cap (EIP-7825).
contract GasCapTest is SwarmlingsBase {
    function test_gasWorstCases() public {
        uint256 n = ling.MAX_MINT_PER_TRANSFER();
        // 1. exact-out buy minting n NFTs through the router
        uint256 g = gasleft();
        _buyExactOut(alice, UNIT * n);
        uint256 buyGas = g - gasleft();
        assertEq(_nfts(alice), n);
        // 2. plain transfer of n units from an NFT holder to a fresh wallet (direct NFT moves)
        vm.prank(alice);
        g = gasleft();
        ling.transfer(bob, UNIT * n);
        uint256 moveGas = g - gasleft();
        assertEq(_nfts(bob), n);
        // 3. sell burning n NFTs
        g = gasleft();
        _sellExactIn(bob, UNIT * n);
        uint256 sellGas = g - gasleft();
        assertEq(_nfts(bob), 0);
        // 4. transfer from a skip wallet (launcher) minting n NFTs to a fresh wallet
        g = gasleft();
        _give(carol, UNIT * n);
        uint256 mintGas = g - gasleft();
        console.log("n", n);
        console.log("buy exact-out minting n   ", buyGas);
        console.log("transfer moving n NFTs    ", moveGas);
        console.log("sell burning n NFTs       ", sellGas);
        console.log("plain transfer minting n  ", mintGas);
        console.log("EIP-7825 cap              ", uint256(16_777_216));
    }
}

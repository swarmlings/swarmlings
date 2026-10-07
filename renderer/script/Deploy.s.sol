// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwarmlingsRenderer} from "../src/SwarmlingsRenderer.sol";

/// Deploys the renderer through the deterministic deployment proxy, so it lands at the same address on every
/// chain: 0x8d79e6677FA6E52190B39096f8496628811D8281 for the committed bytecode.
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $KEY --broadcast --gas-limit 40000000
/// Check eth_estimateGas on the target chain first: some chains price contract creation far above forge's
/// local simulation.
contract Deploy is Script {
    address constant PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SALT = keccak256("swarmlings.renderer.v1");
    address constant EXPECTED = 0x8d79e6677FA6E52190B39096f8496628811D8281;

    function run() external returns (SwarmlingsRenderer r) {
        bytes memory init = type(SwarmlingsRenderer).creationCode;
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), PROXY, SALT, keccak256(init))))));
        require(predicted == EXPECTED, "bytecode differs from the committed renderer");
        if (predicted.code.length == 0) {
            vm.startBroadcast();
            (bool ok,) = PROXY.call(abi.encodePacked(SALT, init));
            vm.stopBroadcast();
            require(ok && predicted.code.length != 0, "deploy failed");
        }
        r = SwarmlingsRenderer(predicted);
        require(r.SUPPLY() == 3333, "supply");
        require(bytes(r.tokenURI(1)).length > 0, "tokenURI");
        console2.log("SwarmlingsRenderer", predicted);
    }
}

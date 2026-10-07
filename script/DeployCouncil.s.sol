// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwarmlingsCouncil} from "../src/SwarmlingsCouncil.sol";
import {SwarmlingsHook} from "../src/SwarmlingsHook.sol";

/// @notice Deploys the Council through the deterministic deployment proxy, so it lands on `SwarmlingsHook.COUNCIL`
/// on every chain. Run once per chain, before or after the launch:
/// forge script script/DeployCouncil.s.sol --rpc-url $RPC_URL --private-key $TREASURY_PRIVATE_KEY --broadcast
contract DeployCouncil is Script {
    address constant PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant OWNER = 0x92cEf4823119f3332A85A39023eEbA01a06890c4;
    bytes32 constant SALT = keccak256("swarmlings.council.v1");

    function run() external {
        bytes memory initCode = abi.encodePacked(type(SwarmlingsCouncil).creationCode, abi.encode(OWNER));
        address expected = vm.computeCreate2Address(SALT, keccak256(initCode), PROXY);
        require(
            expected == 0xf49c77302dA1D9370d0F5Cb192c228748261621a, "constant: update SwarmlingsHook.COUNCIL"
        );
        require(expected.code.length == 0, "already deployed");
        vm.startBroadcast();
        (bool ok,) = PROXY.call(abi.encodePacked(SALT, initCode));
        vm.stopBroadcast();
        require(ok && expected.code.length != 0, "deploy");
        require(SwarmlingsCouncil(expected).owner() == OWNER, "owner");
        console2.log("SwarmlingsCouncil", expected);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {SwarmlingsBase} from "../utils/SwarmlingsBase.sol";
import {SwarmlingsMirror} from "../../src/SwarmlingsMirror.sol";
import {RENDERER_CODE} from "./RendererCode.sol";

contract RendererGasTest is SwarmlingsBase {
    function test_viewsGas() public {
        vm.etch(ling.RENDERER(), RENDERER_CODE);
        _give(alice, UNIT * 3);
        uint256 g = gasleft();
        string memory u = SwarmlingsMirror(payable(address(mirror))).contractURI();
        console.log("contractURI gas", g - gasleft(), bytes(u).length);
        g = gasleft();
        string memory t = mirror.tokenURI(1);
        console.log("tokenURI(1) gas", g - gasleft(), bytes(t).length);
        vm.etch(ling.RENDERER(), RENDERER_CODE);
        // a few other ids
        uint256 worst;
        for (uint256 id = 1; id <= 3; ++id) {
            g = gasleft();
            mirror.tokenURI(id);
            uint256 used = g - gasleft();
            if (used > worst) worst = used;
        }
        console.log("worst of ids 1..3", worst);
    }
}

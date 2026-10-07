// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SwarmlingsRenderer} from "../src/SwarmlingsRenderer.sol";

contract RendererTest is Test {
    SwarmlingsRenderer r;
    bytes expected;
    mapping(bytes32 => bool) seen;

    function setUp() public {
        r = new SwarmlingsRenderer();
        expected = vm.readFileBinary("test/data/expected-riso2.bin");
    }

    function _expected(uint256 id) internal view returns (bytes32 h) {
        bytes memory e = expected;
        assembly { h := mload(add(add(e, 32), mul(sub(id, 1), 32))) }
    }

    function _parity(uint256 from, uint256 to) internal {
        for (uint256 id = from; id <= to; ++id) {
            string memory s = r.svg(id);
            if (keccak256(bytes(s)) != _expected(id)) {
                vm.writeFile(string.concat("test/out/sol-", LibString.toString(id), ".svg"), s);
                revert(string.concat("svg mismatch at id ", LibString.toString(id), ", written to test/out"));
            }
        }
    }

    // the onchain art equals art/riso2.mjs byte for byte for every id, split so failures point at a range
    function test_parity_0001_0834() public { _parity(1, 834); }
    function test_parity_0835_1667() public { _parity(835, 1667); }
    function test_parity_1668_2500() public { _parity(1668, 2500); }
    function test_parity_2501_3333() public { _parity(2501, 3333); }

    function test_samplesMatchReference() public view {
        assertEq(r.svg(1), vm.readFile("test/data/riso2-1.svg"));
        assertEq(r.svg(32), vm.readFile("test/data/riso2-32.svg"));
        assertEq(r.svg(1697), vm.readFile("test/data/riso2-1697.svg"));
    }

    function test_logoMatchesReference() public view {
        assertEq(r.logoSVG(), vm.readFile("test/data/logo.svg"));
    }

    // distinct traits mean distinct art: every trait value prints differently
    function test_everyIdIsDistinct() public {
        for (uint256 start = 1; start <= 3333; start += 333) {
            uint256 count = start + 333 > 3334 ? 3334 - start : 333;
            bytes memory t = r.traitsRange(start, count);
            for (uint256 n; n < count; ++n) {
                bytes32 key;
                assembly { key := mload(add(add(t, 32), mul(n, 7))) }
                key &= bytes32(uint256(type(uint56).max) << 200);
                assertFalse(seen[key], string.concat("duplicate traits at id ", LibString.toString(start + n)));
                seen[key] = true;
            }
        }
    }

    function test_unknownIdsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmlingsRenderer.UnknownId.selector, 0));
        r.tokenURI(0);
        vm.expectRevert(abi.encodeWithSelector(SwarmlingsRenderer.UnknownId.selector, 3334));
        r.tokenURI(3334);
        vm.expectRevert(abi.encodeWithSelector(SwarmlingsRenderer.UnknownId.selector, 0));
        r.svg(0);
    }

    function test_tokenURIShapeAndGas() public view {
        uint256[6] memory ids = [uint256(1), 7, 32, 64, 1697, 3333];
        uint256 worst;
        for (uint256 i; i < ids.length; ++i) {
            uint256 g = gasleft();
            string memory uri = r.tokenURI(ids[i]);
            uint256 used = g - gasleft();
            if (used > worst) worst = used;
            assertTrue(LibString.startsWith(uri, "data:application/json;base64,"));
        }
        assertLt(worst, 15_000_000, "tokenURI must stay well under RPC eth_call gas caps");
        console.log("worst tokenURI gas", worst);
    }
}

# Swarmlings renderer

The art for the 3,333 Swarmlings: hand-drawn robot portraits from 7 traits, printed as risograph halftone
screens in eight inks. One immutable contract with no owner and no storage; every SVG is derived from the id.

- `tokenURI(id)`: `data:application/json;base64` with the SVG and seven attributes. `svg(id)`: the raw SVG.
  `logoSVG()`: the Swarmlings mark. `seedOf`, `traitsOf`, `traitsRange(start, count)`: traits for sites.
- Traits: `seed = uint256(keccak256(abi.encode(uint256 id, bytes32 SALT, uint8 nonce)))`, nonce 1 for the 21 ids
  in `OVERRIDES`, else 0; trait k = `((seed >> 16k) & 0xffff) % 100` against cumulative weights.
  SALT = `0x011ecad7d0b8a52e4b5e3edd97a38fa83743a5db7ab4446105af4dd40086eacd`. All 3,333 trait sets differ.
- `test/data/expected-riso2.bin` holds keccak256 of the reference SVG of every id; `forge test` checks all 3,333
  byte for byte, the logo, distinctness, unknown ids and tokenURI gas (about 2.5M).
- Deployed with `script/Deploy.s.sol` through the deterministic deployment proxy to
  `0x8d79e6677FA6E52190B39096f8496628811D8281` on every chain. The legacy pipeline (`via_ir = false`) keeps the
  runtime at about 21.5 KB.

Solady's LibString, Base64, DynamicBufferLib and LibBytes (v0.1.26, MIT) are vendored under `lib/solady`.

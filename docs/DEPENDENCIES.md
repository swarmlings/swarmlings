# Vendored dependencies

Every build and test dependency is an ordinary file under `lib/` (and `renderer/lib/`): no submodules, no
downloads, no install step. Vendored source is unmodified; only the parts this project uses are kept.

| Dependency | Version / commit | Kept | License |
| --- | --- | --- | --- |
| Uniswap v4-core | 1.0.2, `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/`, `test/utils/`, `package.json`, `licenses/` | BUSL-1.1 core / MIT (see `lib/v4-core/licenses`) |
| Solmate (bundled with v4-core) | `4b47a19038b798b4a33d9749d25e570443520647` | `src/`, `LICENSE` | AGPL-3.0 (tests only: MockERC20) |
| DN404 (Vectorized) | v0.0.25, `3397cb11558ac853912ee87871422b6a29c9d346` | `src/`, `LICENSE.txt`, `package.json` | MIT |
| forge-std | v1.17.0, `f3dae6e6ee381f25eb6a246f7da9b85c91a68219` | `src/`, licenses, `package.json` | MIT / Apache-2.0 |
| Solady (renderer only) | 0.1.26 | `LibString`, `Base64`, `DynamicBufferLib`, `LibBytes` | MIT |

The deployed contracts use v4-core interfaces and libraries, DN404 and (renderer) Solady. Solmate and
forge-std are test-only. This project's own Solidity is MIT-licensed.

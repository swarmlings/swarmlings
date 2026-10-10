# Swarmlings audit, evm-audit-dos (commit e706550)

Scope: src/SwarmlingsHook.sol, src/Swarmlings.sol, src/SwarmlingsMirror.sol, src/SwarmlingsCouncil.sol, src/modules/*.sol, DN404 loops. Checklist: evm-audit-dos, 17 items. EIP-7825 cap 16,777,216 gas. PoCs: swarmlings/test/audit/Dos.t.sol (both pairings), RendererGas.t.sol, RendererCode.sol. No finding lets a third party take funds or freeze the pool; both Mediums need the council or a module it attached.

## [D-1] A quoter or sink returning malformed data reverts every swap, sells included
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `_quote()` (:486-493), `_pokeSinks()` (:541-543)
**Description**: `try/catch` only catches reverts inside the callee. (1) `bps += extra` is checked arithmetic; a quoter returning `type(uint256).max` panics in the success branch; the clamp comes after. (2) A quoter returning fewer than 32 bytes makes the hook's ABI decode revert outside the catch. (3) `due()` returning anything other than 0/1 or no data reverts the bool decode; `_pokeSinks` runs on every launch-pool swap. One `council.execute` reaches all of this; recovery needs another council tx; permanent if the council was frozen with a bad entry attached.
**Proof of Concept**: `test_sellBrick_hugeQuoter`, `test_sellBrick_silentQuoter`, `test_sellBrick_weirdSinkDue`.
**Recommendation**: Assembly `staticcall` with a 32-byte output buffer; accept only `success && returndatasize() >= 32`; clamp `extra` to MAX_FEE_BPS before adding; treat malformed `due()` as not due.

## [D-2] The module gas cap does not bound the cost: return data is copied without limit and memory grows quadratically
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `_runModules()` (:517-524), `_quote()` (:486)
**Description**: `MODULE_GAS` caps what the callee executes, not what the hook pays afterwards. A module can return ~300 kB inside 200k gas and the hook copies all of it; the free memory pointer is never rewound, so cost grows quadratically. Sell with 1/2/4/8 bomb modules (3 callbacks each): 1.81M / 5.13M / 16.94M / 61.16M gas. Liquidity removal goes through the same loop (23.0M with 8 observers). No revert and no event; the trade simply exceeds the tx cap.
**Proof of Concept**: `test_iso_bomb*`, `test_poc_returndataBombBlocksLiquidityRemoval` (access-control file).
**Recommendation**: Observers: `call(MODULE_GAS, m, 0, in, len, 0, 0)` with no output buffer. Quoters: `staticcall(..., 0x00, 0x20)`. Guards: bound the revert-reason copy (e.g. 256 bytes) and consider a gas cap.

## [D-3] A due sink makes a swap with less than about 1.05M gas left revert instead of skipping the poke
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `_pokeSinks()` (:545), `_requireGas()` (:530-532)
**Description**: When a poke-enabled sink is due, the swap needs 1,045,873 gas left at the end of afterSwap or reverts `InsufficientGas`. A normal wallet gas limit reverts exactly when that swap crosses a sink's threshold; an attacker can arrange the crossing. Sells are hit too. The observer floor is ~233k per capped call (a sell with one observer needs a 290-300k limit for a 206k sell).
**Proof of Concept**: `test_pokeGasTrap`, `test_observerGasFloor` (500k limit reverts; 3M passes).
**Recommendation**: Replace the revert in `_pokeSinks` with `return`. Document the observer floor or skip the module when short.

## [D-4] A sink that stays due, or whose poke keeps failing, is retried every swap and starves all later sinks
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `_pokeSinks()` (:535-552); `BuybackBurn.poke`, `TreasurySink.poke`
**Description**: Only the first due slice is poked. `due()` is a balance test and does not know whether `poke()` can make progress: a band-limited BuybackBurn stays due; a TreasurySink whose recipient cannot receive ETH reverts inside `take` (caught, `SinkFailed`) and stays due. Every later sink is never poked from a swap.
**Proof of Concept**: `test_headOfLineSink`, `test_failingSinkStarvesOthers`.
**Recommendation**: Round-robin cursor, or continue to the next due sink after a failure; stricter `due()`; document that a TreasurySink recipient must accept the reward currency.

## [D-5] The burn path has no per-transaction guard; only the mint side is capped
**Severity**: Info
**Category**: evm-audit-dos
**Location**: `Swarmlings._transfer()` and `_burn()`; DN404 burn loop
**Description**: A wallet holding 3,283 NFTs sells everything for 12,995,844 gas with no modules, 17,738,800 with 24 module calls each burning their allowance (0.96M over the cap). With the shipped modules any holding fits. `keep(ids)` costs 4,361 gas per id, paid by the caller.
**Recommendation**: Document that sells of more than ~3,000 NFTs under a maximal module set may need to be split.

## [D-6] `claim()` pays ETH and the reward token in one transaction, so a holder that cannot receive ETH cannot claim IMD
**Severity**: Info
**Category**: evm-audit-dos
**Location**: `Swarmlings.claim()`, `_payEth()`
**Description**: If the ETH push fails the whole call reverts, including the IMD part. Only that holder's funds are affected.
**Recommendation**: Add `claimToken()` and `claimEth()`, or leave `_owed` untouched on a failed push and still pay the token.

## [D-7] TwapOracle history is 2,048 observations, about 6.8 hours on an active chain; longer windows silently disable VolatilityFee
**Severity**: Info
**Category**: evm-audit-dos
**Location**: `TwapOracle.CARDINALITY`, `_record()`, `_cumulativeAt()`; `VolatilityFee.extraNow()`
**Description**: Fixed ring, 11-step binary search, `consult(5 min)` 7,723 gas. `record()` is public so the ring can be rolled over in 2,048 blocks; a window longer than the ring's reach makes `consult` revert `TooOld` and VolatilityFee fails open with no event.
**Recommendation**: Document the maximum useful window (~2,048 × 12 s) or size the ring; expose a view when `consult` would fail.

## [D-8] `nextMintIds` never returns when all 3,333 ids exist; its id limit differs from DN404's after burns
**Severity**: Info
**Category**: evm-audit-dos
**Location**: `Swarmlings.nextMintIds()`
**Description**: Unbounded `while (_exists(id))`; wrap uses `MAX_NFTS` while DN404 uses `totalSupply / UNIT`. View only. `contractURI` measured at 3,379,120 gas, `tokenURI(1)` 2,178,231 (views).
**Recommendation**: Bound the view and use `totalSupply() / UNIT`.

## Gas table (cold single transaction; EIP-7825 cap = 16,777,216)

| Path | Native | IMD (mainnet) |
| --- | --- | --- |
| Buy exact-out minting 800 NFTs via router, no config | 9,713,066 | 9,734,133 |
| Same + 8 modules × 3 callbacks each burning 200k + 8 slices + real AutoLiquidity poke | 14,932,704 | 14,953,883 |
| Same, poked sink burning its whole 1M | 15,686,725 | 15,707,792 |
| Plain transfer minting 800 NFTs | 9,491,501 | n/a |
| Transfer moving 800 NFTs holder to holder | 4,754,584 | n/a |
| Sell burning 800 NFTs (router, warm) | 2,737,471 | n/a |
| Whale (3,283 NFTs) sell all, no config / 24 burner calls | 12,995,844 / 17,738,800 | n/a |
| `keep` per id | 4,361 | n/a |
| Exact-in buy, skip-NFT buyer, no config | 234,736 | 269,907 |
| + TreasurySink / BuybackBurn / AutoLiquidity (first) poke | 344,408 / 451,045 / 515,433 | 373,757 / 491,012 / 551,440 |
| Sell of 1 NFT, no modules | 206,491 | 220,654 |
| Sell + 1 observer quiet / burning 200k each (two callbacks) | 205,174 / 597,216 | 219,337 / 611,379 |
| Sell + 1 observer returning 200 kB / 300 kB | 624,761 / 1,063,240 | 638,924 / 1,077,403 |
| Sell + 1 / 2 / 4 / 8 bomb modules | 1.81M / 5.13M / 16.94M / 61.16M | n/a |
| First swap after 10 / 500 quiet years | 293,086 / 293,086 | 183,028 / 183,028 |
| First swap with TwapOracle + VolatilityFee (cold) | 279,484 | 307,398 |
| `contractURI()` / `tokenURI(1)` (views) | 3,379,120 / 2,178,231 | n/a |
| Gas required left before a capped module call / before a poke | 233,174 / 1,045,873 | same |

Is the 800 cap sufficient? Yes: the worst configuration the hook allows by construction fits with ~1.07M to spare; a hostile module set can add 4.7M (24 calls at 196k). The cap stops fitting only with return-data abuse (D-2) or an uncapped guard on a buy (documented council power).

## Checklist coverage (17 items)
1 Returndata bombing: D-2. 2 Insufficient gas forwarding: module calls fixed at 200k/1M behind gasleft checks; `due{gas:50_000}` has no floor (not exploitable); D-3 is the flip side. 3 Try/catch gas trick: not exploitable for poke/syncToken/tokenURI; D-1 is the decode class. 4 User-growable arrays: none (council-set, capped at 8; 3,333 supply; fixed ring). 5 External calls in loops: `_quote`, `_runModules`, `_pokeSinks`, `_collect`, bounded; failures caught except D-1/D-2/D-4. 6 Cheap-gas L2s: `_advance` O(1) (same gas after 10 or 500 quiet years). 7 Reverting ETH receiver: claim pays only msg.sender (D-6); claimDev pays constant DEV (EOA on mainnet); `receive()` never reverts; sink recipient failure is D-4. 8 Blocklisted recipients: no batch distribution; IMD has no blocklist. 9 Zero-amount transfers: handled. 10 Block stuffing: no deadlines that matter. 11-15 Timelock/liquidation/paymaster/pause: n/a (only freeze is `setCouncil(0)`, which would also freeze a bad module, see D-1). 16 Price feed revocation: internal oracle, fails open (D-7); OpenSea validator can only block NFT-level transfers. 17 Reverting balanceOf: `_syncToken` depends on IMD.balanceOf (no pause); swaps never depend on it (try/catch).

Examined with no finding: mint paths vs EIP-7825 (`_transfer` only post-construction mint path; guard re-derives count from full balance, incl. from == to); DN404 id scanning uses the exists bitmap; `_advance` at most three turns; `_handOver` native path cannot brick swaps; `claim`/`claimDev` accounting; council `execute` owner-only; trader-supplied hookData costs only the caller.

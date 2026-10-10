# Swarmlings (e706550) - evm-audit-precision-math findings

Scope: `src/Swarmlings.sol`, `src/SwarmlingsHook.sol`, `src/SwarmlingsMirror.sol`, `src/modules/{AutoLiquidity,BuybackBurn,VolatilityFee,TwapOracle,MaxBuy,HiveSink}.sol`, `docs/HIVE.md` (Fee flow).
PoCs and fuzz tests: `test/audit/PrecisionMath.t.sol` (`forge test --match-path 'test/audit/PrecisionMath.t.sol' -vv`; 1000-run fuzz passes for the "clean" checks). Nothing in `src/` was modified.

Result in one line: the core money math (accumulator, day stream, four-mode fee formulas, int128 casts, pro-rata split) is sound; the two real problems are in the optional Hive modules (oracle integration rule, unchecked add on quoter output).

## [M-1] TwapOracle books every interval at the tick the interval started with (one-observation lag), so VolatilityFee surcharges sells for a drop that settled long ago
**Severity**: Medium
**Category**: evm-audit-precision-math
**Location**: `TwapOracle._record()` (src/modules/TwapOracle.sol:68), `TwapOracle._cumulativeAt()` (:95), consumed by `VolatilityFee.extraNow()`
**Description**: `_record()` stores `Observation(now, cumulative, tick)` where `tick` is the pool tick at the *start* of the current block (read in `beforeSwap`, before the swap). The next record then adds `last.tick * (now - last.blockTimestamp)`, i.e. the interval `[t_i, t_{i+1}]` is integrated at the tick that held *before* the swap of block `t_i`. But the price that actually held during that interval is the price *after* block `t_i`'s swaps, which is exactly the tick that gets recorded at `t_{i+1}`. Uniswap v3 does the opposite (the new write's pre-swap tick is used for the elapsed interval). `_cumulativeAt()` extrapolates past the newest observation with `last.tick` for the same reason, and `HiveSink`/`VolatilityFee` compare it with the live `slot0` tick (`extraNow()`), so after any large move the average "remembers" the old price for the whole idle period and, once a swap does record it, for another `window`. Also, in `Hook._quote` the quoters run *before* the `BEFORE_SWAP` observers, so the first seller after a quiet period is charged against the stale value before `record()` can run in the same swap.
**Proof of Concept**: `test_audit_oracleStaleMean` (native pairing, window 1h, 50 bps per percent, cap 375). One quiet hour at tick -177179, then one 150,000,000 LING dump (pool tick moves to -182417), then **nobody trades for 2 days**. The pool has been flat at -182417 for 48h, so the true 1h average is -182417 and the surcharge must be 0. Actual: `consult(1h) = -177179` (the pre-dump tick), `extraNow() = 375` bps. A seller pays 1.25% + 3.75% = 5% instead of 1.25%. Calling `record()` does not repair it (still 375, because the 2-day gap is booked at the old tick); it only drops to 0 1h after that record. A busy market is mis-priced the same way, by one observation gap. Holders receive the overcharge, so this is a wrongly-priced fee on users, not a theft.
**Recommendation**: Integrate with the tick that held during the elapsed interval: in `_record()` use `cumulative = last.tickCumulative + int56(tick) * dt` where `tick` is the freshly read pre-swap tick (the v3 rule), and in `_cumulativeAt()` for `t >= last.blockTimestamp` extrapolate with the live `slot0` tick (via `poolManager.getSlot0`), not `last.tick`. Optionally compare against a block-start tick rather than live spot to keep it flash-manipulation resistant (today the sell's surcharge also moves with same-block spot manipulation by a third party).

## [M-2] `bps += extra` in `_quote` is a checked add outside the try/catch, and a quoter's return data is decoded outside it too: one misbehaving quoter reverts every swap, sells included
**Severity**: Medium
**Category**: evm-audit-precision-math
**Location**: `SwarmlingsHook._quote()` (src/SwarmlingsHook.sol:486-493)
**Description**: The hook documents that quoter failure "is logged, never fatal" and that no module can block a sell. But `try IHiveModule(m.addr).quoteFee{gas: MODULE_GAS}(...) returns (uint256 extra) { bps += extra; }` runs `bps += extra` inside the success branch, where a Solidity 0.8 overflow panic is not caught by the `catch`. The cap (`if (bps > MAX_FEE_BPS)`) is applied only after the loop, so it cannot help. Likewise, a quoter whose call succeeds but returns fewer than 32 bytes (any contract with a permissive `fallback`) makes the compiler-generated return-data decoding revert in the *hook*, which `try/catch` also does not catch. The council can add a quoter at once (`setModules`), so this breaks the advertised constant "nothing can ever block a sell" through a buggy or hostile (or upgraded-proxy) quoter, and does so only on swaps, silently, with no `ModuleFailed` event.
**Proof of Concept**: `test_audit_quoterOverflowBlocksSells`: `FlexModule.setExtra(type(uint256).max)`: `_sellExactIn`, `_sellExactOut` and `_buyExactIn` all revert (Panic 0x11 from `bps(500) + max`). Any `extra >= 2^256 - 500` does it (with 125 floor + slices 375). `test_audit_quoterWithEmptyReturnBlocksSells`: a quoter with `fallback() external {}` (returns 0 bytes) makes `_sellExactIn` revert. With `extra = 2^256 - 626` the sell still works, showing the cap itself is fine.
**Recommendation**: Clamp before adding and decode defensively: replace the module call with a low-level `staticcall` (gas-capped), accept only `ret.length == 32`, then `uint256 e = abi.decode(ret,(uint256)); if (e > MAX_FEE_BPS) e = MAX_FEE_BPS; bps += e;`. Any other outcome emits `ModuleFailed` and adds 0. Keep the final `bps > MAX_FEE_BPS` clamp (and note the snipe add after it is bounded by 4000).

## [L-1] TwapOracle ring buffer is short for a fixed 1h-style window on fast L2s; an attacker can make `consult` revert `TooOld` and so switch the surcharge off
**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `TwapOracle.CARDINALITY` / `_cumulativeAt()` revert `TooOld` (src/modules/TwapOracle.sol:25, :99-100); `VolatilityFee.extraNow()` catch -> 0
**Description**: One observation is written per distinct `block.timestamp` that has a swap. The oracle needs `window` seconds of history but holds only 2048 observations. If an attacker puts a tiny swap in more than 2048 distinct seconds inside the window, the oldest kept observation is newer than `now - window`, `consult` reverts `TooOld`, and `VolatilityFee` fails open (extra = 0). Mainnet (12 s blocks: 2048 obs = 6.8 h) is safe for windows below that; L2s (the docs deploy "on every chain", native-ETH variant) with 1-2 s blocks or sub-second blocks are not: 2048 swaps are cheap there, and the attacker (a seller who wants to dump without the surcharge) pays only the 1.25% fee on dust.
**Proof of Concept**: Window 3600 s on a chain with 1 s block time: 2049 swaps in 2049 consecutive seconds leave `observations[oldest].blockTimestamp > now - 3600`; the next `consult(3600)` reverts `TooOld` and `extraNow()` returns 0 (code path read, not run on a fork).
**Recommendation**: Constructor-check `window * minBlockTime <= CARDINALITY` or, better, make the buffer rate-limited (skip a new observation if less than e.g. `window / (CARDINALITY/2)` seconds elapsed since the last), so the ring always spans the window.

## [I-1] Fee rounding is always in the trader's favour (floor), so very small swaps pay no fee and tiny slice parts become holders' money
**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `_specifiedFee()` (:851), `afterSwap` (:335), `_collect()` (:564)
**Description**: All four modes floor the fee (`mulDiv` floors; `gross*bps/10000`, `gross*bps/(10000-bps)` floor). The fee is therefore at most 1 wei under the exact rate; any swap with `amount * bps < 10000` (below 20 wei at 5%, 80 wei at 1.25%) pays 0. Slice parts `fee * s.bps / bps` also floor, so the sinks lose up to 1 wei each and the holders' remainder (`fee - toSinks`) gains it, which is the safe direction for the holder floor (holders never get less than `fee*125/bps`). No dust amplification is possible: splitting a trade into n pieces saves at most n wei and costs n times the gas.
**Proof of Concept**: Verified by `testFuzz_audit_feeModesWithSnipe` (1000 runs, all four modes, snipe t in [0,69] s, two slices 200+175 bps at the 500 cap, random quoter extra): `totalFees + sinkFees == fee`, `sink claims == fee*s.bps/bps`, `holders >= fee*125/bps`, exact-in buy spends exactly `A`, exact-out sell pays exactly `B`, no `PartialFill`, bps up to 4500 included.
**Recommendation**: None required. If desired, round the fee up (`mulDivRoundingUp`) as the checklist suggests for AMM fees; this changes the invariant equalities in the existing tests.

## [I-2] int128 and 256-bit casts near the limits revert, they never truncate
**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `beforeSwap` (:306), `afterSwap` (:337), `_jitPenalty` (:425-432), `_buy` (:721-724), `AutoLiquidity.poke`, `BuybackBurn.poke`
**Description**: `fee.toInt128()` uses `SafeCast` and reverts above 2^127-1 (for example, an exact-in amount of `-2^200` makes `fee = A*bps/10000 > 2^127`). `_specifiedFee` handles `int256.min` via `-(x+1)+1`. `mulDiv(magnitude, bps, 10000-bps)` cannot overflow because `bps/(10000-bps) < 1` for `bps <= 4500`. `PartialFill`'s `amountSpecified + int256(fee)` could only overflow int256 for amounts the pool cannot settle anyway. `_jitPenalty`'s `int128(uint128(amount))` is safe because `amount <= fee <= int128.max` (and `fee > 0` is checked). `AutoLiquidity`/`BuybackBurn` clamp budgets to `int128.max` before `hook.buy`. `_buy`'s `uint256(uint128(-r))` is reached only for exact-in swaps where `r <= 0`.
**Proof of Concept**: Read-through; `fee = 2^127` -> `SafeCast.toInt128` reverts `SafeCastOverflow`. No silent wrap found.
**Recommendation**: None.

## [I-3] Swarmlings pot accumulator: no loss beyond sub-wei dust; overflow headroom is 15 orders of magnitude for ETH
**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `_stream()` (:324), `_advance()` (:344), `_settle()` (:382), `pending()` (:260)
**Description**: (a) Rate remainder: `rate = queued/EPOCH; queued -= rate*EPOCH` leaves `< 86400` scaled units (1e-31 wei) in `queued`, carried to the next day, never lost. (b) `accPerNFT += amount / nfts` floors `< nfts` scaled units (<3.4e-33 wei) per step. (c) Each `_settle` floors `n*(acc-last)/SCALE`, losing `< 1 wei` per holder per settle; `_settledAcc` is advanced so the residue is gone for good, and stays in the contract. Anyone can force a settle of a victim (a 0/1-wei LING transfer to them), but it costs gas of ~1e5 vs a loss of <1 wei, so no griefing. Dust is booked in `total` and not in `claimed + owed`; the invariant test tolerance of 1e9 equals one billion forced settles. (d) Credits can never exceed the pool: every division floors and holders' shares are `n*(Δacc)/SCALE` with `Σn = nfts`. (e) Overflow: `amount*1e36` needs `amount < 1.157e41` base units (ETH total supply is 1.2e26; fine for IMD unless its supply exceeds 1e41 base units, then `addRewards`/`syncToken` would revert and `_settle` could overflow and brick transfers); `rate*(t-last) <= queued < 2^256` by construction; `n*(acc-last)` with `n <= 3333` has the same headroom. (f) `_advance` terminates in at most 3 iterations; rolling over a gap with 0 NFTs returns the unheld time to `queued`; uint64 casts are fine for 5.8e11 years. (g) Creator-fee split: `toDev = fresh*5000/10000` floors, holders get `fresh - toDev` (remainder), the safe direction.
**Proof of Concept**: `testFuzz_audit_accumulatorConserves` (1000 runs, 1..1e18 wei donations, 0..3 day gaps, transfers between 4 holders incl. fractional-NFT balances): `total == added`, `claimed + owed <= total`, and after two idle days `total - claimed - owed - unpaid <= 1e4` wei. 1 wei donations never accumulate loss because fractions stay inside the scaled `accPerNFT`.
**Recommendation**: None. Optionally document that residual dust is permanent, and consider asserting `rewardCurrency` supply `< 1e41` at deployment.

## [I-4] TwapOracle integer details: truncating mean, int56 horizon, uint32 timestamp
**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `consult()` (src/modules/TwapOracle.sol:87), `_record()` (:60-68)
**Description**: (a) `(nowCum - thenCum) / int56(secondsAgo)` truncates toward zero, while Uniswap rounds to negative infinity. LING ticks are normally negative (about -177,179 in the tests), so the mean is rounded up by up to 1 tick (0.01% in price), shifting the surcharge by at most `bpsPerPercent/100` bps (0.5 bps at 50 bps per percent). (b) `int56` cumulative: `|tick| <= 887,272` so overflow needs `4.06e10` seconds (about 1,286 years); one product `tick * dt` is at most `887272 * 2^32 = 3.8e15 < 3.6e16`. Arithmetic is checked so it would revert, not wrap. (c) `uint32(block.timestamp)` wraps in Feb 2106; after that `now_ - last.blockTimestamp` would revert (fail-open via try/catch in the quoter, but `_record()` in `beforeSwap` is a gas-capped observer so swaps stay safe). (d) Tick sign convention is correct: `rewardIsCurrency0 ? -poolTick : poolTick` makes a higher tick mean "LING dearer in reward", and `now_ < mean` correctly identifies a sell into a falling price; `int24(mean)` cannot truncate since `|mean| <= 887,272`.
**Proof of Concept**: Arithmetic only (see numbers above); sign convention exercised in `test_audit_oracleStaleMean` (dump lowers the LING-terms tick in the native pairing).
**Recommendation**: Optionally floor-divide negative means, and use `uint32` modular arithmetic as Uniswap's oracle does if the module is to live past 2106.

## [I-5] AutoLiquidity: rounding slack is adequate; the 1% buy band, not rounding, decides how much is added
**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `AutoLiquidity.poke()` (src/modules/AutoLiquidity.sol:42-67), `HiveSink._buyLimit()`
**Description**: `getLiquidityForAmounts` floors, the manager rounds required amounts up by at most 1 wei per side, and the code removes 0.1% of the liquidity, so the claims always cover the principal for any realistic liquidity (the slack is `liquidity/1000`, which is 0 only for liquidity below 1000, i.e. dust amounts that cannot reach a sane `threshold`). The real limiter is the 1% price band on the `buy`: in the IMD pairings with `threshold` large relative to depth, only about 19.7 of 37.5 IMD of the half could be spent and 35.7 of the 75 IMD stayed as claims after the batch (they are added by the next poke; `due()` stays true). Documented behaviour, not a loss.
**Proof of Concept**: `testFuzz_audit_autoLiquidityPokeNeverFails` on all three pairings (native, IMD currency0, IMD currency1), 1000 runs each, `threshold` in [1e3, BIG], buys 1e12..2*BIG: `poke()` never reverts and `batches == 1`.
**Recommendation**: None.

## [I-6] SwarmlingsMirror.royaltyInfo and snipeBps integer behaviour
**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `SwarmlingsMirror.royaltyInfo()` (src/SwarmlingsMirror.sol:128-135), `SwarmlingsHook.snipeBps()` (:240-245)
**Description**: `royaltyInfo` computes `salePrice * 500 / 10000` (multiply first, floor, below 1 wei when `salePrice < 20`); `salePrice > 2^256/500` would revert, which ERC-2981 consumers must tolerate and no real price reaches. `snipeBps` is `4000 * (60 - t) / 60`, multiply-first and floored: 4000, 3933, 3866 ... 66 at t=59, 0 at t>=60; the integer steps are monotone, never exceed 4000, and the fee remains an exact function of `bps` in all four modes (verified with the snipe fuzz above, t in [0,69]).
**Proof of Concept**: `test_snipeTaxDecaysOverTheFirstMinute` in the repo plus the fuzz above.
**Recommendation**: None.

## Checklist coverage

Source: evm-audit-skills `evm-audit-precision-math/references/checklist.md` (36 items, numbered 1-36 in file order).

| # | Item | Result |
|---|------|--------|
| 1-2 | Mult before div; expand wmul/wdiv chains | Checked every `a*b/c` (`fee*s.bps/bps`, `n*(acc-last)/SCALE`, `4000*(60-t)/60`, `startCap*9*t/ramp`, `salePrice*500/10000`, `queued/EPOCH`): all multiply first. No wad libraries. |
| 3 | Repeated division by same scale | `accPerNFT` (one /nfts) then one `/SCALE` per settle; no double scaling. I-3. |
| 4 | Small values truncating to zero | Sub-20-wei fees (I-1); sub-wei per-settle dust (I-3); `liquidity/1000` slack (I-5). |
| 5-7 | Rounding direction deposits/withdraw/fee-adjusted conversions | No share vault. Fee floors in trader's favour; holders take the remainder (I-1); DEV share floors, holders get remainder. |
| 8, 28 | `unchecked` blocks | None in src (only `assembly` for transient storage). |
| 9, 35 | Downcast / SafeCast | All int128/uint64/uint32/int24 casts reviewed (I-2, I-3, I-4); casts that cannot truncate noted. |
| 10-11 | Negative-to-unsigned, mixed signed math | `_specifiedFee` int256.min handled; `-rewardDelta` is from int128; `_settleSide` `int256` subtraction safe; TwapOracle `int56*int56(uint56)` safe. |
| 12, 24 | Time-based narrow types / time literals | `uint32 now_`, `uint64 epoch/last`, `1 days` literal is promoted before use (`EPOCH` is a `uint256`); wrap at 2106 (I-4). |
| 13-15, 34 | Oracle / token decimals, hardcoded 1e18 | No oracle price decimals; both reward currencies are 18-decimal; 1e18 appears only in `UNIT`/supply and `MIN_DISTRIBUTE_IMD` (5e18, assumes IMD 18 decimals, true). |
| 16 | Fee remainders | Holders always take the remainder; no 1-wei residue stays in the hook (invariant `totalFees == distributed + pending`). |
| 17 | Compounding on claim and reinvest | No compounding. |
| 18 | Reward-per-token rounds to zero, loses rewards | Scale 1e36; fractions retained in `accPerNFT`; I-3 PoC with 1-wei donations. |
| 19 | Update global state before claim | `claim`, `_transfer`, `_transferFromNFT`, `_burn` all `_accrueAll()` then `_settle` before NFT count changes. |
| 20 | Mint fee shares before distributing | N/A. |
| 21-22 | Zero denominators; max as sentinel | `amount / nfts` guarded by `nfts == 0` branch; `bps` denominators are `>0` and `10000-bps >= 5500`; `/bps` in `_collect` with `bps >= 125`; no sentinel. |
| 23 | Exponential weights | N/A. |
| 25 | Explicit rounding direction | See I-1. |
| 26 | Boundary comparisons | `t >= SNIPE_WINDOW`, `block.number - added >= JIT_BLOCKS`, `t >= ramp`, `nowTs < end` all consistent. |
| 27 | Unsigned subtraction reverting | `address(this).balance - p.accounted` and `balanceOf - accounted` are safe while balances never fall below `accounted` (outside my domain: a rebasing reward token would break it). `now_ - secondsAgo` caught by try/catch. |
| 29 | Chained-division loss | None beyond I-3. |
| 30 | wmul/wdiv chains | N/A. |
| 31 | Repayment rounding to zero | N/A. |
| 32-33 | Scale secondary token; double scaling across modules | Reward amounts are scaled once (`amount*SCALE` in `_stream`) and unscaled once; the hook passes raw wei into the token. |
| 36 | Round AMM fees up | I-1 (floors; harmless, optional change). |

Also covered from the brief: four swap modes incl. `PartialFill` equality with bps to 4500 (I-1/I-2 PoC), `fee*s.bps/bps` with holders as remainder (I-1), accumulator overflow bounds (I-3), `_advance` remainder (I-3), TwapOracle sign convention and ring buffer (M-1, L-1, I-4), AutoLiquidity rounding (I-5), `snipeBps` decay (I-6). One out-of-domain item for other auditors: `_syncToken`/`_syncEth` subtract `accounted` from a live balance, which underflows if the reward token's balance ever falls (rebasing/fee-on-transfer token); IMD is a plain ERC-20 so not filed.

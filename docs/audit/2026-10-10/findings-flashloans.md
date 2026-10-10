# Flash-loan / same-transaction composability audit: Swarmlings (commit e706550)

Auditor domain: evm-audit-flashloans. Scope: `src/Swarmlings.sol`, `src/SwarmlingsHook.sol`, `src/modules/*.sol`, read against v4-core `PoolManager` (`unlock`, `take`, `settle`, claims).
PoCs (Foundry, real v4 PoolManager, native-ETH pairing unless noted; nothing in `src/` was modified): `test/audit/FlashSinks.t.sol`, `FlashAtomic.t.sol`, `FlashOracle.t.sol`, `FlashJit.t.sol`, `FlashSkip.t.sol`.
Run: `forge test --match-path "test/audit/Flash*" -vv`. All pass.
Checklist source: evm-audit-skills `evm-audit-flashloans/references/checklist.md` (13 items, listed under "Checklist coverage").

Headline: the reward stream, the creator-fee ledger, the snipe tax and the hand-over path are sound against atomic attacks (details under "Checked and clean"). One economically exploitable issue exists in the optional sink modules (F-1). The rest are Low.

---

## [F-1] Public `poke()` / in-swap poke lets anyone sandwich a sink's accumulated budget with zero capital
**Severity**: Medium (High if a `BuybackBurn` slice is armed with `poke=false`, the configuration used in `test_buybackBurnsSupply` and described in the docs as "anyone may trigger it")
**Category**: evm-audit-flashloans
**Location**: `BuybackBurn.poke()` (src/modules/BuybackBurn.sol:28-40), `AutoLiquidity.poke()`, `HiveSink._buyLimit()` (src/modules/HiveSink.sol:41-49), `SwarmlingsHook._pokeSinks()` / `_buy()` (src/SwarmlingsHook.sol:~498, ~660)
**Description**: A sink spends its whole claim balance whenever `poke()` runs. `poke()` is permissionless and the hook also fires it inside every swap. The only price protection is `_buyLimit()`, which is a band of about 1% of price (0.5% of sqrtPrice) measured from the CURRENT `slot0`, i.e. from whatever price the caller has just manufactured. There is no per-block limit, no spend cap per call and no comparison with the TwapOracle that already exists in the repo. One buyback therefore pushes the price up by at most about 1%, but `poke()` can be called repeatedly in one transaction, and each call moves the band forward from the already-pushed price. An attacker who buys first, calls `poke()` n times, then sells, captures the price impact of the sink's purchases. The sink pays that impact: it burns fewer LING per reward unit spent.
Because the whole sequence runs inside one v4 `unlock`, only the net delta is settled. The attacker needs no capital: the buy and the sell net out and only the (positive) profit is taken. The attack is profitable only when the sink holds a backlog, since the attacker's own fees (1.25% holders plus the slice, on each leg) must be beaten by the cumulative push. Backlogs arise with `poke=false` slices (unbounded accumulation), after whale trades (one poke per swap absorbs only ~0.5% of the reserve), or when an earlier sink in the slice list is perpetually "due" and starves this one (hook only pokes the first due sink).
`AutoLiquidity` was tested the same way and was NOT profitable (see Checklist coverage): its band-limited half-buy leaves most of the budget unspent, so a single manufactured price only mis-prices roughly 0.05 ETH of liquidity per batch.
**Proof of Concept**: `FlashSinksTest.test_zeroCapitalBuybackSandwich`, `test_buybackSandwichSweep`, `test_buybackBreakEven`, `test_buybackHonestBaseline`. Setup: native pool, ~10 ETH reserve, 800M LING, slice `BuybackBurn` 375 bps (total fee 5%), `poke=false` while Alice round-trips volume until the sink holds 2.17 ETH, then the slice is switched to `poke=true`.
1. Honest baseline: 30 successive `poke()`s spend 1.689 ETH and burn 67.23M LING (about 39.8M LING per ETH).
2. Attack, in ONE unlock by a contract that starts with 0 ETH (`ZeroCapitalSandwich`): swap exact-in 3 ETH to buy LING, call `poke()` 45 times (45 calls cost about 7.6M gas in total, under the 16.7M cap), sell all LING credit, settle. Result: attacker ends with +0.5089 ETH (starting from 0). The sink spent 2.342 ETH and burned only 57.65M LING (about 24.6M per ETH, 38% fewer LING per ETH than the honest run).
3. Other points of the sweep (backlog 2.17 ETH): V=1 ETH / 30 pokes gives +0.186 ETH; V=2 / 45 gives +0.399; V=10 / 30 gives +0.619 (all in ETH, pool reserve about 10 ETH).
4. Break-even backlog at 5% total fee (best V and n per backlog): 0.43 ETH gives -0.046; 0.65 gives -0.012; 0.87 gives +0.022; 1.09 gives +0.092; 1.52 gives +0.257. So it pays once the backlog is above roughly 8% of the pool's reserve; with a smaller slice (lower round-trip fee) the threshold is lower (each poke is worth about 1% of the attacker's position, the round trip costs 2x total fee).
Loss to holders: the value that should have burned LING instead goes to the attacker. A hand-driven variant with dust swaps instead of direct `poke()` calls works the same way (each swap triggers one in-swap poke when `due()`).
**Recommendation**: In the sinks, allow at most one buyback/liquidity batch per block (store `lastBlock`, return early if `block.number == lastBlock`), and cap each poke's spend to a fixed fraction of the budget or reserve. Better, also compare spot with the TwapOracle (skip the poke when spot is more than about 1-2% above the 1h mean) so a price manufactured in the same block cannot be bought into. Restricting `poke()` to the hook alone is not sufficient (the in-swap path and the attacker's own dust swaps remain), so the per-block and TWAP guards are the real fix. For `poke=false` slices, warn in docs that backlog is a standing target.

---

## [F-2] MaxBuy caps one swap, so the anti-snipe limit is bypassed by splitting buys or by using another tier's pool
**Severity**: Low
**Category**: evm-audit-flashloans
**Location**: `MaxBuy.onAfterSwap()` (src/modules/MaxBuy.sol:36-45); `SwarmlingsHook._isLaunch()` gating of `_runModules` (src/SwarmlingsHook.sol:~299, ~730)
**Description**: The guard compares each swap's LING output with `cap()`. Nothing aggregates by sender, block or transaction (checklist item 13, "bypassing rate limits"). A buyer (or a bot using a v4 unlock) splits the purchase into n swaps of at most `cap()` each. In addition, modules run only for the launch pool; a LING/reward pool at another tier with the same hook is charged the fees but has no guard, so one swap there is unbounded. The 1.25% fee and (while it lasts) the snipe tax still apply, but the stated purpose of MaxBuy, limiting how much one buyer can take early, is not delivered. MaxBuy is not active at launch, so this only matters if the council attaches it.
**Proof of Concept**: `FlashAtomicTest.test_maxBuyIsPerSwapSoSplittingBypassesIt`: cap = 1 unit (300,000 LING); a single 5-unit exact-out buy reverts, but 20 consecutive 1-unit buys in the same block succeed and deliver 20 units (20x the cap). `test_maxBuyDoesNotApplyToAnotherTierPool`: with cap = 1 unit, one 0.1 ETH swap in a second-tier pool (fee 3000, same hook) buys 16 units.
**Recommendation**: If the cap is meant per buyer, track cumulative LING bought per (tx.origin or router sender, block) in transient storage and compare against `cap()`; document that it cannot bind sybil/multi-address buyers. For the second pool, either run guards for every charged pool or state in the docs that only the launch pool is guarded.

---

## [F-3] TwapOracle stores the block-opening tick and extrapolates it over the next gap, so the TWAP lags by one observation and a sink `poke()` can set the "opening" tick
**Severity**: Low
**Category**: evm-audit-flashloans
**Location**: `TwapOracle._record()` / `_cumulativeAt()` (src/modules/TwapOracle.sol:62-112)
**Description**: Each observation holds `tick` = slot0 tick BEFORE the block's first swap and the cumulative is later advanced as `last.tick * dt`. After the first swap in block b changes the price from P0 to P1, the gap from b until the next observation is therefore valued at P0 instead of P1. (Uniswap v3 does this correctly by integrating the tick that held during the gap, taken from the pre-swap tick at the NEXT write.) In quiet markets the error persists for as long as nobody swaps or calls `record()`. Separately, the claim "a trade cannot move the price it is measured against" holds for swaps but not for a sink's `poke()`: `hook.buy` swaps as the hook, so no `beforeSwap` runs and nothing is recorded; the next user swap then records the post-poke price as the block's "opening" tick (bounded by the sink's budget; 30 pokes moved it by 3,008 ticks in the PoC).
Effect today: `VolatilityFee` sees a stale (too high) mean after a drop and over-charges the next seller; with the wrong sign (a pump left in place) it under-charges. The surcharge goes to holders, so this is a mis-pricing of a fee, not a loss of funds. Multi-block manipulation cost is not an issue: a 1h window needs the price held off-mean for hundreds of blocks against arbitrageurs, and the single-swap case is covered in F-4.
**Proof of Concept**: `FlashOracleTest.test_e_twapUsesStaleOpeningTickAcrossQuietGaps`: quiet hour at tick -177179, then a 40M LING dump to -178716 (-1,537 ticks, about 15%), then 50 idle minutes. On-chain 1h mean = -177179 (still the old price); the true 1h mean (10 min at the old tick, 50 min at the new) = -178459. `extraNow()` returns 375 bps (the cap; the raw value is 768) versus 128 bps with the correct mean. `test_e_pokeMovesPriceBeforeTheOpeningTickIsRecorded`: previous block closed at tick -176635; after 30 public `BuybackBurn.poke()` calls the next swap records -173627 as the block's opening tick.
**Recommendation**: Record the tick that holds AFTER the block's swaps (write in `afterSwap`, or in `beforeSwap` store the tick valid for the PREVIOUS gap as v3 does: on each new-block observation set `tickCumulative += lastTickAtThatTime * dt` where the tick used is the current pre-swap tick for the interval since the last observation). Have sinks call `oracle.record()` before spending, or refuse to buy within the same block as a price change (see F-1).

---

## [F-4] VolatilityFee charges on pre-swap spot, so the sell that causes the drop pays no surcharge; ring capacity assumption
**Severity**: Low
**Category**: evm-audit-flashloans
**Location**: `VolatilityFee.quoteFee()` / `extraNow()` (src/modules/VolatilityFee.sol:48-70); `SwarmlingsHook._quote()` (runs before the swap); `TwapOracle.CARDINALITY`
**Description**: The quote reads `slot0` before the swap executes, so a single large sell is charged the base fee only; only sells that arrive afterwards pay the extra. A holder dumping a bag in one swap (or via a v4 unlock where the first swap sees spot equal to the mean) escapes the surcharge entirely; splitting the bag across swaps would be punished. Escaping needs no manipulation and no capital. The mechanism therefore penalises followers, not the dumper. Secondary: the oracle ring has 2048 slots and one observation per distinct timestamp. `consult(window)` reverts `TooOld` (caught, fail-open: extra = 0) when the history is shorter than the window. With a 3600 s window the ring must cover 3600 s, i.e. blocks of at least 1.76 s apart. On Ethereum mainnet (12 s) that holds even under per-block `record()` spam (6.8 h of history); on a chain with sub-1.7 s blocks, an attacker can call `record()` every second for 2048 s (about 34 min) and wipe the history, switching the surcharge off. Not applicable to the Ethereum deployment.
**Proof of Concept**: `FlashOracleTest.test_e_singleSwapDumpPaysNoSurcharge`: after a quiet hour, one 140M LING sell (price impact about 15% on a 10 ETH pool) pays 124 bps (1.25% less rounding); the next 1M LING sell, 12 s later, pays 499 bps (125 + 375 cap).
**Recommendation**: Charge on the post-swap price where the hook can know it (afterSwap path for exact-in sells), or on the larger of pre- and post-swap drop; document the first-seller exemption otherwise. Size `CARDINALITY` or the window per chain (`CARDINALITY * minBlockTime >= window`), or make the fail-open path require `count == 0` only.

---

## [F-5] JIT penalty applies to reward-currency fees only, so JIT liquidity around sells keeps its full LING fee
**Severity**: Low
**Category**: evm-audit-flashloans
**Location**: `SwarmlingsHook._jitPenalty()` (src/SwarmlingsHook.sol:~385-405)
**Description**: The penalty is computed from `feesAccrued` in the reward currency, 100% at delta 0 blocks, linear to 0 at 10 blocks. LP fees are charged on the input currency: a buy pays the LP fee in the reward currency (penalised, correct), a sell pays it in LING (not touched). A JIT liquidity provider who adds concentrated liquidity ahead of a visible sell and removes it in the same block keeps the whole LING fee. That fee comes out of the pool's existing LPs (including the hook's permanent positions), and holders receive nothing from it. The JIT provider still carries the inventory risk of the swap, so profit needs a hedge; unhedged it loses to impermanent loss in the PoC.
**Proof of Concept**: `FlashJitTest` (JIT adds 5x the pool's active liquidity over +-6 ticks of spacing, victim swap, JIT removes, same block).
- Victim buys 0.1 ETH: LP fee 1.0417e15 wei in ETH to JIT; the hook mints a penalty of 1.0286e15 wei (98.7% after rounding, the rest being its share of the pool) to holders. Net for JIT marked at the post-trade price: -0.00013 ETH. Works as intended.
- Victim sells 60M LING (gross 1.17 ETH): the JIT provider receives about 0.625M LING of fee (5/6 of 1.25% of 60M, about 0.0126 ETH); penalty minted: 0. Net value marked at the pre-trade price (i.e. if the received LING can be sold elsewhere at the old price): +0.0322 ETH, about 2.7% of the swap; marked at the post-trade price (unhedged): -0.0070 ETH.
**Recommendation**: Penalise LING-side fees too (hand the penalty in LING to the hook as claims and let a sink or the token burn it), or document that JIT is only discouraged on the buy side. Keep the cost in mind: LING claims at the hook have no existing path to holders.

---

## [F-6] NFT ids can be chosen by flash-cycling the DN404 mint counter (traits are a pure function of id)
**Severity**: Low
**Category**: evm-audit-flashloans
**Location**: `Swarmlings.nextMintIds()` / DN404 `_transfer` mint order (src/Swarmlings.sol:130-143); renderer `seedOf(id)`
**Description**: DN404 hands out ids in a cycle starting at `nextTokenId`, skipping existing ones. `PoolManager.take` lets anyone borrow up to the manager's LING balance for the duration of an unlock. Borrowing N units mints N NFTs (<= 800 per transfer), returning them burns them, and the counter stays advanced. Cost is gas only, no capital. A buyer can therefore advance the counter to any id (the renderer's traits are a deterministic function of id, so rare ids are known in advance), then buy exactly one unit and receive that id; ids that were cycled become free again. This also lets an attacker deny sequential-fairness of the primary distribution. It does not touch rewards: every NFT earns the same.
**Proof of Concept**: `FlashAtomicTest.test_idCyclingFlash`: before the cycle `nextMintIds(1)` = 1; one flash cycle of 300 units (take 300 units, return them in the same unlock) costs 4.59M gas and leaves no NFTs and `nextMintIds(1)` = 301. About 11 such cycles reach any id up to 3,333.
**Recommendation**: Treat as an inherent property and disclose it (rarity is not randomly assigned), or break the link between mint order and traits (e.g. derive the trait seed from a post-mint on-chain randomness that is not predictable at purchase time) if fair rarity matters for the launch.

---

## Checked and clean (no finding)

- Flash-borrowed NFTs earn nothing, claim and hand-over inside the same unlock included (`test_a_flashNftsEarnNothing_claimAndDistributeInsideUnlock`): borrowing 500 units from the manager, running `hook.distribute()`, `syncEth()`, `claim()`, a swap and `claim()` again, then returning the LING: claim returns 0/0, pending after payout day = 0. `_advance` pays `(t - last) * rate`, so zero elapsed seconds is zero reward, and `_transfer`/`_transferFromNFT`/`_burn` all run `_accrueAll()` then `_settle(from)`/`_settle(to)` before the NFT count changes (verified against DN404: `transfer`, `transferFrom` go through `_transfer`; NFT moves go through `_transferFromNFT`; supply changes only there and in `_burn`).
- Day-boundary timing (item h), numbers from `test_a_dayBoundaryNumbers`: day-D fees of 0.06328 ETH queued; payout rate = R/86400 per second. A holder with 10 of 555 NFTs who arrives at 23:59:59 of day D has 0 pending at 00:00:00 and 13,196,926,845 wei after one second of the payout day (= R/86400 x 10/555 exactly); leaving then freezes it. Entering a second earlier or later changes nothing but the seconds held.
- Creator-fee ETH (item b), `test_b_syncEthDonationAndClaimDevFrontrun`: forced/donated ETH is split 50/50 and cannot be undone; `accounted` is only decremented by claims/claimDev, so `balance - accounted` cannot be inflated by the caller beyond what the caller pays; a front-run of `claimDev` pays DEV exactly its half (0.5 ETH of 1 ETH) and nothing to the caller.
- Snipe tax (item f), `test_f_snipeAppliesToExactOutAndSecondPool`: exact-out buys at t=0 pay 41.25% (fee = gross x 4125/(10000-4125)); a second-tier LING/reward pool with the same hook pays the same snipe tax (`_isCharged`); `donate` returns nothing to the donor; the hook's own sink buys are untaxed but are funded only by fees. Pre-launch cases are not reachable: `_isCharged` is false until the launch pool binds, and `launchedAt` is set in `afterInitialize`. If the IMD launcher initialises the pool long before opening liquidity, the 60 s window would be spent before the first buy; confirm initialize and seed happen in one transaction (outside this repo).
- Skipped hand-over (item i), `FlashSkipImdTest.test_i_skipIsPerTransactionOnly` (IMD pairing): `sync(IMD)` before the swap skips the in-swap hand-over for the attacker's own swap only (`getSyncedCurrency` is transient). The next ordinary swap hands over everything pending (63.17 IMD in the PoC) and `distribute()` stays open. The manager's balance can never be below pending claims except before the first settlement, so no persistent skip is possible.
- Opening-tick ownership (item e): the first swap of a block records `slot0` before it executes, i.e. the previous block's close. The only way to alter it earlier is a sink `poke()` (F-3).
- AutoLiquidity (item d), `test_autoLiquiditySandwichSweep`: backlog 1.085 ETH threshold, buy V in {1, 3, 10, 30} ETH, poke, sell: attacker P&L -0.101, -0.299, -0.967, -2.813 ETH. Not profitable. A manufactured price is bounded by the 1% band on a half-buy, and the sink adds roughly 0.05 ETH of liquidity per batch at that price. The permanent position's residual mispricing was not quantified beyond that bound.
- Band griefing (item c): `_buyLimit()` is relative to the current price, so pushing the price cannot stop a buyback; it only spends the band. Observed via the sweep: a thin market leaves budget as claims (documented).
- No cross-protocol reentrancy found: `claim()` is nonReentrant (transient slot 0), pays the reward token first and ETH last with the ledger already updated; `addRewards()` is intentionally re-enterable and consistent. The hook's services share one transient lock; sink `poke()` inside a user's swap or an attacker's own unlock reaches `_dispatch` directly (`isUnlocked`) with net-zero hook delta.

## Checklist coverage

| # | Item | Result |
|---|---|---|
| 1 | Flash-loan voting | N/A: no voting in scope. `SwarmlingsCouncil` is owner-executed; token has no snapshots or votes. |
| 2 | Flash-loan quorum manipulation | N/A (no quorum). |
| 3 | Flash loan with AMM spot price manipulation | Found: sinks price their buys from same-block `slot0` (F-1, Medium); `VolatilityFee` and `TwapOracle` read spot (F-3/F-4). AutoLiquidity tested, bounded. |
| 4 | Flash loan with TWAP manipulation | Reviewed: block-opening recording is not manipulable by swaps; multi-block cost is the arbitrage loss over a 1h window; implementation lag and poke gap in F-3; ring capacity note in F-4. |
| 5 | Flash deposit-harvest-withdraw | Clean: holding NFTs for zero seconds earns zero; day-by-day stream, per-second accrual, verified with a v4 flash-borrow PoC and day-boundary numbers. |
| 6 | Share price manipulation | N/A (no vault shares). Closest analogue: `accPerNFT`, which depends on NFT supply at accrual time and is accrued before every supply change (clean). |
| 7 | Flash mint inflating totalSupply | LING is not flash-mintable; `take` from the manager temporarily mints NFTs (supply of NFTs rises, accrued first, no effect on rewards). Side effect: id cycling (F-6). |
| 8 | Flash loan to win auctions | N/A (no auctions). |
| 9 | Flash loan to close auctions early | N/A. |
| 10 | Flash loan with self-liquidation | N/A. |
| 11 | AAVE flash loans inflating the pool index | N/A. |
| 12 | Cross-protocol reentrancy via callbacks | Reviewed: v4 `unlock` callbacks, `claim`/`addRewards`/`syncToken`, hook locks, ERC-20 `take` with `getSyncedCurrency` guards. No exploitable path found. |
| 13 | Flash loans bypassing rate limits | Found: MaxBuy per-swap cap (F-2); sink one-poke-per-swap and 1% band do not limit repeated pokes in one tx (F-1); JIT penalty window is block-based but LING side not covered (F-5). |

Residual notes: the first-due-sink starvation (the hook pokes only the first sink whose `due()` is true) was observed but is reported by the access-control auditor (`test_poc_failingDueSinkStarvesLaterPokes`); it feeds the backlog precondition of F-1.

# Swarmlings (e706550) - evm-audit-defi-amm findings

Scope: src/SwarmlingsHook.sol (the Hive), src/interfaces/IHive.sol, src/modules/*.sol, docs/HIVE.md, docs/SECURITY.md, docs/OPERATIONS.md, with v4-core (Hooks.sol, PoolManager.sol, BeforeSwapDelta.sol, TransientStateLibrary.sol, CurrencyReserves.sol) as reference.
PoCs: swarmlings/test/audit/AmmAudit.t.sol (`forge test --match-path 'test/audit/AmmAudit.t.sol' -vv`; Native/ImdFirst/LingFirst, 27 tests, each pass demonstrates the bug).
Checklist: evm-audit-defi-amm (fetched as a summary) plus the Trail of Bits "Building secure Uniswap v4 hooks" classes.

Summary: the v4 accounting core is sound. Hook deltas net to zero in all four fee modes, the JIT penalty, _handOver, _buy and _modify; the synced-currency guard is correct for ERC-20; unlockCallback cannot be reached from outside; the PartialFill formula matches Hooks.beforeSwap; the _requireGas 63/64 margin is right; the hook's own swaps skip the snipe tax and fee; sandwiching the buyback loses money. Real findings: a JIT-guard bypass (A-1), four ways the "never block a sell / holder floor is constant" rules can be broken or degraded (A-2, A-3, A-5, A-7), and a launch-binding hardening gap (A-4). No Critical/High.

## [A-1] JIT penalty is bypassed by topping up the same position with dust before removing
**Severity**: Medium
**Category**: evm-audit-defi-amm
**Location**: `afterAddLiquidity()` (src/SwarmlingsHook.sol:367-380) and `_jitPenalty()` (:417-434)
**Description**: The JIT guard only looks at `feesAccrued` in `afterRemoveLiquidity`. In v4 every `modifyLiquidity` first settles all fees accrued by the position into the caller's delta, including an add. `afterAddLiquidity` ignores `feesAccrued`, returns ZERO_DELTA and only refreshes `lastAdded`. A JIT LP adds large liquidity in block N, lets the victim swap, adds 1e6 liquidity to the same position (collecting every fee un-penalized), then removes everything: the removal sees `feesAccrued == 0`, penalty 0. Trail of Bits "correct logic in the wrong hook". The hook sets `afterAddLiquidityReturnDelta` but never uses it.
**Proof of Concept**: `test_A1_jitPenaltyBypassedByDustTopUp` (all pairings). Plain remove: penalty to holders = 1.3715e18 (IMD case), LP nets 108.35 units. Add 1e6 liquidity then remove all: penalty = 0, LP nets 109.72 units.
**Recommendation**: Penalize in afterAddLiquidity too: read old `lastAdded` before overwriting; if added within JIT_BLOCKS, take the same pro-rata share of the reward-side `feesAccrued`, mint it as holder claims and return it as the afterAddLiquidity hook delta; then set `lastAdded`. Regression test: dust top-up yields the same penalty as a plain remove.

## [A-2] A council-chosen quoter or sink can still revert every swap, sells included (unchecked `bps += extra`; uncaught return-data decoding of `quoteFee` and `due()`)
**Severity**: Medium
**Category**: evm-audit-defi-amm
**Location**: `_quote()` (src/SwarmlingsHook.sol:473-498), `_pokeSinks()` (:535-552)
**Description**: (1) `bps += extra` runs in the try's success branch; extra ≥ 2^256-500 panics in the hook and `catch` does not see it. (2) A quoter call that succeeds but returns <32 bytes (permissive `fallback`, proxy with a missing implementation) makes the compiler's return decoding revert inside the hook, outside the try. (3) Same for a sink's `due()`: a non-0/1 word or no data reverts the `bool` decode; `_pokeSinks` runs on every launch-pool swap including sells. One buggy/hostile/upgraded module bricks all trading until the council calls disableModule/setSlices. Overlaps precision-math M-2 and access-control C-1.
**Proof of Concept**: `test_A2_overflowingQuoterBlocksSells`, `test_A2_silentQuoterBlocksSells`, `test_A2_dirtySinkDueBlocksSells`.
**Recommendation**: Gas-capped staticcall, require `success && ret.length == 32`, clamp `e` to MAX_FEE_BPS before adding, else emit ModuleFailed and add 0. Same for due() (`success && ret.length == 32 && word <= 1`).

## [A-3] `InsufficientGas` can revert sells: a due sink makes every swap demand ~1.05M gas, and anyone can make a sink due by donating claims
**Severity**: Medium
**Category**: evm-audit-defi-amm
**Location**: `_pokeSinks()` (:545), `_requireGas()` (:530-532)
**Description**: After any launch-pool swap, if the first poke-enabled sink reports due(), `_pokeSinks` reverts with InsufficientGas unless gasleft() ≥ ~1.046M, while a plain sell uses ~200k. due() is `claims(reward) >= threshold` and ERC-6909 claims can be minted to a sink by anyone, so an attacker flips a sink to due for the price of a donation. Any sell with a normal wallet gas limit then reverts. With a low threshold every swap needs >1.05M gas permanently; a band-limited BuybackBurn keeps it due for long periods (A-7).
**Proof of Concept**: `test_A3_dueSinkMakesLowGasSellsRevert` (3 pairings): plain sell passes at 240k; after a donor makes the sink due, the identical sell reverts; with 1.5M it passes and pokes.
**Recommendation**: Make the poke best-effort (`return` instead of revert); reserve POKE_GAS plus a floor for the rest of the swap before poking. Enforce the observer/quoter gas check only on buys, or skip the module and emit ModuleFailed when short.

## [A-4] Launch-pool binding ignores tick spacing and the initializer
**Severity**: Low
**Category**: evm-audit-defi-amm
**Location**: `afterInitialize()` (:264-285); docs/SECURITY.md ("tick spacing 60") vs docs/OPERATIONS.md ("any tick spacing")
**Description**: The hook binds to the first LING/reward pool at fee 12500 without checking tickSpacing, price or initializer. If the hook exists before the intended pool is initialized, anyone can bind a junk pool (spacing 32767 or 1, any price); launchPool, _launchKey and launchedAt then point to it. Mitigation today: the launcher is atomic and an init before the hook has code reverts.
**Proof of Concept**: `test_A4_firstPoolAtTheTierBindsWhateverTheTickSpacing`.
**Recommendation**: Require `key.tickSpacing == 60` and ideally restrict binding to an initializer the token names; reconcile the docs; assert atomicity in the deploy script.

## [A-5] Transient slot 3 is shared scratch: a nested charged swap during beforeSwap zeroes the outer swap's fee
**Severity**: Medium (requires a council-installed module)
**Category**: evm-audit-defi-amm
**Location**: `_quote()` (tstore(3)), `beforeSwap()`, `afterSwap()`
**Description**: beforeSwap stores total bps in transient slot 3 (not keyed by pool or caller); afterSwap reads and clears it. BEFORE_SWAP observers run in between with the PoolManager unlocked, so an observer can call PoolManager.swap in another charged pool; that nested swap ends with tstore(3,0). The outer afterSwap loads bps==0: exact-in sell / exact-out buy → fee 0 (holder floor skipped); exact-in buy / exact-out sell → PartialFill revert. Trail of Bits class 7.
**Proof of Concept**: `test_A5_nestedSwapInASecondPoolZeroesTheOuterFee`: holder fee with module = 12 wei vs 616,362,881,561,147,907 wei without.
**Recommendation**: Key the transient slot by pool and nesting depth, or revert on re-entry; document that modules must not swap.

## [A-6] Buyback / POL run at spot with a 1% band and no TWAP or min-out; sandwiching is uneconomic at current fees
**Severity**: Info
**Category**: evm-audit-defi-amm
**Location**: `HiveSink._buyLimit()`, BuybackBurn.poke, AutoLiquidity.poke, `_buy()`/`_modify()`
**Description**: poke() is permissionless and also runs in someone else's afterSwap, so the limit is taken from a price an attacker may have just moved. Each leg pays 2.5% against at most ~1% improvement per poke, so the attacker loses; a future cheaper route would reopen it.
**Proof of Concept**: `test_A6_sandwichingTheBuybackLosesToFees` (~0.55 loss of 1000).
**Recommendation**: Optionally skip poke when spot deviates from the TwapOracle mean by more than the band; note that safety relies on HOLDER_FEE_BPS + LP fee > band.

## [A-7] The first due sink wins every swap: a sink that stays due starves later sinks and taxes every swap with poke gas
**Severity**: Low
**Category**: evm-audit-defi-amm
**Location**: `_pokeSinks()` (:535-552)
**Description**: Only the first due slice is poked, then the function returns, whether the poke succeeded or made no progress. BuybackBurn stays due whenever the 1% band absorbs less than its claims; a reverting poke stays due. Later slices are never auto-poked and every swap carries the A-3 gas demand.
**Proof of Concept**: `test_A7_stuckFirstSinkStarvesLaterSinks`.
**Recommendation**: Rotate the start index, or poke the next due sink after a failure; skip a sink whose last poke failed.

## [A-8] JIT guard covers only reward-currency fees, uses block.number, and keys by router (informational)
**Severity**: Info
**Category**: evm-audit-defi-amm
**Location**: `_jitPenalty()`, `afterAddLiquidity()`, `_positionKey()`
**Description**: Buys' LP fee is in the reward currency, sells' in LING; only the reward side is penalized. Age in block.number (latent on sub-second chains). lastAdded keyed by (poolId, sender, ticks, salt): no cross-user collision for PositionManager; vault-style routers share one clock; no salt dodge.
**Recommendation**: Document reward-only scope; optionally penalize the LING side; consider block.timestamp.

## [A-9] PartialFill turns partial fills of exact-in buys and exact-out sells into reverts (informational)
**Severity**: Info
**Category**: evm-audit-defi-amm
**Location**: `afterSwap()`
**Description**: With the fee taken up front, any fill stopping at a price limit reverts. Correct formula; only semantics for routers relying on limits for partial fills.
**Recommendation**: Document for integrators.

## [A-10] distribute() has no synced-currency guard (caller-only harm); LING-synced routers disable the buyback poke (informational)
**Severity**: Info
**Category**: evm-audit-defi-amm
**Location**: `distribute()` / `_dispatch(OP_DISTRIBUTE)`, `OP_TAKE`
**Description**: `_distributeDuringSwap` checks getSyncedCurrency()==reward; the public distribute() path (direct dispatch when PM already unlocked) does not; a caller syncing the reward then calling distribute() only shrinks its own credit. A router that syncs LING before a sell makes BuybackBurn.poke revert at hook.take(LING), silently disabling the auto-buyback for that swap.
**Recommendation**: Add the synced check to OP_DISTRIBUTE; BuybackBurn skips the poke when LING is synced.

## Checklist coverage
General AMM: state before external calls (fees are PM claims; `distributed += amount` precedes take); flash-loan callbacks (every hook delta nets to zero: beforeSwap/afterSwap/afterRemoveLiquidity/_handOver/_buy/_modify); fee-on-transfer/rebasing (IMD plain OFT; token counts by balance diff); arbitrary calls from user calldata (none; hookData only to council-chosen modules); signed overflow (SafeCast.toInt128, int256.min handled; unchecked add = A-2).
Slippage: no zero-min issue for user swaps; hook buys use spot band (A-6); PartialFill matches formulas (A-9).
Uniswap v4 hooks: permission bits (all 14, validated, immutable); delta signs verified against Hooks.sol; settle before unlock end; entry points onlyPoolManager; unlockCallback gated by slot 2; pool binding (A-4; dynamic-fee pool can never be launch pool); admin-fee blocking swaps (A-2, A-3); loops bounded (8/8); JIT (A-1, A-8); front-runnable dynamic fee (VolatilityFee moved by same-block spot, capped, to holders). Trail of Bits classes: callers ok, user pools ok, custom accounting ok, wrong hook A-1, permission bits ok, exit blocking A-2/A-3, state between callbacks A-5.
Integrating AMMs: PoolManager immutable; hook never custodies tokens; token order handled via rewardIsCurrency0 everywhere.
Concentrated liquidity managers: TWAP absent on liquidity deploy (A-6, bounded); 0.1% slack with leftovers as claims; permanent operator grant and isSink (documented); fees not retroactive.

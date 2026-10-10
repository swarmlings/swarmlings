# Swarmlings audit: evm-audit-general (commit e706550)

Scope read in full: `src/Swarmlings.sol`, `SwarmlingsMirror.sol`, `SwarmlingsHook.sol`, `SwarmlingsCouncil.sol`, `interfaces/IHive.sol`, `modules/*.sol`, `docs/HIVE.md`, `docs/SECURITY.md`, `docs/OPERATIONS.md`, plus the relevant parts of vendored DN404 and v4-core (`Hooks.sol`).
Checklist source: austintgriffith/evm-audit-skills `evm-audit-general/references/checklist.md` (the fetch tool returned a condensed section-by-section list, 15 sections; every section was walked, see "Checklist coverage").
PoCs live in `test/audit/GeneralAudit.t.sol` (new file; `forge test --match-path test/audit/GeneralAudit.t.sol -vv`). Existing suites (Hive, GasCap, Invariant) pass.

Summary: 0 Critical, 0 High, 3 Medium, 6 Low, 7 Info.

---

## [G-1] A malformed return from any attached quoter or sink reverts every swap, sells included
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `SwarmlingsHook._quote()` (SwarmlingsHook.sol:486-493), `SwarmlingsHook._pokeSinks()` (SwarmlingsHook.sol:541-549)
**Description**: docs/HIVE.md ("What is fixed") and docs/SECURITY.md promise that no module can ever revert a sell and that a quoter or sink that fails is "logged, never fatal". The code wraps `quoteFee` and `due()` in `try ... returns (T)`. A Solidity `try/catch` only catches reverts raised inside the callee. If the callee returns successfully with data that fails ABI decoding (fewer than 32 bytes, or a `bool` outside {0,1}), the decoding revert happens in the hook's own frame and is not caught. The same applies to a call to an address without code (the extcodesize check is in the caller). The result: any quoter (`Callbacks.QUOTE`) whose `quoteFee` returns short data, or any poke-enabled sink whose `due()` returns an invalid bool, makes every swap on a charged pool revert, buys and sells alike. This can be accidental (a proxy module whose implementation changes, a module with a `fallback` that returns nothing) or deliberate: the council owner (one EOA, no delay) can attach such a module and trap all sellers until it chooses to remove it, which contradicts the stated guarantee that the council "can never touch ... anyone's ability to sell". If the council has been handed to a slow timelock or frozen (`setCouncil(address(0))`) after a bad attach, the pool is bricked for good.
**Proof of Concept**: `test_malformedQuoterBlocksSells` and `test_malformedDueBlocksSells` in test/audit/GeneralAudit.t.sol.
1. Council executes `setModules([ShortReturnQuoter, callbacks = QUOTE, guard = false])`, where the quoter's fallback does `mstore(0,1) return(0,1)`.
2. Any `_sellExactIn` now reverts inside `beforeSwap` (test asserts `vm.expectRevert()`); after `disableModule` the same sell succeeds.
3. Same with a slice whose sink `due()` returns the word `2` and `poke = true`: the sell reverts in `afterSwap`.
**Recommendation**: do the calls with low-level `staticcall` and decode defensively so malformed data counts as a failure:
```solidity
(bool ok, bytes memory ret) = m.addr.staticcall{gas: MODULE_GAS}(
    abi.encodeCall(IHiveModule.quoteFee, (sender, key, params, buy, hookData)));
if (ok && ret.length == 32) { bps += abi.decode(ret, (uint256)); } else { emit ModuleFailed(m.addr, IHiveModule.quoteFee.selector); }
// due(): same pattern, treat ret.length != 32 or word > 1 as "not due"
```
Use the same pattern as `_runModules` (return data length bounded, see G-4). Optionally also check `code.length` before calling.

---

## [G-2] TwapOracle integrates the previous observation's tick over each interval, so the average lags the price and VolatilityFee over-charges sellers
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `TwapOracle._record()` (modules/TwapOracle.sol:57-73), `TwapOracle._cumulativeAt()` (modules/TwapOracle.sol:92-96), consumer `VolatilityFee.extraNow()`
**Description**: Each observation stores the pool tick as it was before the first swap of its block ("opening tick"), and `_record` accumulates `last.tickCumulative + last.tick * dt`. But the price that held during `[last.timestamp, now)` is the tick after the last block's swaps, which is exactly the opening tick of the new observation, not `last.tick`. (Uniswap v3 uses the new current tick for the elapsed interval.) The same stale tick is used when querying past the newest observation (`_cumulativeAt`, `t >= last.blockTimestamp`) instead of the live `slot0` tick. The struct comment ("valid from blockTimestamp on") is therefore wrong: the stored tick describes the moment before that block's trades. Consequence: after any price move followed by a quiet period the oracle keeps reporting the pre-move price. `VolatilityFee` compares the live tick with that mean, concludes the price is "below its average", and charges every sell the capped surcharge until a full window has passed after the next recorded swap. Sellers pay up to `capBps` (default example 375 bps) extra with no real volatility. The module is not attached at launch, but it is a shipped primitive and any consumer of `consult()` gets a wrong price.
**Proof of Concept**: `test_twapLagsAfterAPriceMove`.
1. Attach `TwapOracle` (BEFORE_SWAP) and `VolatilityFee(window = 1 hour, 50, 375)`; trade every 10 minutes for 2 hours so the oracle has data (opening tick p0 = -177179).
2. One large sell moves the price to tick -182417 (p1). The oracle records p0 for that block.
3. Nothing trades for 2 hours; the price has been p1 for the whole window. `consult(1 hours)` returns -177179 (p0), `extraNow()` returns 375 (the cap). Expected: mean = p1, extra = 0.
**Recommendation**: write the observation with the tick that held over the elapsed interval, i.e. integrate the new (current) tick:
```solidity
int56 cumulative = last.tickCumulative + int56(tick) * int56(uint56(now_ - last.blockTimestamp));
```
and in `_cumulativeAt` for `t >= last.blockTimestamp` use the live tick (`slot0`, converted to LING terms) instead of `last.tick`. Note the hook's own buys (`_buy`) move the price without calling `beforeSwap`; the next recorded tick will include them, which is fine with the corrected formula. Fix the struct comment and add a test that asserts `consult` equals the post-move tick after a quiet window (the existing `test_twapAndVolatilityFee` calls `o.record()` after the dump, which hides this).

---

## [G-3] Creator fees paid in any asset other than ETH (or WETH on mainnet) are stranded forever
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `Swarmlings._syncEth()` (Swarmlings.sol:298-301), `receive()` (Swarmlings.sol:197); `SwarmlingsMirror.royaltyInfo()` (SwarmlingsMirror.sol:124-130)
**Description**: The ERC-2981 receiver is the token itself. Seaport pays creator fees in the sale currency, and the common currencies for offers are WETH and stablecoins. The token only counts ETH (`address(this).balance`) and, only when `block.chainid == 1`, unwraps the hardcoded mainnet WETH. Everything else has no path out: there is no sweep, no rescue and no owner, by design. Concretely: (a) on any non-mainnet deployment (docs/OPERATIONS.md says the system is built to use the same addresses on every chain, with native ETH as the reward off mainnet) WETH royalties are never unwrapped because the mainnet WETH constant is only consulted on chain 1 and the local WETH address is not known; (b) on mainnet, royalties paid in USDC/USDT/other ERC-20 sit in the contract permanently. Holders and DEV lose their share of that revenue. Nothing else in the accounting is affected (the `accounted` ledger only tracks ETH and the reward token).
**Proof of Concept**: Transfer any ERC-20 other than IMD/mainnet WETH to the token (or run on `chainid != 1` and send WETH). `syncEth()`, `syncToken()`, `claim()`, `claimDev()` never touch it and no function can move it.
**Recommendation**: either (1) set the WETH address per chain in the constructor (immutable `weth`, `address(0)` meaning none) and unwrap on every chain, and (2) add a permissionless `sweep(token)` for any ERC-20 other than `rewardCurrency`/`weth`, sending it to a fixed address (e.g. `DEV`) so it cannot be used to steal holder funds; or document loudly that marketplace fee currency must be ETH only and configure the collection accordingly.

---

## [G-4] Observer and guard calls copy unbounded return data into the hook's memory
**Severity**: Low
**Category**: evm-audit-general
**Location**: `SwarmlingsHook._runModules()` (SwarmlingsHook.sol:517 and 523)
**Description**: Both module call sites use `(bool ok, bytes memory ret) = ...call(...)` or `(bool ok,) = ...call{gas: MODULE_GAS}(...)`. With solc 0.8.26 (legacy codegen) the return data is copied to memory even when the tuple slot is omitted, and the copy is paid by the hook, outside the `MODULE_GAS` cap. A module can return a payload of roughly 250 KB for about 200k gas of its own and make the hook pay roughly as much again in memory expansion. `_requireGas` only reserves `MODULE_GAS + MODULE_GAS/63 + 30_000`, so the copy comes from gas the trader must supply on top; every swap that triggers the module becomes more expensive (checklist: return-bomb / gas draining).
**Proof of Concept**: `test_returnBombCostsExtraGas`: a sell with a quiet BEFORE_SWAP observer costs 97,129 gas; with an observer returning 250,000 bytes it costs 403,471 gas (about 306k extra, above the advertised 200k cap).
**Recommendation**: use an assembly call that never copies more than needed:
```solidity
bool ok;
assembly ("memory-safe") { ok := call(MODULE_GAS_CONST, target, 0, add(data, 32), mload(data), 0, 0) }
```
For guards that must bubble up a revert reason, copy at most a fixed number of bytes (for example 256) with `returndatacopy`.

---

## [G-5] A due-but-failing sink starves every later sink and taxes each swap with a failing poke
**Severity**: Low
**Category**: evm-audit-general
**Location**: `SwarmlingsHook._pokeSinks()` (SwarmlingsHook.sol:535-552), `TreasurySink` constructor (modules/TreasurySink.sol:18)
**Description**: `_pokeSinks` stops at the first slice whose `due()` is true (`return` after one poke), whether or not that poke succeeded or did anything. A sink whose `poke()` reverts or is a no-op while `due()` stays true is therefore poked on every swap forever, and the slices after it are never poked from swaps (only by manual `poke()`). Each failing poke also costs the trader gas (up to `POKE_GAS` = 1,000,000 when it runs out of gas), contrary to the docs ("costs the trader nothing"). A realistic trigger: `TreasurySink` accepts any `recipient`, and with a native reward a recipient contract that rejects ETH makes `hook.take` revert on every poke while `claims(reward) >= minCollect` keeps `due()` true. `BuybackBurn` and `AutoLiquidity` can also stay due while their price band absorbs nothing.
**Proof of Concept**: `test_failingDueSinkStarvesLaterSinks`: slice 0 = `TreasurySink` with a recipient that cannot receive ETH, slice 1 = `BuybackBurn`, both `poke = true`. After five buys, `treasury.collected() == 0`, `treasury.due() == true`, `buyback.spent() == 0` and its claims keep accumulating.
**Recommendation**: after a failed or ineffective poke, continue to the next due slice (still poking at most one successful sink per swap), or rotate the starting index per swap (round robin); validate `recipient` in the `TreasurySink` constructor (non-zero, and for native reward able to receive ETH); update docs to state that failed pokes cost gas.

---

## [G-6] One-step, unvalidated hand-over of the council and of the hook's governance
**Severity**: Low
**Category**: evm-audit-general
**Location**: `SwarmlingsCouncil.setOwner()` (SwarmlingsCouncil.sol:50), `SwarmlingsHook.setCouncil()` (SwarmlingsHook.sol:819)
**Description**: Both functions overwrite the privileged address immediately with no pending/accept step. A typo or a wrong-chain address permanently loses the ability to change slices and modules (`setCouncil`) or to operate the council (`setOwner`). `address(0)` is intended ("freeze"), but any other mistaken value is equally irreversible. Because the planned future is "hand to a timelock, multisig or vote", the hand-over is exactly the operation most likely to be mistyped.
**Proof of Concept**: `council.execute(hook, abi.encodeCall(setCouncil, (0xdead...)), "")` succeeds and nothing can ever change the hook again; the same with `council.setOwner(wrongAddress)`.
**Recommendation**: two-step transfer (`pendingOwner` / `acceptOwnership()` in the council; `proposeCouncil` + `acceptCouncil()` called from the new council in the hook), keeping an explicit `renounce` path for the intended freeze. At minimum require `newCouncil.code.length != 0 || newCouncil == address(0)` in `setCouncil`.

---

## [G-7] Modules and sinks capture `launchPool` / `rewardIsCurrency0` at construction without checking the launch pool exists
**Severity**: Low
**Category**: evm-audit-general
**Location**: `HiveSink` constructor (modules/HiveSink.sol:26-35), `TwapOracle`, `VolatilityFee`, `MaxBuy` constructors
**Description**: These contracts copy `hook.launchPool()` and `hook.rewardIsCurrency0()` into immutables. Before the launch pool is bound they return the zero id and `false`. A `BuybackBurn`, `TwapOracle`, `VolatilityFee` or `MaxBuy` deployed too early keeps wrong immutables forever (wrong pool id, wrong direction for `_buyLimit` and tick sign). `AutoLiquidity` happens to revert (zero tick spacing), the others deploy silently and `BuybackBurn.poke` then fails on every swap while due (see G-5). Nothing flags it at attach time because the hook's `setSlices`/`setModules` do not look at the module.
**Proof of Concept**: Deploy `BuybackBurn(hook, 1)` before `afterInitialize` has run, then attach it; `launchPool()` is `0x0` and `rewardIsCurrency0()` is `false` regardless of the real pool.
**Recommendation**: `require(hook_.launchPoolSet(), "not launched")` in every module/sink constructor, or read the values lazily from the hook instead of caching them.

---

## [G-8] Launch pool binding checks the fee tier only; tick spacing is not enforced and the docs disagree
**Severity**: Low
**Category**: evm-audit-general
**Location**: `SwarmlingsHook.afterInitialize()` (SwarmlingsHook.sol:269-280); docs/SECURITY.md ("static fee 12500, tick spacing 60") vs docs/OPERATIONS.md ("any tick spacing (60 requested)")
**Description**: The hook binds to the first LING/reward pool with `key.fee == 12500`, whatever the tick spacing or initial price. Slices, modules, the services (`_launchKey`), the snipe-tax clock (`launchedAt`) and the TWAP all follow that pool. If anyone can initialize a pool with this hook before the intended launch pool, they capture the binding with a junk price or tick spacing, burning the snipe window and pointing buybacks and POL at the wrong pool; the intended pool then only pays the base 1.25%. The risk is currently mitigated by the atomic IMD launch sequence (token and hook are created in the same transaction as `initialize`, so nobody can pre-initialize with an address that has no code yet), but not for non-atomic deployments (the Sepolia test deployment, any later chain) and SECURITY.md describes a stronger rule than the code applies.
**Proof of Concept**: On any deployment where the hook already has code, call `PoolManager.initialize(PoolKey(reward, ling, 12500, 200, hook), anyPrice)` first; `launchPoolSet` becomes true for that key.
**Recommendation**: also require `key.tickSpacing == 60` (and, if desired, an `initialize` caller or price sanity check) in `afterInitialize`, or restrict binding to a constructor-provided pool id; reconcile SECURITY.md and OPERATIONS.md.

---

## [G-9] JIT guard only penalizes reward-currency fees, so liquidity added just before a sell is not penalized
**Severity**: Low
**Category**: evm-audit-general
**Location**: `SwarmlingsHook._jitPenalty()` (SwarmlingsHook.sol:417-434)
**Description**: The penalty is computed on the reward-currency side of `feesAccrued` only. A swap pays its LP fee in its input token, so buys (reward in) accrue reward-currency fees and are covered, but sells (LING in) accrue LING fees, which are never penalized. A JIT LP can add liquidity in the block of a large sell, remove it right after, keep 100% of the 1.25% LP fee in LING and give nothing to holders. The behavior is stated in the docs ("reward fees"), but the feature is presented as a JIT guard and half of the flow bypasses it.
**Proof of Concept**: Add liquidity at block N via a router, let a victim sell LING (input token LING, fee accrues in LING), remove liquidity in block N: `feesAccrued` in the reward currency is 0, `_jitPenalty` returns `ZERO_DELTA`.
**Recommendation**: either state the limitation in docs/SECURITY.md, or penalize the LING side too (take LING-denominated hook delta and mint LING claims for a sink/holder pot), accepting the extra complexity.

---

## [G-10] The `due()` pre-check is not gas-protected, so a trader can skip the sink poke by choosing the gas limit
**Severity**: Low
**Category**: evm-audit-general
**Location**: `SwarmlingsHook._pokeSinks()` (SwarmlingsHook.sol:541-544)
**Description**: `_requireGas` protects every module call, and the poke itself is guarded by `gasleft() < POKE_GAS + POKE_GAS/63 + 30_000 -> revert InsufficientGas`. The preceding `due{gas: 50_000}()` call has no such guard. A trader (or bot) that supplies slightly less gas than the `due()` call needs makes it run out of gas inside the capped call, the `catch {}` swallows it, `due` stays false and the swap completes without paying the roughly 1M gas poke. Result: the poke cost falls on honest, default-gas traders only, and bots can systematically avoid triggering buybacks and POL (they still do the work through `poke()` calls others pay for). No funds are at risk.
**Proof of Concept**: Send a swap with a gas limit just below what the hook needs up to the `due()` call plus 50,000 * 64/63; `due` evaluates to false and no `SinkFailed`/`Burned` event appears.
**Recommendation**: apply the same `gasleft()` check before the `due()` call (revert with `InsufficientGas`), or treat an out-of-gas `due()` as "unknown" and revert.

---

## [G-11] `nextMintIds()` ignores DN404's shrinking id limit after burns
**Severity**: Info
**Category**: evm-audit-general
**Location**: `Swarmlings.nextMintIds()` (Swarmlings.sol:147-156)
**Description**: DN404 wraps NFT ids at `totalSupply / unit` (DN404.sol:531, 845), which shrinks when LING is burned (`burn()`, BuybackBurn). The view wraps at the constant `MAX_NFTS` (3,333), so after burns its prediction can contain ids that the real mint would wrap past. The mint itself is correct (by pigeonhole there is always a free id at or below the limit). Found by reading the code, not run. View only.
**Proof of Concept**: Burn 1% of LING, then compare `nextMintIds(n)` with the ids of the next mints once `nextTokenId` is near the top of the range.
**Recommendation**: use `uint256 limit = totalSupply() / UNIT` in the view.

---

## [G-12] Documentation and comments drift from the code
**Severity**: Info
**Category**: evm-audit-general
**Location**: docs/OPERATIONS.md:75, docs/SECURITY.md:80 (`syncReward`), modules/MaxBuy.sol:10 ("the council's proposal can take effect"), docs/SECURITY.md Launch pool bullet (tick spacing), docs/HIVE.md ("A sink that is not due, or fails, costs the trader nothing")
**Description**: `Swarmlings.syncReward()` does not exist (the functions are `syncEth()` and `syncToken()`); the council has no proposals or delay any more (commit "Instant council"); the tick-spacing rule is described differently in two docs (G-8); failed pokes do cost gas (G-5). Comments that contradict the code mislead integrators and reviewers (checklist section 7).
**Proof of Concept**: `grep -rn syncReward src docs`.
**Recommendation**: update the text.

---

## [G-13] Tokens or claims donated to the hook, sinks and token are absorbed silently; the hook counters stop reconciling
**Severity**: Info
**Category**: evm-audit-general
**Location**: `SwarmlingsHook.pendingFees()` (SwarmlingsHook.sol:248), `_handOver()` (SwarmlingsHook.sol:599-610); docs/SECURITY.md invariants
**Description**: Anyone can mint ERC-6909 claims to the hook (any account inside an unlock can `PoolManager.mint(hook, id, x)` paying for it). `pendingFees()` reads the claim balance, so gifted claims are handed to holders (harmless), but `totalFees == distributed + pendingFees` then no longer holds (`distributed` grows past `totalFees`). The same applies to `sinkFees` and to ETH/IMD sent directly to the token (which is intended: counted as a donation). No funds are at risk; the stated invariant is just not enforceable on-chain.
**Proof of Concept**: In an unlock, `manager.mint(address(hook), rewardId, 1e18)` then settle; `hook.totalFees() < hook.distributed() + hook.pendingFees()`.
**Recommendation**: treat the counters as informational in the docs, or compute `distributed` from actual burned amounts only and expose `pendingFees` separately.

---

## [G-14] Operational and trust notes (no code defect)
**Severity**: Info
**Category**: evm-audit-general
**Location**: various
**Description**:
- The council owner is a single EOA with instant, unannounced changes (documented). Within its documented limits it can route 3.75% of every swap to a sink it picks and install a guard that reverts all buys; with G-1 it can also revert sells.
- `MaxBuy` caps "one swap", so splitting a buy into several swaps (or several wallets) defeats it; it only deters naive single-transaction snipes.
- The snipe window starts at pool initialization (`launchedAt`), not when liquidity is seeded; if seeding happens more than 60 s later the tax is spent before trading is possible. The atomic IMD sequence avoids this.
- `afterSwap` reverts with `PartialFill` for exact-in buys / exact-out sells that stop at a price limit; a sell with such an exact-out limit can revert (the user's own choice, documented).
- `SwarmlingsMirror.transferFrom` is `payable` and forwards `msg.value` to the token, where it is later counted as a creator fee (half to DEV); ETH attached by mistake is not refundable.
- A receiver whose single transfer would mint more than 800 NFTs is silently switched to `skipNFT = true`, and the sender's NFTs are burned: a large OTC move of NFT-backed LING destroys NFTs (documented as "auto skip").
- `MODULE_GAS`, `POKE_GAS` and the 50,000 `due()` stipend are hardcoded; a future gas repricing could make observers fail silently (they only log `ModuleFailed`).
**Proof of Concept**: n/a.
**Recommendation**: keep the documentation of these behaviors prominent, and consider a short timelock on the council when the project matures.

---

## Checklist coverage (checked and found clean unless listed above)

1. External calls and low-level interactions
   - Calls to addresses without code: `_runModules` low-level calls to a code-less module return success and are a no-op (acceptable); `try` calls are covered by G-1. `setSlices`/`setModules` require code at attach time.
   - Return-data bombs: G-4. Hardcoded gas: noted in G-14. Unchecked `.call()` results: `_payEth`, `_payToken`, `Council.execute` all check success; `_payToken` also handles missing return data and non-contracts.
   - `msg.value` in batched/delegatecall flows: none (no delegatecall, no multicall, `addRewards` is a plain payable). `try/catch` forced into catch with controlled gas: `_requireGas` protects module and poke calls; the `due()` hole is G-10. `abi.encodePacked` collisions: only `abi.encodePacked(selector, msg.data[4:])` (one dynamic item, no ambiguity); hashes use `abi.encode`. `delegatecall` to stateful contracts: none. `transfer()/send()`: none in the contracts (the token's `receive` is empty and works with WETH9's 2300-gas `withdraw`).
2. Force-feeding: ETH or IMD forced into the token is counted as a creator fee/donation by design (`address(this).balance - accounted`, no underflow path); ETH forced into the hook is inert (hook accounting uses claims, not balances); gifted claims: G-13.
3. Pause mechanisms: none exist (no pause, no blocklist); council can freeze configuration only.
4. Reentrancy
   - Token: `claim`, `claimDev`, `syncEth`, `syncToken` use a transient lock; state is updated before `_payToken`/`_payEth`; `addRewards` and `_transfer` are reachable during the ETH callback but the ledger is consistent at that point.
   - Hook: services use transient slot 1, unlock callback uses slot 2, swap data slots 3/4 are cleared; the hook's own swaps/liquidity changes skip its callbacks (verified in `Hooks.sol:253,293`).
   - NFT safe-transfer callbacks run after the base state and reward settlement; read-only/cross-contract reentrancy into `pending()` is safe because settlement happens before NFT ownership changes. No ERC-777.
   - Modifier ordering: `nonReentrant` is the only modifier on token functions; on hook services `onlySink` precedes `nonReentrant`, fine.
5. Merkle trees: none.
6. Reveal-gap steering: none; snipe tax and fee bps are fixed in `beforeSwap` and reused in `afterSwap` from transient storage.
7. Code structure: fee math is symmetric between `beforeSwap` (specified) and `afterSwap` (unspecified) and was re-derived for all four swap modes, including v4's `amountToSwap += hookDeltaSpecified` rule; partial-fill check holds. Duplicated slice/module logic is consistent. Comment drift: G-12. Deployment script `DeployCouncil.s.sol` checks the expected address and owner.
8. Arrays and loops: slices/modules capped at 8, duplicates rejected, O(n^2) with n<=8; `_advance` loop is at most three iterations (verified by reading the epoch/jump logic); `keep()` rejects duplicates and non-owned ids (the `i < k` test is exactly the duplicate test); `nextMintIds` is a view only (G-11).
9. Block/time assumptions: epochs are whole UTC days, snipe window is 60 s (proposer drift of seconds is immaterial); JIT window uses block numbers (acceptable: it is a per-block concept); TWAP uses `uint32` timestamps (2106).
10. Comparison operators: `_requireGas` and poke gas checks use `<` against the required total (correct); `snipeBps` returns 0 at `t >= 60`; `bps > MAX_FEE_BPS` cap before the snipe add (as designed); `block.number - added >= JIT_BLOCKS` zero penalty at exactly 10 blocks (consistent with docs); `mint > have + 800` boundary matches the docs (800 allowed).
11. Multi-agent: a sink can only spend its own claims (`msg.sender`-scoped burns); `take(..., to, ...)` lets a sink choose a recipient (sinks are council-chosen); sellers/receivers pointing at the hook, token or PoolManager only strand their own LING. One role per address is not required anywhere.
12. Compiler: solc 0.8.26, EVM cancun (transient storage and MCOPY required, so deploy only on Cancun+ chains); no `unchecked` in project code; casts reviewed (`uint64`, `uint16`, `int128` conversions go through `SafeCast` or are range-bound; `uint128(-r)` only on non-positive deltas).
13. Solidity footguns: `delete _slices/_modules` have no nested mappings; no storage-pointer reassignment; no state shadowing (`owner` parameter in `_jitPenalty` shadows nothing); self-transfer handled in `_transfer` (`from == to` branch) and in `keep`.
14. RareSkills: no fee-on-transfer assumption (rewards counted by balance difference); no ERC4626; no expression upcasting or ternary-type pitfalls found; no downcasts that can truncate silently.
15. Devdacian: no auctions, loans or refinancing; fee rounding is floor-biased toward holders (`holders = fee - toSinks`), no dust-size bypass beyond sub-80-wei trades paying zero fee.
Additional areas verified: reward accounting (`_advance`, `_settle`, per-pot `accounted` ledger) against double counting and rounding; EIP-7702 skip detection; hand-over path `burn`+`take` delta neutrality; sink services' delta neutrality (`_buy`, `_modify`, `_settleSide`); JIT penalty delta neutrality; guard/observer separation (`mayRevert` false on every sell and every removal path).

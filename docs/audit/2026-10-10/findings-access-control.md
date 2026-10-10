# Swarmlings access-control and governance audit (commit e706550)

Scope: `src/SwarmlingsCouncil.sol`, council-gated and sink-gated paths of `src/SwarmlingsHook.sol`, module authorization in `src/modules/*.sol`, privileged paths of `src/Swarmlings.sol` (`claimDev`, `DEV`, `owner()`), `script/DeployCouncil.s.sol`, `docs/HIVE.md` ("What is fixed", "Trust, plainly"), `docs/SECURITY.md`.
Checklists: `evm-audit-access-control` and `evm-audit-governance` (fetched from the austintgriffith/evm-audit-skills repo, all items walked, see "Checklist coverage").
PoC tests: `test/audit/AccessControlAudit.t.sol` (11 tests x 2 pairings, all pass; `forge test --match-path 'test/audit/AccessControlAudit.t.sol' -vv`). No file under `src/` was changed.

Summary: 2 High, 0 Critical, 2 Low, 4 Info. No third party can take funds or change configuration. The weaknesses are in the council owner's power: the documented bound "nothing can ever block a sell or a liquidity removal" does not hold in code, because three council-chosen contract types can make swaps and removals revert or cost more than the EIP-7825 gas cap.

---

## [C-1] A council-chosen quoter or sink can revert every sell (uncatchable revert paths in `_quote` and `_pokeSinks`)
**Severity**: High
**Category**: evm-audit-governance (centralization / single admin can rug), evm-audit-access-control
**Location**: `SwarmlingsHook._quote()` src/SwarmlingsHook.sol:486-493 (`try ... quoteFee ... returns (uint256 extra)` then `bps += extra`); `SwarmlingsHook._pokeSinks()` src/SwarmlingsHook.sol:541-543 (`try IHiveSink(s.sink).due{gas: 50_000}() returns (bool d)`)
**Description**:
HIVE.md ("What is fixed") and SECURITY.md promise that the council "can never touch ... anyone's ability to sell", that "no module can ever revert a sell", and that "an observer or quoter that reverts is skipped and logged". The `try/catch` only catches a revert inside the callee. Three failure modes happen in the hook's own frame and are not caught:
1. Quoter returns a huge value (for example `type(uint256).max`): the success branch executes `bps += extra` (line 489), which panics on overflow. The clamp to `MAX_FEE_BPS` on line 494 runs after the addition, so it never gets a chance.
2. Quoter (or sink `due()`) returns success with return data shorter than 32 bytes (a contract whose fallback returns nothing, or that executes `return(0,0)`): ABI decoding of `uint256`/`bool` fails in the caller. Solidity does not route decoding failures into `catch`. Same for a `due()` that returns a non-canonical bool (value above 1).
3. Both `quoteFee` (it receives the `buy` argument) and `due()` (it can read `hook.currentSwap()` by staticcall, because transient slot 3 is still set while `_pokeSinks` runs, line 349 clears it after) can tell a sell from a buy. A malicious or compromised owner can therefore register a module or sink that is harmless on buys and reverts only on sells. `due()` can additionally branch on `tx.origin` to exempt the owner. That is a sell-only honeypot: buyers get in, holders cannot get out, the owner can.

The council can do this in one transaction (`execute(hook, setModules/setSlices, memo)`), instantly, with no timelock. The Council is the only party that can undo it; if the owner key is lost, or `setCouncil(address(0))` was called, or the owner is the attacker, the sell block is permanent. Quoters and sinks are not required to be contracts the community can audit: any contract with code passes `setModules`/`setSlices`, including a proxy that is upgraded after being registered.

Impact: loss of exit for all holders (unbounded, versus the documented bound of 3.75% of volume plus a 5% total fee). It needs a malicious or compromised council owner, which is the documented trust assumption, but the docs bound that trust far below what the code allows.
**Proof of Concept**: `test/audit/AccessControlAudit.t.sol`
1. `test_poc_quoterOverflowBlocksEverySell`: `execute(hook, setModules([EvilQuoter, QUOTE, guard=false]))` with the quoter returning `type(uint256).max` on sells. `_sellExactIn` and `_sellExactOut` revert (Panic 0x11); buys succeed; `disableModule` restores sells.
2. `test_poc_quoterMalformedReturnBlocksSells`: quoter returns success with empty return data on sells only. Sells revert, buys work. After `setCouncil(address(0))` the revert is permanent.
3. `test_poc_sinkDueMalformedBlocksSells`: `execute(hook, setSlices([{EvilSink, 100, poke:true}]))`, with `EvilSink.due()` reading `hook.currentSwap()` and returning empty data only on sells. Sells revert, buys work.
Run: `forge test --match-path 'test/audit/AccessControlAudit.t.sol' --match-test 'quoter|sinkDue' -vv`.
**Recommendation**:
- In `_quote`, replace `try/catch` with a low-level `staticcall{gas: MODULE_GAS}` and read the reply with assembly: accept only `returndatasize() >= 32`, `returndatacopy` exactly 32 bytes, and clamp: `if (extra > MAX_FEE_BPS) extra = MAX_FEE_BPS;` before adding (or `unchecked` add after the clamp). Treat any other outcome as a logged failure with `extra = 0`.
- Do the same in `_pokeSinks` for `due()`: staticcall with a 50,000 gas cap, require `returndatasize() == 32` and the word to be 0 or 1, otherwise treat as not due.
- Add a test that fuzzes quoter/sink replies (empty, short, long, non-canonical bool, huge value) on the sell path and asserts the sell succeeds.
- Update HIVE.md only after the code actually enforces the claim.

---

## [C-2] A council-chosen observer can make every sell and liquidity removal cost more than the 16.78M-gas transaction cap (return-data bomb)
**Severity**: High
**Category**: evm-audit-governance (single admin can rug via parameters), evm-audit-access-control (centralization)
**Location**: `SwarmlingsHook._runModules()` src/SwarmlingsHook.sol:521-525 (`(bool ok,) = m.addr.call{gas: MODULE_GAS}(data)`), `_requireGas()` src/SwarmlingsHook.sol:531
**Description**:
Observers are meant to be harmless: HIVE.md says they run "under a gas cap; their failure is logged, never fatal", and sells and removals "can never" be blocked. `MODULE_GAS` caps the gas given to the callee, but not the cost the hook pays afterwards. Solidity copies the callee's whole return data into fresh memory on a low-level `call`, even when the result is discarded (`(bool ok,)`). An observer that returns about 280 kB fits inside its 200,000 gas stipend (memory expansion in the callee) and forces the hook to allocate and copy 280 kB per call. The free memory pointer only grows within a callback, so the cost is quadratic in the number of such modules. The council may attach up to `MAX_MODULES = 8` of them, subscribed to `BEFORE_SWAP | AFTER_SWAP` or to the removal callbacks.

Measured in the PoC (gas of one exact-in sell, versus about 95,000 with no modules):
- 6 bomb observers: 13.6M
- 7 bomb observers: 18.0M (above the EIP-7825 cap of 16,777,216)
- 8 bomb observers: 22.95M
A liquidity removal with 8 bombs on the two removal callbacks costs 23.0M. `eth_estimateGas` then fails or exceeds the cap, so on Ethereum mainnet (the stated deployment chain, and the docs themselves cite EIP-7825) no sell and no removal of any LP, including the launcher's, can be mined. `_requireGas()` only checks gas before each call, so it does not prevent this; it also means a trader supplying exactly the minimum gas gets an out-of-gas revert in the hook after the call.
Same precondition and same escape as C-1 (council owner, instant, reversible only by the council).
Lower-level variant: even with a few bombs the sell cost is multiplied by 10 to 100, which is a toll on exits that the docs say is bounded by `MODULE_GAS`.
**Proof of Concept**: `test_poc_returndataBombInflatesSwapGas` and `test_poc_returndataBombBlocksLiquidityRemoval` in `test/audit/AccessControlAudit.t.sol`.
1. `_govern(setModules([8 x BombModule(BEFORE_SWAP | AFTER_SWAP)]))` where `BombModule.fallback()` executes `return(0, 280000)`.
2. A sell uses 22.95M gas (logged), and `swapRouter.swap{gas: 16_777_216}` reverts.
3. With `BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY` the launcher's `modifyLiquidity{gas: 16_777_216}(remove)` reverts; the same call with unlimited gas succeeds and uses 23.0M.
**Recommendation**:
- Make the observer call not copy return data: `assembly ("memory-safe") { ok := call(MODULE_GAS, addr, 0, add(data, 0x20), mload(data), 0, 0) }` (out size 0). Do the same for `_pokeSinks` (`poke`), and for the guard path limit the copied reason to a fixed size (for example 256 bytes).
- Re-check the guard path (line 517): it is uncapped by design for buys, but it must never run on sells or removals (it does not today; keep a test).
- Add a gas regression test: the worst-case sell with 8 hostile observers, 8 hostile quoters and a due sink must stay below a fixed bound (for example 3M gas).
- Independently of the fix, consider a hard `MAX_OBSERVERS` below 8, or a hook-level circuit breaker that stops calling observers when a swap's gas use passes a threshold.

---

## [C-3] Council is one EOA with instant, unconstrained `execute()`; no timelock, no second signer
**Severity**: Low
**Category**: evm-audit-access-control (centralization risks), evm-audit-governance (timelock, multisig)
**Location**: `SwarmlingsCouncil.execute()` src/SwarmlingsCouncil.sol:30-43, `setOwner()` :50-53; owner fixed to DEV `0x92cEf4823119f3332A85A39023eEbA01a06890c4` by `script/DeployCouncil.s.sol:13,17` (council already deployed on mainnet at `0x4d0b...A032`, owner DEV)
**Description**:
The disclosed trust model (docs/HIVE.md "Trust, plainly", docs/SECURITY.md) is accurate for what an honest owner can do; see the "Powers of the council owner" table. Points the docs do not state:
- The same single hot key is also council owner, `Swarmlings.DEV` (receiver of 50% of creator fees, hardcoded, cannot be rotated), the NFT `owner()` for OpenSea (collection page and transfer-validator policy, `Swarmlings.sol:122`, `SwarmlingsMirror.sol:51`) and the deployer of the council. One compromise gives all of these at once.
- There is no delay and no veto window: a malicious change is live in the same block it is submitted, so holders can only react afterwards (and cannot sell if C-1 or C-2 is used).
- `execute()` is a generic call, so the owner is also not limited to the hook: it can make the council a sink (see table), call the PoolManager as the council, and so on. These are harmless on their own but widen what a compromise can combine.
- The docs name a timelock, multisig or holder vote as a later option. Nothing in code prevents attaching sinks, quoters or guards before that happens.
**Proof of Concept**: `test_poc_councilAsSinkTakesOnlyItsSlice`. The owner calls `execute(hook, setSlices([{council, 375, false}]))`, `execute(poolManager, setOperator(hook, true))`, then after a buy `execute(hook, take(reward, dev, claims))` and receives exactly 3.75% of that volume. Taking one wei more reverts. Holders' pending claims and the 1.25% floor are unchanged. Nothing before the slice was set can be taken.
**Recommendation**: Move the council owner to a Safe with at least 3 signers (or a timelock of 24 to 48 hours with a guardian that can only cancel) before the first slice, guard or quoter is attached. Keep DEV, the OpenSea editor and the council owner on different keys. State in HIVE.md that the council owner can use `execute` to call arbitrary contracts. The fixes for C-1 and C-2 should land before relying on "bounded" language.

---

## [C-4] Single-step hand-overs and silent no-op calls in the council and hook
**Severity**: Low
**Category**: evm-audit-access-control (two-step ownership, renounce can brick)
**Location**: `SwarmlingsCouncil.setOwner()` src/SwarmlingsCouncil.sol:50-53; `SwarmlingsCouncil` constructor :19-22; `SwarmlingsCouncil.execute()` :36; `SwarmlingsHook.setCouncil()` src/SwarmlingsHook.sol:819-822
**Description**:
- `setOwner(newOwner)` takes effect immediately with no acceptance step and no zero-address check. A typo (or `address(0)`) locks the council for good; the hook's `council` is still the council contract, so every future configuration change is impossible. The constructor also accepts `address(0)`.
- `hook.setCouncil(newCouncil)` is single-step and unchecked as well: a wrong address (or an EOA key that is lost) freezes the configuration permanently, including any module or quoter that is currently attached. `address(0)` is an intended freeze, but a typo cannot be told apart from it.
- `execute(target, ...)` does not require `target.code.length != 0`. A call to an address with no code succeeds, and `Executed` is emitted with the memo, so the on-chain log can claim a change that never happened.
- Freezing is irreversible while any guard, quoter or observer is attached; a frozen configuration cannot remove a harmful module (see C-1, C-2). The docs present freezing only as a safety feature.
**Proof of Concept**: `test_poc_singleStepOwnershipFootguns`: `execute(address(0xdead), setCouncil(alice))` succeeds and emits one `Executed` log while `hook.council()` is unchanged; after `setOwner(address(0))` every owner-only call reverts with `OnlyOwner`.
**Recommendation**: Use a two-step transfer (`pendingOwner` / `acceptOwnership`) for the council and for the hook's council (`setCouncil` proposes, the new council calls `acceptCouncil`; keep an explicit `freeze()` for `address(0)`). Revert on `address(0)` in the constructor and `setOwner`. Require `target.code.length != 0` in `execute`, or at least emit a flag in the event.

---

## [C-5] A due sink whose `poke()` always fails starves every later sink and wastes gas on every swap
**Severity**: Low
**Category**: evm-audit-governance (reward distribution degraded by admin configuration)
**Location**: `SwarmlingsHook._pokeSinks()` src/SwarmlingsHook.sol:535-552 (`return` after the first due sink, success or not); `TreasurySink.poke()` src/modules/TreasurySink.sol:27-33
**Description**:
Only the first slice with `poke = true` whose `due()` is true is poked, and the loop returns after that attempt even if `poke()` reverted (the revert is swallowed into `SinkFailed`). If that sink can never succeed (for example `TreasurySink` with a recipient that rejects ETH, a zero recipient with an ERC-20 that rejects `transfer(0)`), `due()` stays true forever because its claims never shrink, so the sink is attempted on every swap (up to `POKE_GAS` 1,000,000 consumed by the trade) and no later slice (buyback, auto-liquidity) is ever poked automatically. They can still be poked by hand. `TreasurySink` has no check that its `recipient` is non-zero or can receive, and `minCollect = 0` makes it always due.
**Proof of Concept**: `test_poc_failingDueSinkStarvesLaterPokes` (native pairing): slices `[TreasurySink(recipient = contract that reverts on receive, poke), BuybackBurn(poke)]`, three buys: `BuybackBurn.burned() == 0` and its claims grow, `TreasurySink.due()` stays true.
**Recommendation**: Continue the loop after a failed poke (or remember a per-sink failure and skip it for a number of blocks), count failures in the event, and validate the constructor arguments of the shipped sinks (`recipient != address(0)`, `minCollect > 0`).

---

## [C-6] Sink and module registration performs no semantic validation
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: `SwarmlingsHook.setSlices()` src/SwarmlingsHook.sol:773-788, `setModules()` :791-802
**Description**: Only `code.length != 0`, non-zero values, duplicates and the fee sum are checked. Consequences, all council-only and self-inflicted: (a) `sink == address(hook)` is accepted; the sink share is minted to the hook's own holder claims, `sinkFees` and `totalFees` stop matching `pendingFees` (invariant `totalFees == distributed + pendingFees` breaks, `test_poc_sinkEqualHookBreaksLedger`), and holders in effect receive the sink share; (b) a sink that never called `setOperator(hook, true)` accrues claims that `take` cannot burn until it does; (c) `guard = true` with a module that does not implement the subscribed callback reverts all buys (a guard that reverts is passed through at line 519); `guard = false` on a guard such as `MaxBuy` silently disables it, because the revert is swallowed; (d) `isSink` is set for any slice address and never cleared, which the docs state ("a former sink keeps access"), and is bounded: `_dispatch` always uses `msg.sender`'s own claims, so a removed sink can only move claims it already holds, but those operations (`buy`) bypass fees, `MaxBuy` and the snipe tax by design, because the hook is the swapper.
**Proof of Concept**: `test_poc_sinkEqualHookBreaksLedger` (a); the other cases follow from the code.
**Recommendation**: Reject `sink` values equal to the hook, the PoolManager and the token; optionally require `poolManager.isOperator(sink, hook)` at registration; document that sinks keep access; add an event when `isSink` flips.

---

## [C-7] `disableModule` swap-and-pop changes execution order; MaxBuy and sink parameters are unchecked
**Severity**: Info
**Category**: evm-audit-governance
**Location**: `SwarmlingsHook.disableModule()` src/SwarmlingsHook.sol:805-816; `MaxBuy` constructor and `cap()` src/modules/MaxBuy.sol:26-40; `TreasurySink` constructor; `HiveSink` constructor src/modules/HiveSink.sol:26-35
**Description**:
- Removing module `i` moves the last module into slot `i` (`test_poc_disableModuleReorders`). Quoter totals do not depend on order and observers are independent in the shipped set, but the first reverting guard's reason is whichever comes first, and a third-party observer that relies on running after another one breaks silently. Not exploitable.
- `MaxBuy`: `startAt` and `startCap` are immutable and unchecked. `startCap = 0` blocks all buys until the ramp ends; `startAt` far in the future keeps `startCap` forever; `startCap * 9 * t` can overflow for a huge `startCap` (buys revert). The cap is per swap, so it is bypassed by splitting a buy over several swaps or addresses in one transaction. All are configuration or design limits, not code defects. `MaxBuy` itself checks `msg.sender == hook` in `onAfterSwap` (line 46).
- `HiveSink` reads `launchPool`, `rewardIsCurrency0` and the pool key at construction; a sink deployed before the launch pool exists captures zero values (`AutoLiquidity` then reverts in `minUsableTick(0)`, the other sinks are silently wrong). The launch is atomic per OPERATIONS.md, so this only matters for re-deployments.
**Proof of Concept**: `test_poc_disableModuleReorders` for the ordering.
**Recommendation**: Preserve order in `disableModule` (shift down) or document the swap-pop; add constructor checks (`startCap > 0`, `startAt >= block.timestamp - 1 days`, `hook.launchPoolSet()` in `HiveSink`).

---

## [C-8] Deployment, `COUNCIL` constant and external trust points (verification notes)
**Severity**: Info
**Category**: evm-audit-access-control (deploy scripts), evm-audit-governance (CREATE2 substitution)
**Location**: `SwarmlingsHook.COUNCIL` src/SwarmlingsHook.sol:70; `script/DeployCouncil.s.sol`; `Swarmlings.owner()` src/Swarmlings.sol:122
**Description**:
- `COUNCIL` is bound to the init code: the address is `keccak256(0xff ++ proxy ++ salt ++ keccak256(creationCode ++ abi.encode(OWNER)))`, so only this exact bytecode with this owner can ever live there. `test_councilLivesAtTheConstant` re-derives it, the script requires it before and after deploying, and `bytecode_hash = "none"` / `cbor_metadata = false` keep it reproducible. The broadcast file confirms a mainnet CREATE2 from DEV through the deterministic proxy (tx `0x4b190c82...`, status success). Replacing the contract is not possible; the post-Dencun `selfdestruct` rule removes metamorphic substitution. If the deploy never happens on a chain, `council` has no code and nobody can configure the hook there: the safe default (floor only, no slices, no modules). A change to any council source line or compiler setting changes the address and must change the constant in the same commit.
- The council owner on every chain is the constructor argument, DEV (the same key everywhere); a key loss or compromise therefore affects every chain at once.
- `Swarmlings.claimDev()` (line 246) pays only the constant `DEV`, is permissionless and `nonReentrant`; no argument controls the recipient. A DEV that reverts on receive would block only DEV's own half. `owner()` is `pure` and used by no access check inside the repo (grep: only `SwarmlingsMirror` reads it for metadata); however OpenSea's validator reads the same address to authorise policy changes, which can affect NFT-contract transfers (not LING transfers). SECURITY.md already states this.
- First-come launch binding: `beforeInitialize` accepts any pool and `afterInitialize` binds the first LING/reward pool at fee 12500 to any tick spacing and price; the snipe window also starts there. This is safe only because the launcher deploys the token and initialises the pool in one transaction (OPERATIONS.md step 2). If the launch were ever split, anyone could initialise the pool first with an attacker-chosen tick spacing and price.
- `Hooks.validateHookPermissions` runs in the constructor (line 159) with all 14 flags, so a hook at a wrongly mined address cannot be created. `receive()` accepts ETH only from the PoolManager (line 613-615); forced ETH by `selfdestruct` is harmless because accounting uses PoolManager claims.
**Proof of Concept**: `forge test --match-test test_councilLivesAtTheConstant` (existing); no new exploit.
**Recommendation**: Keep the constant check in CI; add `require(hook.launchPoolSet())` to sink constructors; consider moving DEV (royalty receiver) behind a rotatable address.

---

## Powers of the council owner

Owner = `SwarmlingsCouncil.owner` (DEV EOA). `execute(target, data, memo)` is a plain `target.call(data)` made by the council contract (`SwarmlingsCouncil.sol:36`), so the owner can do exactly what the council address is allowed to do anywhere. The council holds no tokens, no claims and no roles outside the hook.

| Can (code reference) | Bound / note |
| --- | --- |
| Replace the slice table: up to 8 sinks, total up to 375 bps (`setSlices`, SwarmlingsHook.sol:773-788) | Sum checked after the loop; reverts above `MAX_FEE_BPS - HOLDER_FEE_BPS`. Sinks get `fee * s.bps / bps` per swap, so the owner's share is at most 3.75% of future volume. Past claims of other sinks and holders cannot be reached. |
| Make the council or any contract a sink and withdraw its slice (`setSlices` then `take`, :656-658, :702-711) | `test_poc_councilAsSinkTakesOnlyItsSlice`: exactly 3.75% of volume after registration, never more than its own claims. |
| Replace the module list: up to 8 modules (`setModules`, :791-802), remove one (`disableModule`, :805-816) | Any contract with code. Guards (`guard = true`) run uncapped and can revert buys, liquidity additions and donations (`_runModules` lines 516-520). Observers and quoters are meant to be gas capped (see C-1, C-2 for how that fails). |
| Add sell surcharge through a quoter (`_quote`, :473-498) | Total configured fee clamped at 500 bps (line 494). The surcharge goes entirely to holders (`_collect`, :558-574: sinks get their fixed share of the total, holders the rest); `test_poc_sellerQuoterCannotPayTheOwner`. |
| Block buys, liquidity additions, donations with a guard (documented) | Instant. Reversible only by the council. |
| Block sells and liquidity removal | Documented as impossible. In code possible: C-1 (uncatchable quoter/`due()` failures), C-2 (return-data bomb). |
| Hand the council to anyone, or to `address(0)` (`setCouncil`, :819-822) | Irreversible. Single-step (C-4). |
| Hand the council contract to another owner (`setOwner`) | Single-step, no zero check (C-4). |
| Call any other contract as the council (`execute`) | The council has no assets; PoolManager calls such as `setOperator` apply to the council only. |
| Write journal entries (`post`) | Event only. |

| Cannot (claim in HIVE.md) | Verified against code |
| --- | --- |
| Reduce the holder floor (1.25%) | Holds. `bps >= 125 + sum(slices)` always (line 480-494), sink parts are rounded down (line 564), so `holders = fee - toSinks >= fee * 125 / bps`. Extras only add to holders. Test `testFuzz_feeSplitsAcrossModes` plus `test_poc_councilAsSinkTakesOnlyItsSlice` (floor stays 125 bps with 375 bps of slices). |
| Raise the configured fee above 5% | Holds: `if (bps > MAX_FEE_BPS) bps = MAX_FEE_BPS` (line 494), slices capped at 375 (line 786). The snipe tax (up to 40% on buys in the first 60 s) is added after the cap by design (line 495). The cap line is bypassed by the overflow revert only in the sense that the swap reverts (C-1). |
| Change the snipe tax | Holds. `SNIPE_*` are constants; `launchedAt` is written once, guarded by `!launchPoolSet` (line 269-280). |
| Touch the token, pending holder rewards, the hand-over | Holds for state: the hook's only egress for its own claims is `_handOver` (:599-610); services burn only `msg.sender`'s claims (`_dispatch` :683-714 passes `msg.sender`); the token has no privileged entry. The hand-over itself runs in `beforeSwap` for every charged swap, so it stops working if all swaps revert (C-1, C-2). |
| Remove hook-owned liquidity | Holds. `_modify` only takes `liquidity >= 0` (`int256(uint256(liquidity))`, line 736); no other `modifyLiquidity` caller exists in the hook, and `unlockCallback` runs only under the hook's own `tstore(2,1)` (:665, :673-681). Council/PoolManager calls cannot reach the position (owner = hook, salt = sink). Removal by third-party LPs is not blockable by `mayRevert` (false on those paths), but can be priced out of reach by C-2. |
| Block a sell | Does not hold in code: C-1, C-2. |
| Block liquidity removal | Does not hold in code: C-2. |
| Steal from other sinks | Holds. `take`, `buy`, `addLiquidity`, `collectFees` act on `msg.sender`'s claims; the hook is an operator only for sinks that called `setOperator` themselves. |

---

## Checklist coverage

Access control checklist (15 items):
1. Admin can move user tokens: no rescue or sweep function exists; `take` moves only the caller's own claims; `execute` has no value and the council holds nothing. Not present.
2. Instant parameter changes without timelock: present, documented; events exist for every change (`SlicesSet`, `ModulesSet`, `ModuleDisabled`, `CouncilSet`, `Executed`, `OwnerSet`). C-3.
3. Total upgradeability: no proxy; but modules and sinks are arbitrary external code and can be proxies chosen by the council. C-3, C-6.
4. Pausing that blocks critical operations: no pause; equivalent power via guards (buys only) and via C-1/C-2 (sells). C-1, C-2.
5. Corrupted owner can destroy the protocol: yes via C-1/C-2 (exit blocked), bounded otherwise (3.75% routing). C-1, C-2, C-3.
6. Missing access controls on sensitive functions: every state-changing function reviewed. `setSlices/setModules/disableModule/setCouncil` onlyCouncil; services onlySink; callbacks and `unlockCallback` onlyPoolManager; `receive` PoolManager only; `distribute`, `poke`, `collect`, `TwapOracle.record`, `claimDev`, `syncEth/syncToken/addRewards` are intentionally open and cannot redirect value (recipients are fixed). Module callbacks: `MaxBuy.onAfterSwap` and `TwapOracle.onBeforeSwap` check `msg.sender == hook`; `VolatilityFee.quoteFee` is a view; sink `poke` is open by design. No finding.
7. Two-step ownership: not implemented. C-4.
8. Functions taking a user parameter: none (sinks act on `msg.sender`).
9. Whitelist bypass via proxy tokens: `isSink` is address based and never cleared (documented); a sink that is a proxy can change behaviour but can only move its own claims. C-6.
10. Roles granted in constructor but undocumented: council owner and `COUNCIL` constant are documented (HIVE.md, OPERATIONS.md). C-8.
11. No cap on privileged role count: one council, one owner; modules and slices capped at 8. N/A.
12. Renounce ownership can brick: `setOwner(0)` and `setCouncil(0)` freeze configuration; `setCouncil(0)` is intended but irreversible with a harmful module attached. C-4.
13. Initializer on implementation: no proxies or initializers. N/A.
14. Deploy scripts in scope: `DeployCouncil.s.sol` reviewed; asserts address, owner and code. C-8.
15. All agents the same person: owner is also DEV and NFT `owner()`; a sink whose recipient is the owner is the documented TreasurySink flow. C-3.

Governance checklist (all sections walked):
- Flash loan governance, vote buying, proposal creation, quorum, abstain, staked voting power, Dacian DAO/NFT-power items, merkle governance, treasury delegation: no voting, proposals, tokens-as-votes, quorum or merkle logic exists. N/A.
- Proposal execution front-running, expiry, cross-chain execution, block-number deadlines on L2: no proposals; `execute` is immediate. N/A except as part of C-3 (no delay).
- CREATE2 plus proposal substitution / fake proposals: the only CREATE2 binding is `COUNCIL`, bound to its init code (C-8). Module and sink addresses could be metamorphic only before Dencun; with a proxy they can change behaviour after registration (C-6, C-3).
- Timelock: none; no emergency bypass because there is nothing to bypass. C-3.
- Multisig with insufficient signers: 1-of-1 EOA. C-3. Safe module and guard items: no Safe in the repo. N/A.
- Owner renounce traps: C-4.
- Single admin rug via parameters: fee bounded at 5% total and 3.75% to sinks; quoter and guards bounded in effect but not in availability. C-1, C-2.
- Reward distribution (rate rounding, notify before period end, staking equals reward token): token domain, covered by other auditors; LING is never its own reward currency (reward is IMD or ETH). The only governance-adjacent point is C-5.
- Timelock prevents emergency response / unresponsive signers / abandoned-project takeover: the opposite risk applies (no delay, a single key); lost key means no recovery path for a harmful attached module. C-3, C-4.

Reviewed and found sound (no finding): `COUNCIL` binding, `setSlices` fee-sum check and duplicate check, `_collect` division and rounding, `take`/`buy`/`addLiquidity`/`collectFees` caller scoping, `nonReentrant` transient lock on services, `unlockCallback` single-use authorization, constructor `validateHookPermissions`, `receive()` guard, `claimDev` recipient, `TreasurySink.recipient` immutability, events for every privileged change.

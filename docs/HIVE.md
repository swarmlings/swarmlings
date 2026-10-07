# The Hive: financial primitives on the Swarmlings pool

The Swarmlings hook is not one fixed behaviour. It is a small, immutable **router** on the launch pool with
every Uniswap v4 callback enabled, and a library of **primitives** that can be attached to it after launch.
The token you hold, its address and the holders' share never change; what a trade can *do* can grow.

```
                 Uniswap v4 PoolManager
                          │ callbacks (all 14 flags)
                          ▼
   ┌──────────────────────────────────────────────┐
   │ SwarmlingsHook (immutable)                   │
   │  • 1.25% of every swap → NFT holders (fixed) │
   │  • slices: extra fee → sinks   (≤ 3.75%)     │──── services: buy / addLiquidity / collectFees / take
   │  • modules: guards, observers, quoters       │
   │  • config changes only from `council`        │
   └──────────────────────────────────────────────┘
          ▲ owner's calls, at once           ▲ claims minted per swap
   ┌──────────────┐                 ┌─────────────────────────────────────┐
   │ Council      │                 │ sinks: TreasurySink, BuybackBurn,   │
   │ memo + log   │                 │        AutoLiquidity, …             │
   │ journal      │                 │ modules: TwapOracle, MaxBuy,        │
   └──────────────┘                 │          VolatilityFee, …           │
                                    └─────────────────────────────────────┘
```

## What is fixed

| Rule | Where |
| --- | --- |
| 1.25% of every buy and sell goes to NFT holders, in the reward currency, paid by day | `HOLDER_FEE_BPS`, the token's pots |
| The whole hook fee, slices and quoted extras included, is at most 5% | `MAX_FEE_BPS` |
| No module can ever revert a sell or a liquidity removal | `_runModules(…, mayRevert=false)` on those paths |
| Observers and quoters run under a gas cap; their failure is logged, never fatal | `MODULE_GAS`, `ModuleFailed` |
| Sinks spend their share only through the hook's four services; nothing else touches claims | `onlySink`, `_dispatch` |
| Liquidity added by a sink belongs to the hook and has no removal path, ever | `addLiquidity`, no negative delta anywhere |
| Position fees in the reward currency go to holders, LING fees back to the sink | `_settleSide` |
| Configuration changes come only from `council` | `onlyCouncil`, `SwarmlingsCouncil` |
| Snipe tax: buys in the first 60 s pay up to 40% extra, falling to zero, to holders; sells never | `snipeBps()`, `SNIPE_WINDOW`, `SNIPE_MAX_BPS` |
| The council can be handed on or set to `address(0)`, which freezes everything | `setCouncil` |

## Fee flow

For each swap in the launch pool the hook computes a total `bps`:

```
bps = min(125 (holders) + Σ slice.bps + Σ quoter extras, 500)  + snipeBps() on buys
snipeBps() = 4000 × (60 − seconds since the pool opened) / 60, zero after 60 s
```

The fee is charged on the reward-currency side in all four swap modes exactly as before (buys pay `bps` of what
they spend, sells `bps` of what the pool pays out; up-front fees are checked against the realised delta, see
`PartialFill`). It is then split: each slice gets `fee × slice.bps / bps` minted as ERC-6909 claims to its sink,
and holders get the rest, which includes anything a quoter added. `FeeCollected(buy, fee, toHolders, bps)` logs
every swap.

After the swap, every slice with `poke = true` whose sink reports `due()` is poked with `POKE_GAS`. A sink that
is not due, or fails, costs the trader nothing.

## Services for sinks

A sink is a contract that made the hook its ERC-6909 operator. It can call:

| Service | What it does |
| --- | --- |
| `buy(budget, sqrtPriceLimit)` | Burns `budget` of the sink's reward claims and buys LING in the launch pool as the hook (so no fee and no modules run for it). LING comes back as claims; unspent budget too. |
| `addLiquidity(lo, hi, liquidity)` | Opens or grows a position the hook owns under the sink's salt, paid from the sink's claims. Never removable. |
| `collectFees(lo, hi)` | Realises that position's fees: reward → holders, LING → the sink. |
| `take(currency, to, amount)` | Withdraws the sink's own claims to an address (refused while that ERC-20 is mid-settlement for someone else). |

A former sink keeps access, so removing a slice never strands what it already earned.

## Primitives shipped

| Contract | Kind | Behaviour | Parameters |
| --- | --- | --- | --- |
| `TreasurySink` | sink | Forwards its share to one fixed recipient (project funding). | recipient, minimum |
| `BuybackBurn` | sink | Buys LING with its share, within ~1% of the current price, and burns it (`Swarmlings.burn`). What the band does not absorb waits. | minimum budget |
| `AutoLiquidity` | sink | At a threshold, buys LING with half and adds both to a full-range, hook-owned, permanent position. Its reward fees go to holders; LING fees are re-added. | threshold |
| `TwapOracle` | observer, `BEFORE_SWAP` | Records each block's opening tick (in LING terms) before the first swap; `consult(secondsAgo)` returns the mean tick. | – |
| `MaxBuy` | guard, `AFTER_SWAP` | Anti-snipe: from `startAt` and for `ramp` seconds, one swap may buy at most `cap()` LING (grows 10× over the ramp, then unlimited). Buys only. | startCap, ramp, startAt |
| `VolatilityFee` | quoter | Sells pay `bpsPerPercent` extra per percent LING trades below its `window` average, capped; buys never. Fails open. The extra goes to holders. | oracle, window, bpsPerPercent, cap |

None of them is active at launch. The launch configuration is the floor alone: 1.25% to holders, no slices, no
modules.

## Writing a new primitive

- A **sink** inherits `HiveSink` (sets the operator, knows the pool) and implements `due()` and `poke()`.
  Spend only through the services. Keep `poke` under `POKE_GAS` (1,000,000) or it will be skipped in swaps and
  must be called by hand.
- A **module** implements the callbacks for the bits it subscribes to, with the manager's exact argument lists
  (`IHiveModule`). `hook.currentSwap()` tells it whether the swap is a buy, the total bps and, after the swap,
  the fee. Check `msg.sender == hook`. Guards may revert; everything else should stay under `MODULE_GAS`
  (200,000).
- A **quoter** implements `quoteFee(...)` as a `view` returning extra bps. Fail open.

Then the council's owner calls `execute(hook, setSlices or setModules, memo)` and it applies at once.

## Governance

`SwarmlingsCouncil` is deliberately simple: its owner calls `execute(target, data, memo)` and the change is
live in that block, logged with the memo; `post(memo)` writes a journal entry; `setOwner` hands it on. The
owner is the dev wallet at first; it can later be a timelock, a holder vote, a multisig, or nothing
(`hook.setCouncil(address(0))` freezes the configuration forever).

The council lives at the same CREATE2 address on every chain, `SwarmlingsHook.COUNCIL`
(`0x4d0b3507D80f678d9e658Fd5482Ca6a96636A032`, salt `keccak256("swarmlings.council.v1")`, owner
`0x92cEf4823119f3332A85A39023eEbA01a06890c4`), so the hook can name it before it exists;
`script/DeployCouncil.s.sol` deploys it.

## Trust, plainly

Compared with a fully frozen hook, holders now trust the council with three things, all bounded: up to 3.75% of
extra fee may be routed to sinks of its choosing (including a treasury); buys, liquidity additions and donations
may be guarded; and sells may be surcharged up to the 5% total by a quoter. These changes take effect at once,
each logged with a memo. The council can never touch the token, the holders' 1.25%, their pending rewards, the
hand-over path, the snipe tax, or anyone's ability to sell or remove liquidity.

## Launch snipe tax

Bots that buy in the launch block pay the most. For 60 seconds after the pool opens, every buy pays an extra
fee of `4000 × (60 − t) / 60` bps on top of the normal fee: 40% at `t = 0`, 32% one block later, 16% at 36 s,
nothing from 60 s on. It is charged exactly like the other fees (so a buy's `PartialFill` check includes it)
and every wei goes to the holders' pot, which the first real holders receive the next day. Sells in the window
pay the normal 1.25%. The tax is a constant; the council cannot change it.

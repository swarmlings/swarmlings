# Security notes

## Trust assumptions

- **Council.** `SwarmlingsCouncil` (owner: the dev wallet) is the only address that can change the hook's slices,
  modules and council. Changes apply at once and are logged with a memo; there is no delay, so holders trust
  the dev wallet within the limits the code sets: extra fees of at most 3.75% to sinks, guards on buys,
  liquidity additions and donations only, quoted sell surcharges within the 5% total that go to holders. It
  cannot touch the token, the holders' 1.25%, pending rewards, the hand-over, sells or liquidity removal, and
  it cannot change the snipe tax. The owner can hand the council to a timelock or a vote later. See docs/HIVE.md.
- **Modules.** Each attached module is external code chosen by the council. A guard that reverts stops buys; an
  observer, quoter or sink that reverts, runs out of its gas cap, or answers with anything but one clean word
  is skipped and logged, and its return data is never copied, so no module can make a swap revert or cost more
  than its gas cap. Sinks can spend only their own claims and only through the hook's services, at most once
  per block; liquidity they add is owned by the hook with no removal path.

- **Launch pool.** The hook binds to the first pool pairing LING with the reward currency at the launch tier
  (static fee 12500, any tick spacing). Other tiers cannot take its place, and the IMD launcher creates the
  real one in the same transaction that deploys the hook, so nothing can bind first. Every other LING / reward
  pool with the hook pays the holder fee as well.
- **Marketplace layer.** `owner()` returns DEV for marketplaces. On OpenSea that address edits the collection
  page and off-chain fee settings, and in OpenSea's validator it can change this collection's transfer policy,
  up to blocking transfers made through the NFT contract. None of that can touch LING balances, swaps or
  rewards, and LING transfers always move NFTs, so holders can never be locked out of moving their Swarmlings.
- **Permit2.** DN404 gives Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) an infinite default
  allowance over LING, as most Uniswap-era tokens do; a Permit2 signature moves LING (and the NFTs with it).
  Holders can revoke it with `approve(PERMIT2, 0)`.
- **Contracts holding NFTs.** Rewards belong to the holding address and only it can claim (`claim`,
  `claimEth`, `claimToken`). An NFT sent to a contract with no claim path forfeits its rewards.
- **Validator.** OpenSea's registry is external code with its own administrators. It only ever sees NFT
  transfers made through the NFT contract; if it ever refused them, holders still move NFTs by moving LING.
- **Reward currency.** IMD on mainnet (`BridgedFP`, a LayerZero OFT, verified on Sourcify) has no pause,
  blocklist or fee switch: transfers cannot be stopped, so hook-owned liquidity and holder payouts cannot be
  frozen by its owner. Its owner (`0x047F…54B7`) controls the bridge peers and delegate, so bridged supply is a
  trust point, and can rename the token. The token counts rewards by balance difference, so even a
  fee-on-transfer token would be counted correctly.
- **Renderer.** Immutable, no owner. The token calls it only in `tokenURI`, via a staticcall wrapped in
  try/catch; it cannot affect balances, transfers, fees or rewards.

## Invariants (checked by `test/Invariant.t.sol`)

- Hook: `totalFees == distributed + pendingFees` for the holders' part, `sinkFees` equals what was minted to
  sinks, and the hook never holds the reward currency outside the PoolManager.
- Token: every claim is booked; everyone's `pending` plus DEV's share never exceeds the balance; once every day has paid out, everything added for holders is claimed or claimable up to rounding dust.
- Every wallet's NFT count equals `balance / UNIT`; only wallets hold NFTs; at most 3,333 exist.

## Design choices worth reviewing

- **EIP-7702 wallets.** DN404 treats any code-bearing account as a contract that skips NFTs. A delegated EOA has
  exactly 23 bytes of code starting with `0xef0100`, a prefix EIP-3541 forbids for deployed contracts, so the
  token treats such accounts as wallets. A wallet's explicit `setSkipNFT` still wins.
- **Charged pools.** Fees apply to every LING / reward pool with this hook, so a fee-free tier cannot be
  opened; modules and sinks only run on the launch pool, whose binding is still first-come at the launch tier.
- **JIT penalty.** `afterRemoveLiquidity` returns a hook delta equal to the reward-currency fees of a position
  that leaves within `JIT_BLOCKS` of its last addition (scaled down linearly) and mints the same amount as
  holder claims; the LP's principal and LING fees are untouched, and nothing can revert. The hook's own
  positions are never penalized because v4 skips the hook's callbacks for its own actions.
- **One poke per swap.** At most one sink is poked successfully after a swap, starting from a rotating cursor
  so a sink that stays due cannot starve the others; a failed poke is logged and the next due sink tried; a
  swap with too little gas left simply skips the poke. Sinks act at most once per block.
- **Nested swaps.** A module may swap in another pool while a swap is in flight. Swap state (bps, buy flag,
  fee) is kept per nesting depth in transient storage, and modules and pokes only run for the outermost swap.
- **JIT guard on both sides.** Adding to a position collects its fees as well, so the penalty applies in
  `afterAddLiquidity` and `afterRemoveLiquidity` alike.

- **Snipe tax.** `snipeBps()` is a pure function of time since `launchedAt`: 40% at the launch block, linear to
  0 at 60 seconds, buys only, added after the council cap so the cap stays a bound on governance, not on
  launch protection. It is charged by the same code paths as every other fee, so `PartialFill` and the split
  apply unchanged; everything it collects is holder revenue.

- **Hook-owned actions.** Sinks never call the PoolManager for swaps or liquidity; the hook does, as
  `msg.sender`, and v4 skips a hook's own callbacks for its own actions, so a buyback pays no fee and runs no
  module. Claims are burned from the sink (the hook is its operator) and remints cover leftovers, so the hook's
  delta nets to zero in every service.
- **Gas for modules.** Observers and quoters get exactly `MODULE_GAS`; the hook reverts with `InsufficientGas`
  if a swap brings less, so a trader cannot starve an oracle of gas on purpose. Sinks are poked only when
  `due()`.
- **Current swap in transient storage.** The total bps (with the buy flag) travels from `beforeSwap` to
  `afterSwap` in slot 3, the fee for after-swap modules in slot 4; both are cleared before the callback
  returns.

- **Day-by-day payout.** Rewards that arrive on one UTC day are paid the next day at a constant rate to the
  NFTs that exist; accrual runs before every change of the NFT count, so the count is constant between
  accruals. This removes any edge from holding at the moment of a hand-over (an independent review showed a
  flash-borrowed position could otherwise take ~47% of a distribution; `test_flashBorrowedNftsEarnNothing`
  covers it) and, unlike a rolling stream, pays each day's amount out completely.
- **`keep(ids)`.** Swaps entries in DN404's owned list and the matching owned-index entries; owner aliases and
  the mirror are untouched, so ownership never changes. Rejects ids the caller does not own and duplicates.
- **Auto skip.** The 1,000-NFT guard runs before DN404's own transfer logic; it only flips the receiver's skip
  flag, which DN404 already lets anyone set for themselves.
- **Hand-over inside `beforeSwap`.** Pending claims are burned and the reward is `take`n straight to the token
  (the burn credits the hook exactly what `take` debits). It is skipped if the manager holds too little of the
  currency at that moment, or, for an ERC-20, if that currency is currently synced for settlement (taking it
  then would shrink the payer's credit). `syncReward` is called in try/catch so a swap never depends on it.
- **Per-owner settlement.** Rewards settle in the overridden `_transfer` and `_transferFromNFT`, the only
  DN404 paths that change NFT ownership after construction. Mint and burn happen inside `_transfer`.
- **Partial fills.** When the fee is taken on the specified amount up front, `afterSwap` requires the raw pool
  delta to equal `amountSpecified + fee` (at the bps fixed in `beforeSwap`), so a price limit cannot leave a
  fee on an unswapped amount.
- **Large buys.** Minting is linear in NFTs: about 1.46M gas for 100 NFTs locally. A wallet buying
  thousands of units at once should `setSkipNFT(true)` first.

## Audit

An eight-domain review on the ethskills audit methodology (general, precision math, AMM / v4 hooks, ERC-20,
ERC-721, access control and governance, DoS, flash loans) plus a CROPS review was run on commit `e706550`
on 2026-10-10; the report, the per-domain findings and their proof-of-concept tests are in
[docs/audit/2026-10-10](audit/2026-10-10/). No Critical finding. Every High and Medium needed a malicious or
broken module chosen by the council; all were fixed in the following commit with regression tests
(`test_audit_*`). Accepted: the council is a single key with no delay (the user's choice), the launch-pool
binding trusts IMD's atomic launch, Permit2's default allowance, and the OpenSea editor's validator powers.
No live-chain rehearsal of the launch itself has happened yet; mocks stand in for IMD in tests.

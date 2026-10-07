# Security notes

## Trust assumptions

- **Council.** `SwarmlingsCouncil` (owner: the dev wallet) is the only address that can change the hook's slices,
  modules and council, through a two-day timelock with a public memo. Its powers are bounded in code: extra
  fees of at most 3.75% to sinks, guards on buys, liquidity additions and donations only, quoted sell
  surcharges within the 5% total that go to holders. It cannot touch the token, the holders' 1.25%, pending
  rewards, the hand-over, sells or liquidity removal. `disableModule` needs no delay. See docs/HIVE.md.
- **Modules.** Each attached module is external code chosen by the council. A guard that reverts stops buys; an
  observer or quoter that reverts is skipped and logged. Sinks can spend only their own claims and only through
  the hook's services; liquidity they add is owned by the hook with no removal path.

- **Launch pool.** The hook binds to the first pool pairing LING with the reward currency at the launch tier
  (static fee 12500, tick spacing 60). Other tiers are ignored, so a junk pool cannot take its place; the IMD
  launcher still creates the real one in its deployment transaction.
- **Marketplace layer.** `owner()` returns DEV for marketplaces. On OpenSea that address edits the collection
  page and off-chain fee settings, and OpenSea's validator lets it change this collection's transfer policy.
  None of that can touch LING balances, swaps or rewards, and LING transfers always move NFTs.
- **Validator.** OpenSea's registry is external code with its own administrators. It only ever sees NFT
  transfers made through the NFT contract; if it ever refused them, holders still move NFTs by moving LING.
- **Reward currency.** IMD on mainnet is assumed to be a plain ERC-20 (`transfer` returns true or nothing).
  The token counts rewards by balance difference, so a fee-on-transfer token would still be counted correctly.
- **Renderer.** Immutable, no owner. The token calls it only in `tokenURI`, via a staticcall wrapped in
  try/catch; it cannot affect balances, transfers, fees or rewards.

## Invariants (checked by `test/Invariant.t.sol`)

- Hook: `totalFees == distributed + pendingFees` for the holders' part, `sinkFees` equals what was minted to
  sinks, and the hook never holds the reward currency outside the PoolManager.
- Token: every claim is booked; everyone's `pending` plus DEV's share never exceeds the balance; once every day has paid out, everything added for holders is claimed or claimable up to rounding dust.
- Every wallet's NFT count equals `balance / UNIT`; only wallets hold NFTs; at most 3,333 exist.

## Design choices worth reviewing

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

## Not done

No external audit or live-chain rehearsal of this repository has happened yet. Mocks stand in for IMD in
tests.

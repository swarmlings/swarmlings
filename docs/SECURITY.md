# Security notes

## Trust assumptions

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

- Hook: `totalFees == distributed + pendingFees` and the hook never holds the reward currency.
- Token: every claim is booked; everyone's `pending` plus DEV's share never exceeds the balance; once all
  streams have ended, everything added for holders is claimed or claimable up to rounding dust.
- Every wallet's NFT count equals `balance / UNIT`; only wallets hold NFTs; at most 3,333 exist.

## Design choices worth reviewing

- **Streaming.** Rewards accrue per second to the NFTs that exist; accrual runs before every change of the NFT
  count, so the count is constant between accruals. This removes any edge from holding at the moment of a
  hand-over (an independent review showed a flash-borrowed position could otherwise take ~47% of a
  distribution; `test_flashBorrowedNftsEarnNothing` now covers it).
- **Hand-over inside `beforeSwap`.** Pending claims are burned and the reward is `take`n straight to the token
  (the burn credits the hook exactly what `take` debits). It is skipped if the manager holds too little of the
  currency at that moment, or, for an ERC-20, if that currency is currently synced for settlement (taking it
  then would shrink the payer's credit). `syncReward` is called in try/catch so a swap never depends on it.
- **Per-owner settlement.** Rewards settle in the overridden `_transfer` and `_transferFromNFT`, the only
  DN404 paths that change NFT ownership after construction. Mint and burn happen inside `_transfer`.
- **Partial fills.** When the fee is taken on the specified amount up front, `afterSwap` requires the raw pool
  delta to equal `amountSpecified + fee`, so a price limit cannot leave a fee on an unswapped amount.
- **Large buys.** Minting is linear in NFTs: about 1.46M gas for 100 NFTs locally. A wallet buying
  thousands of units at once should `setSkipNFT(true)` first.

## Not done

No external audit or live-chain rehearsal of this repository has happened yet. Mocks stand in for IMD in
tests.

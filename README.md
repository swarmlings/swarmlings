# Swarmlings (LING)

3,333 hand-drawn robots, printed in riso and rendered fully onchain, that live inside a token balance.
Hold 300,000 LING and a Swarmling appears in your wallet; sell below that and it is gone. Every buy and
sell pays 1.25% to the people who hold Swarmlings, and NFT sales pay a 5% creator fee, half of it to them too.

There is no owner, admin, proxy, pause or upgrade anywhere. Nothing can be changed after deployment.

## Contracts

| Contract | What it does |
| --- | --- |
| [`Swarmlings`](src/Swarmlings.sol) | DN404 token + `DN404Mirror` NFT. 1,000,000,000 LING, 18 decimals, minted once to the deployer. 300,000 LING = 1 NFT, at most 3,333. Holds and pays out NFT rewards. |
| [`SwarmlingsMirror`](src/SwarmlingsMirror.sol) | The ERC-721 side (DN404 mirror): 5% creator fee (ERC-2981) to the token and OpenSea creator-fee enforcement (ERC721-C). |
| [`SwarmlingsHook`](src/SwarmlingsHook.sol) | Uniswap v4 hook (flags `0x10CC`). Takes 1.25% of every swap in the launch pool, in the paired currency, and gives all of it to NFT holders. |
| [`SwarmlingsRenderer`](renderer/) | The art, deployed separately at the same CREATE2 address on every chain. Immutable; derives 7 traits from a fixed seed per id. |

### The token

- **NFTs follow the balance.** A wallet holding `n × 300,000` LING owns `n` Swarmlings. Buying across a unit
  mints, selling below one burns. Transfers between NFT holders move NFTs directly.
- **Contracts skip NFTs** (DN404 default), so the factory, the PoolManager, routers and distributors never hold
  any. Any contract, or an EIP-7702 delegated wallet, can opt in with `setSkipNFT(false)`.
- **Plain transfers.** No fee or burn on transfer; every transfer moves exactly the amount stated.
- **Art:** `tokenURI(id)` returns exactly what the renderer returns. If the renderer has no code or reverts,
  it returns a minimal valid JSON instead of reverting. The renderer can never touch balances or rewards.

### Rewards

Holders earn two things, equally per NFT and **per second held**:

| Source | Currency | Split |
| --- | --- | --- |
| Swap fees: 1.25% of every buy and sell | IMD on Ethereum mainnet (native ETH on testnets) | 100% to holders |
| Creator fee: 5% of every NFT sale on marketplaces (ERC-2981) | ETH (WETH is unwrapped) | 50% holders, 50% `DEV` |

- **Streamed.** Every amount that reaches the token is paid out evenly over 24 hours to whoever holds NFTs
  during that time. Holding for a moment earns a moment's share, so flash loans and buying right before a
  distribution earn nothing extra. With no NFT in existence, the stream waits and joins the next one.
- **Settled on every move.** Before any NFT changes owner (ERC-20 transfers, mints, burns, marketplace NFT
  transfers), both sides are settled. A seller keeps everything their NFTs earned; a buyer earns from then on.
- **Claim:** `pending(holder)` returns `(eth, token)`; `claim()` pays both. `claimDev()` sends DEV its half of
  the creator fees (anyone may call it; the ETH only goes to DEV). DEV never receives swap fees.
- Plain ETH sent to the token counts as a creator fee at the next `syncEth()` (anyone; `claim` runs it too).
  The hook sends swap fees with `addRewards()` (ETH) or as IMD followed by `syncToken()`.
- Traits are cosmetic. Every NFT earns the same share.

### Creator fees on NFT sales

- The NFT contract (`SwarmlingsMirror`) reports a 5% royalty to the token (ERC-2981) and implements OpenSea's
  creator-fee enforcement (ERC721-C): every NFT transfer made through the NFT contract is checked by OpenSea's
  transfer validator `0xA000027A9B2802E1ddf7000061001e5c005A0000`. Owners can always move their own NFTs;
  marketplaces must be authorized (OpenSea authorizes orders that pay the fee). The validator is a constant.
- **Limits, by design:** moving LING moves NFTs too (DN404), and that path is never validated, so holders can
  never be locked out, but a sale settled by transferring LING pays no creator fee. Marketplaces that are not
  authorized by the validator cannot transfer the NFT.
- `owner()` returns `DEV` so OpenSea Studio recognises the collection editor. It has no power in these
  contracts; on OpenSea it controls the collection page and the off-chain fee settings, and in OpenSea's
  validator it can change this collection's transfer policy (LING transfers stay unaffected).
- **Trust point:** OpenSea's fee settings live off-chain with the collection editor. The 50/50 split holds as
  long as the creator-fee payout is the token address; anyone can check it in OpenSea's collection API
  (`fees[].recipient`).

### Which NFT burns, and how to keep one

Selling burns from the end of the wallet's list, the most recently received first, and a burned id is minted
again later to someone else. Sending an NFT to yourself moves it to the end of your list. To keep a favourite,
send your other NFTs to yourself first: they move behind it and burn before it.

### The hook

- Constructor: the chain's PoolManager and the token. The first pool that pairs LING with the token's reward
  currency at the launch tier (static 1.25% LP fee) becomes `launchPool`; pools at other tiers or with a
  dynamic fee trade fee-free and cannot take its place.
- **Fee:** `FEE_BPS = 125`, always in the reward currency, in all four swap modes: buys pay 1.25% of
  everything they spend, sells pay 1.25% of what the pool pays out. A swap that took its fee up front but did
  not fill completely reverts (`PartialFill`).
- Fees are minted as ERC-6909 claims during the swap. Once `minDistribute` has accrued (0.01 ETH, or 5 IMD),
  the next swap hands them to the token; `distribute()` does the same for anyone. The hook keeps nothing.

The total cost of a swap is 2.5%: 1.25% to NFT holders (this hook) and the pool's own 1.25% LP fee
(1% to the launch payer, 0.25% to IMD).

## Build and test

```sh
forge build
forge test
```

Solidity 0.8.26, Cancun, optimizer 200 runs, no IR, `bytecode_hash = "none"`. Dependencies are vendored
under `lib/` (see [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)); tests need no network or RPC.

The suite (119 tests) runs against a real v4 PoolManager in three pairings (native ETH; IMD as currency0;
IMD as currency1): all four fee modes with exact amounts, partial fills, other pools and launch-pool
hijacking, unit boundaries (299,999.99 vs 300,000 LING), contracts and EIP-7702 wallets skipping NFTs,
marketplace NFT sales, burns and the keep-a-favourite trick, streaming by time held, a flash-loan attempt to
snipe a distribution, rewards with no holders, creator fees split with DEV, both currencies on mainnet, a
LING-only seeded pool, a 100-NFT whale buy, reentrancy on `claim`, the validator, the renderer fallback, and
stateful invariants (hook ledger, solvency, booked claims, NFT counts, nothing lost once streams end).
`test/fork/` repeats the validator and IMD checks against the real mainnet contracts when
`MAINNET_RPC_URL` is set.

## ABIs

`docs/abi/<Contract>.json` holds the ABI of each contract (generated with `forge inspect <Contract> abi --json`).

## Launch

[`launch.json`](launch.json) is the IMD `univ4_hook` manifest for Ethereum mainnet, paired with IMD. Deployment notes, the renderer's CREATE2
deployment and the trust assumptions are in [docs/OPERATIONS.md](docs/OPERATIONS.md) and
[docs/SECURITY.md](docs/SECURITY.md).

Links: [imd.fun](https://imd.fun) · [x.com/SwarmlingsIMD](https://x.com/SwarmlingsIMD)

MIT licensed.

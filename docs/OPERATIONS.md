# Deployment and operations

## Fixed parameters

| Parameter | Value |
| --- | --- |
| Token / symbol / decimals | Swarmlings / LING / 18 |
| Supply | `1e27`, all to the constructor caller, who skips NFTs |
| Unit / max NFTs | `300,000e18` / 3,333 |
| Swap-fee reward | native ETH (address 0) unless `block.chainid == 1`, then IMD `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Creator fee | 5% (ERC-2981) to the token: 50% streamed to holders in ETH, 50% to DEV, the dev and treasury wallet `0x92cEf4823119f3332A85A39023eEbA01a06890c4` (also the launch payer, so it collects the pool's 1% LP fee through the IMD launcher) |
| Transfer validator | OpenSea `0xA000027A9B2802E1ddf7000061001e5c005A0000`, fixed |
| Reward payout | what arrives on one UTC day is paid out over the next day, per NFT per second |
| Keep | `keep(ids)` puts the named ids first in the caller's list (last to burn) |
| Auto skip | a transfer that would mint more than 1,000 NFTs switches the receiver to skipNFT instead |
| Renderer | `0x8d79e6677FA6E52190B39096f8496628811D8281` (CREATE2, see below) |
| Hook constructor | `($poolManager, $token)` |
| Hook flags | all 14 (`0x3FFF`), so later modules can use any callback |
| Hook fee | `HOLDER_FEE_BPS = 125`: buys pay 1.25% of what they spend, sells 1.25% of what the pool pays out; slices and quoters may raise the total to `MAX_FEE_BPS = 500` at most |
| Council | `SwarmlingsHook.COUNCIL = 0x4d0b3507D80f678d9e658Fd5482Ca6a96636A032` (CREATE2, salt `keccak256("swarmlings.council.v1")`, owner DEV); changes apply at once |
| Snipe tax | buys in the first 60 s after the pool opens: extra `SNIPE_MAX_BPS = 4000` falling linearly to 0 (`snipeBps()`), to holders; sells exempt |
| Modules at launch | none; see docs/HIVE.md for the shipped primitives and how they are attached |
| Hand-over minimum | 0.01 ETH, or 5 IMD |
| Launch pool | reward currency / LING, static LP fee 12500 (IMD policy tier), any tick spacing (60 requested); other tiers are ignored |
| Compiler | solc 0.8.26, Cancun, optimizer 200, `via_ir = false`, `bytecode_hash = "none"`, `cbor_metadata = false` |

## Sequence

1. Deploy the renderer (once per chain, before or after the launch; see below).
2. In the launcher's atomic transaction: deploy `Swarmlings` (zero arguments), mine and deploy
   `SwarmlingsHook(poolManager, token)` at an address whose low 14 bits are all set (`0x3FFF`), then initialize
   the reward-currency / LING pool with the hook at fee 12500. The hook binds to the first such pool it sees
   and ignores every other tier.
3. Seed liquidity. A LING-only seed works: fees are minted as claims, and the hand-over waits until the
   manager holds enough of the reward currency.
4. Requested economics: `poolBps: 9000` (pool 90%, swarm 10%, nothing to the requester). With the default
   remainder the requester's EOA would receive 100,000,000 LING and mint 333 NFTs inside the launch
   transaction.
5. Deploy the council (once per chain, any time): `forge script script/DeployCouncil.s.sol --rpc-url $RPC_URL
   --private-key $TREASURY_PRIVATE_KEY --broadcast`. Until it has code, nothing can change the hook.
6. To attach a primitive: deploy it (its constructor takes the hook), then from the dev wallet
   `council.execute(hook, abi.encodeCall(setSlices or setModules, …), memo)`; it applies at once.
   `council.post(memo)` writes a journal entry.

## Gas on Sepolia

Sepolia (reth, a newer fork) prices contract creation far above mainnet: `eth_estimateGas` gives about 26.5M
gas for the token with its NFT contract (mainnet about 3.8M) and about 9.6M for the hook (mainnet about 1.3M).
IMD's launch preflight caps a transaction at 16,777,216 gas, so this project cannot launch through IMD on
Sepolia; it fits on mainnet. Test deployments on Sepolia work outside IMD with a high gas limit.

Minting is linear in NFTs: about 11.9M gas for 1,000 NFTs in one transfer on mainnet. A transfer that would
mint more than 1,000 switches the receiver to skipNFT instead of reverting (see README).

## Renderer

`renderer/` is the art contract, a byte-for-byte port of the reference renderer with all 3,333 ids
parity-tested. It is deployed through the deterministic deployment proxy
`0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `keccak256("swarmlings.renderer.v1")`
(`0x5dde17176ece21aada04a91acb5e84954a0b1d1839f25a199dd617e7716ff248`), which gives
`0x8d79e6677FA6E52190B39096f8496628811D8281` on every chain for the committed bytecode
(init code hash `0xecabf6de8bfc120dde1c664959c467dec1a250e029e69f910ccfef8f9542ceb2`).
The token only staticcalls `tokenURI(id)` on it; until it has code, `tokenURI` returns
`data:application/json;utf8,{"name":"Swarmling #id"}`.

## Running it

There is no keeper. Sinks that are due are poked inside swaps; anyone may also call a sink's `poke()` or
`collect()`.

- Trades hand pending fees to holders on their own once the minimum is reached.
- Anyone may call `SwarmlingsHook.distribute()` (reverts below the minimum) and `Swarmlings.syncReward()`.
- Holders call `Swarmlings.claim()`.
- Reward currency sent to the token by anyone is shared with holders at the next sync; plain ETH counts as a
  creator fee (half to DEV).
- After launch, DEV can open the collection in OpenSea Studio (the NFT contract reports DEV as `owner()`), set
  the creator earnings to 5% paid to the token address, and turn on enforcement there if OpenSea asks for it.

## Deployments

| Chain | Contract | Address |
| --- | --- | --- |
| Ethereum mainnet | SwarmlingsRenderer (CREATE2) | `0x8d79e6677FA6E52190B39096f8496628811D8281` (tx `0x20f1d64795f947d618b3c56d1f82d668e38430ba9093501e3f0e225f38c6a96b`) |
| Sepolia | SwarmlingsRenderer (CREATE2) | `0x8d79e6677FA6E52190B39096f8496628811D8281` |
| Sepolia (test, outside IMD) | Swarmlings | `0xA8f8a18e5E85639C46790B31d4f0ac2144Bf1dfC` |
| Sepolia (test, outside IMD) | SwarmlingsMirror | `0x5EAee7e97d7c22C704814B884A738bfE18DF4cfd` |
| Sepolia (test, outside IMD) | SwarmlingsHook | `0x3c0932BE7ad02A2E74C6fb16040B684F1d7910Cc` |

The Sepolia test pool is native ETH / LING at fee 12500, tick spacing 60, pool id
`0xfcb32948f4fb35898800b453dea13820d3d3d84fa88ea2dbc30f8b5a23d45b22`. Checked there with real transactions:
buys minting NFTs with renderer art, the exact 1.25% fee, the automatic hand-over inside a swap once 0.01 ETH
had accrued and its queueing for the next UTC day, `keep` in one transaction followed by a sell that burned the
others first, the creator-fee split and `claimDev`, and the 1,000-NFT auto skip. Mainnet addresses will be
added after the IMD launch.

# Swarmlings audit report (ethskills methodology), 2026-10-10

Scope: commit `e706550` of github.com/swarmlings/swarmlings: `Swarmlings.sol` (DN404 token), `SwarmlingsMirror.sol`,
`SwarmlingsHook.sol` (the Hive), `SwarmlingsCouncil.sol`, `src/modules/*`. Method: the ethskills `audit` pipeline
(evm-audit-skills checklists) with one reviewer per domain: general, precision-math, defi-amm, erc20, erc721,
access-control + governance, dos, flashloans; plus a CROPS review. Every reviewer wrote proof-of-concept tests
(kept under `audit/2026-10-10/poc/`, written against `e706550`). Findings were de-duplicated below and fixed in
the follow-up commit; the "Status" column says what happened.

No Critical findings. Nothing lets a third party take funds or freeze the pool. Every High and Medium needed
either the council owner (a single key) or a module the council attached; the fixes close those paths so the
documented guarantees ("no module can block a sell or a liquidity removal", "the holders' 1.25% is fixed")
hold against a malicious module too.

## Findings

| ID | Severity | Title | Status |
| --- | --- | --- | --- |
| C-1 / A-2 / D-1 / G-1 / M-2 | High | A council-chosen quoter or sink could revert every swap, sells included: `bps += extra` overflowed before the cap; a `quoteFee`/`due()` answering with malformed or no data reverted the hook's ABI decode outside `try/catch`. | **Fixed.** Quoters and `due()` are raw gas-capped `staticcall`s that read one word and require ≥32 bytes back; the extra is clamped to `MAX_FEE_BPS` before it is added; anything else counts as "no extra" / "not due" and logs `ModuleFailed`. Regression: `test_audit_badQuotersNeverBlockSells`, `test_audit_dirtySinkNeverBlocksSwaps`. |
| C-2 / D-2 / G-4 | High | Return-data bomb: observer return data (~300 kB within 200k gas) was copied into the hook's memory, quadratic growth; 4 such modules put a sell or a liquidity removal over the 16.78M tx cap. | **Fixed.** Observer and poke calls copy no return data; guard reverts are bubbled with at most 256 bytes. Regression: `test_audit_returnDataBombIsNotPaidByTraders` (8 bombing modules × 3 callbacks: a sell stays under 6M gas). |
| A-1 | Medium | JIT penalty bypass: a dust top-up of the same position collects its fees in `afterAddLiquidity`, which did not penalize. | **Fixed.** `afterAddLiquidity` applies the same penalty to the fees it collects (via `afterAddLiquidityReturnDelta`), then refreshes `lastAdded`. Regression: `test_audit_jitTopUpIsPenalizedToo`. |
| A-5 | Medium | Transient slot 3 shared by nested swaps: an observer swapping in a second charged pool zeroed the outer swap's fee (holder floor skipped) or forced `PartialFill`. | **Fixed.** Swap state is kept per nesting depth (slot 5 counts depth; slots 16+2d / 17+2d hold that swap's bps and fee); modules and pokes run only at depth 0. Regression: `test_audit_nestedSwapKeepsTheOuterFee`. |
| A-3 / D-3 | Medium | `InsufficientGas` reverted sells: a due sink demanded ~1.05M gas on every swap and anyone could make a sink due by donating claims; observers had a 233k floor. | **Fixed.** A swap that brings too little gas skips the poke or the observer and logs it; nothing reverts. Regression: `test_audit_dueSinkDoesNotMakeLowGasSwapsRevert`, `test_lowGasSkipsObserversInsteadOfReverting`. |
| M-1 / G-2 / F-3 | Medium | TwapOracle lag: each interval was integrated with the previous observation's tick, so after a move and a quiet period the mean stayed at the old price and `VolatilityFee` charged the cap. | **Fixed.** Uniswap v3 semantics: an interval is weighted with the tick that held during it (the tick observed at its end); time after the last observation uses the live tick. Regression: `test_audit_twapHasNoLag`. |
| F-1 | Medium | Sink sandwich: `poke()` could be called repeatedly in one transaction, walking the buyback down the 1% band step by step (+0.509 ETH on a 2.17 ETH backlog in the PoC). | **Fixed.** Sinks act at most once per block (`HiveSink._oncePerBlock`); BuybackBurn also waits when LING is mid-settlement. |
| E-1 / G-3 / L-5 | Medium | Creator fees in WETH on chains other than mainnet (and any other ERC-20 anywhere) were stranded in the token. | **Fixed for wrapped native** on mainnet, Base, Optimism and Arbitrum (`WETH` chosen by chain id in the constructor). Other ERC-20 royalties remain unrecoverable: documented; OpenSea pays in ETH or WETH. |
| D-4 / A-7 / C-5 / G-5 | Low | Head-of-line sink: the first due sink was retried every swap and starved the rest; a failing poke ended the round. | **Fixed.** Rotating `pokeCursor`; a failed poke is logged and the next due sink tried; still one successful poke per swap. Regression: `test_audit_failingSinkDoesNotStarveTheNext`. |
| E-2 / D-6 | Low | `claim()` paid IMD and ETH atomically, so one failing leg locked the other; `_syncToken` could underflow if the IMD balance ever fell below the ledger. | **Fixed.** `claimEth()` and `claimToken()` added; `_syncToken` saturates. Regression: `test_claimOneAssetAtATime`. |
| E-3 / G-11 / D-8 | Low | `nextMintIds` used the constant 3,333 limit instead of DN404's live `totalSupply / UNIT`, and looped forever when every id existed. | **Fixed.** Live limit, bounded to the free ids. Regression: `test_nextMintIdsFollowTheCycle`. |
| L-1 / L-2 / L-3 | Low | `contractURI()` reverted without renderer code; the fallback `tokenURI` carried a raw `#`; the collection description carried a raw `%`. | **Fixed.** Code check, "Swarmling N" fallback, "1.25 percent". |
| C-6 | Info | `setSlices` accepted the hook or the token as a sink, which would break the ledger. | **Fixed.** Rejected with `BadEntry`. |
| A-10 | Info | `distribute()` lacked the synced-currency guard on the direct path. | **Fixed.** `Synced()` check added. |
| A-4 / G-8 | Low | Launch-pool binding checks only the fee tier, not the tick spacing or initializer; safe because IMD's launch is atomic. SECURITY.md and OPERATIONS.md disagreed. | **Accepted, docs reconciled.** Requiring a fixed spacing would risk an unbound hook if IMD's factory ever used another spacing. |
| C-3 / CROPS | Low | The council is one EOA with no delay, which is also DEV, the launch payer and the OpenSea collection editor. | **Accepted by the user** (instant changes were requested). Bounded in code; CROPS recommends a Safe + timelock or freezing before any module is attached. Documented. |
| C-4 | Low | One-step owner / council hand-over, no zero check in `setOwner`. | **Accepted.** The council bytecode is already deployed at its CREATE2 address; changing it would change the address. `setCouncil(address(0))` is the intended freeze. |
| L-4 | Low | DEV, as the OpenSea collection editor, can change the validator policy for this collection, including blocking owner transfers through the NFT contract. | **Documented** (LING transfers always move NFTs regardless). |
| E-4 | Low | NFTs held by contracts without a claim path forfeit rewards; counterfactual addresses can be "stained". | **Documented**; `claimToken()`/`claimEth()` give custody contracts a cheaper path but no `claimFor`. |
| E-5 | Info | Permit2 has DN404's default infinite allowance over LING. | **Documented** as a trust assumption. |
| F-2 | Low | `MaxBuy` caps per swap, not per block; a second charged pool is not guarded. | **Open** (module; not active at launch). |
| F-5 / A-8 | Info | JIT penalty covers reward-currency fees only (sell-side LING fees untouched); keyed by router. | **Documented.** |
| F-6 | Info | Ids can be chosen for gas by flash-cycling the mint counter. Traits are cosmetic. | **Documented.** |
| D-5 | Info | Burns have no per-tx cap: selling >3,000 NFTs under a maximal module set may exceed the tx cap. | **Documented.** |
| D-7 / L-1 (math) | Info | TwapOracle keeps 2,048 observations (~6.8 h of active blocks); longer windows fail open. | **Documented.** |
| G-13 | Info | Claims donated to the hook break the `totalFees == distributed + pendingFees` counter. | **Documented** (counter only). |

## CROPS summary

The contracts pass the walkaway test: holding, selling, claiming and moving NFTs need no key. The surrounding
stack does not yet: the site will be IMD-built and IMD-hosted, read `api.imd.fun`, and the exit asset is IMD,
whose owner controls bridge peers. Governance options, honestly labelled: a frozen council is the most
CROPS-aligned; a Safe 2-of-3 behind a 7-day timelock is the floor if the Hive roadmap is kept; the instant single
key as built is the weakest. The user chose the instant council. The full record is in `CROPS.md`.

## Not covered

The frontend (not built yet), IMD's launch factory (unverified bytecode) and the live mainnet deployment (not
launched). The Turkish legal questions raised in the research report are outside a code audit.

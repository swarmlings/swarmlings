# CROPS Review: Swarmlings (LING)

- Date: 2026-10-10
- Subject: `/Users/mehmet/Desktop/imd.fun/swarmlings`, commit `e706550` (`e70655030c6b32e56c8d3461e1db8d2d0082c191`, matches `baseCommit` in `launch/mainnet-swarmlings.workflow.json`). The folder is not a git checkout here, so the commit is taken from the launch files, not verified against history.
- Procedure: https://ethskills.com/crops/SKILL.md ("Required Review Output" shape, option short-form, walkaway test). Full record, because the system is complex and high-risk: immutable unaudited hook with all 14 flags, an instant admin key, a third-party launcher, a third-party reward currency and a regulated-jurisdiction operator.
- Nothing was posted anywhere and the repo was not modified. This file is the only thing written.
- Not legal advice. The Turkish section relies on the project's own research notes (secondary sources) and says where it stops.

## Evidence reviewed

README.md, docs/HIVE.md, docs/SECURITY.md, docs/OPERATIONS.md, docs/DEPENDENCIES.md, LICENSE, launch.json, `launch/frontend-brief-v3.txt`, `launch/frontend-criteria-v3.json`, `launch/mainnet-swarmlings.workflow.json`, and the legal-exposure parts of `reports/Swarmlings Hive primitive araştırması.md` (7518, Polymarket, TCK 228). Code read directly: `src/SwarmlingsCouncil.sol` (all), `src/SwarmlingsHook.sol` (`_runModules` L506-523, all `_runModules` call sites, governance L771-822, constructor L150-160), `src/SwarmlingsMirror.sol` (validator, royalty, `transferFrom`), `src/Swarmlings.sol` (`DEV`, `owner()`), SPDX headers of every directly imported v4-core file (all MIT) and of the renderer (MIT).

Not reviewed because it does not exist yet or was not provided: the IMD-built frontend, IMD's launch factory source, IMD token source on-chain, OpenSea's validator source, any live mainnet token/hook.

## System map and who holds what

| Component | Mutability | Controller |
| --- | --- | --- |
| `Swarmlings` (DN404 token) + `SwarmlingsMirror` (ERC-721 side) | immutable; no owner, proxy, pause, mint, transfer fee. `owner()` is a pure function returning `DEV` (marketplace label only) | none |
| `SwarmlingsHook` (v4 hook router, all 14 flags) | immutable code; configuration (slices, modules, council pointer) mutable | `council` (constant `COUNCIL` at construction) |
| `SwarmlingsCouncil` `0x4d0b3507D80f678d9e658Fd5482Ca6a96636A032` | `owner` mutable via `setOwner` | EOA `0x92cEf4823119f3332A85A39023eEbA01a06890c4` (the dev wallet). `execute(target,data,memo)` is instant, no timelock, no delay, no multisig. Per `docs/OPERATIONS.md` it was deployed on mainnet at block 26142845 |
| Modules / sinks (`src/modules`) | none active at launch; arbitrary contracts with code can be attached | council |
| Renderer `0x8d79e6677FA6E52190B39096f8496628811D8281` | immutable, no owner, fully onchain art; token calls it by try/catch staticcall | none |
| 90% single-sided LP | owned and locked by IMD's launch factory forever; `claimFees` permissionless, 80% to launch payer (dev wallet), 20% to IMD | IMD factory (admin powers unverified) |
| Reward currency IMD `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | LayerZero OFT; docs say no pause, blocklist or fee switch; owner controls bridge peers and delegate and can rename | IMD owner `0x047F…54B7` (truncated in docs, identity unknown) |
| OpenSea ERC721-C validator `0xA000…5A0000` | constant in Mirror (`setTransferValidator` always reverts) | OpenSea registry admins; collection editor = `DEV` via `owner()` |
| Frontend | not built yet; hash-routed static site by IMD's swarm, IPFS label "swarmlings", GitHub source, MIT | IMD (host, pinning, label) |

The dev wallet is at once council owner, launch payer (80% of pool fees), creator-fee recipient (50% of NFT royalties, `claimDev`), and OpenSea collection editor. Every discretionary lever sits behind one known EOA.

### What the instant council can do (code-verified)

- `setModules` (max 8, any address with code, no allowlist): a guard module is called with uncapped gas and its revert is passed through on buys (swap call sites pass `buy`), liquidity additions and donations (pass `true`). One tx can therefore halt all buying of LING and all LP additions while the guard stays attached. Sell, remove-liquidity and after-initialize paths pass `false` and are gas-capped; they cannot be reverted by a module.
- `setSlices` (max 8, total at most 3.75% extra): routes up to 3.75% of every swap's value to sinks the owner chooses, including a wallet-like sink; `take` can send a sink's claims to any address. Total hook fee is capped at 5% (plus the constant snipe tax, 40% falling to 0 over 60 s, to holders).
- A quoter module can surcharge sells up to the 5% total, and the extra goes to holders.
- `setCouncil(address(0))` freezes configuration forever; `setOwner` hands the council to a Safe, timelock or vote.
- Cannot: touch token balances, the holders' 1.25%, pending rewards, the snipe tax, sells, liquidity removal, or the hand-over path.

## CROPS Review

Chosen default:
- Frozen council (Option C below): after launch, the dev wallet runs `council.execute(hook, setCouncil(address(0)), memo)` so the hook stays at its launch configuration (holders' 1.25% floor, snipe tax, no slices, no modules) with no key able to halt buys, tax sells or divert fees. It removes the one component that fails C and S, and leaves a token, NFT and hook that nobody can change. Compromise: the Hive roadmap (buyback, auto-liquidity, oracles, guards) is given up and an unaudited immutable hook cannot be tuned. If primitives are wanted, the minimum acceptable alternative is Option B (council owner = Safe 2-of-3 or better behind a TimelockController of at least 7 days). The instant EOA council as built (Option A) is the weakest of the three.

Censorship Resistance:
- Risk: (1) The council owner can instantly attach a guard that reverts every buy, LP addition and donation, with no notice; sells always work. (2) One identifiable, Turkey-resident person holds that switch, so a court or licensing order could be complied with in a single transaction; the research notes record a Polymarket block ordered 16 July 2026 and applied at network level. (3) The frontend will be hosted, pinned and labelled by IMD ("swarmlings" IPFS label) and reads `api.imd.fun`; IMD can unpin or repoint it, and Turkish network blocking of IPFS gateway domains is plausible. (4) NFT movement through the Mirror is gated by OpenSea's validator; non-authorized marketplaces cannot transfer NFTs, and DEV (as collection editor) can change the collection's transfer policy there. (5) Reward and pair currency IMD is an OFT whose owner controls bridge peers; docs claim no pause or blocklist (not independently checked). (6) The 90% LP sits in IMD's factory; its admin powers are unverified. (7) "Buy LING" is a Uniswap deep link only; no router-agnostic swap path is documented.
- Mitigation: Token, NFT and hook are immutable with no pause or blocklist. Sells and LP removal cannot be blocked by any module (checked in `_runModules` call sites). LING transfers (the DN404 path) never pass the validator, so holders can always move NFTs by moving LING. Hard fee cap of 5%. Hand-over to a timelock, vote or `address(0)` is built in. All user actions (`claim`, `keep`, `setSkipNFT`, `distribute`, `syncEth`, `syncToken`) are permissionless contract calls with ABIs in `docs/abi`. The frontend brief limits network calls to chain RPC, `api.imd.fun` and explorer links and uses hash routing and relative paths, so any host can serve it.
- User escape: Sell or transfer LING through any v4 router or the PoolManager directly; call `claim()` from Etherscan or a local script; run the static site from source or a self-pinned CID; move NFTs by moving LING. If a buy-guard is ever attached, existing holders keep full exit and rewards, new buyers cannot enter.

Open (visibility):
- Risk: The frontend does not exist yet and will be generated by IMD's swarm; reproducibility from a pinned commit, the IPFS CID publication, and `dist/imd-deployment.json` (the brief says addresses come only from it) are not yet evidenced. `api.imd.fun` is a hosted API whose schema, source and self-host path are unknown. IMD's launch factory source and policy are outside this repo. Repo location is inconsistent: the launch files point at `github.com/swarmlings/swarmlings`, the stated plan is the `identity-md-launches` org. Contracts are not yet deployed or verified (Sourcify/Etherscan) for the mainnet hook and token. There is no external audit (docs/SECURITY.md "Not done"); the IMD "adversarial-review" step is an agent review.
- Mitigation: Contract repo is complete and public by design: pinned compiler (0.8.26, Cancun, optimizer 200), `bytecode_hash = "none"`, vendored dependencies with commits, 192 tests, ABIs committed, council journal and `Executed` events onchain, renderer source in `renderer/` with deterministic CREATE2 address and init-code hash. Commit to: publish the CID and build instructions with the release, verify all contracts on Sourcify as well as Etherscan, document the `api.imd.fun` endpoints and a chain-only mode, and pick one canonical repo.
- User escape: Fork the repo, rebuild with `forge build` offline, read everything from chain with the committed ABIs.

Free, as in Freedom (license):
- Risk: Repo is MIT, copyright "2026 Swarmlings" (no named holder). Deployed code imports only MIT v4-core files directly (checked); Uniswap's BUSL-licensed PoolManager is a separate deployment and not part of this repo, though transitive imports of v4-core were not enumerated. Solmate (AGPL) is test-only. The art itself (hand-drawn riso, encoded in the renderer's data contract) has no stated license separate from the MIT code. Frontend license (MIT per plan) is unverified until it exists. IMD's factory and `api.imd.fun` licenses are unknown.
- Mitigation: MIT on contracts and renderer, MIT stated for the frontend, dependency table with licenses in `docs/DEPENDENCIES.md`. Add an explicit art license (for example CC0 or CC BY) and a named copyright holder.
- User escape: Anyone may legally fork, redeploy or run a client without asking the team; the deployed token and hook cannot be relicensed or closed.

Privacy:
- Risk: Everything onchain is public by design (addresses, balances, NFT ownership, per-second reward claims, `keep` choices); no privacy is promised. Offchain: the site's RPC provider, `api.imd.fun`, the IPFS gateway and, on exit, Uniswap, each see IP and wallet address. The RPC the site uses, any analytics or telemetry inside the IMD-built frontend (including wallet-connect libraries), and any `api.imd.fun` request logging are unknown. The dev wallet, creator-fee and LP-fee flows link a known operator to a public address.
- Mitigation: Frontend criteria require no network requests except chain RPC, `api.imd.fun` and explorer links, fonts bundled locally (no Google Fonts), plain-text links to imd.fun and x.com/SwarmlingsIMD, and hash routing. Add to the brief: user-configurable RPC URL, no analytics, no error-reporting SDK, no WalletConnect cloud default, and a documented "view-only by address with your own RPC" mode.
- User escape: Use a self-hosted copy of the static site with your own node or RPC; read-only calls need no wallet connection; use a fresh address for holding.

Security:
- Risk: (1) Single EOA, instant, no multisig or timelock for a power set that includes halting buys and diverting up to 3.75% of volume; the skill's baseline is a Safe (at least 2-of-3) plus timelock (24 h floor). Key loss freezes whatever is attached at that moment, and a bad guard could never be removed. (2) Immutable, unaudited 858-line hook with all 14 flags, return deltas and transient storage; the research cites the hook class's recent failures (Bunni, Cork). No pause or fix path. (3) Exit is denominated in IMD, a bridged OFT with an owner controlling peers; sellers receive IMD and need IMD to ETH liquidity. (4) Marketplace layer: OpenSea fee settings are offchain under DEV, so the 50/50 royalty split can be redirected; validator admins are external. (5) Frontend is machine-built and unaudited; surface is small (`claim`, `keep`, `setSkipNFT`, `distribute`, `syncEth`, no approvals). (6) Launch preflight depends on IMD's factory behaving as described (atomic token+hook+pool, LP locked, permissionless `claimFees`).
- Mitigation: Hard limits in code (holder floor, 5% total cap, sells and removals unblockable, snipe tax a constant), 192 tests including invariants and a flash-loan attempt, no custody of user funds by any contract except reward accounting, sinks restricted to four services, hook-owned liquidity has no removal path. Reduce the admin surface by choosing Option B or C. Publish an independent human audit status. Add an IMD to ETH exit-liquidity note on the about page.
- User escape (walkaway test): see the dedicated section below. Short answer: funds and exit survive loss of the team, host and API; they do not survive a buy-halting guard for new entrants, and they depend on IMD-denominated liquidity.

Accepted compromises:
- DN404 balance-linked NFTs: a sale settled by moving LING pays no creator fee, and non-authorized marketplaces cannot move NFTs through the Mirror (by design, bounded by the LING path).
- Fixed OpenSea validator and DEV as collection editor (documented trust point; cannot touch balances, swaps or rewards).
- Reward currency IMD and its OFT owner as a trust point (documented).
- Hook complexity and no external audit at launch: acceptable only with the hook immutable, tests green, and the audit gap stated on the site. Not justified if modules are attached later without review.
- Instant EOA council: acceptable only as a short, publicly dated bridge (for example the first N days) before moving to Option B or C. Not justified as a permanent state.
- Hosted frontend by IMD with IPFS and `api.imd.fun`: acceptable only if the CID, build steps and a chain-only mode are public.
- Single dev wallet holding revenue roles: bounded to revenue and the council; no user funds.

## Governance options

Option A: Instant council as built (EOA owner, no timelock)
- C: weakens; one key can halt all buys and LP additions at once, tax sells up to 5% total, and one known person is the legal pressure point
- O/F: neutral; changes and memos are logged onchain, but attached modules are arbitrary contracts that need not be verified or open source
- P: neutral; council actions are public and tie to one known wallet; no extra data leak
- S: weakest; single key, zero notice, key loss freezes a possibly bad configuration forever; blast radius is bounded by hard limits (not the 1.25%, rewards, sells or LP removal) but still up to 3.75% of volume diverted

Option B: Council behind a timelock (owner = Safe 2-of-3 or more, proposer, then TimelockController of 7 days or more, public queue, `Executed` events)
- C: improves; a buy-halting guard or fee slice is visible days ahead, and since sells can never be blocked holders can exit first; the legal coercion lever slows but stays (modules unrestricted after the delay)
- O/F: improves; queued calldata is public and a "module source must be verified before queueing" policy becomes enforceable by signers, but the hook has no code-level allowlist
- P: neutral; signers' identities become partly visible, but concentration on one person falls
- S: strong; no single key, notice period sized to the exit window, key loss no longer fatal; costs: deploy Safe and timelock, one `setOwner` tx, ongoing signer operations

Option C: Frozen council (`council.execute(hook, setCouncil(address(0)), memo)`; recommended default)
- C: strongest; nobody can attach a buy guard, surcharge sells or reroute fees; no discretionary lever for an authority to pull
- O/F: strongest; behavior is the verified, tested launch code, nothing external can be attached later
- P: neutral; nothing changes about data exposure, but no operator decision logs remain to be made
- S: strongest against admin risk; irreversible, so the unaudited hook and its 14-flag surface cannot be tuned or patched, and Hive primitives (buyback, auto-liquidity, oracles) are given up. Doing it requires a post-launch tx by the dev wallet; it is not automatic.

Recommended default: **Option C**, honestly the most CROPS-aligned, and it differs from what was built (Option A). If the team insists on keeping the Hive roadmap, Option B is the floor; A should be at most a short, publicly dated bridge with a stated handover or freeze date. Feasibility: the council and hook are already deployed/fixed, but both B and C are reachable with the existing code (`setOwner`, `setCouncil`), no redeploy.

Note on timing: at launch no module or slice is active. If the owner freezes before ever attaching anything, the hook is exactly the reviewed floor. If a guard is attached first and then the key is lost or the council is frozen, the guard cannot be removed; freeze only from the empty configuration.

## Turkish regulatory angle (from the research notes; not legal advice)

- The operator (the dev wallet, launch payer and creator-fee recipient) resides in Turkey. The notes record: Law 7518 requires licensing for crypto-asset issuance, trading, custody and transfer, unlicensed CASP activity 3-12 years, licence needs a TRY 150M-capital Turkish joint stock company; Law 7258 (internet betting) 4-6 years for operating, 3-5 for facilitating money transfers, 1-3 for advertising; Law 320 (state lottery monopoly); TCK 228 (gambling, 3-5 years when electronic; gambling is presumed where outcome depends on an uncertain future event and entry needs payment). Milli Piyango decision 2026/10 of 16 July 2026 had Polymarket blocked via BTK although Polymarket did not geoblock Turkey, so enforcement is at network level against the access point. 2026 enforcement is heavy (47,493 sites blocked, wallets frozen).
- The notes leave open, and this review cannot close, whether a 1.25% fee stream paid to NFT holders is a security or a CASP service in Turkey, the EU or the US, and name a written Turkish legal opinion as a precondition to mainnet. I found no record that this opinion exists. Treat it as a launch-blocking missing fact.
- The base product's mint mechanics (which id a buyer receives is determined by DN404's order, and buying LING costs money) were not analysed against the TCK 228 uncertainty-plus-payment test in the notes; the notes only reject lotteries, jackpots, price-prediction and trait-weighted yield for attachable primitives. Ask counsel specifically.
- CROPS interaction: (a) an instant, identifiable council is the pressure channel, since an order to halt buys can be obeyed in one transaction; a frozen council (C) or a timelocked multisig (B) removes or slows that channel, and also makes any "decentralization" argument more credible, which is a hypothesis for counsel, not a conclusion. (b) Revenue streams to the dev wallet (80% of pool fees, 50% of royalties) undercut a "no operator" argument whatever the council does. (c) Frontend blocking in Turkey is plausible; IPFS plus independent pinning and mirrors, and documenting direct contract calls, protect users, not the operator. (d) Adopt a written "never attach" list (lottery, jackpot, prediction, loans against NFTs) enforced by freezing or a signer policy.

## Walkaway test

If the team, vendor, host or oracle disappears, can the user still access funds and exit?

| Scenario | Result | Why |
| --- | --- | --- |
| Dev disappears or loses the key | Pass, with a caveat | Token, NFTs, rewards, sells, `claim`, `distribute`, `syncEth` are permissionless. Config stays at its last state: at launch that is the floor only. Caveat: a guard attached before the loss can never be removed; DEV's half of royalties is stranded (not user funds) |
| Dev key compromised | Bounded failure | Attacker can halt new buys, add up to 3.75% of volume to a sink, surcharge sells to 5% total; cannot stop sells, LP removal, claims. Holders can exit |
| IMD stops hosting the site / `api.imd.fun` / IPFS label | Partial pass | Contracts and pool unaffected; users call contracts directly (ABIs in repo) or build the site from source. Needs published CID, build steps and chain-only mode, none evidenced yet |
| IMD launch factory misbehaves | Unknown | LP is owned and locked by the factory; claimed locked forever and `claimFees` permissionless but admin powers not verified. Holder exit does not need the LP to be removable, only the pool to trade |
| IMD token (OFT) owner acts | Partial | Reward and pair currency; no pause or blocklist claimed (unverified by me), but owner controls bridge peers; exit is paid in IMD, so exit to ETH depends on IMD liquidity |
| OpenSea / validator changes | Pass for funds | NFT transfers through the Mirror can be blocked for marketplaces, but moving LING moves NFTs; creator-fee income at risk |
| Uniswap interface blocks LING or geofences | Partial | Direct PoolManager or any router works; no router-agnostic swap guide exists yet |
| Turkish authority blocks the site/gateway | Partial | Chain unaffected; users need alternate hosts; operator remains exposed |

Verdict: the contracts pass the walkaway test (no key is needed to hold, sell, claim or move). The stack around them does not yet: IMD-hosted frontend and API, IMD-denominated exit, unverified factory and OFT powers, and a single admin key whose only safe state is "never used" or "frozen".

## Missing facts (each counts as a finding)

1. RPC used by the IMD-built site: hardcoded provider, wallet-injected only, or user-configurable; any fallback.
2. Analytics, telemetry and error reporting in the IMD-built frontend and its wallet/connect libraries (`package.json` and actual network calls); the brief only constrains destination hosts.
3. Which numbers come from `api.imd.fun` vs chain; that API's source, schema, logging, availability commitment and a chain-only fallback.
4. IPFS details: who pins "swarmlings", gateway/ENS/DNS entry point, CID publication, retention, reproducible build, whether `dist/imd-deployment.json` is committed, and whether anyone besides IMD pins.
5. Canonical GitHub location (`github.com/swarmlings/swarmlings` in launch files vs `identity-md-launches` org), who holds admin, mirror plan.
6. OpenSea validator admin powers: who can change policy, whether collection editor `DEV` can restrict owner-initiated transfers (caller constraints), whether registry can pause, how off-chain fee recipient is protected.
7. IMD launch factory: source, verification, admin or upgrade powers, ability to touch LP or fee recipients, whether `claimFees` split is immutable.
8. IMD token OFT owner identity and custody (`0x047F…54B7` is truncated in docs), Sourcify verification not independently confirmed by this review.
9. Council owner key custody (hardware wallet?), backup, planned handover or freeze date; no timeline stated anywhere.
10. External human audit: none; IMD in tests is a mock; fork tests need `MAINNET_RPC_URL`.
11. Art and trademark license; named copyright holder.
12. Written Turkish legal opinion; EU/US securities-style analysis of the holder fee stream.
13. Uniswap v4 protocol-fee controller status for this pool; Uniswap interface listing and geoblock behavior for LING.
14. Mainnet launch status: token/hook addresses, explorer and Sourcify verification, transitive v4-core license check.
15. Stale instructions: `launch/mainnet-swarmlings.workflow.json` still tells IMD "nobody owns or administers anything and nothing can change after deployment" and "No owner or admin anywhere", which contradicts the council (the frontend brief v3 and docs state it). If IMD's site copy is generated from that text, the about page may overstate immutability. Align before launch.

## Recommended actions, in order

1. Decide governance: freeze (C) or Safe plus 7-day timelock (B) before or at launch; publish the decision and date. Do not leave the instant EOA as the steady state.
2. Obtain the written Turkish legal opinion before mainnet launch.
3. Fix the stale "no owner or admin" wording in the IMD workflow text.
4. Add to the frontend brief: configurable RPC, no analytics, documented `api.imd.fun` endpoints with chain-only mode, published CID and reproducible build, canonical repo.
5. Verify IMD factory and OFT owner powers on-chain and record the results here; verify all contracts on Sourcify and Etherscan after launch.
6. Add a short "direct contract usage and router-agnostic selling" guide and an exit-currency (IMD) note to docs and the about page.
7. State the art license and copyright holder; commission an independent human audit of the hook or state its absence on the site.

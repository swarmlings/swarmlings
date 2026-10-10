# Swarmlings (commit e706550) - evm-audit-erc721 findings

Scope: `src/SwarmlingsMirror.sol`, the NFT side of `src/Swarmlings.sol` (tokenURI delegation, `keep`, auto-skip, burn order, royalties), marketplace flows against the real OpenSea registry (mainnet fork).
Tests: `test/audit/Erc721Audit.t.sol` (local, 23 tests, incl. a 1,500-run fuzz of keep/transfer/burn) and `test/audit/Erc721AuditFork.t.sol` (mainnet fork, 8 tests). Helper scripts: `audit/2026-10-10/poc-erc721/`.
Run: `forge test --match-path "test/audit/Erc721Audit*.t.sol" -vv` (fork tests need `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com`).
No Critical/High/Medium issues found. The ERC721-C integration, ERC-165, approvals, events, `keep` and the royalty receive path all behave correctly (see "Verified correct").

## [L-1] `contractURI()` reverts when the renderer has no code (try/catch does not cover it)
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.contractURI()` (src/SwarmlingsMirror.sol:56-68)
**Description**: The logo is fetched with `try ILogo(RENDERER).logoSVG() returns (string memory svg) {...} catch {}`. In Solidity, a call to an address without code (or one that returns empty data) does not revert inside the callee: the failure happens while the caller ABI-decodes the empty return data (or in the extcodesize check), which is outside `try/catch` and reverts the whole function. `Swarmlings._tokenURI` guards with `RENDERER.code.length != 0` first; `contractURI` does not. docs/OPERATIONS.md step 1 explicitly allows deploying the renderer "before or after the launch", and the renderer lives at a fixed CREATE2 address per chain, so on any chain/time where it is not yet deployed the collection-level metadata (name, image, collaborators) is unavailable and marketplaces (OpenSea reads `contractURI`) show a blank collection. On Ethereum mainnet the renderer is already deployed (verified on the fork), so this is a latent/operational risk, not a live one. It also contradicts the intent stated in the code ("the logo comes from the token's renderer", best-effort).
**Proof of Concept**: `forge test --match-test "test_contractURI_noRenderer_reverts|test_contractURI_rendererWithEmptyReturn_reverts" -vv` in `test/audit/Erc721Audit.t.sol`. Deploy `Swarmlings` on a chain without code at `0x8d79...8281`; `mirror.contractURI()` reverts while `mirror.tokenURI(1)` returns the fallback JSON. Same revert if the address holds code that returns nothing (`vm.etch(RENDERER, hex"00")`).
**Recommendation**: Mirror the guard used in `_tokenURI`: `address r = IOwnerView(baseERC20()).RENDERER(); if (r.code.length != 0) { try ILogo(r).logoSVG() returns (string memory svg) {...} catch {} }`. Optionally use a low-level `staticcall` and decode only when `returndata.length >= 64`.

## [L-2] `tokenURI` fallback JSON contains a raw `#`, which truncates it when consumed as a URL
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `Swarmlings._tokenURI()` (src/Swarmlings.sol:169)
**Description**: When the renderer has no code or reverts, `_tokenURI` returns `data:application/json;utf8,{"name":"Swarmling #<id>"}`. In a non-base64 data URI a literal `#` starts the URL fragment, so any consumer that parses it as a URL (browsers, `fetch`, Node `URL`) sees the body `{"name":"Swarmling ` and fails to parse it. `SwarmlingsMirror._escape` already encodes `#` as `%23` for the logo, so the codebase knows the rule; the fallback just does not apply it. The docs (README "Art", SECURITY.md "Renderer") promise "a minimal valid JSON". Impact is limited to the fallback path (renderer missing or reverting, e.g. out of gas under a small `eth_call` gas limit), but indexers may cache that broken metadata.
**Proof of Concept**: `forge test --match-test test_tokenURIFallback -vv` prints the URI as hex; then
```
forge test --match-path test/audit/Erc721Audit.t.sol --match-test "contractURI_nasty|contractURI_control|tokenURIFallback" -vv | grep -E "^\s+(URI|SVG|FALLBACK)" > out.txt
node audit/2026-10-10/poc-erc721/uri_check.js out.txt
```
Output: `FALLBACK fetch FAIL Unterminated string in JSON at position 19` and `URL hash: "#1%22}"` (while `decodeURIComponent` + `JSON.parse` succeeds, which is why simple splitters do not notice).
**Recommendation**: Emit `%23` instead of `#` (`'...Swarmling %23', _toString(id), '"}'`), or return a `data:application/json;base64,` URI for the fallback.

## [L-3] `contractURI()` JSON is not strictly percent-decodable: the description has a raw `%`
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.contractURI()` description string (src/SwarmlingsMirror.sol:67)
**Description**: The outer JSON is placed unencoded after `data:application/json;utf8,`. The description contains `1.25% to the people`. `% t` is not a valid percent-escape, so a strict decoder such as JavaScript `decodeURIComponent(body)` throws `URIError: URI malformed` (lenient decoders such as WHATWG `fetch`/Python `unquote` accept it). Many NFT/indexer libraries decode data URIs with `decodeURIComponent`. The `image` field is fine (its `%` and `#` are encoded, and I verified the real renderer logo round-trips to the identical well-formed 7,403-byte SVG with `json.loads` + `unquote`), so only the description is at risk. If OpenSea's pipeline is strict, the collection page loses its name/image/description.
**Proof of Concept**: Same output file as L-2: `node audit/2026-10-10/poc-erc721/uri_check.js out.txt` prints `URI_NASTY decodeURIComponent FAIL URI malformed` but `fetch OK`. The same JSON parses with Python (`uri_check.py`: "JSON OK", "svg roundtrip True"), and the real-renderer URI from `test_fork_realContractURI_and_tokenURI` parses (`MAINNET_RPC_URL=... forge test --match-test realContractURI -vv | grep -E '^\s+REAL_' > real.txt; python3 -I real_uri_check.py`), showing the only offender is the `%`.
**Recommendation**: Write `1.25%25` in the description literal (and `%23` for any `#`), or switch the whole `contractURI` to base64. Add a test that runs `decodeURIComponent` (or an equivalent strict percent-decoder) over the output.

## [L-4] Collection owner (DEV) can change or switch off the OpenSea validator policy for this collection; README overstates what is fixed
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.owner()`, `TRANSFER_VALIDATOR`; README "Creator fees on NFT sales"
**Description**: The validator address is constant, but the registry's per-collection policy is controlled by whoever `owner()` returns, and `owner()` is `DEV`. On the mainnet fork DEV can call `setTransferSecurityLevelOfCollection(mirror, level)`: levels 7 and 8 make even `transferFrom(alice, alice, id)` (owner self-transfer) revert, levels 4 and 6 also blocked an owner-to-EOA transfer in my test, and level 1 lets any approved operator (no Seaport zone attestation) move NFTs, i.e. fee-free trading through any marketplace. LING transfers are unaffected in all cases. So DEV can (a) freeze all marketplace and direct NFT transfers, or (b) turn creator-fee enforcement off, which cuts the holders' 50% of royalties. The registry owner (default list owner `0x939c...ba18a`) can also change the default list that currently makes OpenSea's SignedZone the authorizer. README says "Owners can always move their own NFTs" and "The token, the NFTs and the holders' share are fixed", which is not true of the NFT-transfer path; SECURITY.md discloses the policy power but only in passing. The 50/50 recipient is similarly set off-chain by DEV in OpenSea Studio (already noted as a trust point).
**Proof of Concept**: `MAINNET_RPC_URL=... forge test --match-test "test_fork_devCanReconfigureCollectionPolicy|test_fork_levels78BlockSelfTransfer|test_fork_devCanSwitchEnforcementOff" -vv` (logs which levels block owner transfers; shows an unauthorized approved operator reverting by default and succeeding after `vm.prank(DEV)` sets level 1).
**Recommendation**: Reword README/SECURITY.md to state plainly that DEV (and the registry's owner) can freeze NFT-path transfers or disable fee enforcement, and that LING transfers are the escape hatch. If that power is unwanted, make `owner()` return an address that cannot act (e.g. a burn address or a non-calling contract) after OpenSea Studio setup is done; note the trade-off: Studio and the registry then can no longer be configured.

## [L-5] Creator fees paid in anything other than ETH, or WETH on Ethereum mainnet, are stuck forever
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `Swarmlings._syncEth()`; `SwarmlingsMirror.royaltyInfo()` (receiver = token)
**Description**: The royalty receiver is the token contract. ETH is accepted by the empty `receive()` (works with Seaport's `call` and with a 2,300-gas `transfer`), and on `block.chainid == 1` WETH is unwrapped in `_syncEth` (verified on the fork: 1 WETH arrives, `syncEth` unwraps it, DEV share and holder stream increase). Any other currency (e.g. USDC, or WETH on a non-mainnet deployment) that a marketplace pays as the creator fee lands in the contract as an ERC-20 balance and nothing in `Swarmlings` can move or account for it (no rescue, no arbitrary call, `rewardCurrency` is the only ERC-20 handled). Seaport lets listings be priced in any ERC-20, and the `royaltyInfo` fee is taken in the sale currency. The funds are not stolen, just lost to holders and DEV.
**Proof of Concept**: `MAINNET_RPC_URL=... forge test --match-test "test_fork_wethCreatorFeeIsUnwrapped|test_fork_otherCurrenciesAreStuck" -vv`. `test_fork_otherCurrenciesAreStuck` credits 1,000 USDC to the token, calls `syncEth()`; the balance stays and no function can release it.
**Recommendation**: Either document that the creator fee is only recovered for ETH/WETH sales and set OpenSea's fee config accordingly, or add a narrowly scoped `sweep(token)` that forwards non-`rewardCurrency` ERC-20 balances to DEV (with the usual guard against pulling `address(this)`/`rewardCurrency`). Adding WETH unwrapping for the configured chain's WETH (instead of the mainnet-only constant) would cover other deployments.

## [I-1] No `OwnershipTransferred` event at launch; `pullOwner()` is how to emit it
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.owner()` override; `DN404._initializeDN404`
**Description**: `_initializeDN404` only calls the mirror's `pullOwner()` if the base can answer `owner()` via a staticcall to itself, which returns empty while the base is being constructed, so nothing is emitted and the mirror's stored owner stays `address(0)`. `owner()` is overridden to read live, so the value is right, but indexers that rely on `OwnershipTransferred` see no owner. `pullOwner()` is permissionless and (verified) emits `OwnershipTransferred(0, DEV)` on the first call.
**Proof of Concept**: `forge test --match-test test_noOwnershipEventAtLaunchButPullOwnerWorks -vv`.
**Recommendation**: Call `mirror.pullOwner()` once after deployment (add to the launch checklist in docs/OPERATIONS.md).

## [I-2] `ICreatorTokenLegacy` interface id (0xa07d229a) is not advertised
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.supportsInterface()`
**Description**: `supportsInterface` returns true for ERC-2981 (0x2a55205a), `ICreatorToken` (0xad0d7f6c, verified equal to getTransferValidator ^ getTransferValidationFunction ^ setTransferValidator and to the LimitBreak id), ERC-165/721/721Metadata. LimitBreak's ERC721-C also advertises `ICreatorTokenLegacy` (0xa07d229a = getTransferValidator ^ setTransferValidator). OpenSea's docs only require the `ICreatorToken` functions, so this is unlikely to matter, but some tooling probes the legacy id.
**Proof of Concept**: `forge test --match-test test_interfaceIds -vv`; `cast sig` XORs: `0x098144d4 ^ 0xa9fc664e = 0xa07d229a`.
**Recommendation**: Optionally add `|| interfaceId == 0xa07d229a`.

## [I-3] `_escape` does not handle backslash or control characters (latent)
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror._escape()`
**Description**: `_escape` encodes `"`, `#`, `%` and the x3 output buffer is large enough for the worst case (no overflow possible; `_hex` is correct for 42 chars). It leaves `\` and bytes below 0x20 untouched, which makes the JSON string invalid. The current renderer's `logoSVG()` contains none of these (I decoded the real mainnet logo: no control chars, no backslash, no `&`, ASCII only, well-formed XML), and the renderer is immutable at a CREATE2 address, so this cannot trigger today. It would if the logo source ever changed.
**Proof of Concept**: `forge test --match-test test_contractURI_controlChars -vv` then `python3 -I audit/2026-10-10/poc-erc721/uri_check.py out.txt` -> `CTRL JSON FAIL Invalid control character`. The nasty-but-supported case (`"`, `#`, `%`, `<`, `&`, UTF-8, `'`) passes: `NASTY JSON OK`, `svg roundtrip True`.
**Recommendation**: Escape `\` as `\\` and bytes < 0x20 as `\u00XX` (the buffer would then need x6 for control bytes), or base64-encode the logo.

## [I-4] `royaltyInfo` reverts for absurd sale prices
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.royaltyInfo()`
**Description**: `salePrice * ROYALTY_BPS` overflows (checked) for `salePrice > 2^256/500`, reverting. ERC-2981 consumers should treat that as no royalty; unrealistic in practice.
**Proof of Concept**: `forge test --match-test test_royaltyHugePriceReverts -vv`.
**Recommendation**: Use `Math.mulDiv`/unchecked-safe arithmetic or ignore.

## [I-5] NFTs sent to the token, the mirror or a dead address keep earning an unclaimable share
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.transferFrom` -> `DN404._transferFromNFT`
**Description**: `transferFrom` (not `safeTransferFrom`) to any non-zero address succeeds, including `address(ling)`, the mirror or `0x...dEaD`. The recipient is counted in `activeNFTs()` and accrues per-NFT rewards that nobody can claim, diluting everyone else (cost to the sender: the NFT and its 300,000 LING). Self-inflicted; no third-party exploit.
**Proof of Concept**: `forge test --match-test test_nftToTokenContractIsDeadWeight -vv`.
**Recommendation**: Optional: reject `to == address(this)` / the mirror in `_transferFromNFT`. Otherwise document.

## [I-6] DN404 behaviours worth knowing (accepted by design)
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `DN404Mirror`, `Swarmlings._skipNFTDefault`
**Description**: (1) Mints never call `onERC721Received`; contracts only get NFTs after `setSkipNFT(false)` and EIP-7702 delegated wallets get them regardless, so a delegate that cannot hold NFTs is not protected on mint. (2) `safeTransferFrom` to an EIP-7702 wallet calls the delegate (`extcodesize` is 23) and reverts with `TransferToNonERC721ReceiverImplementer` if the delegate has no receiver hook; `transferFrom` and the LING path still work. (3) `balanceOf(address(0))` returns 0 instead of reverting. (4) ERC20 spenders (including Permit2's default infinite allowance, DN404) can move NFTs with LING without the validator, as documented. (5) Operator approvals from `setApprovalForAll` persist for NFTs minted to the same owner later; the validator (only SignedZone-attested operators succeed on the fork) is what limits this on the NFT path. None of these breaks an invariant.
**Proof of Concept**: `forge test --match-test "test_safeTransferToContracts|test_burnedIdViews" -vv` (callback only on safeTransferFrom, reentrancy-safe since state and rewards are settled before the callback).
**Recommendation**: None required; keep the README's "Limits, by design" section.

## [I-7] Validation is silently skipped if the registry has no code on the chain
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `SwarmlingsMirror.transferFrom()` (`TRANSFER_VALIDATOR.code.length != 0`)
**Description**: On a chain where `0xA000027A...` is not deployed, validation is skipped (fail-open), so creator fees are not enforced while `getTransferValidator()` still reports the address. Fine for Ethereum and Sepolia (where the registry exists); worth a note for any future chain.
**Proof of Concept**: `test_validatorGatesOperatorTransfersOnly` in test/Swarmlings.t.sol only enforces after `vm.etch`.
**Recommendation**: Document, or return `address(0)` from `getTransferValidator()` when the registry has no code.

---

## Verified correct (with evidence)
- `transferFrom` / `safeTransferFrom`: `validateTransfer(msg.sender, from, to, id)` runs before every mirror NFT transfer; `safeTransferFrom(...,data)` resolves to the overridden `transferFrom`, and the original caller reaches both the validator and `_transferFromNFT` (`test_safeTransferPassesOriginalCallerToValidator`, `test_approvedOperatorAndNonOperator`). `approve`/`setApprovalForAll` are not transfers and do not bypass anything; only the LING path bypasses (documented).
- Real registry on a mainnet fork: default policy blocks an unattested operator; after OpenSea's SignedZone (`0x000056F7...D100`, authorizer in default list 0) calls `beforeAuthorizedTransfer(mirror, id)` the operator succeeds for that id only and after `afterAuthorizedTransfer` it is blocked again; owners can move NFTs to EOAs and contracts, `safeTransferFrom` to a receiver works (`test_fork_zoneAuthorizedSale`, `test_fork_ownersToContractsAndSafe`). The 4-arg view selector `0xcaee23ea` matches the registry and `getTransferValidationFunction() = (0xcaee23ea, true)`.
- ERC-165: 0x2a55205a, 0xad0d7f6c (computed three ways), 0x80ac58cd, 0x5b5e139f, 0x01ffc9a7 true; 0xffffffff false.
- Royalty receiver: 2,300-gas `transfer` into the token works; WETH on mainnet is unwrapped and split; see L-5 for other currencies.
- `owner()`: live read, no construction-time problem (unlinked mirror reverts `NotLinked`, only matters before linking, which happens atomically in the Swarmlings constructor; no linking front-run possible).
- `contractURI()` structure: valid JSON for logos with `"`, `#`, `%`, `<`, `&`, `'`, non-ASCII (see I-3 for control chars); image data URI decodes back to the original SVG; the real mainnet logo round-trips; `_escape` x3 sizing safe; `_hex` correct (collaborator equals DEV).
- Events: mint/burn/NFT transfer/direct LING transfer all emit exactly one ERC-721 `Transfer` per id from the mirror (`test_eventsOnMintBurnTransfer`, `test_directLingTransferEmitsErc721Logs`). `ownerOf`, `getApproved`, `tokenURI` revert for burned ids; `ownerAt` returns 0.
- Approvals: per-id approvals are cleared on NFT transfer, direct LING transfer, balance-driven burn, and a re-minted id (after the id cycle wraps) is not exposed to the old spender (`test_staleApproval*`).
- `keep(ids)`: ownership unchanged, owned-list and index stay consistent, burn order honours the new order, duplicates, foreign, zero and >32-bit ids rejected; fuzz over keep/transfer/LING transfer/burn/self-transfer (1,500 runs) found no inconsistency.

## Checklist coverage (evm-audit-erc721 references/checklist.md, all 21 items)
1. ERC721/ERC1155 dual: n/a (no 1155); `supportsInterface` is unambiguous.
2. ERC404/DN404 mixed ERC20/721: reviewed; LING path moves NFTs without validator (documented, I-6, L-4); mint-callback and approval persistence in I-6.
3. CryptoPunks `offerPunkForSaleToAddress`: n/a.
4. Wrapped NFTs unwrap risk: n/a.
5. Shared contract `setApprovalForAll`: n/a (one collection per mirror); approvals persist across auto-mints (I-6).
6. `totalSupply`/enumerable across collections: n/a; `totalSupply()` reads the base NFT supply.
7. Large/encoded token ids: ids 1..3333, high-bit ids rejected in `keep` (test_keepBogusIds).
8. Non-contiguous ids: ids cycle and skip existing; `nextMintIds` handles it.
9. Probabilistic burn on transfer: none; burns are deterministic by balance.
10. Auto-burning NFTs: DN404 burns on LING balance drop; `ownerOf` reverts for burned ids (verified); `keep` protects favourites.
11. Upgradeable NFT: none (constants, no proxy); registry upgradeability/admin noted in L-4.
12. Pausable NFT: none; registry policy can freeze NFT-path transfers (L-4).
13. Registry blacklists/operator filter: OpenSea registry, DEV/list-owner control noted (L-4); reverts handled by owners via the LING path.
14. `safeTransferFrom` reentrancy via `onERC721Received`: callback runs after DN404 state and reward settlement; no exploitable path (I-6).
15. ERC1155 batch callbacks: n/a.
16. NFT permit (ERC-4494): not implemented; approvals only via `approve`/`setApprovalForAll` events.
17. Airdrops/receivers trapping tokens: contract holders can receive NFTs via `transferFrom` and hold them; no airdrop logic; I-5.
18. Fractional vaults: n/a.
19. Constructor mints without events: initial supply goes to the launcher with skipNFT, no NFT mints in the constructor; later mints/burns log through `logTransfer`.
20. `transferFrom` vs `safeTransferFrom` receiver check: `transferFrom` to non-receivers allowed (standard); `safeTransferFrom` enforces `onERC721Received` (verified revert for a non-receiver).
21. User-supplied `from`: base verifies `from == ownerOf` and caller owner/approved/operator; validator also sees `from`; no approval-theft path (`test_approvedOperatorAndNonOperator`).

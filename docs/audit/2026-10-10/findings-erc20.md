# Swarmlings audit, evm-audit-erc20 (commit e706550)

Summary: no Critical or High issues. 1 Medium, 3 Low, 2 Info. PoCs in `swarmlings/test/audit/ERC20Audit.t.sol` (21 tests; the E-1..E-4 tests assert the faulty behaviour, so a pass confirms the issue). Checklist coverage was done against a paraphrased fetch of the checklist. The IMD token source (`BridgedFP`, OZ ERC20 + LayerZero OFT, 18 decimals, owner can only rename and manage peers; no pause/blocklist/fee/hooks) was pulled from Sourcify.

## [E-1] Non-ETH creator fees are stranded forever: WETH off mainnet, and any other ERC-20 on every chain
**Severity**: Medium
**Category**: evm-audit-erc20
**Location**: `_syncEth()` (src/Swarmlings.sol:298-311); `WETH` constant (line 42); `SwarmlingsMirror.royaltyInfo()` (receiver = the token)
**Description**: The ERC-2981 royalty receiver is the token itself on every chain, and the token is meant to be deployable on several chains ("native ETH everywhere else"). `_syncEth` only unwraps WETH when `block.chainid == 1`, and only at the hard-coded mainnet WETH address. Marketplaces pay royalties in the sale currency, so every accepted collection or item offer (WETH) on an L2 delivers WETH to the token that is never counted and cannot be moved: no owner, sweep or rescue function; the only token call is `transfer` on the reward token. The same holds on mainnet for any royalty paid in a token other than WETH (1000e6 USDC stays in the token). Value is lost permanently, half holders', half DEV's. Plain-ETH sales are unaffected.
**Proof of Concept**: `forge test --match-test test_E3_wethRoyaltyOnL2IsNotUnwrapped -vv`. On chainid 8453 a token sits at the OP-stack WETH address `0x4200...0006`; after 5 WETH is sent to `ling`, `syncEth()` and `claim()` leave `stream(0).total == 0` and `devOwed == 0`.
**Recommendation**: Pick the wrapped-native address per chain at deployment (chainid table: 1, OP-stack 0x4200…0006, Arbitrum One 0x82aF…) and unwrap it whenever it has code; optionally a permissionless `rescue(token)` that forwards any ERC-20 other than `rewardCurrency` and LING to DEV. Document in docs/SECURITY.md.

## [E-2] `claim()` pays two assets atomically, so one failing asset locks the other; `_syncToken` underflows if the IMD balance falls below the ledger
**Severity**: Low
**Category**: evm-audit-erc20
**Location**: `claim()` (lines 221-243), `_syncToken()` (lines 313-321), `_payToken()` (lines 435-439)
**Description**: On mainnet `claim()` always runs `_syncToken()` and then pays IMD and ETH in one transaction. (a) `IERC20Lite(c).balanceOf(this) - p.accounted` is a checked subtraction: if the token balance ever drops below `accounted` (downward rebase, admin burn, token bug; none exist in today's IMD), every `claim()` and `syncToken()` reverts with Panic(0x11), locking ETH rewards too. (b) If `IMD.transfer` ever reverts or returns false, `_payToken` reverts with `PayFailed` and the holder's ETH is locked with it. Robustness, not an exploit.
**Proof of Concept**: `test_E4_failingRewardTokenBlocksTheEthClaimToo`, `test_E4_balanceBelowAccountedBricksClaimForEveryone`.
**Recommendation**: In `_syncToken`, use `bal > accounted ? bal - accounted : 0`. Add `claimEth()` / `claimToken()` so one asset cannot block the other.

## [E-3] `nextMintIds` disagrees with DN404 once supply has been burned, and never terminates when all 3,333 ids exist
**Severity**: Low
**Category**: evm-audit-erc20
**Location**: `nextMintIds()` (lines 147-156)
**Description**: The view wraps ids at `MAX_NFTS` (3333) while DN404 mints with `idLimit = totalSupply / _unit()`, which falls as LING is burned (a burn of just over 100,000 LING takes it to 3332). The real mint then restarts at the lowest free id while the view reports an id that can no longer be minted. Separately `while (_exists(id))` loops forever when every id exists. View only.
**Proof of Concept**: `test_E1_*` (prints `nextMintIds(1)[0] = 11`, `id actually minted = 10`), `test_E2_nextMintIdsNeverReturnsWhenAllIdsExist`.
**Recommendation**: Use `idLimit = totalSupply() / UNIT`, mirror DN404's search order, bound the loop to `MAX_NFTS` probes and return fewer entries when fewer ids are free.

## [E-4] Rewards accrue to contracts that cannot call `claim()` and are then stranded; address staining makes this reachable for future contract addresses
**Severity**: Low
**Category**: evm-audit-erc20
**Location**: `claim()` (msg.sender only), `_skipNFTDefault()` (lines 128-143), `_transferFromNFT`
**Description**: Only the holding address can claim; there is no `claimFor`/`claimTo`. An NFT can be sent directly to any contract by `transferFrom` (escrow, custody), and an address without code counts as a wallet, so LING sent to a counterfactual address mints NFTs there; after deployment those NFTs sit in a contract that cannot move them and their earnings stay in `_owed` forever. Staining costs 300,000 LING per NFT, so it is uneconomic; the escrow case is a user-side loss.
**Proof of Concept**: `test_E5_*`: LING to an empty address mints an NFT; a no-claim contract etched there; after `addRewards{value:1 ether}` and a day, `pending(future)` is ~1 ETH, claimable by nobody.
**Recommendation**: Add `claim(address to)` or an approved `claimFor`; document that NFTs held by contracts without a claim path forfeit rewards and that sinks/modules at predictable addresses should be deployed before LING can reach them.

## [E-5] Permit2 holds an infinite default allowance over all LING, not listed as a trust assumption
**Severity**: Info
**Category**: evm-audit-erc20
**Location**: `DN404.allowance`, `DN404.transferFrom`, `_givePermit2DefaultInfiniteAllowance()` (lib/dn404/src/DN404.sol)
**Description**: `Swarmlings` does not override `_givePermit2DefaultInfiniteAllowance`, so Permit2 (0x000000000022D473030F116dDEE9F6B43aC78BA3) can `transferFrom` any holder's LING with no prior `approve` (a valid Permit2 signature is still needed). A phished Permit2 signature moves LING and its NFTs with no onchain approval to inspect. Revoke with `approve(PERMIT2, 0)`. No EIP-2612 `permit` (calls revert; no phantom-permit hazard).
**Proof of Concept**: `test_permit2IsInfinitelyApprovedByDefault`, `test_permitAndDomainSeparatorRevertNotPhantom`.
**Recommendation**: Override to return false if unwanted, or add Permit2 to the trust assumptions in docs/SECURITY.md.

## [E-6] LING sent to the token or mirror address is unrecoverable; auto-skip is sticky for balances above 800 units
**Severity**: Info
**Category**: evm-audit-erc20
**Location**: `_transfer` (lines 393-407); `transfer`/`transferFrom` accept `address(this)` and the mirror
**Description**: (a) Transfers to the token or its mirror succeed and nothing can spend that balance. (b) `_setSkipNFT(to, true)` from the 800-unit guard is effectively permanent while the receiver still needs more than 800 NFTs minted; `setSkipNFT(false)` followed by any transfer to that wallet flips it back. Not exploitable by a third party (forcing it costs ≥801 units given away).
**Proof of Concept**: `test_E3_mainnetOnlyHandlesWeth_otherTokensAreStuck`, `test_edges`.
**Recommendation**: Optionally revert transfers to `address(this)` and the mirror. Document the sticky skip flag.

## Checklist coverage
1. Transfer anomalies: LING moves exact amounts; IMD has no fee; inbound rewards use balance difference (donations go to holders); rebasing not applicable (downward change would underflow `_syncToken`, E-2); zero-amount allowed, `claim` never sends zero; LING reverts only for `address(0)` (E-6); no flash-mint, admin mint, blocklist or pause in LING or IMD.
2. Approvals: standard ERC-20 race only; `approve(x,0)` allowed; max allowance not decremented; Permit2 default (E-5).
3. Missing returns: `_payToken` accepts a no-return token only if the address has code, rejects false/reverts/short returndata.
4. Decimals: LING and IMD both 18; `SCALE = 1e36` cannot overflow at realistic amounts.
5. ERC777/677 hooks: none; `claim` zeroes the ledger and pays token before ETH under `nonReentrant` (transient slot 0); re-entering `transfer`/`claim` from the ETH callback cannot double-spend.
6. Permit: no EIP-2612, no phantom permit; Permit2 default (E-5).
7. Protocol-specific: WETH unwrap uses a 2300-gas empty `receive()`; off-mainnet WETH and other tokens stranded (E-1); DN404 burn-pool theft not applicable (`_addToBurnedPool` false); LIFO bait-and-switch affects only the owner (`keep` owner-only, approvals cleared); address staining is E-4.
8. Weird ERC-20s: supply 1e27 below 2^96; `name`/`symbol` return strings.

Also checked, no finding: `keep(ids)` (stateful fuzz 1500×150 over gives, moves, random keeps, burns, skip flags: no duplicate ids, owner/alias/index mismatches, NFT count above `balance/UNIT`); `burn(uint256)` runs `_accrueAll`/`_settle(from)` first; settlement covers every ownership change (`_transfer`, `_transferFromNFT`, `_burn`); `_skipNFTDefault` (valid 7702 designator → wallet, other prefixes → contract, explicit flag wins, scratch memory harmless; EIP-3541 blocks 0xEF contract code); MAX_MINT_PER_TRANSFER edges (exactly at limit mints, one over flips, self-transfers use post-burn count, revert rolls back the flag; sender-side burns ~2.5M gas for 800); BuybackBurn `take` then `burn` from a skip contract; TreasurySink `take` to a fixed recipient.

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DN404} from "dn404/DN404.sol";
import {SwarmlingsMirror} from "./SwarmlingsMirror.sol";

interface IRenderer {
    function tokenURI(uint256 id) external view returns (string memory);
}

interface IERC20Lite {
    function balanceOf(address owner) external view returns (uint256);
}

interface IWETH {
    function balanceOf(address owner) external view returns (uint256);
    function withdraw(uint256 amount) external;
}

/// @title Swarmlings (LING)
/// @notice A fixed-supply ERC-20 where every whole 300,000 LING a wallet holds is one Swarmling NFT, minted and
/// burned automatically by balance (DN404). NFT holders earn, equally per NFT and per second held:
/// - all swap fees from SwarmlingsHook, in `rewardCurrency` (IMD on Ethereum mainnet, native ETH elsewhere);
/// - half of the 5% creator fee on NFT sales, in ETH (the other half goes to DEV).
/// @dev No owner powers, admin, proxy, pause, mint or fee on transfer: every transfer moves exactly the amount
/// stated. Anyone may burn their own LING. `owner()` only tells marketplaces who edits the collection page; nothing in these contracts checks it.
/// Rewards are paid by day: everything that arrives during one EPOCH (a UTC day) is paid out the next day at a
/// constant rate per second, to whoever holds NFTs during that time. Holding for a moment (including flash loans)
/// earns only that moment's share, and every day's payout is known in advance. Accrual runs and both sides are
/// settled before every change of NFT ownership.
contract Swarmlings is DN404 {
    /// @notice LING per Swarmling. 1e27 / 300,000e18 = 3,333 NFTs at most; the last 100,000 LING never form one.
    uint256 public constant UNIT = 300_000e18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant MAX_NFTS = 3_333;

    /// @notice The art: same CREATE2 address on every chain (salt keccak256("swarmlings.renderer.v1")).
    address public constant RENDERER = 0x8d79e6677FA6E52190B39096f8496628811D8281;
    /// @notice Identity.md (IMD): the swap-fee reward on Ethereum mainnet.
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @notice WETH on Ethereum mainnet; creator fees paid in WETH are unwrapped and counted as ETH.
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @notice The project's dev and treasury wallet: receives half of the ETH that arrives as creator fees, and
    /// nothing from swaps. It holds no LING allocation and has no power in these contracts.
    address public constant DEV = 0x92cEf4823119f3332A85A39023eEbA01a06890c4;
    uint256 public constant DEV_SHARE_BPS = 5000;
    /// @notice Rewards that arrive during one epoch are paid out evenly over the next one.
    uint256 public constant EPOCH = 1 days;
    /// @notice A transfer that would mint more NFTs than this at once switches the receiver to skipNFT instead,
    /// so a large buy still fits in a transaction; the receiver can opt back in later with `setSkipNFT(false)`.
    uint256 public constant MAX_MINT_PER_TRANSFER = 1_000;

    uint256 public constant ETH_POT = 0;
    uint256 public constant TOKEN_POT = 1;
    uint256 private constant SCALE = 1e36;

    /// @notice The swap-fee currency: address(0) for native ETH, else an ERC-20. Fixed at deployment.
    address public immutable rewardCurrency;

    struct Pot {
        uint256 accPerNFT; // earned by one NFT since launch, scaled by 1e36
        uint256 rate; // scaled amount paid per second during `epoch`
        uint256 queued; // scaled amount to pay out from the next epoch on (arrivals, rounding, unheld time)
        uint64 epoch; // the epoch `rate` belongs to
        uint64 last; // accrued up to here
        uint256 accounted; // balance of this currency the ledger knows about (holders' and DEV's)
        uint256 total; // ever added for holders
        uint256 claimed; // ever paid to holders
    }

    Pot[2] internal _pot;
    mapping(address => uint256[2]) internal _owed;
    mapping(address => uint256[2]) internal _settledAcc;
    uint256 public devOwed;
    uint256 public devPaid;

    error PayFailed();
    error Reentrancy();
    error NotYours();

    event RewardQueued(uint256 indexed pot, uint256 amount, uint256 payoutEpoch);
    event Kept(address indexed holder, uint256[] ids);
    event AutoSkipNFT(address indexed holder, uint256 nftsNotMinted);
    event CreatorFee(uint256 amount, uint256 toHolders, uint256 toDev);
    event Claimed(address indexed holder, uint256 eth, uint256 token);
    event DevPaid(uint256 amount);

    constructor() {
        rewardCurrency = _chooseRewardCurrency();
        _initializeDN404(INITIAL_SUPPLY, msg.sender, address(new SwarmlingsMirror(msg.sender)));
    }

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(0) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`.
                revert(0x1c, 0x04)
            }
            tstore(0, 1)
        }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    /// @dev IMD on Ethereum mainnet, native ETH everywhere else. Virtual only for tests.
    function _chooseRewardCurrency() internal view virtual returns (address) {
        return block.chainid == 1 ? IMD : address(0);
    }

    // ------------------------------------------------------------------ metadata

    function name() public pure override returns (string memory) {
        return "Swarmlings";
    }

    function symbol() public pure override returns (string memory) {
        return "LING";
    }

    /// @notice For marketplaces only (OpenSea Studio reads it through the NFT contract). No power here.
    function owner() public pure returns (address) {
        return DEV;
    }

    function _unit() internal pure override returns (uint256) {
        return UNIT;
    }

    /// @dev Exactly what the renderer returns; a minimal valid JSON if it has no code or reverts.
    function _tokenURI(uint256 id) internal view override returns (string memory) {
        if (RENDERER.code.length != 0) {
            try IRenderer(RENDERER).tokenURI(id) returns (string memory uri) {
                return uri;
            } catch {}
        }
        return string.concat('data:application/json;utf8,{"name":"Swarmling #', _toString(id), '"}');
    }

    /// @notice Puts `ids` (yours) first in your list, in this order, so they are the last to burn when you sell.
    /// Selling burns from the end of the list; one call protects any number of favourites.
    function keep(uint256[] calldata ids) external {
        DN404Storage storage $ = _getDN404Storage();
        Uint32Map storage owned = $.owned[msg.sender];
        Uint32Map storage oo = $.oo;
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            if (_ownerAt(id) != msg.sender) revert NotYours();
            uint256 i = _get(oo, _ownedIndex(id));
            if (i < k) revert NotYours(); // listed twice
            if (i == k) continue;
            uint32 other = _get(owned, k);
            _set(owned, k, uint32(id));
            _set(owned, i, other);
            _set(oo, _ownedIndex(id), uint32(k));
            _set(oo, _ownedIndex(other), uint32(i));
        }
        emit Kept(msg.sender, ids);
    }

    // ------------------------------------------------------------------ money in

    /// @notice Plain ETH is a creator fee (royalty) or a gift; `syncEth` splits it between holders and DEV.
    /// Never reverts, so a marketplace sale can always pay.
    receive() external payable override {}

    /// @notice ETH for holders only (the hook's swap fees off mainnet). Open to anyone.
    function addRewards() external payable {
        if (msg.value == 0) return;
        _pot[ETH_POT].accounted += msg.value;
        _stream(ETH_POT, msg.value);
    }

    /// @notice Counts ETH (and, on mainnet, WETH) that arrived since the last call: half to DEV, half streamed to
    /// holders. Open to anyone; `claim` runs it too.
    function syncEth() external nonReentrant {
        _syncEth();
    }

    /// @notice Counts `rewardCurrency` ERC-20 that arrived since the last call and streams all of it to holders.
    /// Open to anyone; the hook calls it after each hand-over.
    function syncToken() external nonReentrant {
        _syncToken();
    }

    // ------------------------------------------------------------------ money out

    /// @notice Pays the caller everything their NFTs have earned, in ETH and in the reward token.
    function claim() external nonReentrant returns (uint256 eth, uint256 token) {
        _syncEth();
        _syncToken();
        _accrueAll();
        _settle(msg.sender);
        eth = _owed[msg.sender][ETH_POT];
        token = _owed[msg.sender][TOKEN_POT];
        if (eth != 0) {
            _owed[msg.sender][ETH_POT] = 0;
            _pot[ETH_POT].accounted -= eth;
            _pot[ETH_POT].claimed += eth;
        }
        if (token != 0) {
            _owed[msg.sender][TOKEN_POT] = 0;
            _pot[TOKEN_POT].accounted -= token;
            _pot[TOKEN_POT].claimed += token;
        }
        // the reward token first: once ETH is sent, a contract claimer runs code, and by then the ledger and the
        // token balance agree again (syncToken is locked here too)
        if (token != 0) _payToken(msg.sender, token);
        if (eth != 0) _payEth(msg.sender, eth);
        if (eth != 0 || token != 0) emit Claimed(msg.sender, eth, token);
    }

    /// @notice Sends DEV its half of the creator fees. Anyone can trigger it; the ETH only ever goes to DEV.
    function claimDev() external nonReentrant returns (uint256 amount) {
        _syncEth();
        amount = devOwed;
        if (amount == 0) return 0;
        devOwed = 0;
        devPaid += amount;
        _pot[ETH_POT].accounted -= amount;
        _payEth(DEV, amount);
        emit DevPaid(amount);
    }

    // ------------------------------------------------------------------ views

    /// @notice What `holder` can claim right now: ETH, and the reward token (0 off mainnet).
    function pending(address holder) external view returns (uint256 eth, uint256 token) {
        uint256 n = _balanceOfNFT(holder);
        eth = _owed[holder][ETH_POT] + n * (_accView(ETH_POT) - _settledAcc[holder][ETH_POT]) / SCALE;
        token = _owed[holder][TOKEN_POT] + n * (_accView(TOKEN_POT) - _settledAcc[holder][TOKEN_POT]) / SCALE;
    }

    /// @notice A pot today: paid per second now (wei), when today ends, what is queued for tomorrow, totals
    /// added and claimed, and everything not yet paid out (rest of today plus the queue).
    function stream(uint256 pot)
        external
        view
        returns (
            uint256 perSecond,
            uint256 dayEnds,
            uint256 tomorrow,
            uint256 total,
            uint256 claimed,
            uint256 unpaid
        )
    {
        Pot memory p = _advance(_pot[pot], _totalNFTSupply());
        dayEnds = (uint256(p.epoch) + 1) * EPOCH;
        uint256 left = dayEnds > block.timestamp ? (dayEnds - block.timestamp) * p.rate : 0;
        return (p.rate / SCALE, dayEnds, p.queued / SCALE, p.total, p.claimed, (left + p.queued) / SCALE);
    }

    /// @notice NFTs that exist now; each one earns the same share.
    function activeNFTs() external view returns (uint256) {
        return _totalNFTSupply();
    }

    /// @notice Ids `holder` owns, by position in their list [begin, end). Selling burns from the end.
    function ownedIds(address holder, uint256 begin, uint256 end) external view returns (uint256[] memory) {
        return _ownedIds(holder, begin, end);
    }

    // ------------------------------------------------------------------ streaming

    function _syncEth() private {
        if (block.chainid == 1 && WETH.code.length != 0) {
            uint256 w = IWETH(WETH).balanceOf(address(this));
            if (w != 0) IWETH(WETH).withdraw(w);
        }
        Pot storage p = _pot[ETH_POT];
        uint256 fresh = address(this).balance - p.accounted;
        if (fresh == 0) return;
        p.accounted += fresh;
        uint256 toDev = fresh * DEV_SHARE_BPS / 10000;
        devOwed += toDev;
        _stream(ETH_POT, fresh - toDev);
        emit CreatorFee(fresh, fresh - toDev, toDev);
    }

    function _syncToken() private {
        address c = rewardCurrency;
        if (c == address(0)) return;
        Pot storage p = _pot[TOKEN_POT];
        uint256 fresh = IERC20Lite(c).balanceOf(address(this)) - p.accounted;
        if (fresh == 0) return;
        p.accounted += fresh;
        _stream(TOKEN_POT, fresh);
    }

    /// @dev New money waits for the next epoch: it is paid out evenly during it.
    function _stream(uint256 pot, uint256 amount) private {
        Pot storage p = _pot[pot];
        _accrue(p);
        p.queued += amount * SCALE;
        p.total += amount;
        emit RewardQueued(pot, amount, uint256(p.epoch) + 1);
    }

    function _accrue(Pot storage p) private {
        Pot memory q = _advance(p, _totalNFTSupply());
        p.accPerNFT = q.accPerNFT;
        p.rate = q.rate;
        p.queued = q.queued;
        p.epoch = q.epoch;
        p.last = q.last;
    }

    /// @dev Pays `p` up to now for `nfts` NFTs, which is constant over that time because every change of the NFT
    /// count accrues first. Time with no NFT sends its share back to the queue. At most three steps: the rest of
    /// the current epoch, the next one (paying what was queued), then a jump to today.
    function _advance(Pot memory p, uint256 nfts) private view returns (Pot memory) {
        uint256 nowTs = block.timestamp;
        while (true) {
            uint256 end = (uint256(p.epoch) + 1) * EPOCH;
            uint256 t = nowTs < end ? nowTs : end;
            if (t > p.last) {
                uint256 amount = (t - p.last) * p.rate;
                if (nfts == 0) p.queued += amount;
                else p.accPerNFT += amount / nfts;
                p.last = uint64(t);
            }
            if (nowTs < end) return p;
            uint256 today = nowTs / EPOCH;
            p.epoch = uint64(nfts == 0 ? today : p.epoch + 1);
            p.last = uint64(uint256(p.epoch) * EPOCH);
            p.rate = p.queued / EPOCH;
            p.queued -= p.rate * EPOCH;
            if (p.rate == 0 && p.epoch < today) {
                p.epoch = uint64(today);
                p.last = uint64(today * EPOCH);
            }
        }
        return p; // unreachable
    }

    function _accrueAll() private {
        _accrue(_pot[ETH_POT]);
        if (rewardCurrency != address(0)) _accrue(_pot[TOKEN_POT]);
    }

    function _accView(uint256 pot) private view returns (uint256) {
        return _advance(_pot[pot], _totalNFTSupply()).accPerNFT;
    }

    // ------------------------------------------------------------------ settlement around NFT moves

    /// @dev Credits what `holder`'s NFTs earned since their last settlement. Runs after `_accrueAll` and before
    /// their NFT count changes; the count only changes inside `_transfer` and `_transferFromNFT`.
    function _settle(address holder) private {
        uint256 n = _balanceOfNFT(holder);
        for (uint256 i; i < 2; ++i) {
            uint256 acc = _pot[i].accPerNFT;
            uint256 last = _settledAcc[holder][i];
            if (last == acc) continue;
            if (n != 0) _owed[holder][i] += n * (acc - last) / SCALE;
            _settledAcc[holder][i] = acc;
        }
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        _accrueAll();
        _settle(from);
        _settle(to);
        if (!getSkipNFT(to)) {
            uint256 after_ = from == to ? balanceOf(to) : balanceOf(to) + amount;
            uint256 mint = after_ / UNIT;
            uint256 have = _balanceOfNFT(to);
            if (mint > have + MAX_MINT_PER_TRANSFER) {
                _setSkipNFT(to, true);
                emit AutoSkipNFT(to, mint - have);
            }
        }
        super._transfer(from, to, amount);
    }

    function _transferFromNFT(address from, address to, uint256 id, address msgSender) internal override {
        _accrueAll();
        _settle(from);
        _settle(to);
        super._transferFromNFT(from, to, id, msgSender);
    }

    /// @notice Burns `amount` LING from the caller, and the Swarmlings it no longer backs. Supply only ever
    /// shrinks this way; the Hive's buyback module uses it.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function _burn(address from, uint256 amount) internal override {
        _accrueAll();
        _settle(from);
        super._burn(from, amount);
    }

    // ------------------------------------------------------------------ helpers

    function _payEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayFailed();
    }

    function _payToken(address to, uint256 amount) private {
        address c = rewardCurrency;
        (bool ok, bytes memory ret) = c.call(abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer
        if (!ok || (ret.length == 0 ? c.code.length == 0 : !abi.decode(ret, (bool)))) revert PayFailed();
    }

    function _toString(uint256 v) private pure returns (string memory s) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) {
            ++len;
        }
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) {
            b[--len] = bytes1(uint8(48 + v % 10));
        }
        s = string(b);
    }
}

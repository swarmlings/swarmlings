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
/// stated. `owner()` only tells marketplaces who edits the collection page; nothing in these contracts checks it.
/// Rewards are streamed: each amount that arrives is folded, with whatever is still unpaid, into a new STREAM-long
/// stream to whoever holds NFTs during that time, so holding for a moment (including flash loans) earns only that
/// moment's share. With steady trading this pays out gradually (roughly two thirds within a day). Accrual runs
/// and both sides are settled before every change of NFT ownership.
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
    /// @notice Every reward is paid out evenly over this long.
    uint256 public constant STREAM = 1 days;

    uint256 public constant ETH_POT = 0;
    uint256 public constant TOKEN_POT = 1;
    uint256 private constant SCALE = 1e36;

    /// @notice The swap-fee currency: address(0) for native ETH, else an ERC-20. Fixed at deployment.
    address public immutable rewardCurrency;

    struct Pot {
        uint256 accPerNFT; // earned by one NFT since launch, scaled by 1e36
        uint256 rate; // scaled amount streamed per second
        uint256 idle; // scaled amount waiting to be streamed (accrued while no NFT existed, or rounding)
        uint64 finish; // when the current stream ends
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

    event RewardStreamed(uint256 indexed pot, uint256 amount, uint256 ratePerSecond, uint256 finish);
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

    /// @notice A pot's stream: amount per second (in wei), when it ends, totals added and claimed, and what is
    /// still to be paid out (the rest of the stream, plus anything that waits for an NFT to exist).
    function stream(uint256 pot)
        external
        view
        returns (uint256 perSecond, uint256 finish, uint256 total, uint256 claimed, uint256 unpaid)
    {
        Pot storage p = _pot[pot];
        uint256 t = block.timestamp < p.finish ? block.timestamp : p.finish;
        uint256 scaled = p.idle + (p.finish > t ? (p.finish - t) * p.rate : 0);
        if (t > p.last && _totalNFTSupply() == 0) scaled += (t - p.last) * p.rate;
        return (p.rate / SCALE, p.finish, p.total, p.claimed, scaled / SCALE);
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

    /// @dev Folds what is left of the current stream, plus anything idle, into a new STREAM-long stream.
    function _stream(uint256 pot, uint256 amount) private {
        Pot storage p = _pot[pot];
        _accrue(p);
        uint256 left = p.finish > block.timestamp ? (p.finish - block.timestamp) * p.rate : 0;
        uint256 total = amount * SCALE + left + p.idle;
        uint256 rate = total / STREAM;
        p.rate = rate;
        p.idle = total - rate * STREAM;
        p.finish = uint64(block.timestamp + STREAM);
        p.last = uint64(block.timestamp);
        p.total += amount;
        emit RewardStreamed(pot, amount, rate / SCALE, block.timestamp + STREAM);
    }

    /// @dev The NFT count is constant between two accruals, because every change of it accrues first.
    function _accrue(Pot storage p) private {
        uint256 t = block.timestamp < p.finish ? block.timestamp : p.finish;
        uint256 last = p.last;
        if (t <= last) return;
        uint256 amount = (t - last) * p.rate;
        p.last = uint64(t);
        uint256 nfts = _totalNFTSupply();
        if (nfts == 0) p.idle += amount;
        else p.accPerNFT += amount / nfts;
    }

    function _accrueAll() private {
        _accrue(_pot[ETH_POT]);
        if (rewardCurrency != address(0)) _accrue(_pot[TOKEN_POT]);
    }

    function _accView(uint256 pot) private view returns (uint256 acc) {
        Pot storage p = _pot[pot];
        acc = p.accPerNFT;
        uint256 t = block.timestamp < p.finish ? block.timestamp : p.finish;
        uint256 nfts = _totalNFTSupply();
        if (t > p.last && nfts != 0) acc += (t - p.last) * p.rate / nfts;
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
        super._transfer(from, to, amount);
    }

    function _transferFromNFT(address from, address to, uint256 id, address msgSender) internal override {
        _accrueAll();
        _settle(from);
        _settle(to);
        super._transferFromNFT(from, to, id, msgSender);
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
        for (uint256 t = v; t != 0; t /= 10) ++len;
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) b[--len] = bytes1(uint8(48 + v % 10));
        s = string(b);
    }
}

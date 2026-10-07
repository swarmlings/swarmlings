// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {SwarmlingsMirror, ICreatorToken} from "../src/SwarmlingsMirror.sol";

contract MockRenderer {
    function tokenURI(uint256 id) external pure returns (string memory) {
        return string.concat("data:application/json;base64,ART", id == 7 ? "7" : "?");
    }
}

contract RevertingRenderer {
    function tokenURI(uint256) external pure returns (string memory) {
        revert("broken");
    }
}

/// @dev Stands in for OpenSea's registry: owners may move their own NFTs, operators need an authorization.
contract MockValidator {
    mapping(address => bool) public authorized;
    uint256 public calls;

    function allow(address operator, bool ok) external {
        authorized[operator] = ok;
    }

    function validateTransfer(address caller, address from, address, uint256) external view {
        if (caller != from && !authorized[caller]) revert("unauthorized operator");
    }
}

/// @dev Re-enters claim from its receive hook.
contract GreedyHolder {
    Swarmlings immutable ling;
    uint256 public reentered;

    constructor(Swarmlings l) {
        ling = l;
        l.setSkipNFT(false);
    }

    function claim() external {
        ling.claim();
    }

    receive() external payable {
        if (reentered++ == 0) ling.claim();
    }
}

/// @dev Token behaviour without a pool: units, skipNFT, streamed rewards, creator fees and NFT moves.
contract SwarmlingsTest is Test {
    address launcher = makeAddr("launcher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    Swarmlings ling;
    SwarmlingsMirror mirror;
    uint256 UNIT;
    uint256 DAY;

    function setUp() public virtual {
        vm.prank(launcher);
        ling = new Swarmlings();
        mirror = SwarmlingsMirror(payable(ling.mirrorERC721()));
        UNIT = ling.UNIT();
        DAY = ling.STREAM();
        vm.deal(address(this), 1_000 ether);
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(launcher);
        ling.transfer(to, amount);
    }

    /// @dev What the hook does off mainnet: holders-only ETH.
    function _swapFees(uint256 amount) internal {
        ling.addRewards{value: amount}();
    }

    /// @dev What a marketplace does: plain ETH to the token, counted at the next sync.
    function _creatorFee(uint256 amount) internal {
        (bool ok,) = address(ling).call{value: amount}("");
        assertTrue(ok);
        ling.syncEth();
    }

    function _eth(address who) internal view returns (uint256 e) {
        (e,) = ling.pending(who);
    }

    // ------------------------------------------------------------------ supply and units

    function test_constructor() public view {
        assertEq(ling.totalSupply(), 1e27);
        assertEq(ling.balanceOf(launcher), 1e27);
        assertTrue(ling.getSkipNFT(launcher), "the launcher never receives NFTs");
        assertEq(ling.name(), "Swarmlings");
        assertEq(ling.symbol(), "LING");
        assertEq(ling.decimals(), 18);
        assertEq(UNIT, 300_000e18);
        assertEq(ling.INITIAL_SUPPLY() / UNIT, ling.MAX_NFTS());
        assertEq(mirror.totalSupply(), 0);
        assertEq(ling.rewardCurrency(), block.chainid == 1 ? ling.IMD() : address(0), "IMD on mainnet, ETH elsewhere");
        assertEq(mirror.owner(), ling.DEV(), "marketplaces see the dev as collection editor");
    }

    function test_unitBoundaries() public {
        _give(alice, UNIT - 0.01e18);
        assertEq(mirror.balanceOf(alice), 0, "299,999.99 LING is no Swarmling");
        _give(alice, 0.01e18);
        assertEq(mirror.balanceOf(alice), 1, "300,000 LING is one");
        _give(alice, UNIT * 2);
        assertEq(mirror.balanceOf(alice), 3);
        vm.prank(alice);
        ling.transfer(bob, 1);
        assertEq(mirror.balanceOf(alice), 2, "dropping one wei below 3 units burns one");
        assertEq(mirror.balanceOf(bob), 0);
    }

    function test_transfersMoveExactAmounts(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        _give(alice, amount);
        assertEq(ling.balanceOf(alice), amount);
        assertEq(ling.balanceOf(launcher), 1e27 - amount);
        assertEq(ling.totalSupply(), 1e27);
        assertEq(mirror.balanceOf(alice), amount / UNIT);
    }

    function test_swarmShareMintsNoNftUntilTopUp() public {
        _give(alice, 120_000e18); // a typical 8% swarm seat share
        assertEq(mirror.balanceOf(alice), 0);
        _give(alice, 180_000e18);
        assertEq(mirror.balanceOf(alice), 1);
    }

    function test_contractsSkipUnlessTheyOptIn() public {
        GreedyHolder c = new GreedyHolder(ling);
        address plain = address(new MockRenderer());
        _give(plain, UNIT * 2);
        _give(address(c), UNIT);
        assertEq(mirror.balanceOf(plain), 0, "contracts skip NFTs by default");
        assertEq(mirror.balanceOf(address(c)), 1, "an opted-in contract gets them");
    }

    function test_codeBearingEoaSkipsUntilOptIn() public {
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(0x1234))); // EIP-7702 delegation designator
        _give(alice, UNIT);
        assertEq(mirror.balanceOf(alice), 0);
        vm.prank(alice);
        ling.setSkipNFT(false);
        _give(alice, 1);
        assertEq(mirror.balanceOf(alice), 1);
    }

    // ------------------------------------------------------------------ streamed rewards

    function test_rewardsStreamOverADay() public {
        _give(alice, UNIT * 3);
        _give(bob, UNIT);
        _swapFees(4 ether);
        assertEq(_eth(alice), 0, "nothing at the moment it arrives");
        skip(DAY / 2);
        assertApproxEqAbs(_eth(alice), 1.5 ether, 1e6);
        assertApproxEqAbs(_eth(bob), 0.5 ether, 1e6);
        skip(DAY);
        assertApproxEqAbs(_eth(alice), 3 ether, 1e6, "all of it after the stream ends");
        assertApproxEqAbs(_eth(bob), 1 ether, 1e6);
        assertEq(_eth(launcher), 0, "skip holders earn nothing");

        uint256 before = alice.balance;
        vm.prank(alice);
        (uint256 e,) = ling.claim();
        assertEq(alice.balance - before, e);
        assertApproxEqAbs(e, 3 ether, 1e6);
        assertEq(_eth(alice), 0);
    }

    function test_holdingForAMomentEarnsAMomentsShare() public {
        _give(alice, UNIT * 10);
        _swapFees(10 ether);
        skip(DAY / 2);
        _give(bob, UNIT * 1000); // a whale arrives halfway, holds one second, leaves
        skip(1);
        vm.prank(bob);
        ling.transfer(launcher, UNIT * 1000);
        skip(DAY);
        assertLt(_eth(bob), 0.0002 ether, "one second of a day");
        assertApproxEqRel(_eth(alice), 10 ether, 0.001e18);
    }

    function test_newRewardsFoldIntoTheStream() public {
        _give(alice, UNIT);
        _swapFees(1 ether);
        skip(DAY / 2);
        _swapFees(1 ether); // 0.5 left + 1 new, over a fresh day
        skip(DAY);
        assertApproxEqAbs(_eth(alice), 2 ether, 1e6);
    }

    function test_rewardWithNoNftsWaitsForTheFirstOne() public {
        _swapFees(1 ether);
        skip(DAY * 2); // streamed into nobody: kept idle
        _give(alice, UNIT);
        _swapFees(1 ether); // idle joins the new stream
        skip(DAY);
        assertApproxEqAbs(_eth(alice), 2 ether, 1e6);
    }

    /// @dev An NFT sold on a marketplace: LING moves with it, earnings stay with the seller.
    function test_nftSaleKeepsEarningsWithSeller() public {
        _give(alice, UNIT * 2);
        _swapFees(2 ether);
        skip(DAY);
        uint256 id = ling.ownedIds(alice, 0, 1)[0];
        vm.prank(alice);
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
        assertEq(ling.balanceOf(bob), UNIT, "300,000 LING went with the NFT");
        assertApproxEqAbs(_eth(alice), 2 ether, 1e6, "seller keeps what both NFTs earned");
        assertEq(_eth(bob), 0, "buyer starts from zero");

        _swapFees(2 ether);
        skip(DAY);
        assertApproxEqAbs(_eth(alice), 3 ether, 1e6);
        assertApproxEqAbs(_eth(bob), 1 ether, 1e6);
    }

    function test_sellingBelowAUnitBurnsTheNewestAndKeepsEarnings() public {
        _give(alice, UNIT * 2);
        uint256[] memory ids = ling.ownedIds(alice, 0, 2);
        _swapFees(2 ether);
        skip(DAY);
        vm.prank(alice);
        ling.transfer(launcher, 1); // e.g. a sell into the pool
        assertEq(mirror.balanceOf(alice), 1);
        assertEq(ling.ownedIds(alice, 0, 1)[0], ids[0], "the newest id burns first");
        assertEq(mirror.ownerAt(ids[1]), address(0), "burned");
        assertApproxEqAbs(_eth(alice), 2 ether, 1e6, "earnings of the burned NFT stay claimable");
    }

    /// @dev Keep a favourite: sending your other NFTs to yourself moves them behind it, so they burn first.
    function test_selfTransferProtectsAFavourite() public {
        _give(alice, UNIT * 3);
        uint256[] memory ids = ling.ownedIds(alice, 0, 3); // ids[0] oldest .. ids[2] newest
        uint256 favourite = ids[2]; // would burn first
        vm.startPrank(alice);
        mirror.transferFrom(alice, alice, ids[0]);
        mirror.transferFrom(alice, alice, ids[1]);
        ling.transfer(launcher, UNIT * 2); // sell two units
        vm.stopPrank();
        assertEq(mirror.ownerOf(favourite), alice, "the favourite survived");
        assertEq(mirror.balanceOf(alice), 1);
    }

    function test_claimCannotBeReentered() public {
        GreedyHolder g = new GreedyHolder(ling);
        _give(address(g), UNIT);
        _swapFees(1 ether);
        skip(DAY);
        vm.expectRevert(Swarmlings.PayFailed.selector);
        g.claim();
        assertApproxEqAbs(_eth(address(g)), 1 ether, 1e6, "a failed claim changes nothing");
    }

    function testFuzz_rewardsNeverExceedWhatArrived(uint256 a, uint256 b, uint256 v1, uint256 v2, uint256 moved, uint256 dt)
        public
    {
        a = bound(a, 0, 50);
        b = bound(b, 1, 50);
        v1 = bound(v1, 1, 100 ether);
        v2 = bound(v2, 1, 100 ether);
        dt = bound(dt, 0, 3 * DAY);
        _give(alice, UNIT * a);
        _give(bob, UNIT * b);
        _swapFees(v1);
        skip(dt);
        moved = bound(moved, 0, ling.balanceOf(bob));
        vm.prank(bob);
        ling.transfer(carol, moved);
        _swapFees(v2);
        skip(2 * DAY);
        uint256 owedTotal = _eth(alice) + _eth(bob) + _eth(carol);
        assertLe(owedTotal, v1 + v2);
        // with no NFT left after the move, the second reward waits idle for the next holder instead
        if (ling.activeNFTs() != 0) assertLe(v1 + v2 - owedTotal, 1e6, "only rounding dust stays behind");
        assertLe(owedTotal, address(ling).balance, "always solvent");
    }

    // ------------------------------------------------------------------ creator fees

    function test_creatorFeeSplitsHalfToDev() public {
        _give(alice, UNIT);
        _creatorFee(1 ether);
        assertEq(ling.devOwed(), 0.5 ether);
        skip(DAY);
        assertApproxEqAbs(_eth(alice), 0.5 ether, 1e6);
        uint256 before = ling.DEV().balance;
        vm.prank(bob); // anyone can trigger; the ETH only goes to DEV
        ling.claimDev();
        assertEq(ling.DEV().balance - before, 0.5 ether);
        assertEq(ling.devOwed(), 0);
    }

    function test_swapFeesNeverGoToDev() public {
        _give(alice, UNIT);
        _swapFees(1 ether);
        ling.syncEth();
        assertEq(ling.devOwed(), 0);
    }

    function test_claimCountsUnsyncedCreatorFees() public {
        _give(alice, UNIT);
        (bool ok,) = address(ling).call{value: 2 ether}("");
        assertTrue(ok);
        vm.prank(alice);
        ling.claim(); // syncs first; nothing streamed yet
        skip(DAY);
        assertApproxEqAbs(_eth(alice), 1 ether, 1e6);
        assertEq(ling.devOwed(), 1 ether);
    }

    function test_royaltyInfo() public view {
        (address r, uint256 amount) = mirror.royaltyInfo(1, 1 ether);
        assertEq(r, address(ling));
        assertEq(amount, 0.05 ether);
        assertTrue(mirror.supportsInterface(0x2a55205a), "ERC-2981");
        assertTrue(mirror.supportsInterface(type(ICreatorToken).interfaceId), "ERC721-C");
        assertTrue(mirror.supportsInterface(0x80ac58cd), "ERC-721");
        assertEq(mirror.getTransferValidator(), mirror.TRANSFER_VALIDATOR());
        (bytes4 fn, bool isView) = mirror.getTransferValidationFunction();
        assertEq(fn, bytes4(0xcaee23ea));
        assertTrue(isView);
    }

    function test_validatorIsFixed() public {
        vm.expectRevert(SwarmlingsMirror.ValidatorIsFixed.selector);
        mirror.setTransferValidator(address(0));
    }

    function test_validatorGatesOperatorTransfersOnly() public {
        MockValidator v = new MockValidator();
        vm.etch(mirror.TRANSFER_VALIDATOR(), address(v).code);
        MockValidator reg = MockValidator(mirror.TRANSFER_VALIDATOR());
        _give(alice, UNIT * 2);
        uint256[] memory ids = ling.ownedIds(alice, 0, 2);
        address market = makeAddr("market");
        vm.prank(alice);
        mirror.setApprovalForAll(market, true);

        vm.prank(alice);
        mirror.transferFrom(alice, bob, ids[0]); // owners move their own NFTs
        assertEq(mirror.ownerOf(ids[0]), bob);

        vm.prank(market);
        vm.expectRevert(bytes("unauthorized operator"));
        mirror.transferFrom(alice, carol, ids[1]);

        reg.allow(market, true); // e.g. Seaport with the creator fee attested
        vm.prank(market);
        mirror.transferFrom(alice, carol, ids[1]);
        assertEq(mirror.ownerOf(ids[1]), carol);

        vm.prank(carol); // moving LING always works, whatever the validator says
        ling.transfer(alice, UNIT);
        assertEq(mirror.balanceOf(alice), 1);
    }

    // ------------------------------------------------------------------ art

    function test_tokenURIPlaceholderWithoutRenderer() public {
        _give(alice, UNIT);
        assertEq(mirror.tokenURI(1), 'data:application/json;utf8,{"name":"Swarmling #1"}');
    }

    function test_tokenURIComesFromRenderer() public {
        vm.etch(ling.RENDERER(), address(new MockRenderer()).code);
        _give(alice, UNIT * 7);
        assertEq(mirror.tokenURI(7), "data:application/json;base64,ART7");
    }

    function test_tokenURISurvivesARevertingRenderer() public {
        vm.etch(ling.RENDERER(), address(new RevertingRenderer()).code);
        _give(alice, UNIT);
        assertEq(mirror.tokenURI(1), 'data:application/json;utf8,{"name":"Swarmling #1"}');
    }
}

/// @dev Calls syncToken from its ETH callback, the reviewer's double-count attempt.
contract SyncOnReceive {
    Swarmlings immutable ling;

    constructor(Swarmlings l) {
        ling = l;
        l.setSkipNFT(false);
    }

    function claim() external returns (uint256 e, uint256 t) {
        return ling.claim();
    }

    receive() external payable {
        ling.syncToken();
    }
}

/// @dev Mainnet: swap fees arrive in IMD (all to holders) while creator fees arrive in ETH (half to DEV).
contract SwarmlingsMainnetTest is SwarmlingsTest {
    MockERC20 imd;

    function setUp() public override {
        vm.chainId(1);
        deployCodeTo(
            "lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("Identity.md", "IMD", uint8(18)),
            0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7
        );
        imd = MockERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        super.setUp();
    }

    function _imdFees(uint256 amount) internal {
        imd.mint(address(ling), amount);
        ling.syncToken();
    }

    function test_mainnetEarnsBothCurrencies() public {
        assertEq(ling.rewardCurrency(), address(imd));
        _give(alice, UNIT);
        _give(bob, UNIT);
        _imdFees(100e18);
        _creatorFee(1 ether);
        assertEq(ling.devOwed(), 0.5 ether, "dev gets half of the ETH only");
        skip(DAY);
        (uint256 e, uint256 t) = ling.pending(alice);
        assertApproxEqAbs(e, 0.25 ether, 1e6);
        assertApproxEqAbs(t, 50e18, 1e6);

        uint256 eb = alice.balance;
        vm.prank(alice);
        (uint256 ce, uint256 ct) = ling.claim();
        assertEq(alice.balance - eb, ce);
        assertEq(imd.balanceOf(alice), ct);
        assertApproxEqAbs(ct, 50e18, 1e6);
    }

    function test_claimCannotReenterSyncToken() public {
        SyncOnReceive c = new SyncOnReceive(ling);
        _give(address(c), UNIT);
        _give(alice, UNIT);
        _imdFees(100e18);
        _swapFees(1 ether);
        skip(DAY);
        vm.expectRevert(Swarmlings.PayFailed.selector); // its callback hits the lock, so its own claim fails
        c.claim();
        (, uint256 total,,) = _tokenStream();
        assertEq(total, 100e18, "nothing counted twice");
        vm.prank(alice);
        (, uint256 t) = ling.claim();
        assertApproxEqAbs(t, 50e18, 1e6, "everyone else still claims");
        ling.syncToken();
    }

    function _tokenStream() internal view returns (uint256, uint256, uint256, uint256) {
        (uint256 r, uint256 f, uint256 total, uint256 claimed,) = ling.stream(1);
        return (r, total, f, claimed);
    }

    function test_unsolicitedImdGoesToHoldersToo() public {
        _give(alice, UNIT);
        imd.mint(address(ling), 10e18);
        vm.prank(alice);
        ling.claim(); // counts it
        skip(DAY);
        (, uint256 t) = ling.pending(alice);
        assertApproxEqAbs(t, 10e18, 1e6);
        assertEq(ling.devOwed(), 0);
    }
}

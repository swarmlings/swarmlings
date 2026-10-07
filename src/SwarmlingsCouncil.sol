// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwarmlingsHook} from "./interfaces/IHive.sol";

/// @title SwarmlingsCouncil
/// @notice The timelock that governs the Hive. Every change to the hook's slices, modules or council goes
/// through `propose` and can run no sooner than `DELAY` later, so holders always see what is coming and have
/// time to act. Two things need no delay because they only ever take behaviour away: `disableModule`, and
/// nothing else. `post` writes a journal entry on chain.
/// @dev The owner (the dev wallet at first) proposes; anyone may execute a ripe proposal. Changing the owner is
/// itself a proposal (`setOwner` accepts only the council). Deployed with CREATE2 so the hook can name it as a
/// constant before it exists.
contract SwarmlingsCouncil {
    uint256 public constant DELAY = 2 days;
    /// @notice A proposal that is not executed within this window after it ripens lapses.
    uint256 public constant GRACE = 14 days;

    struct Proposal {
        address target;
        bytes32 dataHash;
        uint64 eta;
        bool done;
    }

    address public owner;
    uint256 public nonce;
    mapping(bytes32 => Proposal) public proposals;

    error OnlyOwner();
    error OnlySelf();
    error UnknownProposal();
    error TooEarly();
    error Lapsed();
    error Mismatch();

    event Proposed(bytes32 indexed id, address indexed target, bytes data, string memo, uint256 eta);
    event Executed(bytes32 indexed id);
    event Cancelled(bytes32 indexed id);
    event Journal(string memo);
    event OwnerSet(address indexed owner);

    constructor(address owner_) {
        owner = owner_;
        emit OwnerSet(owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Queues `target.call(data)` for `DELAY` from now. `memo` is the reason, kept in the log.
    function propose(address target, bytes calldata data, string calldata memo)
        external
        onlyOwner
        returns (bytes32 id)
    {
        id = keccak256(abi.encode(target, data, nonce++));
        uint256 eta = block.timestamp + DELAY;
        proposals[id] = Proposal(target, keccak256(data), uint64(eta), false);
        emit Proposed(id, target, data, memo, eta);
    }

    /// @notice Runs a ripe proposal. Anyone may call; the call data must match what was proposed.
    function execute(bytes32 id, bytes calldata data) external returns (bytes memory result) {
        Proposal storage p = proposals[id];
        if (p.eta == 0 || p.done) revert UnknownProposal();
        if (block.timestamp < p.eta) revert TooEarly();
        if (block.timestamp > p.eta + GRACE) revert Lapsed();
        if (keccak256(data) != p.dataHash) revert Mismatch();
        p.done = true;
        bool ok;
        (ok, result) = p.target.call(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        emit Executed(id);
    }

    function cancel(bytes32 id) external onlyOwner {
        Proposal storage p = proposals[id];
        if (p.eta == 0 || p.done) revert UnknownProposal();
        p.done = true;
        emit Cancelled(id);
    }

    /// @notice Removes a module from `hook` at once. Only ever takes behaviour away, so it needs no delay.
    function disableModule(address hook, address module) external onlyOwner {
        ISwarmlingsHook(hook).disableModule(module);
    }

    /// @notice A journal entry: what changed and why, in plain words, on chain.
    function post(string calldata memo) external onlyOwner {
        emit Journal(memo);
    }

    /// @notice Only through a proposal targeting this contract.
    function setOwner(address newOwner) external {
        if (msg.sender != address(this)) revert OnlySelf();
        owner = newOwner;
        emit OwnerSet(newOwner);
    }
}

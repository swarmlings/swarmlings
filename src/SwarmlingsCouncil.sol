// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SwarmlingsCouncil
/// @notice The hand that configures the Hive. Its owner (the dev wallet) can attach or remove slices and modules
/// at once; every change carries a memo and is logged, and `post` writes a journal entry on chain. The hook's
/// hard limits (holder floor, 5% cap, nothing can block a sell) hold whatever the council does. The owner can
/// hand the council to another address, for example a timelock or a holder vote, at any time.
/// @dev Deployed with CREATE2 so the hook can name it as a constant before it exists.
contract SwarmlingsCouncil {
    address public owner;

    error OnlyOwner();

    event Executed(address indexed target, bytes data, string memo);
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

    /// @notice Runs `target.call(data)` now. `memo` says what and why, for the log.
    function execute(address target, bytes calldata data, string calldata memo)
        external
        onlyOwner
        returns (bytes memory result)
    {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        emit Executed(target, data, memo);
    }

    /// @notice A journal entry: what changed and why, in plain words, on chain.
    function post(string calldata memo) external onlyOwner {
        emit Journal(memo);
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
        emit OwnerSet(newOwner);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DN404Mirror} from "dn404/DN404Mirror.sol";

interface IOwnerView {
    function owner() external view returns (address);
}

interface ITransferValidator {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}

/// @dev OpenSea's creator token interface (ERC721-C), see docs.opensea.io/docs/creator-fee-enforcement.
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
    function setTransferValidator(address validator) external;
}

/// @title Swarmlings NFT (the ERC-721 side of LING)
/// @notice DN404 mirror with a 5% creator fee (ERC-2981) paid to the Swarmlings token, which gives half to
/// NFT holders and half to the dev, and OpenSea's creator-fee enforcement: marketplace transfers of an NFT
/// must pass the fixed transfer validator, so sales through Seaport carry the fee.
/// @dev The validator is a constant; nobody can change or remove it. It is only consulted for NFT transfers
/// made through this contract. Moving LING moves NFTs too (DN404), so holders can never be locked out of their
/// NFTs by the validator; the same path also means the creator fee cannot be enforced on LING transfers.
contract SwarmlingsMirror is DN404Mirror, ICreatorToken {
    /// @notice OpenSea's StrictAuthorizedTransferSecurityRegistry (same address on Ethereum and Sepolia).
    address public constant TRANSFER_VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    uint256 public constant ROYALTY_BPS = 500;

    error ValidatorIsFixed();

    constructor(address deployer) DN404Mirror(deployer) {
        emit TransferValidatorUpdated(address(0), TRANSFER_VALIDATOR);
    }

    /// @notice The collection editor marketplaces show (the token's `owner()`); it has no power in these contracts.
    /// @dev Read live: the base cannot answer while it is still being constructed, so nothing is cached.
    function owner() public view override returns (address) {
        return IOwnerView(baseERC20()).owner();
    }

    function getTransferValidator() external pure returns (address) {
        return TRANSFER_VALIDATOR;
    }

    /// @dev validateTransfer(address,address,address,uint256), a view.
    function getTransferValidationFunction() external pure returns (bytes4, bool) {
        return (0xcaee23ea, true);
    }

    function setTransferValidator(address) external pure {
        revert ValidatorIsFixed();
    }

    /// @notice ERC-2981: 5% of every sale, to the Swarmlings token (half to holders, half to the dev).
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 amount) {
        return (baseERC20(), salePrice * ROYALTY_BPS / 10000);
    }

    /// @dev safeTransferFrom routes through here too.
    function transferFrom(address from, address to, uint256 id) public payable override {
        if (TRANSFER_VALIDATOR.code.length != 0) {
            ITransferValidator(TRANSFER_VALIDATOR).validateTransfer(msg.sender, from, to, id);
        }
        super.transferFrom(from, to, id);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a // ERC-2981
            || interfaceId == type(ICreatorToken).interfaceId || super.supportsInterface(interfaceId);
    }
}

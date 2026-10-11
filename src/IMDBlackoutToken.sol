// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMDBlackout (IMDBLACKOUT)
/// @notice A fixed-supply ERC-20 for the IMDBlackout custom-token launch on Robinhood Chain.
/// @dev Design, in one place:
///
///  - Supply. Exactly 1,000,000,000 whole tokens with 18 decimals are minted once, in the constructor,
///    to `msg.sender`. On launch `msg.sender` is the IMD ProjectFactory, which pays the swarm's share
///    to the MerkleDistributor, seeds the Uniswap v4 pool, and forwards the remainder to the requester.
///    There is no mint function, no owner, no minter role and no upgrade path, so the supply can never
///    grow after deployment. Holders may burn their own tokens through {burn}; nobody can burn anyone
///    else's.
///
///  - Transfer rules. The brief's "Transfer rules" field named only the requester's wallet,
///    0x6616Cb624cec0B46C9718D423098150587D1272b, and no restriction, fee, tax, cooldown or limit.
///    Transfers are therefore the plain ERC-20 rules: a holder moves what it holds, an approved spender
///    moves what it was approved for, and every transfer delivers exactly the amount sent. There is no
///    pause, blacklist, freeze, lock or seize power, so no privileged hand can move or freeze a holder's
///    balance. The launch flows (factory to distributor, distributor to claimants, seed and swaps
///    through the PoolManager) therefore move exactly what they say without any exemption list.
///
///  - Requester. The address from the brief is recorded as {REQUESTER} for reference. It carries no
///    power over the token: it is where the launch forwards the requester's remainder (the manifest's
///    `economics.remainderTo`) and is exposed here only so integrators and reviewers can confirm it.
///
///  - Constructor. Takes no arguments and calls no other contract, so the launch's deployer can run it
///    on an empty chain and the manifest's `constructorArgs` is the empty list.
contract IMDBlackoutToken is ERC20 {
    /// @notice The token name, as `name()` returns it.
    string internal constant TOKEN_NAME = "IMDBlackout";

    /// @notice The token symbol, as `symbol()` returns it.
    string internal constant TOKEN_SYMBOL = "IMDBLACKOUT";

    /// @notice Whole-token supply before decimals.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The entire supply in minor units (18 decimals), minted once in the constructor.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** 18;

    /// @notice The requester's wallet from the brief. Informational only: it has no power over the token.
    address public constant REQUESTER = 0x6616Cb624cec0B46C9718D423098150587D1272b;

    /// @notice Emitted once, at construction, with the deployer that received the whole supply.
    event SupplyMinted(address indexed to, uint256 amount);

    /// @notice Emitted when a holder burns its own tokens.
    event Burned(address indexed from, uint256 amount);

    /// @notice Mints the whole fixed supply to the deployer (the ProjectFactory on launch).
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Destroys `amount` of the caller's own tokens, permanently reducing the total supply.
    /// @dev Only the caller's balance can be burned. There is no `burnFrom`: no approval or privilege
    ///      lets one account burn another's tokens.
    /// @param amount The amount to burn, in minor units.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }
}

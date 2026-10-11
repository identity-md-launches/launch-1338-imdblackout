// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IMDBlackoutToken} from "../src/IMDBlackoutToken.sol";

/// @title Deploy IMDBlackoutToken
/// @notice Reviewable deployment script. On the IMD launch the ProjectFactory deploys the token from
///         its creation code and this script is not used; it exists for local runs, forks and review.
/// @dev The token takes no constructor arguments, so there is no configuration to read. `run()` only
///      wraps {deploy} in a broadcast; tests call {deploy} directly and never read the environment.
contract DeployIMDBlackoutToken is Script {
    /// @notice Deploys the token. The caller of this function's transaction receives the whole supply.
    function deploy() public returns (IMDBlackoutToken token) {
        token = new IMDBlackoutToken();
    }

    /// @notice Broadcast entry point for `forge script`. Requires a signer supplied on the command line.
    function run() external returns (IMDBlackoutToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HIToken} from "../src/HIToken.sol";

/// @notice Local and review-only deployment of HI.
/// @dev In the custom-token launch the factory deploys the token itself through
/// ProjectFactory.launchCustom, with the manifest's constructor arguments. This script exists for
/// local forks and reviews. The caller of `deploy` receives the whole supply.
contract DeployHI is Script {
    struct Config {
        address factory;
        address poolManager;
        uint64 launchNumber;
    }

    /// @notice Reads the three parameters from the environment and deploys.
    /// Required: HI_FACTORY, HI_POOL_MANAGER, HI_LAUNCH_NUMBER.
    function run() external returns (HIToken token) {
        Config memory config = Config({
            factory: vm.envAddress("HI_FACTORY"),
            poolManager: vm.envAddress("HI_POOL_MANAGER"),
            launchNumber: uint64(vm.envUint("HI_LAUNCH_NUMBER"))
        });
        vm.startBroadcast();
        token = deploy(config);
        vm.stopBroadcast();
    }

    /// @notice Deploys with an explicit configuration. Tests call this directly.
    function deploy(Config memory config) public returns (HIToken token) {
        token = new HIToken(config.factory, config.poolManager, config.launchNumber);
    }
}

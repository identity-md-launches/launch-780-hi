// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HIToken} from "../../src/HIToken.sol";

/// @notice Stands in for the launch factory: deploys the token so it holds the supply, answers
/// `distributorOf`, and forwards transfers the way the factory does.
contract MockLaunchFactory {
    mapping(uint64 => address) public distributorOf;

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function deployToken(address poolManager, uint64 launchNumber) external returns (HIToken) {
        return new HIToken(address(this), poolManager, launchNumber);
    }

    function move(HIToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function pull(HIToken token, address from, address to, uint256 amount) external returns (bool) {
        return token.transferFrom(from, to, amount);
    }

    function call(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }
}

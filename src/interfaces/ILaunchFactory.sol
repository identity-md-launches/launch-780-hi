// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The one view the token needs from the launch factory: the MerkleDistributor of a launch.
/// @dev The distributor's address depends on the token's, so it cannot be a constructor argument.
/// The token asks the factory for it at transfer time.
interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

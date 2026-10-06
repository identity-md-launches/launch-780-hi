// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployHI} from "../script/DeployHI.s.sol";
import {HIToken} from "../src/HIToken.sol";

contract DeployHITest is Test {
    function test_deployWithExplicitConfigMintsToTheScriptCaller() public {
        DeployHI deployer = new DeployHI();
        HIToken token = deployer.deploy(
            DeployHI.Config({factory: address(0xFAC7), poolManager: address(0x90A1), launchNumber: 42})
        );
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 * 1e18);
        assertEq(token.factory(), address(0xFAC7));
        assertEq(token.poolManager(), address(0x90A1));
        assertEq(token.launchNumber(), 42);
    }

    function test_deployRejectsZeroFactory() public {
        DeployHI deployer = new DeployHI();
        vm.expectRevert(HIToken.ZeroAddress.selector);
        deployer.deploy(DeployHI.Config({factory: address(0), poolManager: address(0x90A1), launchNumber: 42}));
    }
}

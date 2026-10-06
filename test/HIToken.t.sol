// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HIToken} from "../src/HIToken.sol";
import {MockLaunchFactory} from "./mocks/MockLaunchFactory.sol";

contract HITokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH = 7;

    MockLaunchFactory factory;
    HIToken token;

    address constant POOL_MANAGER = address(0x90A1);
    address constant DISTRIBUTOR = address(0xD157);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    function setUp() public {
        factory = new MockLaunchFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH);
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "HI");
        assertEq(token.symbol(), "HI");
        assertEq(token.decimals(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_constructorRecordsLaunchAddresses() public view {
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), POOL_MANAGER);
        assertEq(token.launchNumber(), LAUNCH);
    }

    function test_constructorMintsToWhoeverDeploys() public {
        HIToken direct = new HIToken(address(factory), POOL_MANAGER, LAUNCH);
        assertEq(direct.balanceOf(address(this)), SUPPLY);
        assertEq(direct.balanceOf(address(factory)), 0);
    }

    function test_constructorRejectsZeroFactory() public {
        vm.expectRevert(HIToken.ZeroAddress.selector);
        new HIToken(address(0), POOL_MANAGER, LAUNCH);
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(HIToken.ZeroAddress.selector);
        new HIToken(address(factory), address(0), LAUNCH);
    }

    // ---------------------------------------------------------------- the 1% burn

    function test_ordinaryTransferBurnsOnePercent() public {
        factory.move(token, ALICE, 1_000e18);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(ALICE, address(0), 10e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(ALICE, BOB, 990e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1_000e18));

        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 990e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_ordinaryTransferFromBurnsOnePercent() public {
        factory.move(token, ALICE, 1_000e18);
        vm.prank(ALICE);
        token.approve(CAROL, 1_000e18);

        vm.prank(CAROL);
        assertTrue(token.transferFrom(ALICE, BOB, 1_000e18));

        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 990e18);
        assertEq(token.allowance(ALICE, CAROL), 0);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_burnRoundsDownForDustAmounts() public {
        factory.move(token, ALICE, 1_000);
        assertEq(token.burnFor(99), 0);
        assertEq(token.burnFor(100), 1);
        assertEq(token.burnFor(199), 1);

        vm.prank(ALICE);
        token.transfer(BOB, 99);
        assertEq(token.balanceOf(BOB), 99);
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(ALICE);
        token.transfer(BOB, 100);
        assertEq(token.balanceOf(BOB), 198);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_selfTransferStillBurns() public {
        factory.move(token, ALICE, 1_000e18);
        vm.prank(ALICE);
        token.transfer(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 990e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function testFuzz_ordinaryTransferConservesValue(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        factory.move(token, ALICE, held);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));

        uint256 burned = (amount * 100) / 10_000;
        assertEq(token.balanceOf(BOB), amount - burned, "recipient gets 99%");
        assertEq(token.balanceOf(ALICE), held - amount, "sender pays the full amount");
        assertEq(token.totalSupply(), supplyBefore - burned, "supply shrinks by the burn");
        assertLe(burned * 100, amount, "burn never exceeds 1%");
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(address(factory)), token.totalSupply());
    }

    // ---------------------------------------------------------------- launch exemptions

    function test_factoryTransfersMoveWhole() public {
        assertTrue(factory.move(token, ALICE, 100e18));
        assertEq(token.balanceOf(ALICE), 100e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfersToFactoryMoveWhole() public {
        factory.move(token, ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(address(factory), 100e18);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryAsCallerMovesWhole() public {
        factory.move(token, ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(address(factory), 100e18);
        assertTrue(factory.pull(token, ALICE, BOB, 100e18));
        assertEq(token.balanceOf(BOB), 100e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolManagerTransfersMoveWholeBothWays() public {
        factory.move(token, ALICE, 100e18);
        // Sell into the pool: holder -> PoolManager.
        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 100e18);
        assertEq(token.balanceOf(POOL_MANAGER), 100e18);
        // Buy from the pool: PoolManager -> trader.
        vm.prank(POOL_MANAGER);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 100e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_distributorTransfersMoveWholeBothWays() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        assertEq(token.distributor(), DISTRIBUTOR);

        uint256 swarm = SUPPLY / 10;
        factory.move(token, DISTRIBUTOR, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, swarm / 2));
        assertEq(token.balanceOf(ALICE), swarm / 2);

        vm.prank(ALICE);
        token.transfer(DISTRIBUTOR, swarm / 2);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_distributorIsReadLiveFromTheFactory() public {
        factory.move(token, ALICE, 1_000e18);

        // Before the factory records a distributor, the address is an ordinary holder.
        assertEq(token.distributor(), address(0));
        assertFalse(token.isExempt(ALICE, DISTRIBUTOR));
        vm.prank(ALICE);
        token.transfer(DISTRIBUTOR, 100e18);
        assertEq(token.balanceOf(DISTRIBUTOR), 99e18);

        // Once recorded, it is exempt without any call on the token.
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        assertTrue(token.isExempt(ALICE, DISTRIBUTOR));
        vm.prank(ALICE);
        token.transfer(DISTRIBUTOR, 100e18);
        assertEq(token.balanceOf(DISTRIBUTOR), 199e18);
    }

    function test_otherLaunchesDistributorIsNotExempt() public {
        factory.setDistributor(LAUNCH + 1, DISTRIBUTOR);
        factory.move(token, ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(DISTRIBUTOR, 100e18);
        assertEq(token.balanceOf(DISTRIBUTOR), 99e18);
    }

    function test_launchFlowsMoveExactlyWhatTheySay() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        uint256 swarm = SUPPLY / 10;
        uint256 pool = (SUPPLY * 4_000) / 10_000;

        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertTrue(factory.move(token, POOL_MANAGER, pool));
        assertTrue(factory.move(token, CAROL, SUPPLY - swarm - pool));
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, swarm));
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(BOB, 1e18));
        vm.prank(BOB);
        assertTrue(token.transfer(POOL_MANAGER, 1e18));

        assertEq(token.balanceOf(ALICE), swarm);
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(CAROL), SUPPLY - swarm - pool);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- failures

    function test_transferRevertsOnInsufficientBalance() public {
        factory.move(token, ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10e18, 10e18 + 1));
        token.transfer(BOB, 10e18 + 1);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        factory.move(token, ALICE, 10e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1e18));
        token.transferFrom(ALICE, BOB, 1e18);
    }

    function test_transferToZeroAddressReverts() public {
        factory.move(token, ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_factoryCannotPullAHoldersBalanceWithoutAllowance() public {
        factory.move(token, ALICE, 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        factory.pull(token, ALICE, address(factory), 1);
    }

    function test_distributorLookupRevertsIfFactoryHasNoCode() public {
        HIToken orphan = new HIToken(address(0xFAC7), POOL_MANAGER, LAUNCH);
        vm.expectRevert();
        orphan.distributor();
        // Flows that never consult the distributor still work.
        assertTrue(orphan.transfer(POOL_MANAGER, 1e18));
        // Ordinary transfers need the factory to answer.
        vm.expectRevert();
        orphan.transfer(ALICE, 1e18);
    }

    // ---------------------------------------------------------------- no privileged hand

    function test_noCallIncreasesSupplyOrMintsToACaller() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            (ok,) = factory.call(address(token), data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        factory.move(token, ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = factory.call(address(token), abi.encodeWithSignature(signatures[i], ALICE, true));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(ALICE), held);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2));
        assertGt(token.balanceOf(BOB), 0);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}

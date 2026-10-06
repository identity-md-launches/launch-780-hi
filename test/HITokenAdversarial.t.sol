// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HIToken} from "src/HIToken.sol";
import {MockLaunchFactory} from "./mocks/MockLaunchFactory.sol";

/// @dev Supplements the accepted suite with boundaries, authorization and rollback properties.
/// forge-config: default.fuzz.runs = 1000
contract HITokenAdversarialTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint64 constant LAUNCH = 7;
    address constant POOL = address(0x9001);
    address constant DIST = address(0xD157);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant SPENDER = address(0xCA201);

    MockLaunchFactory factory;
    HIToken token;

    function setUp() public {
        factory = new MockLaunchFactory();
        token = factory.deployToken(POOL, LAUNCH);
        factory.setDistributor(LAUNCH, DIST);
    }

    function test_zeroTransfersFromEmptyAccountEmitAndPreserveState() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(ALICE, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        _assertBalances(0, 0, SUPPLY);
    }

    function test_oneWeiAndFeeThresholds() public {
        factory.move(token, ALICE, 1_000);
        uint256[7] memory amounts = [uint256(0), 1, 99, 100, 101, 199, 200];
        uint256[7] memory fees = [uint256(0), 0, 0, 1, 1, 1, 2];
        uint256 spent;
        uint256 burned;
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(ALICE);
            assertTrue(token.transfer(BOB, amounts[i]));
            spent += amounts[i];
            burned += fees[i];
            _assertBalances(1_000 - spent, spent - burned, SUPPLY - burned);
        }
    }

    function test_fullSupplyCanBeTransferredAndBurnedOnce() public {
        factory.move(token, ALICE, SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, SUPPLY));
        _assertBalances(0, 990_000_000 ether, 990_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function test_maximumTransferRevertsWithBalanceErrorBeforeFeeArithmetic() public {
        factory.move(token, ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, SUPPLY, type(uint256).max);
        vm.expectRevert(errorData);
        vm.prank(ALICE);
        token.transfer(BOB, type(uint256).max);
        vm.expectRevert(errorData);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, type(uint256).max);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        _assertBalances(SUPPLY, 0, SUPPLY);
    }

    function test_approvalsReplaceRatherThanAccumulateAndCanBeRevoked() public {
        factory.move(token, ALICE, 1_000);
        vm.startPrank(ALICE);
        assertTrue(token.approve(SPENDER, type(uint256).max));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(ALICE, SPENDER, 100);
        assertTrue(token.approve(SPENDER, 100));
        assertEq(token.allowance(ALICE, SPENDER), 100);
        assertTrue(token.approve(SPENDER, 0));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        _assertBalances(1_000, 0, SUPPLY);
    }

    function test_finiteAllowanceCannotBeSpentTwice() public {
        factory.move(token, ALICE, 200);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 100));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        _assertBalances(100, 99, SUPPLY - 1);
    }

    function test_infiniteAllowanceSurvivesRepeatedTaxedTransfers() public {
        factory.move(token, ALICE, 300);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            vm.prank(SPENDER);
            assertTrue(token.transferFrom(ALICE, BOB, 100));
            assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        }
        _assertBalances(0, 297, SUPPLY - 3);
    }

    function test_feeExemptSpendersStillNeedPermission() public {
        factory.move(token, ALICE, 1_000);
        address[3] memory spenders = [address(factory), POOL, DIST];
        for (uint256 i; i < spenders.length; ++i) {
            vm.prank(ALICE);
            token.approve(spenders[i], 100);
            vm.prank(ALICE);
            token.approve(spenders[i], 0);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spenders[i], 0, 100)
            );
            vm.prank(spenders[i]);
            token.transferFrom(ALICE, spenders[i], 100);
            assertEq(token.allowance(ALICE, spenders[i]), 0);
        }
        _assertBalances(1_000, 0, SUPPLY);
    }

    function test_approvalDoesNotAuthorizeAnotherSpender() public {
        factory.move(token, ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 100));
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(token.allowance(ALICE, SPENDER), 100);
        _assertBalances(100, 0, SUPPLY);
    }

    function test_zeroRecipientRestoresAlreadySpentAllowance() public {
        factory.move(token, ALICE, 1_000);
        vm.prank(ALICE);
        token.approve(SPENDER, 500);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 500);
        assertEq(token.allowance(ALICE, SPENDER), 500);
        _assertBalances(1_000, 0, SUPPLY);
    }

    function test_zeroValueStillRejectsZeroSenderRecipientAndSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(BOB, 0);
        // transferFrom validates its allowance owner before reaching the transfer itself.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), BOB, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(ALICE);
        token.approve(address(0), 0);
        _assertBalances(0, 0, SUPPLY);
    }

    function test_selfTransferRequiresGrossBalanceEvenThoughOnlyFeeIsLost() public {
        factory.move(token, ALICE, 99);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 99, 100));
        vm.prank(ALICE);
        token.transfer(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 99, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, ALICE, 100);
        assertEq(token.allowance(ALICE, SPENDER), 100);
        _assertBalances(99, 0, SUPPLY);
    }

    function test_distributorReplacementAndRemovalTakeEffectImmediately() public {
        factory.move(token, DIST, 300);
        factory.move(token, ALICE, 300);
        factory.setDistributor(LAUNCH, BOB);
        vm.prank(DIST);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(ALICE), 399, "old distributor must lose its exemption");
        assertEq(token.totalSupply(), SUPPLY - 1);
        vm.prank(ALICE);
        token.transfer(BOB, 100);
        assertEq(token.balanceOf(BOB), 100, "new distributor receives the gross amount");
        factory.setDistributor(LAUNCH, address(0));
        vm.prank(BOB);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(ALICE), 398);
        assertEq(token.totalSupply(), SUPPLY - 2);
        assertEq(token.distributor(), address(0));
    }

    function testFuzz_overdraftIsAtomicForOrdinaryAndExemptRecipients(uint256 held, uint256 excess, uint8 recipientSeed)
        public
    {
        held = bound(held, 0, SUPPLY);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        address[4] memory recipients = [BOB, address(factory), POOL, DIST];
        address recipient = recipients[recipientSeed % 4];
        factory.move(token, ALICE, held);
        uint256 recipientBefore = token.balanceOf(recipient);
        vm.prank(ALICE);
        token.approve(SPENDER, amount);
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount);
        vm.expectRevert(errorData);
        vm.prank(ALICE);
        token.transfer(recipient, amount);
        vm.expectRevert(errorData);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, recipient, amount);
        assertEq(token.allowance(ALICE, SPENDER), amount, "failed transfer must restore allowance");
        assertEq(token.balanceOf(recipient), recipientBefore);
        _assertBalances(held, 0, SUPPLY);
    }

    function testFuzz_allowanceMustCoverGrossAmount(uint256 approved, uint256 extra) public {
        approved = bound(approved, 0, SUPPLY - 1);
        uint256 amount = approved + bound(extra, 1, SUPPLY - approved);
        factory.move(token, ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(SPENDER, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, approved, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);
        assertEq(token.allowance(ALICE, SPENDER), approved);
        _assertBalances(SUPPLY, 0, SUPPLY);
    }

    function testFuzz_delegatedTransferAccountsForGrossAmount(
        uint256 held,
        uint256 amount,
        uint256 approvalSeed,
        bool infinite
    ) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        uint256 approved = infinite ? type(uint256).max : bound(approvalSeed, amount, type(uint256).max - 1);
        factory.move(token, ALICE, held);
        vm.prank(ALICE);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        assertEq(token.allowance(ALICE, SPENDER), infinite ? approved : approved - amount);
        uint256 burned = amount / 100;
        _assertBalances(held - amount, amount - burned, SUPPLY - burned);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(ALICE) + token.balanceOf(BOB), token.totalSupply());
    }

    function testFuzz_delegatedSelfTransferBurnsOnceAndSpendsGrossAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        factory.move(token, ALICE, held);
        vm.prank(ALICE);
        token.approve(SPENDER, amount);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, ALICE, amount));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        _assertBalances(held - amount / 100, 0, SUPPLY - amount / 100);
    }

    function testFuzz_exemptTransferFromStillSpendsAllowance(uint256 amount, uint8 recipientSeed) public {
        amount = bound(amount, 0, SUPPLY);
        address[3] memory recipients = [address(factory), POOL, DIST];
        address recipient = recipients[recipientSeed % 3];
        factory.move(token, ALICE, amount);
        uint256 recipientBefore = token.balanceOf(recipient);
        vm.prank(ALICE);
        token.approve(SPENDER, amount);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, recipient, amount));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(recipient), recipientBefore + amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_feeIsRoundedDownWithinOneMinorUnitForTransferableAmounts(uint256 amount) public view {
        amount = bound(amount, 0, SUPPLY);
        uint256 fee = token.burnFor(amount);
        assertLe(fee * 100, amount);
        assertLt(amount - fee * 100, 100);
    }

    function _assertBalances(uint256 alice, uint256 bob, uint256 supply) internal view {
        assertEq(token.balanceOf(ALICE), alice);
        assertEq(token.balanceOf(BOB), bob);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), supply);
    }
}

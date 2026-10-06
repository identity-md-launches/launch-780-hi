// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HIToken} from "src/HIToken.sol";
import {MockLaunchFactory} from "../mocks/MockLaunchFactory.sol";

/// @dev Closed set of holders: every destination and spender is tracked. Ghost balances and
/// allowances are updated from requested actions, never copied from the token after execution.
contract HITokenHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTOR_COUNT = 7;
    uint64 public constant LAUNCH = 7;
    HIToken public immutable token;
    MockLaunchFactory public immutable factory;
    address[7] public actors;
    address public currentDistributor;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public burned;
    uint256 public taxedTransfers;
    uint256 public exemptTransfers;
    uint256 public rejectedTransfers;
    uint256 public approvalChanges;
    uint256 public distributorChanges;

    constructor() {
        factory = new MockLaunchFactory();
        actors = [
            address(factory),
            address(0x9001),
            address(0xD157),
            address(0xA11CE),
            address(0xB0B),
            address(0xCA201),
            address(0xD158)
        ];
        token = factory.deployToken(actors[1], LAUNCH);
        currentDistributor = actors[2];
        factory.setDistributor(LAUNCH, currentDistributor);
        expectedBalance[address(factory)] = INITIAL_SUPPLY;
        // Seed every role so randomized actions can move value from their first call.
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            assertTrue(factory.move(token, actors[i], 1_000_000 ether));
            expectedBalance[address(factory)] -= 1_000_000 ether;
            expectedBalance[actors[i]] = 1_000_000 ether;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        _transfer(from, to, _amount(amountSeed, expectedBalance[from]));
    }

    function transferFullBalance(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), expectedBalance[from]);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 amount = amountSeed % 3 == 0 ? type(uint256).max : _amount(amountSeed, INITIAL_SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    /// @dev Reuses approvals created by earlier calls; does not reset them before spending.
    function spendExistingAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed < limit) limit = allowed;
        _transferFrom(owner, spender, _actor(toSeed), _amount(amountSeed, limit));
    }

    /// @dev Ensures delegated transfers also reach funded, authorized states throughout the run.
    function approveAndTransferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 amountSeed,
        bool infinite
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        _transferFrom(owner, spender, _actor(toSeed), amount);
    }

    function revokeAndAttemptTransfer(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _approve(owner, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), 1);
        ++rejectedTransfers;
        // Leave the model unchanged: global invariants verify complete rollback.
    }

    function attemptOverdraft(uint256 ownerSeed, uint256 toSeed, bool maximum, bool delegated) external {
        address owner = _actor(ownerSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = maximum ? type(uint256).max : held + 1;
        address spender = actors[5];
        if (delegated) _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        vm.prank(delegated ? spender : owner);
        if (delegated) token.transferFrom(owner, _actor(toSeed), amount);
        else token.transfer(_actor(toSeed), amount);
        ++rejectedTransfers;
    }

    /// @dev A rejected recipient must not burn or consume a pre-existing approval.
    function attemptZeroRecipient(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = actors[5];
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        ++rejectedTransfers;
    }

    function changeDistributor(uint256 seed) external {
        uint256 choice = seed % 3;
        currentDistributor = choice == 0 ? address(0) : (choice == 1 ? actors[2] : actors[6]);
        factory.setDistributor(LAUNCH, currentDistributor);
        // Another launch's registration must never influence this token's exemptions.
        factory.setDistributor(LAUNCH + 1, actors[4]);
        ++distributorChanges;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        ++approvalChanges;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, from, to, amount);
        assertLe(token.totalSupply(), supplyBefore, "a transfer cannot grow supply");
    }

    function _transferFrom(address owner, address spender, address to, uint256 amount) internal {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] = allowed - amount;
        _recordTransfer(spender, owner, to, amount);
        assertLe(token.totalSupply(), supplyBefore, "a delegated transfer cannot grow supply");
    }

    function _recordTransfer(address caller, address from, address to, uint256 amount) internal {
        // The accepted economics: ordinary transfers burn floor(amount / 100), launch flows
        // are exact. Use the independently controlled fixture, not token.isExempt/burnFor.
        bool exempt = caller == actors[0] || from == actors[0] || to == actors[0] || from == actors[1]
            || to == actors[1]
            || (currentDistributor != address(0) && (from == currentDistributor || to == currentDistributor));
        uint256 fee = exempt ? 0 : amount / 100;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - fee;
        burned += fee;
        if (amount != 0) {
            if (exempt) ++exemptTransfers;
            else if (fee != 0) ++taxedTransfers;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    /// @dev Explicitly bias toward zero, dust, fee thresholds and the entire available balance.
    function _amount(uint256 seed, uint256 limit) internal pure returns (uint256) {
        uint256 choice = seed % 8;
        uint256 candidate;
        if (choice == 0) candidate = 0;
        else if (choice == 1) candidate = 1;
        else if (choice == 2) candidate = 99;
        else if (choice == 3) candidate = 100;
        else if (choice == 4) candidate = 101;
        else if (choice == 5) candidate = limit;
        else return bound(seed, 0, limit);
        return candidate > limit ? limit : candidate;
    }
}

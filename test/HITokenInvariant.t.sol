// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HIToken} from "src/HIToken.sol";
import {HITokenHandler} from "./handlers/HITokenHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HITokenInvariantTest is Test {
    HITokenHandler handler;
    HIToken token;

    function setUp() public {
        handler = new HITokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferFullBalance.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.spendExistingAllowance.selector;
        selectors[4] = handler.approveAndTransferFrom.selector;
        selectors[5] = handler.revokeAndAttemptTransfer.selector;
        selectors[6] = handler.attemptOverdraft.selector;
        selectors[7] = handler.attemptZeroRecipient.selector;
        selectors[8] = handler.changeDistributor.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Every reachable holder is in the handler's closed actor set; burned units are
    /// removed from supply, not credited to the zero address or a hidden fee beneficiary.
    function invariant_balancesConserveSupplyAndMatchTransferHistory() public view {
        uint256 sum;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            uint256 held = token.balanceOf(actor);
            assertEq(held, handler.expectedBalance(actor), "balance differs from requested transfers");
            sum += held;
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to circulating supply");
        assertEq(token.totalSupply() + handler.burned(), handler.INITIAL_SUPPLY(), "incorrect cumulative burn");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulGrossSpends() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < handler.ACTOR_COUNT(); ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    /// @dev Pin a meaningful sequence independently of random seeds: taxed and exempt paths,
    /// self-transfers, finite/infinite approvals, failures and changing distributor registration.
    function test_handlerExercisesValueMovementAndRejectionPaths() public {
        handler.transfer(3, 4, 3); // 100 minor units, taxed.
        handler.transferFullBalance(4, 4); // Self-transfer, taxed.
        handler.transfer(0, 3, 3); // Factory, exact.
        handler.approve(3, 5, 5); // Finite approval for the whole initial supply.
        handler.spendExistingAllowance(3, 5, 4, 3);
        handler.approveAndTransferFrom(3, 5, 4, 3, true);
        handler.spendExistingAllowance(3, 5, 4, 3);
        handler.approveAndTransferFrom(3, 0, 4, 3, false); // Factory as caller, exact.
        handler.revokeAndAttemptTransfer(3, 5, 4);
        handler.attemptOverdraft(3, 4, false, true);
        handler.attemptOverdraft(3, 1, true, false);
        handler.attemptZeroRecipient(3, 3);
        handler.changeDistributor(2);
        handler.transfer(2, 3, 3); // Former distributor, now taxed.
        handler.transfer(3, 6, 3); // New distributor, exact.
        handler.changeDistributor(0);
        handler.transfer(6, 3, 3); // Deregistered distributor, now taxed.
        invariant_balancesConserveSupplyAndMatchTransferHistory();
        invariant_allowancesMatchApprovalsAndSuccessfulGrossSpends();
        assertGt(handler.taxedTransfers(), 0);
        assertGt(handler.exemptTransfers(), 0);
        assertGt(handler.burned(), 0);
        assertEq(handler.rejectedTransfers(), 4);
        assertEq(handler.distributorChanges(), 2);
        assertGt(handler.approvalChanges(), 0);
    }
}

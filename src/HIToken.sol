// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";

/// @title HI
/// @notice Fixed-supply ERC-20 with a 1% burn on ordinary transfers.
/// @dev Supply: 1,000,000,000 HI (18 decimals), minted once to the deployer in the constructor.
/// There is no owner, no mint, no pause, no blocklist. Nothing can grow the supply after
/// deployment; the burn can only shrink it.
///
/// Transfer rule: 1% of every ordinary transfer is burned (sent to the zero address), so the
/// recipient receives 99%. Transfers that touch a launch address move the full amount:
/// - the launch factory (deployer) as sender, recipient, or caller;
/// - the Uniswap v4 PoolManager as sender or recipient;
/// - the launch's MerkleDistributor, read live from `factory.distributorOf(launchNumber)`.
/// Exempting these keeps the launch flows exact: the swarm's share arrives whole, claims arrive
/// whole, the pool seeds whole, and traders can buy from and sell into the pool.
contract HIToken is ERC20 {
    /// @notice Fee on ordinary transfers, in basis points (1% = 100 bps).
    uint256 public constant BURN_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice 1,000,000,000 HI in minor units (18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice The launch factory: deployer and holder of the initial supply.
    address public immutable factory;
    /// @notice The Uniswap v4 PoolManager the launch pool lives in.
    address public immutable poolManager;
    /// @notice The launch this token belongs to, used to look up its distributor.
    uint64 public immutable launchNumber;

    error ZeroAddress();

    /// @param factory_ The launch factory. Must be the deployer (msg.sender) in a real launch.
    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param launchNumber_ The launch number whose distributor is exempt.
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("HI", "HI") {
        if (factory_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The launch's MerkleDistributor, as the factory reports it right now.
    /// @dev Zero until the factory records it. A zero result exempts nothing: OpenZeppelin's
    /// `transfer` and `transferFrom` already refuse the zero address as a recipient.
    function distributor() public view returns (address) {
        return ILaunchFactory(factory).distributorOf(launchNumber);
    }

    /// @notice Whether a transfer between `from` and `to` moves the full amount.
    function isExempt(address from, address to) public view returns (bool) {
        if (from == factory || to == factory || msg.sender == factory) return true;
        if (from == poolManager || to == poolManager) return true;
        address dist = distributor();
        return dist != address(0) && (from == dist || to == dist);
    }

    /// @notice The burn taken from an ordinary transfer of `amount`, rounded down.
    function burnFor(uint256 amount) public pure returns (uint256) {
        return (amount * BURN_BPS) / BPS_DENOMINATOR;
    }

    /// @dev Routes every transfer through the burn rule. Mints (from == 0) and burns (to == 0)
    /// are internal and never taxed again.
    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0) || isExempt(from, to)) {
            super._update(from, to, amount);
            return;
        }
        uint256 held = balanceOf(from);
        if (held < amount) revert ERC20InsufficientBalance(from, held, amount);
        uint256 burned = burnFor(amount);
        if (burned != 0) super._update(from, address(0), burned);
        super._update(from, to, amount - burned);
    }
}

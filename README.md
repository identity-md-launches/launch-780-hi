# HI (HI)

Fixed-supply ERC-20 with a 1% burn on ordinary transfers, built for the IdentityMD custom-token
launch (`ProjectFactory.launchCustom`).

| Parameter | Value |
|---|---|
| Name | HI |
| Symbol | HI |
| Decimals | 18 |
| Total supply | 1,000,000,000 HI = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor (the factory), once, in the constructor |
| Transfer rule | 1% of each ordinary transfer is burned; the recipient receives 99% |
| Admin powers | None. No owner, mint, pause, blocklist, upgrade, or fee switch |

Contract: `src/HIToken.sol`. Interface it reads: `src/interfaces/ILaunchFactory.sol`.

## Transfer rule

The brief says "Transfer rules: 1%". This project reads that as a 1% fee on ordinary transfers,
and burns the fee. Burning was chosen over a treasury because the brief names no fee recipient,
and a burn needs no privileged address and no admin. If a treasury was intended, the fee
destination is the one line to change in `_update`.

Details:

- The fee is `amount * 100 / 10_000`, rounded down. Amounts under 100 minor units burn nothing.
- The sender pays the full `amount`. The recipient gets `amount - fee`. `totalSupply` drops by `fee`.
- Two `Transfer` events are emitted per taxed transfer: one to the zero address for the burn, one
  to the recipient for the rest.
- A self-transfer is still taxed.
- The supply can only shrink. Nothing can mint after the constructor.

## Launch exemptions

A transfer moves the full amount, with no burn, when any of these hold:

- the factory is the sender, the recipient, or the caller (`msg.sender`);
- the Uniswap v4 PoolManager is the sender or the recipient;
- the launch's MerkleDistributor is the sender or the recipient.

The distributor is not a constructor argument because its address depends on the token's. The
token reads it live from `factory.distributorOf(launchNumber)` on every transfer that is not already
exempt. Until the factory records it, the result is zero and exempts nothing. A distributor
recorded under a different launch number is not exempt.

This makes every launch flow exact: the swarm's 10% arrives whole at the distributor, claims arrive
whole, the pool seeds whole, and traders buy from and sell into the PoolManager without the pool's
settlement coming up short. Direct wallet-to-wallet transfers, and transfers through routers or
other contracts, are taxed. Any Uniswap v4 trade clears through the PoolManager and is therefore
untaxed in both directions. The 1% applies to peer-to-peer movement, not to pool trading.

## Constructor arguments

```
constructor(address factory, address poolManager, uint64 launchNumber)
```

Manifest placeholders, in this order: `$factory`, `$poolManager`, `$launchNumber`. Both addresses
must be non-zero. The constructor does not check that `factory == msg.sender`; the launch floor
checks that the supply was minted to the factory.

## Assumptions

- The factory deploys the token, so the whole supply lands in the factory. The factory then moves
  the swarm share, seeds the pool, and forwards the remainder as the manifest's economics say.
- The factory exposes `distributorOf(uint64) returns (address)` and keeps code at its address for
  the life of the token. If the factory ever has no code, or that call reverts, ordinary
  (non-exempt) transfers revert. Exempt flows that never consult the distributor (factory and
  PoolManager transfers) still work. This is a trust assumption on the launch infrastructure.
- The fee exemption is bound to one PoolManager. A pool on another manager, or a v2/v3 pool, is
  taxed like any other holder. Document this to integrators.
- Rounding favours the sender: dust transfers below 100 minor units are not taxed.

## Operational responsibilities

- **Nobody holds a key over this token.** There is no owner and nothing to rotate, pause, or
  upgrade. Operational risk is in the launch flow, not in the token.
- **The launch deployer** supplies the constructor arguments from the manifest and verifies the
  source on the explorer after deployment (`forge verify-contract`). Unverified code is
  indistinguishable from a scam.
- **The factory** must record the distributor before the swarm share moves to it. If the share is
  sent first, the transfer is still whole (the factory is the sender), but a claim from an
  unrecorded distributor would be taxed. The protected floor records the distributor first.
- **Integrators** (CEXs, bridges, vaults) must treat HI as a fee-on-transfer token and measure
  received balances, except for flows through the exempt PoolManager.
- **Review.** Tests passing is not an audit. Work that holds other people's funds needs an
  independent adversarial review before release.

## Local deployment

`script/DeployHI.s.sol` deploys the token for forks and reviews. The caller receives the supply.
`run()` reads `HI_FACTORY`, `HI_POOL_MANAGER`, and `HI_LAUNCH_NUMBER` from the environment and
hands them to `deploy(Config)`, which the tests call directly. In the real launch the factory
deploys the token; this script is not part of that path and broadcasts nothing unless you ask it to.

```
forge script script/DeployHI.s.sol --rpc-url <rpc> --broadcast
```

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `bytecode_hash = "none"`, `ffi = false`, and no filesystem
permissions. Tests read no environment variables and pass in any order and in parallel.

## Dependencies

Vendored as ordinary files under `lib/`, no submodules:

- `lib/forge-std` — foundry-rs/forge-std v1.9.7 (`src/`, licences). Commit in `VENDORED_COMMIT.txt`.
- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.1.0, only the files `ERC20` needs
  (`ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`, `Context.sol`, `draft-IERC6093.sol`) and the
  licence. Commit in `VENDORED_COMMIT.txt`.

## Tests

`test/HIToken.t.sol` covers metadata and supply, constructor failures, the burn and its rounding
(unit and fuzz, with value conservation), every exemption in both directions, the live distributor
lookup, a full launch-flow rehearsal, insufficient balance and allowance failures, a sweep of common
admin selectors from a stranger and from the factory, and an opcode scan of the runtime for
DELEGATECALL, CALLCODE, and SELFDESTRUCT. `test/DeployHI.t.sol` exercises the script's `deploy`
function with explicit config.

## Security checklist (eth-security)

Checked against the pinned ethskills security reference. Applicable items:

- Access control: no privileged functions exist.
- Reentrancy: the only external call is a `view` read of the factory, made before balances change.
- Integer math: fee multiplies before dividing, in basis points.
- Input validation: zero factory and zero PoolManager rejected in the constructor; zero recipient
  rejected by OpenZeppelin ERC20.
- Events: the burn and the net transfer each emit `Transfer`.
- Fee-on-transfer: this token is one. Integrators are warned above.
- No proxies, delegatecall, selfdestruct, signatures, or oracles.
- Tools run: `forge build`, `forge test` (256 fuzz runs), `forge fmt --check`. Slither and Mythril
  were not available in this task and did not run.
- Open items for the network deployer: explorer verification after deployment.

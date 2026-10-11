# IMDBlackout (IMDBLACKOUT)

A fixed-supply ERC-20 built for an IMD custom-token launch on Robinhood Chain (chain id 4663).

| Item | Value |
| --- | --- |
| Solidity contract | `IMDBlackoutToken` (`src/IMDBlackoutToken.sol`) |
| `name()` | `IMDBlackout` |
| `symbol()` | `IMDBLACKOUT` |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 tokens = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor, once (the IMD ProjectFactory on launch) |
| Requester wallet (informational) | `0x6616Cb624cec0B46C9718D423098150587D1272b`, exposed as `REQUESTER()` |

## Behaviour

- **Supply.** The whole supply is minted once in the constructor to the deployer. There is no mint
  function, owner, minter role, proxy or upgrade path, so the supply can never grow afterwards.
- **Burn.** A holder may call `burn(amount)` to destroy its own tokens. There is no `burnFrom`, so no
  approval or privilege lets anyone burn another account's balance.
- **Transfers.** Plain ERC-20 rules from OpenZeppelin v5.1.0: every transfer and `transferFrom`
  delivers exactly the amount sent, with no fee, tax, cooldown, cap or exemption list.
- **No privileged powers.** There is no pause, blacklist, freeze, lock, seize or ownership function.
  Calls to any such selector revert because the selector does not exist.
- **No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`** in the runtime bytecode, and the constructor
  calls no other contract, so it deploys on an empty chain.

## Assumptions

- **The "Transfer rules" field of the brief contained only an address**, the requester's wallet
  `0x6616Cb624cec0B46C9718D423098150587D1272b`, and no rule. The same address is the launch's
  `economics.remainderTo`. We read this as "no transfer restrictions" and implemented unrestricted
  ERC-20 transfers. The address is recorded on-chain as the `REQUESTER` constant for reference only;
  it has no power over the token and is treated like any other holder. If a specific rule was
  intended (for example a per-wallet cap, a tax, or a cooldown), it needs to be stated and the token
  re-issued before launch, because nothing here can be changed after deployment.
- The launch's own terms (pair IMD, fee 1.25%, tick spacing 60, 88% of the supply to the pool, a
  2,500 IMD opening cap, 2% to the requester, 10% to the swarm) are carried out by the
  ProjectFactory and the manifest step, not by this contract. The token imposes no condition on
  those flows, so they move exactly what they say without any exemption list.

## Deployment parameters

- **Creation code:** `type(IMDBlackoutToken).creationCode` as built by `forge build` with
  `foundry.toml` at the repository root (solc 0.8.26, optimizer on, 200 runs, `bytecode_hash =
  "none"`, `cbor_metadata = false`), so the deployed bytes are reproducible.
- **Constructor arguments:** none. The manifest's `constructorArgs` is `[]`.
- **Manifest supply:** `token.totalSupply` is `1000000000000000000000000000`; `token.decimals` is 18.
- **Deployer:** whoever runs the constructor receives the whole supply. On launch that is the
  ProjectFactory, which forwards the swarm's share to the MerkleDistributor, seeds the pool and
  sends the remainder to the requester.
- **Script:** `script/Deploy.s.sol` exposes `deploy()` (no configuration) and a `run()` wrapper for
  `forge script` with a signer supplied on the command line. The launch does not use it; it is for
  local runs, forks and review. This repository holds no keys and broadcasts nothing.

## After launch

There is nothing to configure. The token has no owner-settable values, no setters and no
administrative role, so there are no post-launch steps for the requester beyond ordinary use.

## Operational responsibilities

- **Requester.** Holds the 2% remainder sent by the launch at the `REQUESTER` address and is
  responsible for that wallet's key. Nothing in the token can recover tokens sent to a wrong address
  or burned by mistake.
- **IMD launch.** Deploys the bytecode as built, records the contract under its Solidity name
  `IMDBlackoutToken`, and performs the distributor, pool seed and remainder flows.
- **Holders.** Own their balances outright. Burning is irreversible and only ever touches the caller.
- **Nobody** can pause, freeze, seize, mint or upgrade. If that is undesirable, it is a design change
  that must be made before launch.

## Verification

```
forge build
forge test
forge fmt --check
```

The test suite (`test/IMDBlackoutToken.t.sol`) deploys the token through a CREATE2 factory stub the
way the launch does and covers metadata, the one-time mint, transfers and approvals (success and
every revert path), burning, the absence of any mint or privileged selector from a stranger, the
factory and the requester, bytecode opcode checks, EIP-170 size, the deploy script's function, and a
simulation of the launch flows (factory to distributor to claimant, seed, remainder, buy and sell)
checking every leg arrives whole and the supply is unchanged. Tests read no environment variables
and are independent of order.

Tests passing are not a security audit. Review by an independent contributor is expected before
release. Tools that ran here: `forge build`, `forge test` (including a 256-run fuzz), `forge fmt`.
Slither and Mythril were not run.

## Dependencies

Vendored as ordinary files under `lib/` (no git submodules):

- `lib/forge-std` — foundry-rs/forge-std v1.9.7 (`src/` plus licences).
- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.1.0, only the files `ERC20.sol` needs:
  `token/ERC20/ERC20.sol`, `token/ERC20/IERC20.sol`, `token/ERC20/extensions/IERC20Metadata.sol`,
  `utils/Context.sol`, `interfaces/draft-IERC6093.sol`, and the MIT licence.

Remappings are in `remappings.txt`.

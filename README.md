# YieldFarming Pool

A Solidity yield farming contract built with Foundry, demonstrating `abi.encodePacked` for deterministic pool identifier generation and a time-weighted reward-accrual system.

## Architecture

| Contract | Description |
|---|---|
| `src/YieldFarmingPool.sol` | Core logic: pool creation, staking, withdrawal and reward distribution |
| `src/MockToken.sol` | Minimal ERC-20 used by the test suite |

### Key design decisions

- **Pool IDs** are derived from `keccak256(abi.encodePacked(token, rewardRate, timestamp, chainId))`, making each pool unique per block.
- **Reward accrual** is proportional to each staker's share of `totalStaked` and accumulates per second via `rewardRate`.
- **Safe payouts** — `_safeRewardTransfer` caps reward transfers to the contract's available balance, preventing reverts when funds run low.
- **Reentrancy protection** via OpenZeppelin's `ReentrancyGuard`.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) ≥ 0.2

## Quick start

```bash
git clone <repo-url>
cd YieldFarming
forge install
forge build
```

## Testing

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vvv

# Coverage (excludes lib/)
forge coverage --no-match-path "lib/**"
```

### Coverage

| Contract | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `YieldFarmingPool.sol` | 100% | 100% | 100% | 100% |

37 tests — 35 unit + 2 fuzz (256 runs each).

## Contract interface

### Owner-only

| Function | Description |
|---|---|
| `createPool(address token, uint256 rewardRate) → bytes32` | Creates a new staking pool and returns its ID |
| `updatePoolRewardRate(bytes32 poolId, uint256 newRate)` | Updates the reward rate of an existing pool |
| `emergencyWithdraw(address token, uint256 amount)` | Rescues any ERC-20 token held by the contract |

### User-facing

| Function | Description |
|---|---|
| `stake(bytes32 poolId, uint256 amount)` | Deposits tokens; auto-claims pending rewards on restake |
| `withdraw(bytes32 poolId, uint256 amount)` | Withdraws a partial position and claims pending rewards |
| `claim(bytes32 poolId)` | Claims all pending rewards without touching the principal |

### View helpers

| Function | Returns |
|---|---|
| `getActivePools()` | All pool IDs in insertion order |
| `getActivePoolsCount()` | Number of registered pools |
| `getPoolEncodedData(bytes32)` | ABI-packed pool struct (149 bytes) |
| `getUserHash(bytes32, address)` | Deterministic user-pool identifier |

## License

MIT

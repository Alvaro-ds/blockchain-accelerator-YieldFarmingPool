// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../lib/forge-std/src/Test.sol";
import "../src/YieldFarmingPool.sol";
import "../src/MockToken.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title YieldFarmingPool Test Suite
/// @author Alvaro Dapena
/// @notice Unit and fuzz tests for YieldFarmingPool covering all functions and branches.
/// @dev Each test is isolated: setUp deploys fresh contracts before every test function.
contract YieldFarmingPoolTest is Test {
    // Mirror events from YieldFarmingPool for vm.expectEmit
    event PoolCreated(bytes32 indexed poolId, address indexed token, uint256 rewardRate);
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    event RewardClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate);

    YieldFarmingPool internal yieldPool;
    MockToken internal stakeToken;
    MockToken internal rewardToken;

    address internal owner = vm.addr(1);
    address internal user1 = vm.addr(2);
    address internal user2 = vm.addr(3);
    address internal attacker = vm.addr(4);

    uint256 internal constant INITIAL_SUPPLY = 1000000;
    uint256 internal constant REWARD_RATE = 1e18;
    uint256 internal constant STAKE_AMOUNT = 100e18;
    uint256 internal constant REWARD_FUND = 500000e18;

    bytes32 internal poolId;

    /// @notice Deploys stakeToken, rewardToken and yieldPool; funds the pool with REWARD_FUND;
    /// distributes stakeToken to user1 and user2; creates one pool; grants max allowance to both users.
    function setUp() public {
        vm.label(owner, "owner");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(attacker, "attacker");

        vm.startPrank(owner);
        stakeToken = new MockToken("Stake Token", "STK", INITIAL_SUPPLY);
        rewardToken = new MockToken("Reward Token", "RWD", INITIAL_SUPPLY);
        yieldPool = new YieldFarmingPool(address(rewardToken));
        rewardToken.transfer(address(yieldPool), REWARD_FUND);
        stakeToken.transfer(user1, 10000e18);
        stakeToken.transfer(user2, 10000e18);
        vm.stopPrank();

        vm.startPrank(owner);
        poolId = yieldPool.createPool(address(stakeToken), REWARD_RATE);
        vm.stopPrank();

        vm.startPrank(user1);
        stakeToken.approve(address(yieldPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        stakeToken.approve(address(yieldPool), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // constructor
    // ─────────────────────────────────────────────────────────────

    /// @notice rewardToken storage variable matches the address passed to the constructor.
    function test_constructor_setsRewardToken() public view {
        assert(address(yieldPool.rewardToken()) == address(rewardToken));
    }

    /// @notice owner is set to msg.sender at deployment.
    function test_constructor_setsOwner() public view {
        assert(yieldPool.owner() == owner);
    }

    /// @notice reverts with "Invalid reward token" when _rewardToken is address(0).
    function test_constructor_revertsOnZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("Invalid reward token"));
        new YieldFarmingPool(address(0));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // createPool
    // ─────────────────────────────────────────────────────────────

    /// @notice pool is stored with the correct token address and isActive set to true.
    function test_createPool_success() public {
        vm.startPrank(owner);
        bytes32 newPId = yieldPool.createPool(address(stakeToken), 2e18);
        vm.stopPrank();

        (address token,,,,, bool isActive) = yieldPool.pools(newPId);
        assert(token == address(stakeToken));
        assert(isActive);
    }

    /// @notice reverts when called by an account that is not the owner.
    function test_createPool_revertsNotOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        yieldPool.createPool(address(stakeToken), REWARD_RATE);
        vm.stopPrank();
    }

    /// @notice reverts with "Invalid token address" when token is address(0).
    function test_createPool_revertsZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("Invalid token address"));
        yieldPool.createPool(address(0), REWARD_RATE);
        vm.stopPrank();
    }

    /// @notice reverts with "Reward rate must be positive" when rewardRate is 0.
    function test_createPool_revertsZeroRewardRate() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("Reward rate must be positive"));
        yieldPool.createPool(address(stakeToken), 0);
        vm.stopPrank();
    }

    /// @notice reverts with "Pool already exists" when a pool with identical parameters is created in the same block.
    function test_createPool_revertsAlreadyExists() public {
        vm.startPrank(owner);
        yieldPool.createPool(address(stakeToken), 2e18);

        vm.expectRevert(bytes("Pool already exists"));
        yieldPool.createPool(address(stakeToken), 2e18);
        vm.stopPrank();
    }

    /// @notice the active pools count increases by one after a successful createPool call.
    function test_createPool_addsToActivePools() public {
        uint256 countBefore = yieldPool.getActivePoolsCount();

        vm.startPrank(owner);
        yieldPool.createPool(address(stakeToken), 2e18);
        vm.stopPrank();

        assert(yieldPool.getActivePoolsCount() == countBefore + 1);
    }

    /// @notice emits PoolCreated with the deterministic poolId, token address and rewardRate.
    function test_createPool_emitsEvent() public {
        uint256 ts = block.timestamp;
        bytes32 expectedPId = keccak256(abi.encodePacked(address(stakeToken), uint256(2e18), ts, block.chainid));

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit PoolCreated(expectedPId, address(stakeToken), 2e18);
        yieldPool.createPool(address(stakeToken), 2e18);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // stake
    // ─────────────────────────────────────────────────────────────

    /// @notice tokens are transferred from user to contract; user.amount and pool.totalStaked are updated correctly.
    function test_stake_success() public {
        uint256 balanceBefore = stakeToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assert(stakeToken.balanceOf(user1) == balanceBefore - STAKE_AMOUNT);
        assert(stakeToken.balanceOf(address(yieldPool)) == STAKE_AMOUNT);
        (uint256 amount,,) = yieldPool.userInfo(poolId, user1);
        assert(amount == STAKE_AMOUNT);
        (, uint256 totalStaked,,,,) = yieldPool.pools(poolId);
        assert(totalStaked == STAKE_AMOUNT);
    }

    /// @notice reverts with "Pool is not active" when the pool id is not registered.
    function test_stake_revertsPoolNotActive() public {
        bytes32 fakePId = keccak256("fake");

        vm.startPrank(user1);
        vm.expectRevert(bytes("Pool is not active"));
        yieldPool.stake(fakePId, STAKE_AMOUNT);
        vm.stopPrank();
    }

    /// @notice reverts with "Amount must be positive" when amount is 0.
    function test_stake_revertsZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes("Amount must be positive"));
        yieldPool.stake(poolId, 0);
        vm.stopPrank();
    }

    /// @notice accrued rewards are transferred to the user automatically on a subsequent stake after time has elapsed.
    function test_stake_autoClaimsOnRestake() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        uint256 rewardsBefore = rewardToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assert(rewardToken.balanceOf(user1) > rewardsBefore);
    }

    /// @notice no reward transfer occurs when restaking in the same block because pending rewards are zero.
    function test_stake_restakeInSameBlock_doesNotClaimRewards() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        uint256 rewardBefore = rewardToken.balanceOf(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assert(rewardToken.balanceOf(user1) == rewardBefore);
    }

    /// @notice emits Staked with poolId, user address and staked amount.
    function test_stake_emitsEvent() public {
        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Staked(poolId, user1, STAKE_AMOUNT);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();
    }

    /// @notice user.amount equals the staked amount for any valid non-zero input.
    /// @dev amount is bounded to [1, 9999e18] to stay within the user1 token balance set in setUp.
    function testFuzz_stake_updatesUserAmount(uint256 amount) public {
        amount = bound(amount, 1, 9999e18);

        vm.startPrank(user1);
        yieldPool.stake(poolId, amount);
        vm.stopPrank();

        (uint256 userAmount,,) = yieldPool.userInfo(poolId, user1);
        assert(userAmount == amount);
    }

    // ─────────────────────────────────────────────────────────────
    // withdraw
    // ─────────────────────────────────────────────────────────────

    /// @notice staking tokens are returned to the user and user.amount is reduced by the withdrawn amount.
    function test_withdraw_success() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        uint256 balanceBefore = stakeToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.withdraw(poolId, STAKE_AMOUNT / 2);
        vm.stopPrank();

        assert(stakeToken.balanceOf(user1) == balanceBefore + STAKE_AMOUNT / 2);
        (uint256 amount,,) = yieldPool.userInfo(poolId, user1);
        assert(amount == STAKE_AMOUNT - STAKE_AMOUNT / 2);
    }

    /// @notice reverts with "Insuficient staked amount" when withdrawing exactly the full staked balance.
    function test_withdraw_revertsOnExactAmount() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert(bytes("Insuficient staked amount"));
        yieldPool.withdraw(poolId, STAKE_AMOUNT);
        vm.stopPrank();
    }

    /// @notice reverts with "Insuficient staked amount" when the requested amount exceeds the staked balance.
    function test_withdraw_revertsMoreThanStaked() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert(bytes("Insuficient staked amount"));
        yieldPool.withdraw(poolId, STAKE_AMOUNT * 2);
        vm.stopPrank();
    }

    /// @notice accrued rewards are paid to the user when withdrawing after time has elapsed.
    function test_withdraw_claimsRewards() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        uint256 rewardsBefore = rewardToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.withdraw(poolId, STAKE_AMOUNT / 2);
        vm.stopPrank();

        assert(rewardToken.balanceOf(user1) > rewardsBefore);
    }

    /// @notice emits Withdrawn with poolId, user address and withdrawn amount.
    function test_withdraw_emitsWithdrawnEvent() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 10);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(poolId, user1, STAKE_AMOUNT / 2);
        yieldPool.withdraw(poolId, STAKE_AMOUNT / 2);
        vm.stopPrank();
    }

    /// @notice remaining user.amount equals staked minus withdrawn for any valid combination of amounts.
    /// @dev stakeAmt in [2, 9999e18]; withdrawAmt in [1, stakeAmt-1] to satisfy the strict less-than guard in withdraw.
    function testFuzz_withdraw_updatesBalance(uint256 stakeAmt, uint256 withdrawAmt) public {
        stakeAmt = bound(stakeAmt, 2, 9999e18);
        withdrawAmt = bound(withdrawAmt, 1, stakeAmt - 1);

        vm.startPrank(user1);
        yieldPool.stake(poolId, stakeAmt);
        yieldPool.withdraw(poolId, withdrawAmt);
        vm.stopPrank();

        (uint256 remaining,,) = yieldPool.userInfo(poolId, user1);
        assert(remaining == stakeAmt - withdrawAmt);
    }

    // ─────────────────────────────────────────────────────────────
    // claim
    // ─────────────────────────────────────────────────────────────

    /// @notice reward tokens are transferred to the user after staking and waiting for rewards to accrue.
    function test_claim_success() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        uint256 rewardsBefore = rewardToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.claim(poolId);
        vm.stopPrank();

        assert(rewardToken.balanceOf(user1) > rewardsBefore);
    }

    /// @notice reverts with "No rewards to claim" when the user has no pending rewards.
    function test_claim_revertsNoRewards() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes("No rewards to claim"));
        yieldPool.claim(poolId);
        vm.stopPrank();
    }

    /// @notice lastClaimTime is updated to block.timestamp after a successful claim.
    function test_claim_updatesLastClaimTime() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        vm.startPrank(user1);
        yieldPool.claim(poolId);
        vm.stopPrank();

        (,, uint256 lastClaimTime) = yieldPool.userInfo(poolId, user1);
        assert(lastClaimTime == block.timestamp);
    }

    /// @notice emits RewardClaimed with poolId and user address.
    function test_claim_emitsEvent() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, false);
        emit RewardClaimed(poolId, user1, 0);
        yieldPool.claim(poolId);
        vm.stopPrank();
    }

    /// @notice when pending rewards exceed the contract balance the transfer is capped to the available balance.
    function test_claim_capsRewardsAtContractBalance() public {
        uint256 bal = rewardToken.balanceOf(address(yieldPool));
        vm.startPrank(owner);
        yieldPool.emergencyWithdraw(address(rewardToken), bal - 1);
        vm.stopPrank();

        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 1000000);

        vm.startPrank(user1);
        yieldPool.claim(poolId);
        vm.stopPrank();

        assert(rewardToken.balanceOf(user1) == 1);
        assert(rewardToken.balanceOf(address(yieldPool)) == 0);
    }

    /// @notice when the contract holds zero reward tokens the transfer is skipped and the user balance is unchanged.
    function test_claim_skipsTransferWhenRewardBalanceZero() public {
        vm.startPrank(owner);
        yieldPool.emergencyWithdraw(address(rewardToken), rewardToken.balanceOf(address(yieldPool)));
        vm.stopPrank();

        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        uint256 balanceBefore = rewardToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.claim(poolId);
        vm.stopPrank();

        assert(rewardToken.balanceOf(user1) == balanceBefore);
    }

    // ─────────────────────────────────────────────────────────────
    // updatePoolRewardRate
    // ─────────────────────────────────────────────────────────────

    /// @notice pool.rewardRate is updated to the new value after the call.
    function test_updatePoolRewardRate_success() public {
        uint256 newRate = 2e18;

        vm.startPrank(owner);
        yieldPool.updatePoolRewardRate(poolId, newRate);
        vm.stopPrank();

        (,, uint256 rewardRate,,,) = yieldPool.pools(poolId);
        assert(rewardRate == newRate);
    }

    /// @notice emits PoolUpdated with poolId and the new reward rate.
    function test_updatePoolRewardRate_emitsEvent() public {
        uint256 newRate = 2e18;

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit PoolUpdated(poolId, newRate);
        yieldPool.updatePoolRewardRate(poolId, newRate);
        vm.stopPrank();
    }

    /// @notice reverts when called by an account that is not the owner.
    function test_updatePoolRewardRate_revertsNotOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        yieldPool.updatePoolRewardRate(poolId, 2e18);
        vm.stopPrank();
    }

    /// @notice reverts with "Pool is not active" for an unregistered pool id.
    function test_updatePoolRewardRate_revertsPoolNotActive() public {
        bytes32 fakePId = keccak256("fake");

        vm.startPrank(owner);
        vm.expectRevert(bytes("Pool is not active"));
        yieldPool.updatePoolRewardRate(fakePId, 2e18);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // getActivePools
    // ─────────────────────────────────────────────────────────────

    /// @notice returns the array of active pool ids in insertion order.
    function test_getActivePools_returnsAllPools() public view {
        bytes32[] memory all = yieldPool.getActivePools();

        assert(all.length == 1);
        assert(all[0] == poolId);
    }

    // ─────────────────────────────────────────────────────────────
    // getPoolEncodedData
    // ─────────────────────────────────────────────────────────────

    /// @notice returns a 149-byte packed encoding: address(20) + uint256×4(128) + bool(1).
    function test_getPoolEncodedData_returnsExpectedLength() public view {
        bytes memory data = yieldPool.getPoolEncodedData(poolId);

        assert(data.length == 149);
    }

    // ─────────────────────────────────────────────────────────────
    // getUserHash
    // ─────────────────────────────────────────────────────────────

    /// @notice returned hash matches keccak256(abi.encodePacked(poolId, user, "YIELD_FARMING_USER")).
    function test_getUserHash_matchesExpectedValue() public view {
        bytes32 expected = keccak256(abi.encodePacked(poolId, user1, "YIELD_FARMING_USER"));

        assert(yieldPool.getUserHash(poolId, user1) == expected);
    }

    /// @notice different users produce different hashes for the same pool.
    function test_getUserHash_differsByUser() public view {
        assert(yieldPool.getUserHash(poolId, user1) != yieldPool.getUserHash(poolId, user2));
    }
}

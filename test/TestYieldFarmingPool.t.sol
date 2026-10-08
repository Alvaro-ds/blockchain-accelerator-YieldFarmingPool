// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../lib/forge-std/src/Test.sol";
import "../src/YieldFarmingPool.sol";
import "../src/MockToken.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

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

    function test_constructor_setsRewardToken() public view {
        assert(address(yieldPool.rewardToken()) == address(rewardToken));
    }

    function test_constructor_setsOwner() public view {
        assert(yieldPool.owner() == owner);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("Invalid reward token"));
        new YieldFarmingPool(address(0));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // createPool
    // ─────────────────────────────────────────────────────────────

    function test_createPool_success() public {
        vm.startPrank(owner);
        bytes32 newPId = yieldPool.createPool(address(stakeToken), 2e18);
        vm.stopPrank();
        (address token,,,,, bool isActive) = yieldPool.pools(newPId);
        assert(token == address(stakeToken));
        assert(isActive);
    }

    function test_createPool_revertsNotOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        yieldPool.createPool(address(stakeToken), REWARD_RATE);
        vm.stopPrank();
    }

    function test_createPool_revertsZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("Invalid token address"));
        yieldPool.createPool(address(0), REWARD_RATE);
        vm.stopPrank();
    }

    function test_createPool_revertsZeroRewardRate() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("Reward rate must be positive"));
        yieldPool.createPool(address(stakeToken), 0);
        vm.stopPrank();
    }

    function test_createPool_revertsAlreadyExists() public {
        vm.startPrank(owner);
        yieldPool.createPool(address(stakeToken), 2e18);
        vm.expectRevert(bytes("Pool already exists"));
        yieldPool.createPool(address(stakeToken), 2e18);
        vm.stopPrank();
    }

    function test_createPool_addsToActivePools() public {
        uint256 countBefore = yieldPool.getActivePoolsCount();
        vm.startPrank(owner);
        yieldPool.createPool(address(stakeToken), 2e18);
        vm.stopPrank();
        assert(yieldPool.getActivePoolsCount() == countBefore + 1);
    }

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

    function test_stake_revertsPoolNotActive() public {
        bytes32 fakePId = keccak256("fake");
        vm.startPrank(user1);
        vm.expectRevert(bytes("Pool is not active"));
        yieldPool.stake(fakePId, STAKE_AMOUNT);
        vm.stopPrank();
    }

    function test_stake_revertsZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes("Amount must be positive"));
        yieldPool.stake(poolId, 0);
        vm.stopPrank();
    }

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

    function test_stake_emitsEvent() public {
        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Staked(poolId, user1, STAKE_AMOUNT);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();
    }

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

    function test_withdraw_revertsOnExactAmount() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();
        vm.startPrank(user1);
        vm.expectRevert(bytes("Insuficient staked amount"));
        yieldPool.withdraw(poolId, STAKE_AMOUNT);
        vm.stopPrank();
    }

    function test_withdraw_revertsMoreThanStaked() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();
        vm.startPrank(user1);
        vm.expectRevert(bytes("Insuficient staked amount"));
        yieldPool.withdraw(poolId, STAKE_AMOUNT * 2);
        vm.stopPrank();
    }

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

    function test_claim_revertsNoRewards() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes("No rewards to claim"));
        yieldPool.claim(poolId);
        vm.stopPrank();
    }

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

    function test_claim_capsRewardsAtContractBalance() public {
        // Leave only 1 wei of rewards → pending >> balance → amount gets capped
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

    function test_updatePoolRewardRate_success() public {
        uint256 newRate = 2e18;
        vm.startPrank(owner);
        yieldPool.updatePoolRewardRate(poolId, newRate);
        vm.stopPrank();
        (,, uint256 rewardRate,,,) = yieldPool.pools(poolId);
        assert(rewardRate == newRate);
    }

    function test_updatePoolRewardRate_emitsEvent() public {
        uint256 newRate = 2e18;
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit PoolUpdated(poolId, newRate);
        yieldPool.updatePoolRewardRate(poolId, newRate);
        vm.stopPrank();
    }

    function test_updatePoolRewardRate_revertsNotOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        yieldPool.updatePoolRewardRate(poolId, 2e18);
        vm.stopPrank();
    }

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

    function test_getActivePools_returnsAllPools() public view {
        bytes32[] memory all = yieldPool.getActivePools();
        assert(all.length == 1);
        assert(all[0] == poolId);
    }

    // ─────────────────────────────────────────────────────────────
    // getPoolEncodedData
    // ─────────────────────────────────────────────────────────────

    function test_getPoolEncodedData_returnsExpectedLength() public view {
        bytes memory data = yieldPool.getPoolEncodedData(poolId);
        // address(20) + uint256*4(128) + bool(1) = 149 bytes
        assert(data.length == 149);
    }

    // ─────────────────────────────────────────────────────────────
    // getUserHash
    // ─────────────────────────────────────────────────────────────

    function test_getUserHash_matchesExpectedValue() public view {
        bytes32 expected = keccak256(abi.encodePacked(poolId, user1, "YIELD_FARMING_USER"));
        assert(yieldPool.getUserHash(poolId, user1) == expected);
    }

    function test_getUserHash_differsByUser() public view {
        assert(yieldPool.getUserHash(poolId, user1) != yieldPool.getUserHash(poolId, user2));
    }

    // ─────────────────────────────────────────────────────────────
    // stake – restake mismo bloque (pending == 0, sin auto-claim)
    // ─────────────────────────────────────────────────────────────

    function test_stake_restakeInSameBlock_doesNotClaimRewards() public {
        vm.startPrank(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        uint256 rewardBefore = rewardToken.balanceOf(user1);
        yieldPool.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();
        assert(rewardToken.balanceOf(user1) == rewardBefore);
    }
}

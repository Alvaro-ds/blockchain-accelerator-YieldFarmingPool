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
}

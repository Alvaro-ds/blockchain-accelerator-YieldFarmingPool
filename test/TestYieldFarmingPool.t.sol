// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../lib/forge-std/src/Test.sol";
import "../src/YieldFarmingPool.sol";
import "../src/MockToken.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract YieldFarmingPoolTest is Test {
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
}

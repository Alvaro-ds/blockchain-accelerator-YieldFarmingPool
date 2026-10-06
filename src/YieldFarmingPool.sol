// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title YieldFarmingPool
 * @author Alvaro Dapena
 * @dev Yield Farming contract demostrating the use of abi.encodePacked
 * to encode pool parameters and calculate unique identifiers
 */
contract YieldFarmingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Structure to store pool information
    struct Pool {
        address token; 
        uint256 totalStaked;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        bool isActive;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastClaimTime;
    }

    // Reward token
    IERC20 public immutable rewardToken;

    // Mapping of pools by their unique identifier
    mapping(bytes32 => Pool) public pools;

    // Mapping of user information by pool and address
    mapping(bytes32 => mapping(address => UserInfo)) public userInfo;

    // List of all active pools
    bytes32[] public activePools;

    // Events
    event PoolCreated(bytes32 indexed poolId, address indexed token, uint256 rewardRate);
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    event RewardClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate);

    /**
     * @dev The contract constructor
     * @param _rewardToken address of the reward token
     */
    constructor(address _rewardToken) Ownable(msg.sender) {
        require(_rewardToken != address(0), "Invalid reward token");
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @dev Creates a new yield farming pool
     * @param token Address of the token to stake
     * @param rewardRate Reward rate per second
     * @return poolId Unique pool identifier
     */
    function createPool(address token, uint256 rewardRate) external onlyOwner returns(bytes32 poolId) {
        require(token != address(0), "Invalid token address");
        require(rewardRate > 0, "Reward rate must be positive");

        poolId = keccak256(abi.encodePacked(token, rewardRate, block.timestamp, block.chainid));

        require(pools[poolId].token == address(0), "Pool already exists");

        pools[poolId] = Pool({
            token: token,
            totalStaked: 0,
            rewardRate: rewardRate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            isActive: true
        });

        activePools.push(poolId);

        emit PoolCreated(poolId, token, rewardRate);
    }

    /**
     * @dev Stake tokens in a specific pool
     * @param poolId Pool identifier
     * @param amount Amount of tokens to stake
     */
    function stake(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is not active");
        require(amount > 0, "Amount must be positive");

        _updatePool(poolId);

        UserInfo storage user = userInfo[poolId][msg.sender];

        if (user.amount > 0) {
            uint256 pending = _calculatePendingRewards(poolId, msg.sender);
            if (pending > 0) {
                _safeRewardsTransfer(msg.sender, pending);
                emit RewardClaimed(poolId, msg.sender, pending);
            }
        }

        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);

        user.amount += amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18; // 1e18 * 1e18 = 1e32 / 1e18 = 32 - 18 = 1e18
        user.lastClaimTime = block.timestamp;

        pool.totalStaked += amount;

        emit Staked(poolId, msg.sender, amount);
    }

    /**
     * @dev Withdraw staked tokens from a pool
     * @param poolId Pool identifier
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][msg.sender];

        require(user.amount > amount, "Insuficient staked amount");

        _updatePool(poolId);

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        if (pending > 0) {
            _safeRewardsTransfer(msg.sender, pending);
            emit RewardClaimed(poolId, msg.sender, pending);
        }

        user.amount -= amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;

        pool.totalStaked -= amount;

        IERC20(pool.token).safeTransfer(msg.sender, amount);

        emit Withdrawn(poolId, msg.sender, amount);
    }

    /**
     * @dev Claim pending rewards
     * @param poolId Pool Identifier
     */
    function claim(bytes32 poolId) external nonReentrant {
        _updatePool(poolId);

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        require(pending > 0, "No rewards to claim");

        UserInfo storage user = userInfo[poolId][msg.sender];
        user.rewardDebt = user.amount * pools[poolId].rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;

        _safeRewardTransfer(msg.sender, pending);

        emit RewardClaimed(poolId, msg.sender, pending);
    }

    /**
     * @dev Update the reward rate of a pool
     * @param poolId Pool Identifier
     * @param newRewardRate New reward rate
     */
    function updatePoolRewardRate(bytes32 poolId, uint256 newRewardRate) external onlyOwner {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is not active");

        _updatePool(poolId);
        pool.rewardRate = newRewardRate;

        emit PoolUpdated(poolId, newRewardRate);
    }

    /**
     * @dev Get encoded pool information for external use
     * @param poolId Pool identifier
     * @return encodedData Encoded pool data
     */
    function getPoolEncodedData(bytes32 poolId) external view returns(bytes memory encodedData) {
        Pool storage pool = pools[poolId];
        
        encodedData = abi.encodePacked(
            pool.token,
            pool.tokenStaked,
            pool.rewardRate,
            pool.lastUpdateTime,
            pool.rewardPerTokenStored,
            pool.isActive
        );
    }

    /**
     * @dev Create a unoque hash for a user in a specific pool
     * @param poolId Pool identifier
     * @param user User address
     * @return userHash Unique user hash
     */
    function getUserHash(bytes32 poolId, address user) external pure returns(bytes32 userHash) {
        userHash = keccak256(abi.encodePacked(poolId, user, "YIELD_FARMING_USER"));
    }

    /** 
     * @dev Get the total number of active pools
     * @return Number of active pools
     */
    function getActivePoolsCount() external view returns(uint256) {
        return activePools.length;
    }

    /**
     * @dev Get all active pools
     * @return Array with the identifiers of the active pools
     */
    function getActivePools() external view returns(bytes32[] memory) {
        return activePools;
    }

    /**
     * @dev Emergency function for the owner
     * @param token Address of the token to rescue
     * @param amount Amount to rescue
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    function _updatePool(bytes32 poolId) internal {

    } 
}
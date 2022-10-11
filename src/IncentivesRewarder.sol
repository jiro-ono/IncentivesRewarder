// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;


import {console} from "forge-std/console.sol";

import "lib/solmate/src/utils/SafeTransferLib.sol";
import "lib/solmate/src/utils/ReentrancyGuard.sol";
import "./libraries/Auth.sol";
import "./libraries/PackedUint144.sol";
import "./libraries/FullMath.sol";

interface IRewarder {
    function onSushiReward(uint256 pid, address user, address recipient, uint256 sushiAmount, uint256 newLpAmount) external;
    function pendingTokens(uint256 pid, address user, uint256 sushiAmount) external view returns (IERC20[] memory, uint256[] memory);
}

interface IMasterChefV2 {
    function lpToken(uint256 pid) external view returns (IERC20 _lpToken);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // EIP 2612
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

contract IncentivesRewarder is IRewarder, ReentrancyGuard, Auth {

    using SafeTransferLib for ERC20;
    using PackedUint144 for uint144;

    //todo: look in struct packing for this, pid prob can be moved around
    struct Incentive {
        address creator;            // 1st slot
        uint256 pid;                // 2nd slot
        address rewardToken;        // 3rd slot
        uint256 rewardPerLiquidity; // 3rd slot
        uint32 endTime;             // 3rd slot
        uint32 lastRewardTime;      // 4th slot
        uint112 rewardRemaining;    // 5th slot
    }

    // @notice Info of each Rewarder user.
    // 'liquidity' LP token amount the user has provided.
    /*struct UserStakes {
        uint256 liquidity;
    }*/

    // alternate way of calculating ->
    // userStaked state should be saved pid wide, and liquidity events logged for each incentive?
    // assume everyone is staked and use masterchef balance as the staked amount
    // check StakingContract repo for more details

    struct PoolInfo {
        //uint256[] subscribedIncentives;
        uint256 liquidityStaked;
        //uint144 subscribedIncentiveIds; // Six packed uint24 values.
        uint24[] subscribedIncentiveIds;
    }

    struct UserInfo {
        uint256 liquidity;
        uint64 lastRewardTime;
    }

    address public immutable MASTERCHEF_V2;
    uint256 public incentiveCount;
    
    // starts with 1. zero is an invalid incentive
    mapping(uint256 => Incentive) public incentives;

    // rewardPerLiquidityLast
    // think this rewardPerLiquidityLast[user][icentiveId]
    // after operator subscribes to incentives, any action from user stakes will trigger an entry
    // for them and incentive id to track their rewards for each individual incentive

    //todo: maybe instead of activateIncentive, we save a lastRewardTime for user's on each pid
    //      if new incentive is hit during onSushiReward and lastRewardTime is not 0 on the user or
    //      user has a staked balance then we _claimRewards for user??
    
    /// @dev rewardPerLiquidityLast[user][incentiveId]
    /// @dev Semantic overload: if value is zero user isn't subscribed to the incentive.
    mapping(address => mapping(uint256 => uint256)) public rewardPerLiquidityLast;

    // @dev poolInfo[pid]
    mapping(uint256 => PoolInfo) public poolInfo ;
    //@dev userStakes[pid][user]
    //todo: do we wanna make userStakes uint112
    mapping(uint256 => mapping(address => uint256)) public userStakes;

    error InvalidInput();
    error InvalidTimeFrame();
    error IncentiveOverflow();
    error NoToken();
    error InvalidIndex();
    error UserNotStaked();
    error BatchError(bytes innerError);
    error OnlyCreator();
    error AlreadyActivated();

    event IncentiveCreated(uint256 indexed pid, address indexed rewardToken, address indexed creator, uint256 id, uint256 amount, uint256 startTime, uint256 endTime);
    event IncentiveUpdated(uint256 indexed id, int256 changeAmount, uint256 newStartTime, uint256 newEndTime);

    
    constructor(
        address owner,
        address user,
        address chefAddress
    ) Auth(owner, user) {
        MASTERCHEF_V2 = chefAddress;
    }
    
    // create a new incentive, anyone can create an incentive for a pid
    function createIncentive(
        uint256 pid,
        address rewardToken,
        uint112 rewardAmount,
        uint32 startTime,
        uint32 endTime
    ) external nonReentrant returns (uint256 incentiveId) {
        
        if (rewardAmount <= 0) revert InvalidInput();
        if (startTime < block.timestamp) startTime = uint32(block.timestamp);
        if (startTime >= endTime) revert InvalidTimeFrame();

        unchecked { incentiveId = ++incentiveCount; }

        //todo: figure out why uint24.max
        if (incentiveId > type(uint24).max) revert IncentiveOverflow();

        _saferTransferFrom(rewardToken, rewardAmount);

        incentives[incentiveId] = Incentive({
            creator: msg.sender,
            pid: pid,
            rewardToken: rewardToken,
            lastRewardTime: startTime,
            endTime: endTime,
            rewardRemaining: rewardAmount,
            // Initial value of rewardPerLiquidity can be arbitrarily set to a non-zero value.
            rewardPerLiquidity: type(uint256).max / 2
        });

        emit IncentiveCreated(pid, rewardToken, msg.sender, incentiveId, rewardAmount, startTime, endTime);
    } 

    // update an incentive, only incentive creator can update it
    function updateIncentive(
        uint256 incentiveId,
        int112 changeAmount,
        uint32 newStartTime,
        uint32 newEndTime
    ) external nonReentrant {
        Incentive storage incentive = incentives[incentiveId];
        if (msg.sender != incentive.creator) revert OnlyCreator();
        
        _accrueRewards(incentive);

        if (newStartTime != 0) {
            if (newStartTime < block.timestamp) newStartTime = uint32(block.timestamp);
            incentive.lastRewardTime = newStartTime;
        }
        
        if (newEndTime != 0) {
            if (newEndTime < block.timestamp) newEndTime = uint32(block.timestamp);
            incentive.endTime = newEndTime;
        }

        if (incentive.lastRewardTime >= incentive.endTime) revert InvalidTimeFrame();
        if (changeAmount > 0) {
            incentive.rewardRemaining += uint112(changeAmount);
            ERC20(incentive.rewardToken).safeTransferFrom(msg.sender, address(this), uint112(changeAmount));
        } else if (changeAmount < 0) {
            uint112 transferOut = uint112(-changeAmount);
            
            if (transferOut > incentive.rewardRemaining) transferOut = incentive.rewardRemaining;
            unchecked { incentive.rewardRemaining -= transferOut; }
            ERC20(incentive.rewardToken).safeTransfer(msg.sender, transferOut);
        }

        emit IncentiveUpdated(incentiveId, changeAmount, incentive.lastRewardTime, incentive.endTime);
    }

    function subscribeToIncentive(uint256 pid, uint256 incentiveId) external onlyOwner {
        if (incentiveId > incentiveCount || incentiveId <= 0) revert InvalidInput();
        //todo: add check on pid?? / should we be checking pid in places to make sure there is a pool on masterchef?
        //todo: if already subscribed erorr message
        
        // updatePool?

        PoolInfo storage pool = poolInfo[pid];
        pool.subscribedIncentiveIds.push(uint24(incentiveId));

    }

    function unsubscribeFromIncentive(uint256 pid, uint256 incentiveIndex) external onlyOwner {
        PoolInfo storage pool = poolInfo[pid];

        // updatePool needed?

        uint256 subscribedLength = pool.subscribedIncentiveIds.length;
        if (incentiveIndex >= subscribedLength) revert InvalidIndex();

        if (subscribedLength > 1) {
            for (uint256 i = incentiveIndex; i < pool.subscribedIncentiveIds.length - 1; _increment(i)) {
                pool.subscribedIncentiveIds[i] = pool.subscribedIncentiveIds[i+1];
            }
        }

        pool.subscribedIncentiveIds.pop();
    }

    function getSubscribedIncentives(uint256 pid) public view returns (uint24[] memory) {
        return poolInfo[pid].subscribedIncentiveIds;
    }

    function _accrueRewards(Incentive storage incentive) internal {
        // accrue will generally be the same setup
        // updates rewardPerLiquidity used in onSushiRewards
        // also updates rewardsRemaining and lastRewardTime on Incentive
        uint256 lastRewardTime = incentive.lastRewardTime;
        uint256 endTime = incentive.endTime;

        PoolInfo memory pool = poolInfo[incentive.pid];

        unchecked {
            uint256 maxTime = block.timestamp < endTime ? block.timestamp : endTime;

            if (pool.liquidityStaked > 0 && lastRewardTime < maxTime) {
                uint256 totalTime = endTime - lastRewardTime;
                uint256 passedTime = maxTime - lastRewardTime;

                uint256 reward = uint256(incentive.rewardRemaining) * passedTime / totalTime;

                // Increments of less than type(uint224).max - overflow is unrealistic.
                incentive.rewardPerLiquidity += reward * type(uint112).max / pool.liquidityStaked;
                incentive.rewardRemaining -= uint112(reward);
                incentive.lastRewardTime = uint32(maxTime);
            } else if (pool.liquidityStaked == 0 && lastRewardTime < block.timestamp) {
                incentive.lastRewardTime = uint32(maxTime);
            }
        }
    }

    function activateIncentive(uint256 incentiveId, address user) public nonReentrant {
        //todo: make sure we double check/test the and that userStakes is correct in action
        uint256 userRewardPerLiquidityLast = rewardPerLiquidityLast[user][incentiveId];
        if (userRewardPerLiquidityLast != 0) return;

        // todo: need to think about this one somemore to make sure we cover any holes since it's public
        //       and above was discovered

        //todo: probably need a check for if incentiveId is valid, same for rest of
        //      functions like this

        Incentive storage incentive = incentives[incentiveId];
        if (userStakes[incentive.pid][user] == 0) revert UserNotStaked();
        rewardPerLiquidityLast[user][incentiveId] = incentive.rewardPerLiquidity;
    }

    function _claimReward(Incentive storage incentive, uint256 incentiveId, address user, address to, uint256 usersLiquidity) internal {
        uint256 reward = _calculateReward(incentive, incentiveId, user, usersLiquidity);
        rewardPerLiquidityLast[user][incentiveId] = incentive.rewardPerLiquidity;
        
        ERC20(incentive.rewardToken).safeTransfer(to, reward);
        
        // emit event
    }

    //todo: maybe add rewardRate function?? Look into new subgraph tohse if it uses it or how it calculates it for the rewards


    function _calculateReward(Incentive storage incentive, uint256 incentiveId, address user, uint256 usersLiquidity) internal view returns (uint256 reward) {
        uint256 userRewardPerLiquidtyLast = rewardPerLiquidityLast[user][incentiveId];
        if (userRewardPerLiquidtyLast == 0) return 0;
        
        uint256 rewardPerLiquidityDelta;
        unchecked { rewardPerLiquidityDelta = incentive.rewardPerLiquidity - userRewardPerLiquidtyLast; }

        reward = FullMath.mulDiv(rewardPerLiquidityDelta, usersLiquidity, type(uint112).max);
    }


    function onSushiReward(uint256 pid, address _user, address to, uint256, uint256 lpTokenAmount) onlyMCV2 nonReentrant override external {
        //require(IMasterChefV2(MASTERCHEF_V2).lpToken(pid) == masterLpToken);
        PoolInfo memory pool = _updatePool(pid);
        uint256 userStake = userStakes[pid][_user];

        uint256 n = pool.subscribedIncentiveIds.length;
        for (uint256 i = 0; i < n; i = _increment(i)) {
            Incentive storage incentive = incentives[pool.subscribedIncentiveIds[i]]; // may need to conver this to uint256
            _accrueRewards(incentive);
            _claimReward(incentive, pool.subscribedIncentiveIds[i], _user, to, userStake);
        }

        userStakes[pid][_user] = lpTokenAmount;

        // emit event
    }

    function pendingTokens(uint256 _pid, address _user, uint256) public view returns (IERC20[] memory rewardTokens, uint256[] memory rewardAmounts) {
        PoolInfo memory pool = poolInfo[_pid];
        uint256 userStake = userStakes[_pid][_user];

        uint256 n = pool.subscribedIncentiveIds.length;
        IERC20[] memory _rewardTokens = new IERC20[](n);
        uint256[] memory _rewardAmounts = new uint256[](n);

        for (uint256 i = 0; i < n; i = _increment(i)) {
            uint256 incentiveId = pool.subscribedIncentiveIds[i];
            Incentive storage incentive = incentives[incentiveId]; // may need to conver to uint256??
            _rewardAmounts[i] = _pendingToken(incentive, incentiveId, _user, userStake);
            _rewardTokens[i] = IERC20(incentive.rewardToken);
        }

        return (_rewardTokens, _rewardAmounts);
    }

    function _pendingToken(Incentive storage incentive, uint256 incentiveId, address user, uint256 usersLiquidity) internal view returns (uint256 reward) {
        uint256 rewardPer = incentive.rewardPerLiquidity;
        uint256 lpSupply = IMasterChefV2(MASTERCHEF_V2).lpToken(incentive.pid).balanceOf(MASTERCHEF_V2);

        if (block.timestamp > incentive.lastRewardTime && lpSupply != 0) {
            uint256 maxTime = block.timestamp < incentive.endTime ? block.timestamp : incentive.endTime;
            uint256 passedTime = maxTime - incentive.lastRewardTime;
            uint256 totalTime = incentive.endTime - incentive.lastRewardTime;
            reward = uint256(incentive.rewardRemaining) * passedTime / totalTime;
            rewardPer += reward * type(uint112).max / lpSupply;
        }

        uint256 userRewardPerLiquidtyLast = rewardPerLiquidityLast[user][incentiveId];
        if (userRewardPerLiquidtyLast == 0) return 0;
        uint256 rewardPerLiquidityDelta;
        unchecked { rewardPerLiquidityDelta = rewardPer - userRewardPerLiquidtyLast; }

        reward = FullMath.mulDiv(rewardPerLiquidityDelta, usersLiquidity, type(uint112).max);
    }


    function _updatePool(uint256 pid) internal returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        pool.liquidityStaked = IMasterChefV2(MASTERCHEF_V2).lpToken(pid).balanceOf(MASTERCHEF_V2);
        poolInfo[pid] = pool;
    }


    function _saferTransferFrom(address token, uint256 amount) internal {
        if (token.code.length == 0) revert NoToken();
        ERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _increment(uint256 i) internal pure returns (uint256) {
        unchecked { return i + 1; }
    }

    modifier onlyMCV2 {
        require(
            msg.sender == MASTERCHEF_V2,
            "Only MCV2 can call this function."
        );
        _;
    }
}
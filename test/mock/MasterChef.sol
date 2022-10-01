// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import "lib/solmate/src/tokens/ERC20.sol";
import "../../IncentivesRewarder.sol";


contract MasterChef {

    struct UserInfo {
        uint256 amount;
    }
    
    struct PoolInfo {
        uint64 allocPoint;
    }

    ERC20 public immutable SUSHI;

    ERC20[] public lpToken;
    IRewarder[] public rewarder;

    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    uint256 totalAllocPoint;

    PoolInfo[] public poolInfo;

    constructor(ERC20 _sushi) {
        SUSHI = _sushi;
    }

    function add(uint256 allocPoint, ERC20 _lpToken, address _rewarder) public {
        totalAllocPoint += allocPoint;
        lpToken.push(_lpToken);
        rewarder.push(IRewarder(_rewarder));

        poolInfo.push(PoolInfo({
            allocPoint: uint64(allocPoint)
        }));
    }
    
    function set(uint256 _pid, uint256 _allocPoint, bool overwrite) public {
        totalAllocPoint = (totalAllocPoint - poolInfo[_pid].allocPoint) + _allocPoint;
        poolInfo[_pid].allocPoint = uint64(_allocPoint);
    }

    function deposit(uint256 pid, uint256 amount, address to) public {
        UserInfo storage user = userInfo[pid][to];

        user.amount += amount;

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, to, to, 0, user.amount);
        }

        lpToken[pid].transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 pid, uint256 amount, address to) public {
        UserInfo storage user = userInfo[pid][to];

        user.amount -= amount;
        
        IRewarder _rewarder = rewarder[pid];
        if(address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, msg.sender, to, 0, amount);
        }

        lpToken[pid].transfer(to, amount);
    }

    function harvest(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        
        SUSHI.transfer(to, 1);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, msg.sender, to, 1, user.amount);
        }
    }
}

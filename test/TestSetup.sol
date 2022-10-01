// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import "../IncentivesRewarder.sol";
import "./mock/Token.sol";
import "./mock/MasterChef.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert(bytes memory) external;
    function expectRevert(bytes4) external;
}

contract TestSetup is DSTestPlus {
    Vm vm = Vm(HEVM_ADDRESS);

    address userA = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address userB = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address zeroAddress = 0x0000000000000000000000000000000000000000;

    uint256 MAX_UINT256 = type(uint256).max;
    uint112 MAX_UINT112 = type(uint112).max;
    uint32 testIncentiveDuration = 2592000;
    uint112 testIncentiveAmount = 1e21;

    Token sushiToken = new Token();
    Token stakedToken = new Token();
    Token tokenA = new Token();
    Token tokenB = new Token();
    Token tokenC = new Token();

    MasterChef masterChef = new MasterChef(sushiToken);
    IncentivesRewarder incentivesRewarder = new IncentivesRewarder(userA, userA, address(masterChef));

    bytes4 noToken = bytes4(keccak256("NoToken()"));
    bytes4 invalidInput = bytes4(keccak256("InvalidInput()"));
    bytes4 invalidTimeFrame = bytes4(keccak256("InvalidTimeFrame()"));
    bytes4 panic = 0x4e487b71;
    bytes overflow = abi.encodePacked(panic, bytes32(uint256(0x11)));

    function setUp() public {
        sushiToken.mint(MAX_UINT256);
        stakedToken.mint(MAX_UINT256);
        tokenA.mint(MAX_UINT256);

        tokenA.approve(address(incentivesRewarder), MAX_UINT256);

        tokenA.transfer(userA, MAX_UINT112);
        //tokenA.transfer(userB, MAX_UINT112);
        stakedToken.transfer(address(userB), 100);
        sushiToken.transfer(address(masterChef), MAX_UINT112);

        vm.prank(userA);
        tokenA.approve(address(incentivesRewarder), MAX_UINT256);

        vm.prank(userB);
        stakedToken.approve(address(masterChef), MAX_UINT256);

        // MasterChef Setup
        masterChef.add(10, stakedToken, address(incentivesRewarder));

        uint112 amount = testIncentiveAmount;
        uint256 currentTime = block.timestamp;
        uint256 duration = testIncentiveDuration;

    }

    function _createIncentive(
        uint256 pid,
        address rewardToken,
        uint112 amount,
        uint32 startTime,
        uint32 endTime
    ) public returns (uint256) {
        uint256 count = incentivesRewarder.incentiveCount();
        uint256 thisBalance = Token(rewardToken).balanceOf(address(this));
        uint256 rewarderBalance = Token(rewardToken).balanceOf(address(incentivesRewarder));

        if (amount <= 0) {
            vm.expectRevert(invalidInput);
            return incentivesRewarder.createIncentive(pid, rewardToken, amount, startTime, endTime);
        }

        if (endTime <= startTime || endTime <= block.timestamp) {
            vm.expectRevert(invalidTimeFrame);
            return incentivesRewarder.createIncentive(pid, rewardToken, amount, startTime, endTime);
        }
        
        uint256 id = incentivesRewarder.createIncentive(
            pid, rewardToken, amount, startTime, endTime
        );

        IncentivesRewarder.Incentive memory incentive = _getIncentive(id);

        assertEq(incentive.creator, address(this));
        assertEq(incentive.pid, pid);
        assertEq(incentive.rewardToken, rewardToken);
        assertEq(incentive.rewardPerLiquidity, type(uint256).max / 2);
        assertEq(incentive.endTime, endTime);
        assertEq(incentive.lastRewardTime, startTime < block.timestamp ? uint32(block.timestamp) : startTime);
        assertEq(incentive.rewardRemaining, amount);
        assertEq(incentivesRewarder.poolInfo(pid), 0);
        assertEq(count + 1, id);
        assertEq(incentivesRewarder.incentiveCount(), id);
        assertEq(thisBalance - amount, Token(rewardToken).balanceOf(address(this)));
        assertEq(rewarderBalance + amount, Token(rewardToken).balanceOf(address(incentivesRewarder)));
        
        return id;
    }

    function _updateIncentive(
        uint256 incentiveId,
        int112 changeAmount,
        uint32 startTime,
        uint32 endTime
    ) public {
        IncentivesRewarder.Incentive memory incentive = _getIncentive(incentiveId);
        uint256 thisBlance = Token(incentive.rewardToken).balanceOf(address(this));
        uint256 rewarderBalance = Token(incentive.rewardToken).balanceOf(address(incentivesRewarder));
        uint32 newStartTime = startTime == 0 ? incentive.lastRewardTime : (startTime < uint32(block.timestamp) ? uint32(block.timestamp) : startTime);
        uint32 newEndTime = endTime == 0 ? incentive.endTime : (endTime < uint32(block.timestamp) ? uint32(block.timestamp) : endTime);
        
        if (newStartTime >= endTime) {
            vm.expectRevert(invalidTimeFrame);
            incentivesRewarder.updateIncentive(incentiveId, changeAmount, startTime, endTime);
            return;
        }

        if (changeAmount == type(int112).min) {
            vm.expectRevert(overflow);
            incentivesRewarder.updateIncentive(incentiveId, changeAmount, startTime, endTime);
            return;
        }

        if (changeAmount > 0 && uint112(changeAmount) + uint256(incentive.rewardRemaining) > type(uint112).max) {
            vm.expectRevert(overflow);
            incentivesRewarder.updateIncentive(incentiveId, changeAmount, startTime, endTime);
            return;
        }

        incentivesRewarder.updateIncentive(incentiveId, changeAmount, startTime, endTime);

        if (changeAmount < 0 && uint112(-changeAmount) > incentive.rewardRemaining) {
            changeAmount = -int112(incentive.rewardRemaining);
        }

        IncentivesRewarder.Incentive memory updatedIncentive = _getIncentive(incentiveId);
        assertEq(updatedIncentive.lastRewardTime, newStartTime);
        assertEq(updatedIncentive.endTime, newEndTime);
        assertEq(updatedIncentive.rewardRemaining, changeAmount < 0 ? incentive.rewardRemaining - uint112(-changeAmount) : incentive.rewardRemaining + uint112(changeAmount));
        assertEq(updatedIncentive.creator, incentive.creator);
        assertEq(updatedIncentive.pid, incentive.pid);
        assertEq(updatedIncentive.rewardToken, incentive.rewardToken);
    }





    function _getIncentive(uint256 id) public returns (IncentivesRewarder.Incentive memory incentive) {
        (
            address creator,
            uint256 pid,
            address rewardToken,
            uint256 rewardPerLiquidity,
            uint32 endTime,
            uint32 lastRewardTime,
            uint112 rewardRemaining
        ) = incentivesRewarder.incentives(id);
        incentive = IncentivesRewarder.Incentive(
            creator,
            pid,
            rewardToken,
            rewardPerLiquidity,
            endTime,
            lastRewardTime,
            rewardRemaining
        );
    }
}
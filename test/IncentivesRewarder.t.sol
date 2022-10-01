// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import "./TestSetup.sol";

contract IncentivesTest is TestSetup {

    function testInitialCreateIncentive() public {
        uint256 id = _createIncentive(0, address(tokenA), 100, 2592000, 2593000);
        assertEq(id, 1);
    }
    
    function testInitialUpdateIncentive() public {
        uint256 id = _createIncentive(0, address(tokenA), 100, 2592000, 2593000);
        _updateIncentive(id, 10, 2593000, 2594000);
    }

    function testIniitialIntegration() public {
        
        //vm.prank(userB);
        //masterChef.deposit(0, 1, userB);
        
        uint32 duration = 2592000;
        uint256 ongoingIncentive = _createIncentive(0, address(tokenA), 100, uint32(block.timestamp), uint32(block.timestamp + duration));
        
        vm.prank(userA);
        incentivesRewarder.subscribeToIncentive(0, ongoingIncentive);

        //vm.warp(block.timestamp + 10);

        //incentivesRewarder.activateIncentive(ongoingIncentive, userB);

        vm.warp(block.timestamp + 10);

        vm.prank(userB);
        masterChef.deposit(0, 1, userB);
        
        vm.warp(block.timestamp + duration);
        
        vm.prank(userB);
        masterChef.harvest(0, userB);
        uint256 balanceB = Token(tokenA).balanceOf(address(userB));
        
        //console.log(balanceB);
        assertEq(balanceB, 100);
    }

    function testCreateIncentive(
        uint256 pid,
        uint112 amount,
        uint32 startTime,
        uint32 endTime
    ) public {
        _createIncentive(pid, address(tokenA), amount, startTime, endTime);
    }

    function testFailCreateIncentiveRewardToken(uint32 startTime, uint32 endTime) public {
        _createIncentive(0, zeroAddress, 1, startTime, endTime);
    }

    /*function testUpdateIncentive(
        int112 changeAmount0,
        int112 changeAmount1,
        uint32 startTime0,
        uint32 startTime1,
        uint32 endTime0,
        uint32 endTime1
    ) public {
        _updateIncentive(ongoingIncentive, changeAmount0, startTime1, endTime1);
    }*/

}

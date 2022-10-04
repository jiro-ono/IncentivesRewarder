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
        
        vm.prank(userB);
        masterChef.deposit(0, 1, userB);
        
        uint32 duration = 2592000;
        uint256 ongoingIncentive = _createIncentive(0, address(tokenA), 100, uint32(block.timestamp), uint32(block.timestamp + duration));
        
        vm.prank(userA);
        incentivesRewarder.subscribeToIncentive(0, ongoingIncentive);

        vm.prank(userB);
        incentivesRewarder.activateIncentive(1, userB);

        //vm.warp(block.timestamp + 10);

        //incentivesRewarder.activateIncentive(ongoingIncentive, userB);

        vm.warp(block.timestamp + 10);

        //vm.prank(userB);
        //masterChef.deposit(0, 1, userB);
        
        vm.warp(block.timestamp + duration);
        
        IERC20[] memory rewardTokens;
        uint256[] memory rewardAmounts;
        (rewardTokens, rewardAmounts) = incentivesRewarder.pendingTokens(0, userB, 0);
        assertEq(rewardAmounts[0], 100);
        assertEq(address(rewardTokens[0]), address(tokenA));


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


    //todo: test_activate_incentive for gas snapshot



    // Scenario 1
    // ------------
    // userA stakes first
    // userB stakes durtation after start
    // userA unstakes duration after userB stakes
    // userC stakes
    // userA stakes
    // user B unstakes 1/2
    // reward period ends


    // Scenario 2
    // --------------
    // test 3 users staking, period ends and new incentives are spun up 100 blocks later
    //  - sub test of this could be 1 user activates and 1 doesn't for a certain duration then
    //    activates certain amount of time later


    // Scenario 3
    // ---------------
    // test incentive creator updates incentives midway through the period w/ users rewards
    // still avail to be harvested by users 

    // Scenario 4
    // ---------------
    //  Run scenario 1 situation but with multiple incentives for 1 pair, that become
    //  active at different periods. Probably can fuzz test this as well to cover lots of
    //  cases
    //

    // 


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

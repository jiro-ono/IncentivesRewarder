// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import "./TestSetup.sol";

import {console} from "forge-std/console.sol";

contract IncentivesTest is TestSetup {

    function testIniitialIntegration() public {
        
        _depositChef(0, 1, userA);
        
        uint32 duration = 2592000;
        uint256 ongoingIncentive = _createIncentive(0, address(rewardToken0), 100, uint32(block.timestamp), uint32(block.timestamp + duration));
        
        //vm.prank(userOwner);
        //incentivesRewarder.subscribeToIncentive(0, ongoingIncentive);
        _subscribeToIncentive(0, ongoingIncentive);

        _activateIncentive(1, userA);
        _activateIncentive(1, userB);

        //vm.warp(block.timestamp + 10);

        //incentivesRewarder.activateIncentive(ongoingIncentive, userA);

        vm.warp(block.timestamp + 10);

        uint256 userStaked = _getUsersLiquidityStaked(0, userA);

        //vm.prank(userA);
        //masterChef.deposit(0, 1, userA);
        
        vm.warp(block.timestamp + duration);
        
        IERC20[] memory rewardTokens;
        uint256[] memory rewardAmounts;
        (rewardTokens, rewardAmounts) = _pendingTokens(0, userA);
        assertEq(rewardAmounts[0], 100);
        assertEq(address(rewardTokens[0]), address(rewardToken0));

        _harvestChef(0, userA);
        uint256 balanceB = Token(rewardToken0).balanceOf(address(userA));
        
        //console.log(balanceB);
        assertEq(balanceB, 100);


        vm.prank(userOwner);
        _unsubscribeFromIncentive(0, 0);

        _withdrawChef(0, 1, userA);
    }

    function testCreateValidIncentive(
        uint256 pid,
        uint112 amount,
        uint32 startTime,
        uint32 endTime
    ) public {
        vm.assume(startTime < endTime && startTime > block.timestamp);
        vm.assume(startTime > block.timestamp);
        vm.assume(amount > 0);

        uint256 incentiveId = _createIncentive(pid, address(rewardToken0), amount, startTime, endTime);
        assertEq(incentiveId, 1);
    }

    function testFailCreateIncentiveInvalidRewardToken(uint32 startTime, uint32 endTime) public {
        _createIncentive(0, zeroAddress, 1, startTime, endTime);
    }

    function testCreateAndUpdateValidIncentive(
        uint112 amount,
        int112 changeAmount,
        uint32 startTime,
        uint32 endTime
    ) public {
        vm.assume(startTime < endTime && startTime > block.timestamp);
        vm.assume(amount > 0);

        uint256 id = _createIncentive(0, address(rewardToken0), amount, startTime, endTime);

        vm.warp(startTime + 1);
        _updateIncentive(1, changeAmount, startTime, endTime);
    }

    function testCreateAndSubscribeValidIncentive(
         uint256 pid,
        uint112 amount,
        uint32 startTime,
        uint32 endTime
    ) public {
        vm.assume(startTime < endTime && startTime > block.timestamp);
        vm.assume(startTime > block.timestamp);
        vm.assume(amount > 0);
        
        uint256 incentiveId = _createIncentive(pid, address(rewardToken0), amount, startTime, endTime);
       
        vm.prank(userOwner);
        _subscribeToIncentive(0, incentiveId);
        uint24[] memory subscribed = incentivesRewarder.getSubscribedIncentives(0);
        assertEq(subscribed[0], incentiveId);

        vm.warp(startTime + 1);
        vm.prank(userOwner);
        _unsubscribeFromIncentive(0, 0);
        uint24[] memory subscribedAfter = incentivesRewarder.getSubscribedIncentives(0);
        assertEq(subscribedAfter.length, 0);
    }


    //todo: test_activate_incentive for gas snapshot


    function testScenario1() public {
        //create incentive: 1000 rewardToken0 over 50ms starting @ next timestamp for stakedToken0
        uint256 incentive = _createIncentive(0, address(rewardToken0), 1000, uint32(2), uint32(52));
        _subscribeToIncentive(0, incentive);

        // userA stakes 10 stakedToken0
        _depositChef(0, 10, userA);

        // warp to incentive start
        vm.warp(2);

        uint256 userAStaked = incentivesRewarder.userStakes(0, userA);
        assertEq(userAStaked, 10);

        // warp to halfway of incentive (2 + 25)
        // userA pendingTokens should be 50 rewardToken0
        vm.warp(27);
        IERC20[] memory rewardTokens;
        uint256[] memory rewardAmounts;
        (rewardTokens, rewardAmounts) = _pendingTokens(0, userA);
        assertEq(rewardAmounts[0], 500);

        // userB stakes 10 stakedToken0
        _depositChef(0, 10, userB);

        //warp to end of incentive
        // userA pendingTokens should be 75, and userB 25
        vm.warp(52);
        IERC20[] memory rewardTokensA;
        uint256[] memory rewardAmountsA;
        IERC20[] memory rewardTokenB;
        uint256[] memory rewardAmountsB;
        (rewardTokensA, rewardAmountsA) = _pendingTokens(0, userA);
        (rewardTokenB, rewardAmountsB) = _pendingTokens(0, userB);

        assertEq(rewardAmountsA[0], 750);
        assertEq(rewardAmountsB[0], 250);

        // harvest for users
        _harvestChef(0, userA);
        _harvestChef(0, userB);


        uint256 balanceA = Token(rewardToken0).balanceOf(address(userA));
        uint256 balanceB = Token(rewardToken0).balanceOf(address(userB));
        uint256 balanceRewarder = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        assertEq(balanceA, 750);
        assertEq(balanceB, 250);
        assertEq(balanceRewarder, 0);

        IncentivesRewarder.Incentive memory testIncentive = _getIncentive(incentive);
        assertEq(testIncentive.rewardRemaining, 0);
    }

    function testScenario2() public {
        //create incentive: 1000 rewardToken0 over 50ms starting @ next timestamp for stakedToken0
        uint256 incentive = _createIncentive(0, address(rewardToken0), 1000, uint32(2), uint32(52));
        _subscribeToIncentive(0, incentive);

        // userA stakes 10 stakedToken0
        _depositChef(0, 10, userA);

        // warp to end of incentives
        vm.warp(52);
        IERC20[] memory rewardTokensA;
        uint256[] memory rewardAmountsA;
        (rewardTokensA, rewardAmountsA) = _pendingTokens(0, userA);

        assertEq(rewardAmountsA[0], 1000);

        // userA harvests the rewards from incentive
        _harvestChef(0, userA);
        uint256 balanceA = Token(rewardToken0).balanceOf(address(userA));
        uint256 balanceRewarder = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        assertEq(balanceA, 1000);
        assertEq(balanceRewarder, 0);

        // warp to 18 blocks later, and update last incentive to re-run it again
        vm.warp(70);
        _updateIncentive(incentive, 1000, 70, 120);

        IncentivesRewarder.Incentive memory incentiveObj = _getIncentive(incentive);
        balanceRewarder = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        assertEq(incentiveObj.rewardRemaining, 1000);
        assertEq(balanceRewarder, 1000);
        
        // warp to end of incentive
        vm.warp(120);
        (rewardTokensA, rewardAmountsA) = _pendingTokens(0, userA);
        assertEq(rewardAmountsA[0], 1000);

        _harvestChef(0, userA);
        balanceA = Token(rewardToken0).balanceOf(address(userA));
        balanceRewarder = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        assertEq(balanceA, 2000);
        assertEq(balanceRewarder, 0);

    }

    function testScenario3() public {
        // Incentive runs, user doesn't harvest, then updated incentive runs that's idential
        // user should be able to harvest 2000 rewardToken0 from both incentive periods
        //create incentive: 1000 rewardToken0 over 50ms starting @ next timestamp for stakedToken0
        uint256 incentive = _createIncentive(0, address(rewardToken0), 1000, uint32(2), uint32(52));
        _subscribeToIncentive(0, incentive);

        // userA stakes 10 stakedToken0
        _depositChef(0, 10, userA);

        // warp to end of incentives
        vm.warp(52);
        IERC20[] memory rewardTokensA;
        uint256[] memory rewardAmountsA;
        (rewardTokensA, rewardAmountsA) = _pendingTokens(0, userA);
        assertEq(rewardAmountsA[0], 1000);

        uint256 balanceA = Token(rewardToken0).balanceOf(address(userA));
        uint256 balanceRewarder = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        assertEq(balanceA, 0);
        assertEq(balanceRewarder, 1000);

        // warp to 18 blocks later, and update last incentive to re-run it again
        vm.warp(70);
        _updateIncentive(incentive, 1000, 70, 120);

        IncentivesRewarder.Incentive memory incentiveObj = _getIncentive(incentive);
        balanceRewarder = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        assertEq(incentiveObj.rewardRemaining, 2000);
        assertEq(balanceRewarder, 2000);
        
        // warp to end of incentive
        vm.warp(120);
        (rewardTokensA, rewardAmountsA) = _pendingTokens(0, userA);
        assertEq(rewardAmountsA[0], 2000);

        _harvestChef(0, userA);
        balanceA = Token(rewardToken0).balanceOf(address(userA));
        balanceRewarder = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        assertEq(balanceA, 2000);
        assertEq(balanceRewarder, 0);
    }

    function testScenario4() public {
        //create incentive: 1000 rewardToken0 over 50ms starting @ next timestamp for stakedToken0
        uint256 incentive = _createIncentive(0, address(rewardToken0), 1000, uint32(2), uint32(52));
        _subscribeToIncentive(0, incentive);

        // userA stakes 10 stakedToken0
        _depositChef(0, 10, userA);

        // warp 10 blocks ahead of incentive start
        vm.warp(12);
        uint256 incentive2 = _createIncentive(0, address(rewardToken1), 500, uint32(12), uint32(52));
        _subscribeToIncentive(0, incentive2);
        
        //activate incentive2 for userA
        _activateIncentive(incentive2, userA);

        vm.warp(52);
        IERC20[] memory rewardTokensA;
        uint256[] memory rewardAmountsA;
        (rewardTokensA, rewardAmountsA) = _pendingTokens(0, userA);
        assertEq(rewardAmountsA[0], 1000);
        assertEq(rewardAmountsA[1], 500);

        _harvestChef(0, userA);
        uint256 balanceUser0 = Token(rewardToken0).balanceOf(address(userA));
        uint256 balanceUser1 = Token(rewardToken1).balanceOf(address(userA));
        uint256 balanceRewarder0 = Token(rewardToken0).balanceOf(address(incentivesRewarder));
        uint256 balanceRewarder1 = Token(rewardToken1).balanceOf(address(incentivesRewarder));
        assertEq(balanceUser0, 1000);
        assertEq(balanceUser1, 500);
        assertEq(balanceRewarder0, 0);
        assertEq(balanceRewarder1, 0);

    }



    // Scenario 1
    // ------------
    // userA stakes first, is entire pool for half of the incentive duration
    // userB stakes second, halfway through incentive period
    // incentive ends and userA get 75% of the rewards, userB get's 25% of the rewards

    // Scenario 2
    // --------------
    // userA stakes, incentive period runs full duration
    // userA harvests the rewards at end of incentive
    // skip couple blocks, then update incentive to run it again for same amount & period
    // userA harvest the same amount of rewards at end of 2nd iteration of same incentiveId
    

    // Scenario3
    // ------------
    // Same as scenario2, execept userA doesn't harvest in between new incentive periods
    // Is able to full amount from both icentive periods that ran for the same incentiveId


    // Scenario 4
    // ---------------
    // test incentive creator updates incentives midway through the period w/ users rewards
    // still avail to be harvested by users 

    // Scenario 4
    // ---------------
    //  Run scenario 1 situation but with multiple incentives for 1 pair, that become
    //  active at different periods. Probably can fuzz test this as well to cover lots of
    //  cases
    //

    // Scenario 5
    // ----------------
    // Need to double test that when an incentive period ends that no one can come in an use
    // activateIncentive or anything to clean out the rewards
    // delta should always be 0 for those that come in after incentive ends
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

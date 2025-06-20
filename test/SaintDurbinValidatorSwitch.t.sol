// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/SaintDurbin.sol";
import "./mocks/MockStaking.sol";
import "./mocks/MockMetagraph.sol";

contract SaintDurbinValidatorSwitchTest is Test {
    SaintDurbin public saintDurbin;
    MockStaking public mockStaking;
    MockMetagraph public mockMetagraph;

    address emergencyOperator = address(0x2);
    bytes32 drainSs58Address = bytes32(uint256(0x999));
    bytes32 validatorHotkey = bytes32(uint256(0x777));
    bytes32 contractSs58Key = bytes32(uint256(0x888));
    uint16 netuid = 1;
    uint16 validatorUid = 123;

    // Additional validators for testing
    bytes32 validator2Hotkey = bytes32(uint256(0x778));
    uint16 validator2Uid = 124;
    bytes32 validator3Hotkey = bytes32(uint256(0x779));
    uint16 validator3Uid = 125;

    bytes32[] recipientColdkeys;
    uint256[] proportions;

    uint256 constant INITIAL_STAKE = 10000e9; // 10,000 TAO

    event ValidatorSwitched(bytes32 indexed oldHotkey, bytes32 indexed newHotkey, uint16 newUid, string reason);
    event ValidatorCheckFailed(string reason);

    function setUp() public {
        // Deploy mock staking at the expected address
        vm.etch(address(0x805), type(MockStaking).runtimeCode);
        mockStaking = MockStaking(address(0x805));

        // Deploy mock metagraph at the expected address
        vm.etch(address(0x802), type(MockMetagraph).runtimeCode);
        mockMetagraph = MockMetagraph(address(0x802));

        // Setup recipients
        recipientColdkeys = new bytes32[](16);
        proportions = new uint256[](16);

        for (uint256 i = 0; i < 16; i++) {
            recipientColdkeys[i] = bytes32(uint256(0x100 + i));
            proportions[i] = 625; // 6.25% each
        }

        // Set up the initial validator in the metagraph
        mockMetagraph.setValidator(netuid, validatorUid, true, true, validatorHotkey, uint64(1000e9), 10000);
        mockMetagraph.setUidCount(netuid, 130); // Set higher than our test UIDs

        // Set initial stake for the contract
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, INITIAL_STAKE);

        // Deploy SaintDurbin
        saintDurbin = new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            recipientColdkeys,
            proportions
        );
    }

    function testValidatorLosesPermit() public {
        // Set up alternative validators
        mockMetagraph.setValidator(netuid, validator2Uid, true, true, validator2Hotkey, uint64(2000e9), 15000);
        mockMetagraph.setValidator(netuid, validator3Uid, true, true, validator3Hotkey, uint64(1500e9), 12000);

        // Current validator loses permit
        mockMetagraph.setValidator(netuid, validatorUid, false, true, validatorHotkey, uint64(1000e9), 10000);

        // Expect the validator switch event
        vm.expectEmit(true, true, false, true);
        emit ValidatorSwitched(validatorHotkey, validator2Hotkey, validator2Uid, "Validator lost permit");

        // Call checkAndSwitchValidator
        saintDurbin.checkAndSwitchValidator();

        // Verify validator was switched
        assertEq(saintDurbin.currentValidatorHotkey(), validator2Hotkey);
        assertEq(saintDurbin.currentValidatorUid(), validator2Uid);
    }

    function testValidatorBecomesInactive() public {
        // Set up alternative validator
        mockMetagraph.setValidator(netuid, validator2Uid, true, true, validator2Hotkey, uint64(2000e9), 15000);

        // Current validator becomes inactive
        mockMetagraph.setValidator(netuid, validatorUid, true, false, validatorHotkey, uint64(1000e9), 10000);

        // Expect the validator switch event
        vm.expectEmit(true, true, false, true);
        emit ValidatorSwitched(validatorHotkey, validator2Hotkey, validator2Uid, "Validator is inactive");

        // Call checkAndSwitchValidator
        saintDurbin.checkAndSwitchValidator();

        // Verify validator was switched
        assertEq(saintDurbin.currentValidatorHotkey(), validator2Hotkey);
        assertEq(saintDurbin.currentValidatorUid(), validator2Uid);
    }

    function testValidatorUidHotkeyMismatch() public {
        // Set up alternative validator
        mockMetagraph.setValidator(netuid, validator2Uid, true, true, validator2Hotkey, uint64(2000e9), 15000);

        // Change the hotkey for the current UID (simulating UID reassignment)
        bytes32 differentHotkey = bytes32(uint256(0x666));
        mockMetagraph.setValidator(netuid, validatorUid, true, true, differentHotkey, uint64(1000e9), 10000);

        // Expect the validator switch event
        vm.expectEmit(true, true, false, true);
        emit ValidatorSwitched(validatorHotkey, validator2Hotkey, validator2Uid, "Validator UID hotkey mismatch");

        // Call checkAndSwitchValidator
        saintDurbin.checkAndSwitchValidator();

        // Verify validator was switched
        assertEq(saintDurbin.currentValidatorHotkey(), validator2Hotkey);
        assertEq(saintDurbin.currentValidatorUid(), validator2Uid);
    }

    function testSelectBestValidator() public {
        // Set up multiple validators with different scores
        // Validator 2: stake=2000, dividend=15000 -> score = 2000 * (65535 + 15000) / 65535 ≈ 2458
        mockMetagraph.setValidator(netuid, validator2Uid, true, true, validator2Hotkey, uint64(2000e9), 15000);

        // Validator 3: stake=3000, dividend=5000 -> score = 3000 * (65535 + 5000) / 65535 ≈ 3229
        mockMetagraph.setValidator(netuid, validator3Uid, true, true, validator3Hotkey, uint64(3000e9), 5000);

        // Current validator loses permit
        mockMetagraph.setValidator(netuid, validatorUid, false, true, validatorHotkey, uint64(1000e9), 10000);

        // Should select validator3 as it has the highest score
        vm.expectEmit(true, true, false, true);
        emit ValidatorSwitched(validatorHotkey, validator3Hotkey, validator3Uid, "Validator lost permit");

        // Call checkAndSwitchValidator
        saintDurbin.checkAndSwitchValidator();

        // Verify validator3 was selected (highest score)
        assertEq(saintDurbin.currentValidatorHotkey(), validator3Hotkey);
        assertEq(saintDurbin.currentValidatorUid(), validator3Uid);
    }

    function testNoValidValidatorFound() public {
        // All other validators are inactive or don't have permits
        mockMetagraph.setValidator(netuid, validator2Uid, false, true, validator2Hotkey, uint64(2000e9), 15000);
        mockMetagraph.setValidator(netuid, validator3Uid, true, false, validator3Hotkey, uint64(1500e9), 12000);

        // Current validator loses permit
        mockMetagraph.setValidator(netuid, validatorUid, false, true, validatorHotkey, uint64(1000e9), 10000);

        // Expect the check failed event
        vm.expectEmit(false, false, false, true);
        emit ValidatorCheckFailed("No valid validator found");

        // Call checkAndSwitchValidator
        saintDurbin.checkAndSwitchValidator();

        // Verify validator was NOT switched
        assertEq(saintDurbin.currentValidatorHotkey(), validatorHotkey);
        assertEq(saintDurbin.currentValidatorUid(), validatorUid);
    }

    function testValidatorSwitchDuringExecuteTransfer() public {
        // Set up alternative validator
        mockMetagraph.setValidator(netuid, validator2Uid, true, true, validator2Hotkey, uint64(2000e9), 15000);

        // Add some yield to distribute
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 100e9);

        // Advance time to allow transfer
        vm.roll(block.number + 7201);

        // Current validator loses permit
        mockMetagraph.setValidator(netuid, validatorUid, false, true, validatorHotkey, uint64(1000e9), 10000);

        // executeTransfer should check and switch validator
        vm.expectEmit(true, true, false, true);
        emit ValidatorSwitched(validatorHotkey, validator2Hotkey, validator2Uid, "Validator lost permit");

        // Call executeTransfer
        saintDurbin.executeTransfer();

        // Verify validator was switched
        assertEq(saintDurbin.currentValidatorHotkey(), validator2Hotkey);
        assertEq(saintDurbin.currentValidatorUid(), validator2Uid);
    }

    function testMoveStakeFailure() public {
        // Set up alternative validator
        mockMetagraph.setValidator(netuid, validator2Uid, true, true, validator2Hotkey, uint64(2000e9), 15000);

        // Current validator loses permit
        mockMetagraph.setValidator(netuid, validatorUid, false, true, validatorHotkey, uint64(1000e9), 10000);

        // Make moveStake fail
        mockStaking.setShouldRevert(true, "Move stake failed");

        // Expect the check failed event
        vm.expectEmit(false, false, false, true);
        emit ValidatorCheckFailed("Failed to move stake to new validator");

        // Call checkAndSwitchValidator
        saintDurbin.checkAndSwitchValidator();

        // Verify validator was NOT switched due to moveStake failure
        assertEq(saintDurbin.currentValidatorHotkey(), validatorHotkey);
        assertEq(saintDurbin.currentValidatorUid(), validatorUid);
    }
}

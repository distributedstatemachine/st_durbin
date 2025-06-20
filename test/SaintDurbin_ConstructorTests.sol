// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/SaintDurbin.sol";
import "./mocks/MockStaking.sol";

contract SaintDurbinConstructorTests is Test {
    MockStaking public mockStaking;

    address emergencyOperator = address(0x2);
    bytes32 drainSs58Address = bytes32(uint256(0x999));
    bytes32 validatorHotkey = bytes32(uint256(0x777));
    bytes32 contractSs58Key = bytes32(uint256(0x888));
    uint16 netuid = 1;
    uint16 validatorUid = 123;

    bytes32[] recipientColdkeys;
    uint256[] proportions;

    function setUp() public {
        // Deploy mock staking
        vm.etch(address(0x805), type(MockStaking).runtimeCode);
        mockStaking = MockStaking(address(0x805));

        // Setup recipients
        recipientColdkeys = new bytes32[](16);
        proportions = new uint256[](16);

        for (uint256 i = 0; i < 16; i++) {
            recipientColdkeys[i] = bytes32(uint256(0x100 + i));
            proportions[i] = 625; // 6.25% each
        }
    }

    function testConstructor_InvalidEmergencyOperator() public {
        vm.expectRevert(SaintDurbin.InvalidAddress.selector);
        new SaintDurbin(
            address(0), // invalid emergency operator
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            recipientColdkeys,
            proportions
        );
    }

    function testConstructor_InvalidDrainAddress() public {
        vm.expectRevert(SaintDurbin.InvalidAddress.selector);
        new SaintDurbin(
            emergencyOperator,
            bytes32(0), // invalid drain address
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            recipientColdkeys,
            proportions
        );
    }

    function testConstructor_InvalidValidatorHotkey() public {
        vm.expectRevert(SaintDurbin.InvalidHotkey.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            bytes32(0),
            validatorUid, // invalid validator hotkey
            contractSs58Key,
            netuid,
            recipientColdkeys,
            proportions
        );
    }

    function testConstructor_InvalidSs58Key() public {
        vm.expectRevert(SaintDurbin.InvalidAddress.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            bytes32(0), // invalid SS58 key
            netuid,
            recipientColdkeys,
            proportions
        );
    }

    function testConstructor_MismatchedArrays() public {
        bytes32[] memory wrongColdkeys = new bytes32[](15); // mismatched length

        vm.expectRevert(SaintDurbin.ProportionsMismatch.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            wrongColdkeys,
            proportions
        );
    }

    function testConstructor_WrongRecipientCount() public {
        bytes32[] memory wrongRecipients = new bytes32[](15); // wrong count
        uint256[] memory wrongProportions = new uint256[](15);

        for (uint256 i = 0; i < 15; i++) {
            wrongRecipients[i] = bytes32(uint256(0x100 + i));
            wrongProportions[i] = 666;
        }

        vm.expectRevert(SaintDurbin.ProportionsMismatch.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            wrongRecipients,
            wrongProportions
        );
    }

    function testConstructor_InvalidRecipient() public {
        bytes32[] memory badRecipients = new bytes32[](16);
        uint256[] memory validProportions = new uint256[](16);

        for (uint256 i = 0; i < 16; i++) {
            badRecipients[i] = bytes32(uint256(0x100 + i));
            validProportions[i] = 625;
        }
        badRecipients[5] = bytes32(0); // invalid recipient

        vm.expectRevert(SaintDurbin.InvalidAddress.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            badRecipients,
            validProportions
        );
    }

    function testConstructor_InvalidProportion() public {
        uint256[] memory invalidProportions = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            invalidProportions[i] = 625;
        }
        invalidProportions[5] = 0; // invalid proportion

        vm.expectRevert(SaintDurbin.InvalidProportion.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            recipientColdkeys,
            invalidProportions
        );
    }

    function testConstructor_InvalidProportionSum() public {
        uint256[] memory wrongProportions = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            wrongProportions[i] = 500; // total will be 8000, not 10000
        }

        vm.expectRevert(SaintDurbin.ProportionsMismatch.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            recipientColdkeys,
            wrongProportions
        );
    }

    function testConstructor_ValidDeployment() public {
        // Set up initial stake for principal calculation
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 10000e9);

        SaintDurbin saintDurbin = new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            recipientColdkeys,
            proportions
        );

        // Verify all immutable values are set correctly
        assertEq(saintDurbin.emergencyOperator(), emergencyOperator);
        assertEq(saintDurbin.drainSs58Address(), drainSs58Address);
        assertEq(saintDurbin.currentValidatorHotkey(), validatorHotkey);
        assertEq(saintDurbin.thisSs58PublicKey(), contractSs58Key);
        assertEq(saintDurbin.netuid(), netuid);
        assertEq(saintDurbin.principalLocked(), 10000e9);
        assertEq(saintDurbin.getRecipientCount(), 16);
    }
}

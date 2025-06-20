// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/SaintDurbin.sol";

contract TestDeploy is Script {
    function run() external {
        vm.startBroadcast();

        // Test configuration
        address emergencyOperator = msg.sender;
        bytes32 drainSs58Address = bytes32(uint256(1));
        bytes32 validatorHotkey = bytes32(uint256(2));
        uint16 validatorUid = 0;
        bytes32 thisSs58PublicKey = bytes32(uint256(3));
        uint16 netuid = 0;

        // Recipients configuration
        bytes32[] memory recipientColdkeys = new bytes32[](16);
        uint256[] memory proportions = new uint256[](16);

        // Set up test recipients
        for (uint256 i = 0; i < 16; i++) {
            recipientColdkeys[i] = bytes32(uint256(0x100 + i));
        }

        // Set up proportions (total 10000)
        proportions[0] = 100; // Sam: 1%
        proportions[1] = 100; // WSL: 1%
        proportions[2] = 500; // Paper: 5%
        proportions[3] = 100; // Florian: 1%
        proportions[4] = 100; // 1%
        proportions[5] = 100; // 1%
        proportions[6] = 100; // 1%
        proportions[7] = 300; // 3%
        proportions[8] = 300; // 3%
        proportions[9] = 300; // 3%
        proportions[10] = 1000; // 10%
        proportions[11] = 1000; // 10%
        proportions[12] = 1000; // 10%
        proportions[13] = 1500; // 15%
        proportions[14] = 1500; // 15%
        proportions[15] = 2000; // 20%

        SaintDurbin saintDurbin = new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            thisSs58PublicKey,
            netuid,
            recipientColdkeys,
            proportions
        );

        console.log("SaintDurbin deployed at:", address(saintDurbin));

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/SaintDurbin.sol";

contract DeploySaintDurbin is Script {
    function run() external {
        // Configuration - ALL MUST BE SET BEFORE DEPLOYMENT
        address emergencyOperator = vm.envAddress("EMERGENCY_OPERATOR");
        bytes32 drainSs58Address = vm.envBytes32("DRAIN_SS58_ADDRESS");
        bytes32 validatorHotkey = vm.envBytes32("VALIDATOR_HOTKEY");
        uint16 validatorUid = uint16(vm.envUint("VALIDATOR_UID"));
        bytes32 thisSs58PublicKey = vm.envBytes32("CONTRACT_SS58_KEY");
        uint16 netuid = uint16(vm.envUint("NETUID"));

        // Recipients configuration
        bytes32[] memory recipientColdkeys = new bytes32[](16);
        uint256[] memory proportions = new uint256[](16);

        // Named recipients from spec
        recipientColdkeys[0] = vm.envBytes32("RECIPIENT_SAM"); // Sam
        recipientColdkeys[1] = vm.envBytes32("RECIPIENT_WSL"); // WSL
        recipientColdkeys[2] = vm.envBytes32("RECIPIENT_PAPER"); // Paper
        recipientColdkeys[3] = vm.envBytes32("RECIPIENT_FLORIAN"); // Florian

        proportions[0] = 100; // Sam: 1%
        proportions[1] = 100; // WSL: 1%
        proportions[2] = 500; // Paper: 5%
        proportions[3] = 100; // Florian: 1%

        // Remaining 12 wallets (92% total - uneven distribution)
        // Load from environment
        for (uint256 i = 4; i < 16; i++) {
            recipientColdkeys[i] = vm.envBytes32(string.concat("RECIPIENT_", vm.toString(i)));
        }

        // Uneven distribution of remaining 92%
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

        // Verify proportions sum to 10,000
        uint256 totalProportions = 0;
        for (uint256 i = 0; i < proportions.length; i++) {
            totalProportions += proportions[i];
        }
        require(totalProportions == 10000, "Proportions must sum to 10,000");

        // Log configuration
        console.log("Deploying SaintDurbin with:");
        console.log("Emergency Operator:", emergencyOperator);
        console.log("Drain SS58 Address:", vm.toString(drainSs58Address));
        console.log("Validator Hotkey:", vm.toString(validatorHotkey));
        console.log("Validator UID:", validatorUid);
        console.log("Contract SS58 Key:", vm.toString(thisSs58PublicKey));
        console.log("NetUID:", netuid);
        console.log("Total Recipients:", recipientColdkeys.length);

        // Deploy the contract
        vm.startBroadcast();

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

        vm.stopBroadcast();

        // Log deployment result
        console.log("SaintDurbin deployed at:", address(saintDurbin));
        console.log("Initial principal locked:", saintDurbin.principalLocked());

        // Get current validator info
        (bytes32 hotkey, uint16 uid, bool isValid) = saintDurbin.getCurrentValidatorInfo();
        console.log("Current validator hotkey matches:", hotkey == validatorHotkey);
        console.log("Current validator UID:", uid);
        console.log("Validator is valid:", isValid);

        // Verify immutable configuration
        console.log("\nVerifying immutable configuration:");
        console.log("Emergency Operator:", saintDurbin.emergencyOperator());
        console.log("Drain SS58 Address:", vm.toString(saintDurbin.drainSs58Address()));
        console.log("Current Validator Hotkey:", vm.toString(saintDurbin.currentValidatorHotkey()));
        console.log("Contract SS58 Key:", vm.toString(saintDurbin.thisSs58PublicKey()));
        console.log("NetUID:", saintDurbin.netuid());

        console.log("\nDeployment complete! Contract is now fully immutable.");
    }
}

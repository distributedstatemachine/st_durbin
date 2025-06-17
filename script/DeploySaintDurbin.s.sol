// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/SaintDurbin.sol";

/**
 * @title DeploySaintDurbin
 * @notice Deployment script for the SaintDurbin contract
 * @dev Run with: forge script script/DeploySaintDurbin.s.sol:DeploySaintDurbin --rpc-url $RPC_URL --broadcast
 */
contract DeploySaintDurbin is Script {
    // Deployment parameters struct to avoid stack too deep
    struct DeployParams {
        address owner;
        address emergencyOperator;
        bytes32 drainSs58Address;
        bytes32 validatorHotkey;
        uint16 netuid;
        bytes32[] recipientColdkeys;
        uint256[] proportions;
    }
    
    function run() external {
        DeployParams memory params;
        
        // Load deployment parameters from environment
        params.owner = vm.envAddress("OWNER_ADDRESS");
        params.emergencyOperator = vm.envAddress("EMERGENCY_OPERATOR_ADDRESS");
        params.drainSs58Address = vm.envBytes32("DRAIN_SS58_ADDRESS");
        params.validatorHotkey = vm.envBytes32("VALIDATOR_HOTKEY");
        params.netuid = uint16(vm.envUint("NETUID"));
        
        // Recipients configuration
        params.recipientColdkeys = new bytes32[](16);
        params.proportions = new uint256[](16);
        
        // Load recipient coldkeys from environment
        params.recipientColdkeys[0] = vm.envBytes32("RECIPIENT_SAM");
        params.recipientColdkeys[1] = vm.envBytes32("RECIPIENT_WSL");
        params.recipientColdkeys[2] = vm.envBytes32("RECIPIENT_PAPER");
        params.recipientColdkeys[3] = vm.envBytes32("RECIPIENT_FLORIAN");
        
        // Load remaining 12 recipients
        for (uint256 i = 4; i < 16; i++) {
            params.recipientColdkeys[i] = vm.envBytes32(string.concat("RECIPIENT_", vm.toString(i - 3)));
        }
        
        // Set proportions based on spec
        params.proportions[0] = 100;  // Sam: 1%
        params.proportions[1] = 100;  // WSL: 1%
        params.proportions[2] = 500;  // Paper: 5%
        params.proportions[3] = 100;  // Florian: 1%
        
        // Calculate remaining distribution
        uint256 allocated = 100 + 100 + 500 + 100; // 800 basis points
        uint256 remaining = 10000 - allocated; // 9200 basis points
        uint256 perWallet = remaining / 12; // 766 basis points each
        uint256 leftover = remaining % 12; // 8 basis points
        
        // Distribute evenly among remaining 12 wallets
        for (uint256 i = 4; i < 16; i++) {
            params.proportions[i] = perWallet;
            if (i == 15) {
                // Add any leftover to the last wallet to ensure sum is exactly 10000
                params.proportions[i] += leftover;
            }
        }
        
        // Verify proportions sum to 10000
        uint256 total = 0;
        for (uint256 i = 0; i < params.proportions.length; i++) {
            total += params.proportions[i];
        }
        require(total == 10000, "Proportions must sum to 10000");
        
        // Start broadcast
        vm.startBroadcast();
        
        // Deploy the contract
        SaintDurbin saintDurbin = new SaintDurbin(
            params.owner,
            params.emergencyOperator,
            params.drainSs58Address,
            params.validatorHotkey,
            params.netuid,
            params.recipientColdkeys,
            params.proportions
        );
        
        vm.stopBroadcast();
        
        // Log deployment information
        console.log("SaintDurbin deployed at:", address(saintDurbin));
        console.log("Owner:", params.owner);
        console.log("Emergency Operator:", params.emergencyOperator);
        console.log("Network UID:", params.netuid);
        console.log("Initial Principal:", saintDurbin.principalLocked());
        
        // Log recipient configuration
        console.log("\nRecipient Configuration:");
        console.log("Sam: 1% (100 basis points)");
        console.log("WSL: 1% (100 basis points)");
        console.log("Paper: 5% (500 basis points)");
        console.log("Florian: 1% (100 basis points)");
        console.log("Remaining 12 wallets: ~7.67% each (", perWallet, "basis points)");
        console.log("Total verified:", total, "basis points");
        
        // Write deployment info to file
        writeDeploymentInfo(address(saintDurbin), params);
    }
    
    function writeDeploymentInfo(address contractAddr, DeployParams memory params) internal {
        string memory deploymentInfo = string.concat(
            '{"address":"', vm.toString(contractAddr),
            '","owner":"', vm.toString(params.owner),
            '","emergencyOperator":"', vm.toString(params.emergencyOperator),
            '","netuid":', vm.toString(params.netuid),
            ',"blockNumber":', vm.toString(block.number),
            '}'
        );
        
        vm.writeFile("deployment.json", deploymentInfo);
    }
}
import { getDevnetApi, getRandomSubstrateKeypair } from "../../subtensor_chain/evm-tests/src/substrate";
import { convertPublicKeyToSs58 } from "../../subtensor_chain/evm-tests/src/address-utils";
import { forceSetBalanceToSs58Address, addNewSubnetwork, addStake } from "../../subtensor_chain/evm-tests/src/subtensor";
import { tao } from "../../subtensor_chain/evm-tests/src/balance-math";

async function testSetup() {
    console.log("Starting SaintDurbin integration test setup...");
    
    try {
        // Connect to devnet
        const api = await getDevnetApi();
        console.log("✓ Connected to devnet");
        
        // Create test accounts
        const hotkey = getRandomSubstrateKeypair();
        const coldkey = getRandomSubstrateKeypair();
        
        // Fund accounts
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(hotkey.publicKey));
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(coldkey.publicKey));
        console.log("✓ Funded test accounts");
        
        // Create subnet
        await addNewSubnetwork(api, hotkey, coldkey);
        const netuid = (await api.query.SubtensorModule.TotalNetworks.getValue()) - 1;
        console.log(`✓ Created subnet with netuid: ${netuid}`);
        
        // Add stake
        await addStake(api, netuid, convertPublicKeyToSs58(hotkey.publicKey), tao(1000), coldkey);
        console.log("✓ Added stake to validator");
        
        console.log("\nTest setup complete! You can now deploy SaintDurbin contract.");
        console.log(`Validator hotkey: ${convertPublicKeyToSs58(hotkey.publicKey)}`);
        console.log(`Validator coldkey: ${convertPublicKeyToSs58(coldkey.publicKey)}`);
        console.log(`Netuid: ${netuid}`);
        
    } catch (error) {
        console.error("Test setup failed:", error);
        process.exit(1);
    }
}

// Run the test
testSetup();
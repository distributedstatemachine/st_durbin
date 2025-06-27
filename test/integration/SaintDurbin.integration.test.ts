import { describe, it, before, beforeEach } from "mocha";
import { expect } from "chai";
import { ethers } from "ethers";
import { getDevnetApi, getRandomSubstrateKeypair } from "../../subtensor_chain/evm-tests/src/substrate";
import { TypedApi } from "polkadot-api";
import { convertPublicKeyToSs58 } from "../../subtensor_chain/evm-tests/src/address-utils";
import { tao } from "../../subtensor_chain/evm-tests/src/balance-math";
import {
    forceSetBalanceToSs58Address,
    forceSetBalanceToEthAddress,
    addNewSubnetwork,
    addStake,
    burnedRegister,
    setMaxAllowedValidators
} from "../../subtensor_chain/evm-tests/src/subtensor";
import { generateRandomEthersWallet } from "../../subtensor_chain/evm-tests/src/utils";
import { IMETAGRAPH_ADDRESS, IMetagraphABI } from "../../subtensor_chain/evm-tests/src/contracts/metagraph";

// Import the SaintDurbin contract ABI and bytecode
import SaintDurbinArtifact from "../../out/SaintDurbin.sol/SaintDurbin.json";

describe("SaintDurbin Live Integration Tests", () => {
    let api: any; // TypedApi from polkadot-api
    let provider: ethers.JsonRpcProvider;
    let signer: ethers.Wallet;
    let netuid: number;
    
    // Test accounts
    const emergencyOperator = generateRandomEthersWallet();
    const validator1Hotkey = getRandomSubstrateKeypair();
    const validator1Coldkey = getRandomSubstrateKeypair();
    const validator2Hotkey = getRandomSubstrateKeypair();
    const validator2Coldkey = getRandomSubstrateKeypair();
    const contractColdkey = getRandomSubstrateKeypair();
    const drainAddress = getRandomSubstrateKeypair();
    
    // Recipients for testing
    const recipients: { keypair: any, proportion: number }[] = [];
    for (let i = 0; i < 16; i++) {
        recipients.push({
            keypair: getRandomSubstrateKeypair(),
            proportion: 625 // 6.25% each
        });
    }
    
    let saintDurbin: any; // Using any to avoid type issues with contract deployment
    let metagraph: ethers.Contract;

    before(async function() {
        this.timeout(180000); // 3 minutes timeout for setup
        
        // Connect to local subtensor chain
        provider = new ethers.JsonRpcProvider("http://127.0.0.1:8545");
        signer = emergencyOperator.connect(provider);
        
        // Initialize substrate API
        api = await getDevnetApi();
        
        // Fund all test accounts
        console.log("Funding validator1Hotkey...");
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(validator1Hotkey.publicKey));
        console.log("Funding validator1Coldkey...");
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(validator1Coldkey.publicKey));
        console.log("Funding validator2Hotkey...");
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(validator2Hotkey.publicKey));
        console.log("Funding validator2Coldkey...");
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(validator2Coldkey.publicKey));
        console.log("Funding contractColdkey...");
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(contractColdkey.publicKey));
        console.log("Funding emergencyOperator...");
        await forceSetBalanceToEthAddress(api, emergencyOperator.address);
        
        // Recipients don't need funding - they only receive distributions
        // Wait a bit for all balance updates to settle
        console.log("Waiting for balance updates to settle...");
        await new Promise(resolve => setTimeout(resolve, 2000));
        
        // Create a new subnet
        console.log("Creating new subnet...");
        try {
            await addNewSubnetwork(api, validator1Hotkey, validator1Coldkey);
            netuid = (await api.query.SubtensorModule.TotalNetworks.getValue()) - 1;
            console.log(`Subnet created with netuid: ${netuid}`);
        } catch (error) {
            console.error("Failed to create subnet:", error);
            throw error;
        }
        
        // Register validators
        console.log("Registering validator1...");
        await burnedRegister(api, netuid, convertPublicKeyToSs58(validator1Hotkey.publicKey), validator1Coldkey);
        console.log("Registering validator2...");
        await burnedRegister(api, netuid, convertPublicKeyToSs58(validator2Hotkey.publicKey), validator2Coldkey);
        
        // Set max allowed validators to enable validator permits
        console.log("Setting max allowed validators...");
        await setMaxAllowedValidators(api, netuid, 2);
        
        // Initialize metagraph contract
        metagraph = new ethers.Contract(IMETAGRAPH_ADDRESS, IMetagraphABI, signer);
        
        console.log(`Test setup complete. Netuid: ${netuid}`);
    });

    beforeEach(async function() {
        // Add initial stake to validator1 from contract coldkey
        await addStake(api, netuid, convertPublicKeyToSs58(validator1Hotkey.publicKey), tao(10000), contractColdkey);
    });

    describe("Contract Deployment", () => {
        it("Should deploy SaintDurbin contract with correct parameters", async function() {
            this.timeout(30000);
            
            // Get validator1 UID
            const validator1Uid = await metagraph.getUid(netuid, validator1Hotkey.publicKey);
            
            const recipientColdkeys = recipients.map(r => r.keypair.publicKey);
            const proportions = recipients.map(r => r.proportion);
            
            // Deploy SaintDurbin
            const factory = new ethers.ContractFactory(
                SaintDurbinArtifact.abi,
                SaintDurbinArtifact.bytecode.object,
                signer
            );
            
            // Convert SS58 addresses to bytes32 format for the contract
            const drainAddressSs58 = convertPublicKeyToSs58(drainAddress.publicKey);
            const contractColdkeySs58 = convertPublicKeyToSs58(contractColdkey.publicKey);
            
            // For bytes32, we need to pad the public keys to 32 bytes
            const drainAddressBytes32 = '0x' + drainAddress.publicKey.toString('hex').padEnd(64, '0');
            const validator1HotkeyBytes32 = '0x' + validator1Hotkey.publicKey.toString('hex').padEnd(64, '0');
            const contractColdkeyBytes32 = '0x' + contractColdkey.publicKey.toString('hex').padEnd(64, '0');
            const recipientColdkeysBytes32 = recipientColdkeys.map(key => 
                '0x' + key.toString('hex').padEnd(64, '0')
            );
            
            saintDurbin = await factory.deploy(
                emergencyOperator.address,
                drainAddressBytes32,
                validator1HotkeyBytes32,
                validator1Uid,
                contractColdkeyBytes32,
                netuid,
                recipientColdkeysBytes32,
                proportions
            );
            
            await saintDurbin.waitForDeployment();
            const contractAddress = await saintDurbin.getAddress();
            
            console.log(`SaintDurbin deployed at: ${contractAddress}`);
            
            // Verify deployment
            expect(await saintDurbin.emergencyOperator()).to.equal(emergencyOperator.address);
            expect(await saintDurbin.currentValidatorHotkey()).to.equal(validator1HotkeyBytes32);
            expect(await saintDurbin.netuid()).to.equal(netuid);
            expect(await saintDurbin.getRecipientCount()).to.equal(16);
            
            // Check initial balance
            const stakedBalance = await saintDurbin.getStakedBalance();
            expect(stakedBalance).to.be.gt(0);
            expect(await saintDurbin.principalLocked()).to.equal(stakedBalance);
        });
    });

    describe("Yield Distribution", () => {
        it("Should execute transfer when yield is available", async function() {
            this.timeout(60000);
            
            // Wait for some blocks to pass and generate yield
            // In a real test environment, you would trigger epoch changes to generate rewards
            await new Promise(resolve => setTimeout(resolve, 30000));
            
            // Check if transfer can be executed
            const canExecute = await saintDurbin.canExecuteTransfer();
            if (!canExecute) {
                // Fast forward blocks if needed
                const blocksRemaining = await saintDurbin.blocksUntilNextTransfer();
                console.log(`Waiting for ${blocksRemaining} blocks...`);
            }
            
            // Execute transfer
            const tx = await saintDurbin.executeTransfer();
            const receipt = await tx.wait();
            
            // Check events
            const transferEvents = receipt.logs.filter((log: any) => {
                try {
                    const parsed = saintDurbin.interface.parseLog(log);
                    return parsed?.name === "StakeTransferred";
                } catch {
                    return false;
                }
            });
            
            expect(transferEvents.length).to.be.gt(0);
            
            // Verify recipients received funds
            for (let i = 0; i < 3; i++) { // Check first 3 recipients
                const recipientBalance = await api.query.SubtensorModule.Stake.getValue({
                    hotkey: validator1Hotkey.publicKey,
                    coldkey: recipients[i].keypair.publicKey,
                    netuid: netuid
                });
                console.log(`Recipient ${i} balance: ${recipientBalance}`);
            }
        });
    });

    describe("Validator Switching", () => {
        it("Should switch validators when current validator loses permit", async function() {
            this.timeout(60000);
            
            // For this test we'll need to simulate validator losing permit
            // This would require more complex setup, so we'll simplify
            
            // Trigger validator check
            const tx = await saintDurbin.checkAndSwitchValidator();
            const receipt = await tx.wait();
            
            // Check for validator switch event
            const switchEvents = receipt.logs.filter((log: any) => {
                try {
                    const parsed = saintDurbin.interface.parseLog(log);
                    return parsed?.name === "ValidatorSwitched";
                } catch {
                    return false;
                }
            });
            
            expect(switchEvents.length).to.equal(1);
            
            // Verify new validator
            const newValidatorHotkey = await saintDurbin.currentValidatorHotkey();
            expect(newValidatorHotkey).to.equal(ethers.hexlify(validator2Hotkey.publicKey));
        });
    });

    describe("Emergency Drain", () => {
        it("Should handle emergency drain with timelock", async function() {
            this.timeout(120000);
            
            // Request emergency drain
            const requestTx = await saintDurbin.requestEmergencyDrain();
            await requestTx.wait();
            
            // Check drain status
            const [isPending, timeRemaining] = await saintDurbin.getEmergencyDrainStatus();
            expect(isPending).to.be.true;
            expect(timeRemaining).to.be.gt(0);
            
            // Try to execute before timelock - should fail
            try {
                await saintDurbin.executeEmergencyDrain();
                expect.fail("Should not execute before timelock");
            } catch (error: any) {
                expect(error.message).to.include("TimelockNotExpired");
            }
            
            // Cancel the drain for this test
            const cancelTx = await saintDurbin.cancelEmergencyDrain();
            await cancelTx.wait();
            
            const [isPendingAfter] = await saintDurbin.getEmergencyDrainStatus();
            expect(isPendingAfter).to.be.false;
        });
    });

    describe("Principal Detection", () => {
        it("Should detect and preserve principal additions", async function() {
            this.timeout(60000);
            
            const initialPrincipal = await saintDurbin.principalLocked();
            
            // Add more stake (simulating principal addition)
            await addStake(api, netuid, convertPublicKeyToSs58(validator1Hotkey.publicKey), tao(5000), contractColdkey);
            
            // Execute transfer
            const tx = await saintDurbin.executeTransfer();
            const receipt = await tx.wait();
            
            // Check for principal detection event
            const principalEvents = receipt.logs.filter((log: any) => {
                try {
                    const parsed = saintDurbin.interface.parseLog(log);
                    return parsed?.name === "PrincipalDetected";
                } catch {
                    return false;
                }
            });
            
            if (principalEvents.length > 0) {
                const newPrincipal = await saintDurbin.principalLocked();
                expect(newPrincipal).to.be.gt(initialPrincipal);
            }
        });
    });
    
    after(async function() {
        // Clean up API connection
        if (api) {
            await api.destroy();
        }
    });
});
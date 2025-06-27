import { ethers } from "ethers";
import { TypedApi } from "polkadot-api";
import { devnet } from "@polkadot-api/descriptors";
import { convertPublicKeyToSs58 } from "../../../subtensor_chain/evm-tests/src/address-utils";
import { addStake, forceSetBalanceToSs58Address } from "../../../subtensor_chain/evm-tests/src/subtensor";
import { tao } from "../../../subtensor_chain/evm-tests/src/balance-math";
import { IMETAGRAPH_ADDRESS, IMetagraphABI } from "../../../subtensor_chain/evm-tests/src/contracts/metagraph";
import { ISTAKING_V2_ADDRESS, IStakingV2ABI } from "../../../subtensor_chain/evm-tests/src/contracts/staking";

export interface ValidatorInfo {
    hotkey: any;
    coldkey: any;
    uid?: number;
    stake?: bigint;
    isActive?: boolean;
    hasPermit?: boolean;
}

export interface RecipientInfo {
    keypair: any;
    proportion: number;
    expectedAmount?: bigint;
}

/**
 * Helper to wait for a specific number of blocks
 */
export async function waitForBlocks(provider: ethers.Provider, blocks: number): Promise<void> {
    const startBlock = await provider.getBlockNumber();
    const targetBlock = startBlock + blocks;
    
    while (await provider.getBlockNumber() < targetBlock) {
        await new Promise(resolve => setTimeout(resolve, 12000)); // ~12s per block
    }
}

/**
 * Helper to get validator information from metagraph
 */
export async function getValidatorInfo(
    metagraph: ethers.Contract,
    netuid: number,
    validator: ValidatorInfo
): Promise<ValidatorInfo> {
    const uid = await metagraph.getUid(netuid, validator.hotkey.publicKey);
    const isActive = await metagraph.getIsActive(netuid, uid);
    const hasPermit = await metagraph.getValidatorStatus(netuid, uid);
    const stake = await metagraph.getStake(netuid, uid);
    
    return {
        ...validator,
        uid: Number(uid),
        isActive,
        hasPermit,
        stake: BigInt(stake)
    };
}

/**
 * Helper to calculate expected yield distribution
 */
export function calculateExpectedDistributions(
    availableYield: bigint,
    recipients: RecipientInfo[]
): RecipientInfo[] {
    const BASIS_POINTS = 10000n;
    let remainingYield = availableYield;
    
    return recipients.map((recipient, index) => {
        let expectedAmount: bigint;
        
        if (index === recipients.length - 1) {
            // Last recipient gets remaining amount to avoid dust
            expectedAmount = remainingYield;
        } else {
            expectedAmount = (availableYield * BigInt(recipient.proportion)) / BASIS_POINTS;
            remainingYield -= expectedAmount;
        }
        
        return {
            ...recipient,
            expectedAmount
        };
    });
}

/**
 * Helper to simulate yield generation by adding rewards
 */
export async function simulateYieldGeneration(
    api: TypedApi<typeof devnet>,
    netuid: number,
    validatorHotkey: Uint8Array,
    contractColdkey: any,
    amount: bigint
): Promise<void> {
    // In a real environment, this would be done through epoch changes
    // For testing, we manually add stake to simulate yield
    await addStake(api, netuid, convertPublicKeyToSs58(validatorHotkey), amount, contractColdkey);
}

/**
 * Helper to verify recipient balances after distribution
 */
export async function verifyRecipientBalances(
    staking: ethers.Contract,
    validatorHotkey: Uint8Array,
    netuid: number,
    recipients: RecipientInfo[]
): Promise<{ recipient: RecipientInfo, actualBalance: bigint }[]> {
    const results = [];
    
    for (const recipient of recipients) {
        const actualBalance = await staking.getStake(
            validatorHotkey,
            recipient.keypair.publicKey,
            netuid
        );
        
        results.push({
            recipient,
            actualBalance: BigInt(actualBalance)
        });
    }
    
    return results;
}

/**
 * Helper to fast-forward time for testing timelocks
 */
export async function fastForwardTime(provider: ethers.JsonRpcProvider, seconds: number): Promise<void> {
    await provider.send("evm_increaseTime", [seconds]);
    await provider.send("evm_mine", []);
}

/**
 * Helper to get all validators with permits in a subnet
 */
export async function getActiveValidators(
    metagraph: ethers.Contract,
    netuid: number,
    maxUid: number
): Promise<ValidatorInfo[]> {
    const validators: ValidatorInfo[] = [];
    
    for (let uid = 0; uid < maxUid; uid++) {
        try {
            const hasPermit = await metagraph.getValidatorStatus(netuid, uid);
            const isActive = await metagraph.getIsActive(netuid, uid);
            
            if (hasPermit && isActive) {
                const hotkey = await metagraph.getHotkey(netuid, uid);
                const stake = await metagraph.getStake(netuid, uid);
                const dividend = await metagraph.getDividends(netuid, uid);
                
                validators.push({
                    hotkey: { publicKey: hotkey },
                    coldkey: null, // Not available from metagraph
                    uid,
                    stake: BigInt(stake),
                    isActive,
                    hasPermit
                });
            }
        } catch (error) {
            // UID doesn't exist, continue
        }
    }
    
    return validators;
}

/**
 * Helper to monitor contract events
 */
export async function monitorContractEvents(
    contract: ethers.Contract,
    eventName: string,
    blockRange: { from: number; to: number }
): Promise<any[]> {
    const filter = contract.filters[eventName]();
    const events = await contract.queryFilter(filter, blockRange.from, blockRange.to);
    
    return events.map(event => ({
        ...event,
        args: contract.interface.parseLog(event)?.args
    }));
}

/**
 * Helper to setup a complete test environment
 */
export async function setupTestEnvironment(
    api: TypedApi<typeof devnet>,
    provider: ethers.JsonRpcProvider,
    config: {
        numValidators: number;
        numRecipients: number;
        initialStake: bigint;
        fundAmount: bigint;
    }
): Promise<{
    validators: ValidatorInfo[];
    recipients: RecipientInfo[];
    netuid: number;
}> {
    const validators: ValidatorInfo[] = [];
    const recipients: RecipientInfo[] = [];
    
    // Create validators
    for (let i = 0; i < config.numValidators; i++) {
        const hotkey = getRandomSubstrateKeypair();
        const coldkey = getRandomSubstrateKeypair();
        
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(hotkey.publicKey), config.fundAmount);
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(coldkey.publicKey), config.fundAmount);
        
        validators.push({ hotkey, coldkey });
    }
    
    // Create recipients
    const proportionPerRecipient = Math.floor(10000 / config.numRecipients);
    for (let i = 0; i < config.numRecipients; i++) {
        const keypair = getRandomSubstrateKeypair();
        const proportion = i === config.numRecipients - 1 
            ? 10000 - (proportionPerRecipient * (config.numRecipients - 1))
            : proportionPerRecipient;
        
        await forceSetBalanceToSs58Address(api, convertPublicKeyToSs58(keypair.publicKey), tao(10));
        
        recipients.push({ keypair, proportion });
    }
    
    // Create subnet and register validators
    const netuid = await createAndSetupSubnet(api, validators[0].hotkey, validators[0].coldkey);
    
    for (const validator of validators) {
        await registerNeuron(api, netuid, validator.hotkey, validator.coldkey);
        await setValidatorPermit(api, netuid, validator.hotkey, true);
    }
    
    return { validators, recipients, netuid };
}

// Import missing functions
import { getRandomSubstrateKeypair } from "../../../subtensor_chain/evm-tests/src/substrate";
import { 
    addNewSubnetwork, 
    registerNeuron, 
    setValidatorPermit 
} from "../../../subtensor_chain/evm-tests/src/subtensor";

async function createAndSetupSubnet(
    api: TypedApi<typeof devnet>,
    hotkey: any,
    coldkey: any
): Promise<number> {
    await addNewSubnetwork(api, hotkey, coldkey);
    return (await api.query.SubtensorModule.TotalNetworks.getValue()) - 1;
}
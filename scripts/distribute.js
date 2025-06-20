// scripts/distribute.js
const { ethers } = require('ethers');

// Only load dotenv if not in test environment
if (process.env.NODE_ENV !== 'test') {
  require('dotenv').config();
}

const SAINTDURBIN_ABI = [
  "function canExecuteTransfer() external view returns (bool)",
  "function executeTransfer() external",
  "function getNextTransferAmount() external view returns (uint256)",
  "function blocksUntilNextTransfer() external view returns (uint256)",
  "function getAvailableRewards() external view returns (uint256)",
  "function currentValidatorHotkey() external view returns (bytes32)",
  "function currentValidatorUid() external view returns (uint16)",
  "function getCurrentValidatorInfo() external view returns (bytes32 hotkey, uint16 uid, bool isValid)",
  "function getStakedBalance() external view returns (uint256)",
  "function checkAndSwitchValidator() external",
  "event ValidatorSwitched(bytes32 indexed oldHotkey, bytes32 indexed newHotkey, uint16 newUid, string reason)"
];

// Configuration for monitoring
const CONFIG = {
  // Check validator status every N distributions
  checkInterval: parseInt(process.env.VALIDATOR_CHECK_INTERVAL || '10'),
  
  // Monitor for validator switches
  monitorValidatorSwitches: true
};

let distributionCount = 0;

/**
 * Get current distribution count
 * @returns {number} Current distribution count
 */
function getDistributionCount() {
  return distributionCount;
}

/**
 * Set distribution count (useful for testing)
 * @param {number} count - New distribution count
 */
function setDistributionCount(count) {
  distributionCount = count;
}

/**
 * Execute a distribution
 * @param {ethers.Contract} contract - The SaintDurbin contract instance
 * @param {ethers.providers.Provider} provider - The Ethereum provider
 * @param {Object} options - Options for distribution
 * @param {boolean} options.skipValidatorCheck - Skip validator status check
 * @returns {Object} Result object with success status and details
 */
async function executeDistribution(contract, provider, options = {}) {
  const result = {
    success: false,
    canExecute: false,
    blocksRemaining: null,
    transactionHash: null,
    amount: null,
    gasUsed: null,
    error: null,
    validatorSwitched: false
  };

  try {
    // Increment distribution counter
    distributionCount++;
    
    // Check validator status periodically
    if (!options.skipValidatorCheck && distributionCount % CONFIG.checkInterval === 0) {
      await checkValidatorStatus(contract, provider, options);
    }

    // Check if distribution can be executed
    result.canExecute = await contract.canExecuteTransfer();
    
    if (!result.canExecute) {
      result.blocksRemaining = await contract.blocksUntilNextTransfer();
      const message = `Distribution not ready. Blocks remaining: ${result.blocksRemaining}`;
      console.log(message);
      return result;
    }

    // Get distribution details
    const nextAmount = await contract.getNextTransferAmount();
    const availableRewards = await contract.getAvailableRewards();
    
    console.log('Next transfer amount:', ethers.formatUnits(nextAmount, 9), 'TAO');
    console.log('Available rewards:', ethers.formatUnits(availableRewards, 9), 'TAO');

    // Execute the transfer
    console.log('Executing transfer...');
    const tx = await contract.executeTransfer({
      gasLimit: 1000000 // Adjust based on testing
    });
    
    console.log('Transaction submitted:', tx.hash);
    const receipt = await tx.wait();
    
    if (receipt.status === 1) {
      result.success = true;
      result.transactionHash = tx.hash;
      result.amount = nextAmount.toString();
      result.gasUsed = receipt.gasUsed.toString();
      
      const message = `✅ Distribution successful!\nTx: ${tx.hash}\nAmount: ${ethers.formatUnits(nextAmount, 9)} TAO\nGas used: ${receipt.gasUsed.toString()}`;
      console.log(message);
      
      // Monitor for validator switches during distribution
      const switchEvents = await monitorValidatorSwitches(contract, receipt, options);
      result.validatorSwitched = switchEvents.length > 0;
    } else {
      throw new Error('Transaction failed');
    }

  } catch (error) {
    result.error = error.message;
    const message = `❌ Distribution failed!\nError: ${error.message}`;
    console.error(message);
  }

  return result;
}

/**
 * Initialize distribution components
 * @param {Object} config - Configuration object
 * @param {string} config.rpcUrl - RPC URL
 * @param {string} config.privateKey - Private key
 * @param {string} config.contractAddress - Contract address
 * @returns {Object} Object with provider, wallet, and contract
 */
function initializeDistribution(config) {
  const provider = new ethers.JsonRpcProvider(config.rpcUrl);
  const wallet = new ethers.Wallet(config.privateKey, provider);
  const contract = new ethers.Contract(config.contractAddress, SAINTDURBIN_ABI, wallet);
  
  return { provider, wallet, contract };
}

/**
 * Main function for CLI execution
 */
async function main() {
  console.log('SaintDurbin Distribution Script Started');
  console.log('Contract:', process.env.CONTRACT_ADDRESS);
  
  try {
    const { provider, wallet, contract } = initializeDistribution({
      rpcUrl: process.env.RPC_URL,
      privateKey: process.env.PRIVATE_KEY,
      contractAddress: process.env.CONTRACT_ADDRESS
    });
    
    console.log('Executor:', wallet.address);
    
    const result = await executeDistribution(contract, provider);
    
    if (!result.success && result.error) {
      process.exit(1);
    }
  } catch (error) {
    console.error('Failed to initialize distribution:', error.message);
    process.exit(1);
  }
}

/**
 * Check validator status
 * @param {ethers.Contract} contract - The SaintDurbin contract instance
 * @param {ethers.providers.Provider} provider - The Ethereum provider
 * @param {Object} options - Options
 * @returns {Object} Status object with validator information
 */
async function checkValidatorStatus(contract, provider, options = {}) {
  console.log('Checking validator status...');
  
  const status = {
    success: false,
    hotkey: null,
    uid: null,
    isValid: false,
    stakedBalance: null,
    validatorSwitched: false,
    switchTransactionHash: null,
    error: null
  };
  
  try {
    // Get current validator info
    const [hotkey, uid, isValid] = await contract.getCurrentValidatorInfo();
    status.hotkey = hotkey;
    status.uid = uid.toString();
    status.isValid = isValid;
    
    console.log('Current validator:');
    console.log('  Hotkey:', hotkey);
    console.log('  UID:', uid.toString());
    console.log('  Is valid:', isValid);
    
    if (!isValid) {
      const message = `⚠️ Current validator is no longer valid!\nThe contract will automatically switch to a new validator.\nHotkey: ${hotkey}\nUID: ${uid}`;
      console.warn(message);
      
      // Optionally trigger manual validator check
      console.log('Triggering validator check...');
      try {
        const tx = await contract.checkAndSwitchValidator({
          gasLimit: 500000
        });
        console.log('Validator check transaction:', tx.hash);
        status.switchTransactionHash = tx.hash;
        const receipt = await tx.wait();
        
        // Check for ValidatorSwitched event
        const switchEvent = receipt.logs.find(log => {
          try {
            const parsed = contract.interface.parseLog(log);
            return parsed && parsed.name === 'ValidatorSwitched';
          } catch {
            return false;
          }
        });
        
        if (switchEvent) {
          const parsed = contract.interface.parseLog(switchEvent);
          status.validatorSwitched = true;
          const message = `✅ Validator switched successfully!\nOld: ${parsed.args.oldHotkey}\nNew: ${parsed.args.newHotkey}\nNew UID: ${parsed.args.newUid}\nReason: ${parsed.args.reason}`;
          console.log(message);
        }
      } catch (error) {
        console.log('Validator check transaction failed or no switch needed:', error.message);
      }
    } else {
      console.log('Validator status check passed');
    }
    
    // Also check contract's staked balance
    const stakedBalance = await contract.getStakedBalance();
    status.stakedBalance = stakedBalance.toString();
    console.log('Contract staked balance:', ethers.formatUnits(stakedBalance, 9), 'TAO');
    
    status.success = true;
  } catch (error) {
    status.error = error.message;
    const message = `❌ Validator status check failed!\nError: ${error.message}`;
    console.error(message);
  }
  
  return status;
}

/**
 * Monitor for validator switch events
 * @param {ethers.Contract} contract - The SaintDurbin contract instance
 * @param {Object} receipt - Transaction receipt
 * @param {Object} options - Options
 * @returns {Array} Array of switch events
 */
async function monitorValidatorSwitches(contract, receipt, options = {}) {
  const switchEvents = [];
  
  if (!CONFIG.monitorValidatorSwitches) return switchEvents;
  
  try {
    // Check for ValidatorSwitched events in the transaction receipt
    const events = receipt.logs.filter(log => {
      try {
        const parsed = contract.interface.parseLog(log);
        return parsed && parsed.name === 'ValidatorSwitched';
      } catch {
        return false;
      }
    });
    
    for (const event of events) {
      const parsed = contract.interface.parseLog(event);
      const eventData = {
        oldHotkey: parsed.args.oldHotkey,
        newHotkey: parsed.args.newHotkey,
        newUid: parsed.args.newUid.toString(),
        reason: parsed.args.reason
      };
      switchEvents.push(eventData);
      
      const message = `🔄 Validator switched during distribution!\nOld: ${eventData.oldHotkey}\nNew: ${eventData.newHotkey}\nNew UID: ${eventData.newUid}\nReason: ${eventData.reason}`;
      console.log(message);
    }
  } catch (error) {
    console.error('Error monitoring validator switches:', error.message);
  }
  
  return switchEvents;
}

// Export functions for testing
module.exports = {
  SAINTDURBIN_ABI,
  CONFIG,
  initializeDistribution,
  executeDistribution,
  checkValidatorStatus,
  monitorValidatorSwitches,
  getDistributionCount,
  setDistributionCount,
  main
};

// Run main function if this file is executed directly
if (require.main === module) {
  main().catch((error) => {
    console.error('Unhandled error:', error);
    process.exit(1);
  });
}
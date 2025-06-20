// scripts/check-validator.js
const { ethers } = require('ethers');
require('dotenv').config();

const SAINTDURBIN_ABI = [
  "function currentValidatorHotkey() external view returns (bytes32)",
  "function currentValidatorUid() external view returns (uint16)",
  "function getCurrentValidatorInfo() external view returns (bytes32 hotkey, uint16 uid, bool isValid)",
  "function getStakedBalance() external view returns (uint256)",
  "function checkAndSwitchValidator() external"
];

/**
 * Get validator information from the contract
 * @param {ethers.Contract} contract - The contract instance
 * @returns {Promise<Object>} Validator info including hotkey, uid, isValid, and stakedBalance
 */
async function getValidatorInfo(contract) {
  const [hotkey, uid, isValid] = await contract.getCurrentValidatorInfo();
  const stakedBalance = await contract.getStakedBalance();
  
  return {
    hotkey: hotkey.toString(),
    uid: uid.toString(),
    isValid,
    stakedBalance: stakedBalance.toString(),
    stakedBalanceFormatted: ethers.formatUnits(stakedBalance, 9)
  };
}

/**
 * Switch to a new validator
 * @param {ethers.Contract} contract - The contract instance
 * @param {Object} options - Options for the switch
 * @param {boolean} options.skipTransaction - If true, don't actually send the transaction
 * @param {number} options.gasLimit - Gas limit for the transaction
 * @returns {Promise<Object>} Result of the switch operation
 */
async function switchValidator(contract, options = {}) {
  const { skipTransaction = false, gasLimit = 500000 } = options;
  
  if (skipTransaction) {
    return {
      success: true,
      skipped: true,
      message: 'Transaction skipped (test mode)'
    };
  }
  
  const tx = await contract.checkAndSwitchValidator({ gasLimit });
  const receipt = await tx.wait();
  
  if (receipt.status !== 1) {
    return {
      success: false,
      transactionHash: tx.hash,
      message: 'Transaction failed'
    };
  }
  
  // Get new validator info after switch
  const newValidatorInfo = await getValidatorInfo(contract);
  
  return {
    success: true,
    transactionHash: tx.hash,
    previousValidator: null, // Will be set by calling function
    newValidator: newValidatorInfo,
    message: 'Validator switched successfully'
  };
}

/**
 * Check validator status and optionally switch if invalid
 * @param {Object} options - Configuration options
 * @param {string} options.rpcUrl - RPC URL for the provider
 * @param {string} options.privateKey - Private key for the wallet
 * @param {string} options.contractAddress - Contract address
 * @param {boolean} options.shouldSwitch - Whether to switch if validator is invalid
 * @param {boolean} options.skipTransaction - Skip actual transaction (for testing)
 * @param {boolean} options.silent - Suppress console output
 * @returns {Promise<Object>} Structured result data
 */
async function checkValidator(options = {}) {
  const {
    rpcUrl = process.env.RPC_URL,
    privateKey = process.env.PRIVATE_KEY,
    contractAddress = process.env.CONTRACT_ADDRESS,
    shouldSwitch = false,
    skipTransaction = false,
    silent = false
  } = options;
  
  const log = silent ? () => {} : console.log;
  const error = silent ? () => {} : console.error;
  
  try {
    // Initialize provider, wallet, and contract
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey, provider);
    const contract = new ethers.Contract(contractAddress, SAINTDURBIN_ABI, wallet);
    
    // Get current validator info
    const validatorInfo = await getValidatorInfo(contract);
    
    log('SaintDurbin Validator Check');
    log('Contract:', contractAddress);
    log('');
    log('Current Validator Status:');
    log('  Hotkey:', validatorInfo.hotkey);
    log('  UID:', validatorInfo.uid);
    log('  Is Valid:', validatorInfo.isValid ? '✅ Yes' : '❌ No');
    log('');
    log('Contract Staked Balance:', validatorInfo.stakedBalanceFormatted, 'TAO');
    log('');
    
    const result = {
      success: true,
      contractAddress,
      currentValidator: validatorInfo,
      switchPerformed: false,
      switchResult: null
    };
    
    if (!validatorInfo.isValid) {
      log('⚠️  WARNING: Current validator is no longer valid!');
      log('The contract will automatically switch validators during the next distribution.');
      
      if (shouldSwitch) {
        log('');
        log('Triggering manual validator switch...');
        
        const switchResult = await switchValidator(contract, { skipTransaction });
        result.switchPerformed = true;
        result.switchResult = switchResult;
        
        if (switchResult.success) {
          if (switchResult.skipped) {
            log('✅ Switch skipped (test mode)');
          } else {
            log('Transaction submitted:', switchResult.transactionHash);
            log('✅ Transaction successful!');
            
            if (switchResult.newValidator) {
              log('');
              log('New Validator:');
              log('  Hotkey:', switchResult.newValidator.hotkey);
              log('  UID:', switchResult.newValidator.uid);
              log('  Is Valid:', switchResult.newValidator.isValid ? '✅ Yes' : '❌ No');
            }
          }
        } else {
          log('❌ Transaction failed!');
        }
      } else {
        log('');
        log('To manually trigger a validator switch, run:');
        log('  npm run check-validator -- --switch');
      }
    } else {
      log('✅ Validator is healthy and active');
    }
    
    return result;
    
  } catch (err) {
    error('❌ Error checking validator:', err.message);
    return {
      success: false,
      error: err.message,
      errorDetails: err
    };
  }
}

/**
 * CLI entry point
 */
async function main() {
  const shouldSwitch = process.argv.includes('--switch');
  
  const result = await checkValidator({
    shouldSwitch,
    silent: false
  });
  
  if (!result.success) {
    process.exit(1);
  }
}

// Export functions for testing
module.exports = {
  getValidatorInfo,
  switchValidator,
  checkValidator,
  SAINTDURBIN_ABI
};

// Run main function if this is the entry point
if (require.main === module) {
  main().catch((error) => {
    console.error('Unhandled error:', error);
    process.exit(1);
  });
}
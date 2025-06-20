// scripts/distribute.js
const { ethers } = require('ethers');
const axios = require('axios');
require('dotenv').config();

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

// No longer needed - contract handles validator switching automatically
// const ISTAKING_ABI = [
//   "function getTotalStake(bytes32 hotkey, uint16 netuid) external view returns (uint256)"
// ];

// Configuration for monitoring
const CONFIG = {
  // Check validator status every N distributions
  checkInterval: parseInt(process.env.VALIDATOR_CHECK_INTERVAL || '10'),
  
  // Monitor for validator switches
  monitorValidatorSwitches: true
};

let distributionCount = 0;

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
  const contract = new ethers.Contract(process.env.CONTRACT_ADDRESS, SAINTDURBIN_ABI, wallet);
  // Staking contract no longer needed - contract handles validator switching

  console.log('SaintDurbin Distribution Script Started');
  console.log('Contract:', process.env.CONTRACT_ADDRESS);
  console.log('Executor:', wallet.address);

  try {
    // Increment distribution counter
    distributionCount++;
    
    // Check validator status periodically
    if (distributionCount % CONFIG.checkInterval === 0) {
      await checkValidatorStatus(contract, provider);
    }

    // Check if distribution can be executed
    const canExecute = await contract.canExecuteTransfer();
    
    if (!canExecute) {
      const blocksRemaining = await contract.blocksUntilNextTransfer();
      const message = `Distribution not ready. Blocks remaining: ${blocksRemaining}`;
      console.log(message);
      await sendSlackNotification(message, 'warning');
      return;
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
      const message = `✅ Distribution successful!\nTx: ${tx.hash}\nAmount: ${ethers.formatUnits(nextAmount, 9)} TAO\nGas used: ${receipt.gasUsed.toString()}`;
      console.log(message);
      await sendSlackNotification(message, 'success');
      
      // Monitor for validator switches during distribution
      await monitorValidatorSwitches(contract, receipt);
    } else {
      throw new Error('Transaction failed');
    }

  } catch (error) {
    const message = `❌ Distribution failed!\nError: ${error.message}`;
    console.error(message);
    await sendSlackNotification(message, 'error');
    process.exit(1);
  }
}

async function checkValidatorStatus(contract, provider) {
  console.log('Checking validator status...');
  
  try {
    // Get current validator info
    const [hotkey, uid, isValid] = await contract.getCurrentValidatorInfo();
    console.log('Current validator:');
    console.log('  Hotkey:', hotkey);
    console.log('  UID:', uid.toString());
    console.log('  Is valid:', isValid);
    
    if (!isValid) {
      const message = `⚠️ Current validator is no longer valid!\nThe contract will automatically switch to a new validator.\nHotkey: ${hotkey}\nUID: ${uid}`;
      console.warn(message);
      await sendSlackNotification(message, 'warning');
      
      // Optionally trigger manual validator check
      console.log('Triggering validator check...');
      try {
        const tx = await contract.checkAndSwitchValidator({
          gasLimit: 500000
        });
        console.log('Validator check transaction:', tx.hash);
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
          const message = `✅ Validator switched successfully!\nOld: ${parsed.args.oldHotkey}\nNew: ${parsed.args.newHotkey}\nNew UID: ${parsed.args.newUid}\nReason: ${parsed.args.reason}`;
          console.log(message);
          await sendSlackNotification(message, 'success');
        }
      } catch (error) {
        console.log('Validator check transaction failed or no switch needed:', error.message);
      }
    } else {
      console.log('Validator status check passed');
    }
    
    // Also check contract's staked balance
    const stakedBalance = await contract.getStakedBalance();
    console.log('Contract staked balance:', ethers.formatUnits(stakedBalance, 9), 'TAO');
    
  } catch (error) {
    const message = `❌ Validator status check failed!\nError: ${error.message}`;
    console.error(message);
    await sendSlackNotification(message, 'error');
  }
}

// Monitor for validator switch events
async function monitorValidatorSwitches(contract, receipt) {
  if (!CONFIG.monitorValidatorSwitches) return;
  
  try {
    // Check for ValidatorSwitched events in the transaction receipt
    const switchEvents = receipt.logs.filter(log => {
      try {
        const parsed = contract.interface.parseLog(log);
        return parsed && parsed.name === 'ValidatorSwitched';
      } catch {
        return false;
      }
    });
    
    for (const event of switchEvents) {
      const parsed = contract.interface.parseLog(event);
      const message = `🔄 Validator switched during distribution!\nOld: ${parsed.args.oldHotkey}\nNew: ${parsed.args.newHotkey}\nNew UID: ${parsed.args.newUid}\nReason: ${parsed.args.reason}`;
      console.log(message);
      await sendSlackNotification(message, 'info');
    }
  } catch (error) {
    console.error('Error monitoring validator switches:', error.message);
  }
}

async function sendSlackNotification(message, type = 'info') {
  if (!process.env.SLACK_WEBHOOK) {
    console.log('Slack webhook not configured');
    return;
  }

  const color = type === 'success' ? 'good' : 
                type === 'error' ? 'danger' : 
                type === 'critical' ? '#ff0000' :
                'warning';
  
  try {
    await axios.post(process.env.SLACK_WEBHOOK, {
      attachments: [{
        color: color,
        title: 'SaintDurbin Distribution Update',
        text: message,
        footer: 'SaintDurbin Cron Job',
        ts: Math.floor(Date.now() / 1000)
      }]
    });
  } catch (error) {
    console.error('Failed to send Slack notification:', error.message);
  }
}

main().catch((error) => {
  console.error('Unhandled error:', error);
  process.exit(1);
});
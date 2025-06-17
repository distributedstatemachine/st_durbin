// scripts/distribute.js
const { ethers } = require('ethers');
const axios = require('axios');
require('dotenv').config();

const SAINTDURBIN_ABI = [
  "function canExecuteTransfer() external view returns (bool)",
  "function executeTransfer() external",
  "function getNextTransferAmount() external view returns (uint256)",
  "function blocksUntilNextTransfer() external view returns (uint256)",
  "function getAvailableRewards() external view returns (uint256)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
  const contract = new ethers.Contract(process.env.CONTRACT_ADDRESS, SAINTDURBIN_ABI, wallet);

  console.log('SaintDurbin Distribution Script Started');
  console.log('Contract:', process.env.CONTRACT_ADDRESS);
  console.log('Executor:', wallet.address);

  try {
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

async function sendSlackNotification(message, type = 'info') {
  if (!process.env.SLACK_WEBHOOK) {
    console.log('Slack webhook not configured');
    return;
  }

  const color = type === 'success' ? 'good' : type === 'error' ? 'danger' : 'warning';
  
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
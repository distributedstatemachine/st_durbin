// scripts/check-validator.js
const { ethers } = require('ethers');
const axios = require('axios');
require('dotenv').config();

const SAINTDURBIN_ABI = [
  "function currentValidatorHotkey() external view returns (bytes32)",
  "function currentValidatorUid() external view returns (uint16)",
  "function getCurrentValidatorInfo() external view returns (bytes32 hotkey, uint16 uid, bool isValid)",
  "function getStakedBalance() external view returns (uint256)",
  "function checkAndSwitchValidator() external"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
  const contract = new ethers.Contract(process.env.CONTRACT_ADDRESS, SAINTDURBIN_ABI, wallet);

  console.log('SaintDurbin Validator Check');
  console.log('Contract:', process.env.CONTRACT_ADDRESS);
  console.log('');

  try {
    // Get current validator info
    const [hotkey, uid, isValid] = await contract.getCurrentValidatorInfo();
    
    console.log('Current Validator Status:');
    console.log('  Hotkey:', hotkey);
    console.log('  UID:', uid.toString());
    console.log('  Is Valid:', isValid ? '✅ Yes' : '❌ No');
    console.log('');
    
    // Get staked balance
    const stakedBalance = await contract.getStakedBalance();
    console.log('Contract Staked Balance:', ethers.formatUnits(stakedBalance, 9), 'TAO');
    console.log('');
    
    if (!isValid) {
      console.log('⚠️  WARNING: Current validator is no longer valid!');
      console.log('The contract will automatically switch validators during the next distribution.');
      
      // Ask if user wants to trigger manual switch
      if (process.argv.includes('--switch')) {
        console.log('');
        console.log('Triggering manual validator switch...');
        
        const tx = await contract.checkAndSwitchValidator({
          gasLimit: 500000
        });
        
        console.log('Transaction submitted:', tx.hash);
        const receipt = await tx.wait();
        
        if (receipt.status === 1) {
          console.log('✅ Transaction successful!');
          
          // Get new validator info
          const [newHotkey, newUid, newIsValid] = await contract.getCurrentValidatorInfo();
          console.log('');
          console.log('New Validator:');
          console.log('  Hotkey:', newHotkey);
          console.log('  UID:', newUid.toString());
          console.log('  Is Valid:', newIsValid ? '✅ Yes' : '❌ No');
        } else {
          console.log('❌ Transaction failed!');
        }
      } else {
        console.log('');
        console.log('To manually trigger a validator switch, run:');
        console.log('  npm run check-validator -- --switch');
      }
    } else {
      console.log('✅ Validator is healthy and active');
    }
    
  } catch (error) {
    console.error('❌ Error checking validator:', error.message);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error('Unhandled error:', error);
  process.exit(1);
});
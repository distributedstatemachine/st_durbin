// test/distribute.integration.example.js
// Example of how to use the refactored distribute module for integration testing

const {
  initializeDistribution,
  executeDistribution,
  checkValidatorStatus,
  setDistributionCount,
  CONFIG
} = require('../scripts/distribute');

// Example integration test setup
async function runIntegrationTest() {
  // Configure test environment
  process.env.NODE_ENV = 'test';
  process.env.RPC_URL = 'http://localhost:8545'; // Use local test network
  process.env.PRIVATE_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'; // Test private key
  process.env.CONTRACT_ADDRESS = '0x5FbDB2315678afecb367f032d93F642f64180aa3'; // Test contract address

  try {
    // Initialize components
    const { provider, wallet, contract } = initializeDistribution({
      rpcUrl: process.env.RPC_URL,
      privateKey: process.env.PRIVATE_KEY,
      contractAddress: process.env.CONTRACT_ADDRESS
    });

    console.log('Test wallet address:', wallet.address);

    // Test 1: Check validator status
    console.log('\n--- Testing Validator Status Check ---');
    const validatorStatus = await checkValidatorStatus(contract, provider, {
      skipSlackNotifications: true
    });
    console.log('Validator status:', validatorStatus);

    // Test 2: Execute distribution (dry run)
    console.log('\n--- Testing Distribution Execution ---');
    const distributionResult = await executeDistribution(contract, provider, {
      skipSlackNotifications: true
    });
    console.log('Distribution result:', distributionResult);

    // Test 3: Test validator check interval
    console.log('\n--- Testing Validator Check Interval ---');
    // Set distribution count to trigger validator check
    setDistributionCount(CONFIG.checkInterval - 1);
    
    const resultWithValidatorCheck = await executeDistribution(contract, provider, {
      skipSlackNotifications: true
    });
    console.log('Distribution with validator check:', resultWithValidatorCheck);

    // Test 4: Test with custom options
    console.log('\n--- Testing with Custom Options ---');
    const customResult = await executeDistribution(contract, provider, {
      skipValidatorCheck: true,
      skipSlackNotifications: true
    });
    console.log('Custom options result:', customResult);

  } catch (error) {
    console.error('Integration test failed:', error);
  }
}

// Mock contract for unit testing without actual blockchain
function createMockContract() {
  const { ethers } = require('ethers');
  
  return {
    canExecuteTransfer: async () => true,
    blocksUntilNextTransfer: async () => 0,
    getNextTransferAmount: async () => ethers.parseUnits('10', 9),
    getAvailableRewards: async () => ethers.parseUnits('100', 9),
    executeTransfer: async () => ({
      hash: '0xmocktxhash',
      wait: async () => ({
        status: 1,
        gasUsed: BigInt(50000),
        logs: []
      })
    }),
    getCurrentValidatorInfo: async () => [
      '0x1234567890123456789012345678901234567890123456789012345678901234',
      42,
      true
    ],
    getStakedBalance: async () => ethers.parseUnits('1000', 9),
    checkAndSwitchValidator: async () => ({
      hash: '0xmockswitchtx',
      wait: async () => ({ logs: [] })
    }),
    interface: {
      parseLog: () => null
    }
  };
}

// Example of testing with a mock contract
async function runMockTest() {
  console.log('\n=== Running Mock Contract Test ===');
  
  const mockContract = createMockContract();
  const mockProvider = {};
  
  const result = await executeDistribution(mockContract, mockProvider, {
    skipSlackNotifications: true
  });
  
  console.log('Mock test result:', result);
}

// Run tests if executed directly
if (require.main === module) {
  console.log('Running integration test examples...');
  runMockTest().then(() => {
    console.log('\nFor real integration tests, ensure you have a local blockchain running.');
    console.log('You can use Hardhat or Ganache for this purpose.');
  });
}
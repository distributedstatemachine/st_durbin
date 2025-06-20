const { expect } = require('chai');
const sinon = require('sinon');
const { ethers } = require('ethers');
const {
  initializeDistribution,
  executeDistribution,
  checkValidatorStatus,
  monitorValidatorSwitches,
  getDistributionCount,
  setDistributionCount
} = require('../distribute');

describe('SaintDurbin Distribution Integration Tests', function() {
  this.timeout(30000); // 30 second timeout for integration tests
  
  let provider;
  let signer;
  let saintDurbinContract;
  let sandbox;
  
  // Test configuration
  const TEST_CONFIG = {
    contractAddress: process.env.SAINT_DURBIN_ADDRESS || '0x0000000000000000000000000000000000000000',
    rpcUrl: process.env.RPC_URL || 'http://127.0.0.1:9944',
    privateKey: process.env.PRIVATE_KEY || '0x5fb92d6e98884f76de468fa3f6278f8807c48bebc13595d45af5bdc4da702133'
  };
  
  beforeEach(async function() {
    sandbox = sinon.createSandbox();
    
    // Initialize provider and signer
    provider = new ethers.JsonRpcProvider(TEST_CONFIG.rpcUrl);
    signer = new ethers.Wallet(TEST_CONFIG.privateKey, provider);
    
    // Initialize the distribution module
    const { contract } = await initializeDistribution({
      contractAddress: TEST_CONFIG.contractAddress,
      rpcUrl: TEST_CONFIG.rpcUrl,
      privateKey: TEST_CONFIG.privateKey
    });
    
    saintDurbinContract = contract;
    
    // Reset distribution count
    setDistributionCount(0);
  });
  
  afterEach(function() {
    sandbox.restore();
  });
  
  describe('Distribution Execution', function() {
    it('should successfully execute distribution when conditions are met', async function() {
      // Mock contract methods
      sandbox.stub(saintDurbinContract, 'canExecuteTransfer').resolves(true);
      sandbox.stub(saintDurbinContract, 'getNextTransferAmount').resolves(ethers.parseEther('100'));
      sandbox.stub(saintDurbinContract, 'executeTransfer').resolves({
        wait: async () => ({
          hash: '0x123...',
          blockNumber: 12345,
          events: []
        })
      });
      
      const result = await executeDistribution({
        provider,
        signer,
        contract: saintDurbinContract,
        skipValidatorCheck: true
      });
      
      expect(result.success).to.be.true;
      expect(result.txHash).to.equal('0x123...');
      expect(result.amount).to.equal('100.0');
      expect(getDistributionCount()).to.equal(1);
    });
    
    it('should handle distribution when not enough time has passed', async function() {
      sandbox.stub(saintDurbinContract, 'canExecuteTransfer').resolves(false);
      sandbox.stub(saintDurbinContract, 'blocksUntilNextTransfer').resolves(3600n);
      
      const result = await executeDistribution({
        provider,
        signer,
        contract: saintDurbinContract,
        skipValidatorCheck: true
      });
      
      expect(result.success).to.be.false;
      expect(result.error).to.include('Cannot execute transfer yet');
      expect(result.error).to.include('3600 blocks');
    });
    
    it('should handle transaction failures gracefully', async function() {
      sandbox.stub(saintDurbinContract, 'canExecuteTransfer').resolves(true);
      sandbox.stub(saintDurbinContract, 'getNextTransferAmount').resolves(ethers.parseEther('100'));
      sandbox.stub(saintDurbinContract, 'executeTransfer').rejects(new Error('Transaction failed'));
      
      const result = await executeDistribution({
        provider,
        signer,
        contract: saintDurbinContract,
        skipValidatorCheck: true
      });
      
      expect(result.success).to.be.false;
      expect(result.error).to.include('Transaction failed');
    });
  });
  
  describe('Validator Status Checking', function() {
    it('should correctly identify valid validator', async function() {
      sandbox.stub(saintDurbinContract, 'getCurrentValidatorInfo').resolves({
        hotkey: '0x1234567890123456789012345678901234567890123456789012345678901234',
        uid: 42,
        isValid: true
      });
      
      const result = await checkValidatorStatus({ contract: saintDurbinContract });
      
      expect(result.isValid).to.be.true;
      expect(result.uid).to.equal(42);
      expect(result.hotkey).to.match(/^0x[a-f0-9]{64}$/);
    });
    
    it('should correctly identify invalid validator', async function() {
      sandbox.stub(saintDurbinContract, 'getCurrentValidatorInfo').resolves({
        hotkey: '0x1234567890123456789012345678901234567890123456789012345678901234',
        uid: 42,
        isValid: false
      });
      
      const result = await checkValidatorStatus({ contract: saintDurbinContract });
      
      expect(result.isValid).to.be.false;
      expect(result.invalidReason).to.equal('Validator is not active on the metagraph');
    });
    
    it('should handle validator check errors', async function() {
      sandbox.stub(saintDurbinContract, 'getCurrentValidatorInfo').rejects(new Error('RPC error'));
      
      const result = await checkValidatorStatus({ contract: saintDurbinContract });
      
      expect(result.error).to.equal('Failed to check validator status');
    });
  });
  
  describe('Validator Switch Monitoring', function() {
    it('should detect validator switch events', async function() {
      const fromBlock = 1000;
      const toBlock = 2000;
      
      // Mock provider to return current block
      sandbox.stub(provider, 'getBlockNumber').resolves(toBlock);
      
      // Create mock filter and events
      const mockFilter = {};
      const mockEvents = [
        {
          blockNumber: 1500,
          args: {
            oldValidator: '0x0000000000000000000000000000000000000000000000000000000000000001',
            newValidator: '0x0000000000000000000000000000000000000000000000000000000000000002',
            oldUid: 1,
            newUid: 2,
            reason: 'Validator lost permit'
          },
          getBlock: async () => ({ timestamp: 1234567890 })
        }
      ];
      
      sandbox.stub(saintDurbinContract, 'filters').value({
        ValidatorSwitched: () => mockFilter
      });
      sandbox.stub(saintDurbinContract, 'queryFilter').resolves(mockEvents);
      
      const events = await monitorValidatorSwitches({
        contract: saintDurbinContract,
        provider,
        fromBlock
      });
      
      expect(events).to.have.lengthOf(1);
      expect(events[0].oldUid).to.equal(1);
      expect(events[0].newUid).to.equal(2);
      expect(events[0].reason).to.equal('Validator lost permit');
      expect(events[0].timestamp).to.be.a('number');
    });
    
    it('should handle no validator switch events', async function() {
      sandbox.stub(provider, 'getBlockNumber').resolves(2000);
      sandbox.stub(saintDurbinContract, 'filters').value({
        ValidatorSwitched: () => ({})
      });
      sandbox.stub(saintDurbinContract, 'queryFilter').resolves([]);
      
      const events = await monitorValidatorSwitches({
        contract: saintDurbinContract,
        provider,
        fromBlock: 1000
      });
      
      expect(events).to.have.lengthOf(0);
    });
  });
  
  describe('End-to-End Distribution Flow', function() {
    it('should complete full distribution cycle with validator check', async function() {
      // This test simulates a complete distribution cycle
      // In a real integration test, this would interact with the actual local chain
      
      // Mock successful validator status
      sandbox.stub(saintDurbinContract, 'getCurrentValidatorInfo').resolves({
        hotkey: '0x1234567890123456789012345678901234567890123456789012345678901234',
        uid: 42,
        isValid: true
      });
      
      // Mock successful distribution conditions
      sandbox.stub(saintDurbinContract, 'canExecuteTransfer').resolves(true);
      sandbox.stub(saintDurbinContract, 'getNextTransferAmount').resolves(ethers.parseEther('100'));
      sandbox.stub(saintDurbinContract, 'executeTransfer').resolves({
        wait: async () => ({
          hash: '0xabc123...',
          blockNumber: 12345,
          events: [
            {
              event: 'StakeTransferred',
              args: {
                amount: ethers.parseEther('100')
              }
            }
          ]
        })
      });
      
      // Mock no validator switches
      sandbox.stub(provider, 'getBlockNumber').resolves(12345);
      sandbox.stub(saintDurbinContract, 'filters').value({
        ValidatorSwitched: () => ({})
      });
      sandbox.stub(saintDurbinContract, 'queryFilter').resolves([]);
      
      // Execute distribution with all checks enabled
      const result = await executeDistribution({
        provider,
        signer,
        contract: saintDurbinContract,
        skipValidatorCheck: false
      });
      
      expect(result.success).to.be.true;
      expect(result.txHash).to.equal('0xabc123...');
      expect(result.amount).to.equal('100.0');
      expect(result.validatorStatus).to.deep.include({
        isValid: true,
        uid: 42
      });
    });
  });
  
  describe('Contract State Queries', function() {
    it('should query contract state correctly', async function() {
      // Mock various view functions
      sandbox.stub(saintDurbinContract, 'principalLocked').resolves(ethers.parseEther('10000'));
      sandbox.stub(saintDurbinContract, 'lastTransferBlock').resolves(1000n);
      sandbox.stub(saintDurbinContract, 'getStakedBalance').resolves(ethers.parseEther('11000'));
      sandbox.stub(saintDurbinContract, 'getAvailableRewards').resolves(ethers.parseEther('1000'));
      
      const principal = await saintDurbinContract.principalLocked();
      const lastBlock = await saintDurbinContract.lastTransferBlock();
      const balance = await saintDurbinContract.getStakedBalance();
      const rewards = await saintDurbinContract.getAvailableRewards();
      
      expect(ethers.formatEther(principal)).to.equal('10000.0');
      expect(lastBlock.toString()).to.equal('1000');
      expect(ethers.formatEther(balance)).to.equal('11000.0');
      expect(ethers.formatEther(rewards)).to.equal('1000.0');
    });
  });
});
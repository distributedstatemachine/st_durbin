const { expect } = require('chai');
const sinon = require('sinon');
const { ethers } = require('ethers');
const {
  getValidatorInfo,
  switchValidator,
  checkValidator
} = require('../check-validator');

describe('SaintDurbin Validator Check Integration Tests', function() {
  this.timeout(30000); // 30 second timeout for integration tests
  
  let sandbox;
  let mockContract;
  let mockProvider;
  let mockSigner;
  
  // Test configuration
  const TEST_CONFIG = {
    contractAddress: '0x1234567890123456789012345678901234567890',
    rpcUrl: 'http://127.0.0.1:9944',
    privateKey: '0x5fb92d6e98884f76de468fa3f6278f8807c48bebc13595d45af5bdc4da702133'
  };
  
  beforeEach(function() {
    sandbox = sinon.createSandbox();
    
    // Create mock contract
    mockContract = {
      getCurrentValidatorInfo: sandbox.stub(),
      getStakedBalance: sandbox.stub(),
      checkAndSwitchValidator: sandbox.stub(),
      filters: {
        ValidatorSwitched: sandbox.stub().returns({})
      },
      queryFilter: sandbox.stub()
    };
    
    // Create mock provider and signer
    mockProvider = {
      getBlockNumber: sandbox.stub()
    };
    mockSigner = {};
  });
  
  afterEach(function() {
    sandbox.restore();
  });
  
  describe('getValidatorInfo', function() {
    it('should return valid validator information', async function() {
      const mockValidatorInfo = {
        hotkey: '0x1234567890123456789012345678901234567890123456789012345678901234',
        uid: 42n,
        isValid: true
      };
      
      mockContract.getCurrentValidatorInfo.resolves(mockValidatorInfo);
      mockContract.getStakedBalance.resolves(ethers.parseEther('10000'));
      
      const result = await getValidatorInfo(mockContract);
      
      expect(result).to.deep.equal({
        hotkey: '0x1234567890123456789012345678901234567890123456789012345678901234',
        uid: '42',
        isValid: true,
        stakedBalance: '10000000000000000000000',
        stakedBalanceFormatted: '10000.0'
      });
    });
    
    it('should handle invalid validator', async function() {
      const mockValidatorInfo = {
        hotkey: '0x0000000000000000000000000000000000000000000000000000000000000000',
        uid: 0n,
        isValid: false
      };
      
      mockContract.getCurrentValidatorInfo.resolves(mockValidatorInfo);
      mockContract.getStakedBalance.resolves(ethers.parseEther('5000'));
      
      const result = await getValidatorInfo(mockContract);
      
      expect(result).to.deep.equal({
        hotkey: '0x0000000000000000000000000000000000000000000000000000000000000000',
        uid: '0',
        isValid: false,
        stakedBalance: '5000000000000000000000',
        stakedBalanceFormatted: '5000.0'
      });
    });
    
    it('should handle errors gracefully', async function() {
      mockContract.getCurrentValidatorInfo.rejects(new Error('RPC error'));
      
      try {
        await getValidatorInfo(mockContract);
        expect.fail('Should have thrown error');
      } catch (error) {
        expect(error.message).to.equal('RPC error');
      }
    });
  });
  
  describe('switchValidator', function() {
    it('should successfully switch validator', async function() {
      const mockTx = {
        wait: sandbox.stub().resolves({
          hash: '0xabc123...',
          blockNumber: 12345
        })
      };
      
      mockContract.checkAndSwitchValidator.resolves(mockTx);
      mockContract.queryFilter.resolves([
        {
          args: {
            oldValidator: '0x0000000000000000000000000000000000000000000000000000000000000001',
            newValidator: '0x0000000000000000000000000000000000000000000000000000000000000002',
            oldUid: 1n,
            newUid: 2n,
            reason: 'Validator became inactive'
          }
        }
      ]);
      mockContract.getCurrentValidatorInfo.resolves({
        hotkey: '0x0000000000000000000000000000000000000000000000000000000000000002',
        uid: 2n,
        isValid: true
      });
      mockContract.getStakedBalance.resolves(ethers.parseEther('10000'));
      
      const result = await switchValidator(mockContract, { silent: true });
      
      expect(result.success).to.be.true;
      expect(result.transactionHash).to.equal('0xabc123...');
      expect(result.message).to.include('switched from UID 1 to UID 2');
      expect(result.newValidator).to.deep.include({
        uid: '2',
        isValid: true
      });
    });
    
    it('should skip transaction when skipTransaction is true', async function() {
      const result = await switchValidator(mockContract, {
        skipTransaction: true,
        silent: true
      });
      
      expect(result.success).to.be.true;
      expect(result.skipped).to.be.true;
      expect(result.message).to.equal('Validator switch simulated (skipTransaction=true)');
      expect(mockContract.checkAndSwitchValidator.called).to.be.false;
    });
    
    it('should handle transaction failure', async function() {
      mockContract.checkAndSwitchValidator.rejects(new Error('Transaction failed'));
      
      const result = await switchValidator(mockContract, { silent: true });
      
      expect(result.success).to.be.false;
      expect(result.message).to.include('Failed to switch validator');
      expect(result.message).to.include('Transaction failed');
    });
    
    it('should handle no validator switch event', async function() {
      const mockTx = {
        wait: sandbox.stub().resolves({
          hash: '0xabc123...',
          blockNumber: 12345
        })
      };
      
      mockContract.checkAndSwitchValidator.resolves(mockTx);
      mockContract.queryFilter.resolves([]); // No events
      
      const result = await switchValidator(mockContract, { silent: true });
      
      expect(result.success).to.be.true;
      expect(result.message).to.equal('Validator check completed (no switch occurred)');
    });
  });
  
  describe('checkValidator', function() {
    it('should check validator without switching when validator is valid', async function() {
      // Mock ethers to return our mock objects
      sandbox.stub(ethers, 'JsonRpcProvider').returns(mockProvider);
      sandbox.stub(ethers, 'Wallet').returns(mockSigner);
      sandbox.stub(ethers, 'Contract').returns(mockContract);
      
      // Mock valid validator
      mockContract.getCurrentValidatorInfo.resolves({
        hotkey: '0x1234567890123456789012345678901234567890123456789012345678901234',
        uid: 42n,
        isValid: true
      });
      mockContract.getStakedBalance.resolves(ethers.parseEther('10000'));
      
      const result = await checkValidator({
        ...TEST_CONFIG,
        shouldSwitch: false,
        silent: true
      });
      
      expect(result.success).to.be.true;
      expect(result.currentValidator.isValid).to.be.true;
      expect(result.currentValidator.uid).to.equal('42');
      expect(result.switchPerformed).to.be.false;
    });
    
    it('should switch validator when invalid and shouldSwitch is true', async function() {
      // Mock ethers
      sandbox.stub(ethers, 'JsonRpcProvider').returns(mockProvider);
      sandbox.stub(ethers, 'Wallet').returns(mockSigner);
      sandbox.stub(ethers, 'Contract').returns(mockContract);
      
      // Mock invalid validator
      mockContract.getCurrentValidatorInfo.resolves({
        hotkey: '0x0000000000000000000000000000000000000000000000000000000000000000',
        uid: 0n,
        isValid: false
      });
      mockContract.getStakedBalance.resolves(ethers.parseEther('10000'));
      
      // Mock successful switch
      const mockTx = {
        wait: sandbox.stub().resolves({
          hash: '0xdef456...',
          blockNumber: 12346
        })
      };
      mockContract.checkAndSwitchValidator.resolves(mockTx);
      mockContract.queryFilter.resolves([
        {
          args: {
            oldValidator: '0x0000000000000000000000000000000000000000000000000000000000000000',
            newValidator: '0x0000000000000000000000000000000000000000000000000000000000000002',
            oldUid: 0n,
            newUid: 2n,
            reason: 'Validator invalid'
          }
        }
      ]);
      
      // Mock new validator info
      mockContract.getCurrentValidatorInfo.onSecondCall().resolves({
        hotkey: '0x0000000000000000000000000000000000000000000000000000000000000002',
        uid: 2n,
        isValid: true
      });
      
      const result = await checkValidator({
        ...TEST_CONFIG,
        shouldSwitch: true,
        silent: true
      });
      
      expect(result.success).to.be.true;
      expect(result.currentValidator.isValid).to.be.false;
      expect(result.switchPerformed).to.be.true;
      expect(result.switchResult.success).to.be.true;
      expect(result.switchResult.newValidator.uid).to.equal('2');
    });
    
    it('should handle errors during validator check', async function() {
      // Mock ethers to throw error
      sandbox.stub(ethers, 'JsonRpcProvider').throws(new Error('Network error'));
      
      const result = await checkValidator({
        ...TEST_CONFIG,
        silent: true
      });
      
      expect(result.success).to.be.false;
      expect(result.error).to.equal('Failed to check validator');
      expect(result.errorDetails.message).to.equal('Network error');
    });
    
    it('should skip transaction in test mode', async function() {
      // Mock ethers
      sandbox.stub(ethers, 'JsonRpcProvider').returns(mockProvider);
      sandbox.stub(ethers, 'Wallet').returns(mockSigner);
      sandbox.stub(ethers, 'Contract').returns(mockContract);
      
      // Mock invalid validator
      mockContract.getCurrentValidatorInfo.resolves({
        hotkey: '0x0000000000000000000000000000000000000000000000000000000000000000',
        uid: 0n,
        isValid: false
      });
      mockContract.getStakedBalance.resolves(ethers.parseEther('10000'));
      
      const result = await checkValidator({
        ...TEST_CONFIG,
        shouldSwitch: true,
        skipTransaction: true,
        silent: true
      });
      
      expect(result.success).to.be.true;
      expect(result.switchPerformed).to.be.true;
      expect(result.switchResult.skipped).to.be.true;
      expect(mockContract.checkAndSwitchValidator.called).to.be.false;
    });
  });
  
  describe('Integration with Local Chain', function() {
    it('should handle real contract interaction patterns', async function() {
      // This test demonstrates how the module would interact with a real contract
      // In actual integration tests, this would use a real local chain
      
      // Mock ethers
      sandbox.stub(ethers, 'JsonRpcProvider').returns(mockProvider);
      sandbox.stub(ethers, 'Wallet').returns(mockSigner);
      sandbox.stub(ethers, 'Contract').returns(mockContract);
      
      // Simulate a sequence of operations
      
      // 1. First check - validator is valid
      mockContract.getCurrentValidatorInfo.onFirstCall().resolves({
        hotkey: '0x1111111111111111111111111111111111111111111111111111111111111111',
        uid: 1n,
        isValid: true
      });
      mockContract.getStakedBalance.resolves(ethers.parseEther('10000'));
      
      let result = await checkValidator({
        ...TEST_CONFIG,
        shouldSwitch: false,
        silent: true
      });
      
      expect(result.success).to.be.true;
      expect(result.currentValidator.isValid).to.be.true;
      
      // 2. Second check - validator becomes invalid
      mockContract.getCurrentValidatorInfo.reset();
      mockContract.getCurrentValidatorInfo.onFirstCall().resolves({
        hotkey: '0x1111111111111111111111111111111111111111111111111111111111111111',
        uid: 1n,
        isValid: false
      });
      
      // Prepare for switch
      const mockTx = {
        wait: sandbox.stub().resolves({
          hash: '0xswitch123...',
          blockNumber: 12347
        })
      };
      mockContract.checkAndSwitchValidator.resolves(mockTx);
      mockContract.queryFilter.resolves([
        {
          args: {
            oldValidator: '0x1111111111111111111111111111111111111111111111111111111111111111',
            newValidator: '0x2222222222222222222222222222222222222222222222222222222222222222',
            oldUid: 1n,
            newUid: 2n,
            reason: 'Validator lost permit'
          }
        }
      ]);
      
      // After switch - new validator
      mockContract.getCurrentValidatorInfo.onSecondCall().resolves({
        hotkey: '0x2222222222222222222222222222222222222222222222222222222222222222',
        uid: 2n,
        isValid: true
      });
      
      result = await checkValidator({
        ...TEST_CONFIG,
        shouldSwitch: true,
        silent: true
      });
      
      expect(result.success).to.be.true;
      expect(result.switchPerformed).to.be.true;
      expect(result.switchResult.success).to.be.true;
      expect(result.switchResult.message).to.include('switched from UID 1 to UID 2');
    });
  });
});
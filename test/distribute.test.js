// test/distribute.test.js
const { expect } = require('chai');
const sinon = require('sinon');
const { ethers } = require('ethers');
const {
  SAINTDURBIN_ABI,
  CONFIG,
  initializeDistribution,
  executeDistribution,
  checkValidatorStatus,
  monitorValidatorSwitches,
  getDistributionCount,
  setDistributionCount
} = require('../scripts/distribute');

describe('Distribute Script', () => {
  let sandbox;

  beforeEach(() => {
    sandbox = sinon.createSandbox();
    // Reset distribution count before each test
    setDistributionCount(0);
  });

  afterEach(() => {
    sandbox.restore();
  });

  describe('initializeDistribution', () => {
    it('should initialize provider, wallet, and contract', () => {
      const config = {
        rpcUrl: 'http://localhost:8545',
        privateKey: '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        contractAddress: '0x1234567890123456789012345678901234567890'
      };

      const result = initializeDistribution(config);

      expect(result).to.have.property('provider');
      expect(result).to.have.property('wallet');
      expect(result).to.have.property('contract');
      expect(result.provider).to.be.instanceOf(ethers.JsonRpcProvider);
      expect(result.wallet).to.be.instanceOf(ethers.Wallet);
      expect(result.contract).to.be.instanceOf(ethers.Contract);
    });
  });

  describe('executeDistribution', () => {
    let mockContract;
    let mockProvider;

    beforeEach(() => {
      mockContract = {
        canExecuteTransfer: sandbox.stub(),
        blocksUntilNextTransfer: sandbox.stub(),
        getNextTransferAmount: sandbox.stub(),
        getAvailableRewards: sandbox.stub(),
        executeTransfer: sandbox.stub(),
        interface: {
          parseLog: sandbox.stub()
        }
      };
      mockProvider = {};
    });

    it('should return early when distribution is not ready', async () => {
      mockContract.canExecuteTransfer.resolves(false);
      mockContract.blocksUntilNextTransfer.resolves(100);

      const result = await executeDistribution(mockContract, mockProvider);

      expect(result.success).to.be.false;
      expect(result.canExecute).to.be.false;
      expect(result.blocksRemaining).to.equal(100);
      expect(result.transactionHash).to.be.null;
    });

    it('should execute distribution successfully', async () => {
      mockContract.canExecuteTransfer.resolves(true);
      mockContract.getNextTransferAmount.resolves(ethers.parseUnits('10', 9));
      mockContract.getAvailableRewards.resolves(ethers.parseUnits('100', 9));
      
      const mockTx = {
        hash: '0xabc123',
        wait: sandbox.stub().resolves({
          status: 1,
          gasUsed: BigInt(50000),
          logs: []
        })
      };
      mockContract.executeTransfer.resolves(mockTx);

      const result = await executeDistribution(mockContract, mockProvider);

      expect(result.success).to.be.true;
      expect(result.transactionHash).to.equal('0xabc123');
      expect(result.amount).to.equal(ethers.parseUnits('10', 9).toString());
      expect(result.gasUsed).to.equal('50000');
    });

    it('should handle transaction failure', async () => {
      mockContract.canExecuteTransfer.resolves(true);
      mockContract.getNextTransferAmount.resolves(ethers.parseUnits('10', 9));
      mockContract.getAvailableRewards.resolves(ethers.parseUnits('100', 9));
      mockContract.executeTransfer.rejects(new Error('Transaction failed'));

      const result = await executeDistribution(mockContract, mockProvider);

      expect(result.success).to.be.false;
      expect(result.error).to.equal('Transaction failed');
    });

    it('should check validator status at configured intervals', async () => {
      // Set distribution count to trigger validator check
      setDistributionCount(CONFIG.checkInterval - 1);
      
      const checkValidatorStatusStub = sandbox.stub();
      sandbox.replace(require('../scripts/distribute'), 'checkValidatorStatus', checkValidatorStatusStub);

      mockContract.canExecuteTransfer.resolves(false);
      mockContract.blocksUntilNextTransfer.resolves(100);

      await executeDistribution(mockContract, mockProvider);

      expect(checkValidatorStatusStub.calledOnce).to.be.true;
    });
  });

  describe('checkValidatorStatus', () => {
    let mockContract;
    let mockProvider;

    beforeEach(() => {
      mockContract = {
        getCurrentValidatorInfo: sandbox.stub(),
        getStakedBalance: sandbox.stub(),
        checkAndSwitchValidator: sandbox.stub()
      };
      mockProvider = {};
    });

    it('should return validator info when validator is valid', async () => {
      const hotkey = '0x1234567890123456789012345678901234567890123456789012345678901234';
      const uid = 42;
      mockContract.getCurrentValidatorInfo.resolves([hotkey, uid, true]);
      mockContract.getStakedBalance.resolves(ethers.parseUnits('1000', 9));

      const result = await checkValidatorStatus(mockContract, mockProvider);

      expect(result.success).to.be.true;
      expect(result.hotkey).to.equal(hotkey);
      expect(result.uid).to.equal('42');
      expect(result.isValid).to.be.true;
      expect(result.stakedBalance).to.equal(ethers.parseUnits('1000', 9).toString());
    });

    it('should handle invalid validator', async () => {
      const hotkey = '0x1234567890123456789012345678901234567890123456789012345678901234';
      const uid = 42;
      mockContract.getCurrentValidatorInfo.resolves([hotkey, uid, false]);
      mockContract.getStakedBalance.resolves(ethers.parseUnits('1000', 9));
      
      const mockTx = {
        hash: '0xdef456',
        wait: sandbox.stub().resolves({
          logs: []
        })
      };
      mockContract.checkAndSwitchValidator.resolves(mockTx);

      const result = await checkValidatorStatus(mockContract, mockProvider);

      expect(result.success).to.be.true;
      expect(result.isValid).to.be.false;
      expect(result.switchTransactionHash).to.equal('0xdef456');
    });
  });


  describe('monitorValidatorSwitches', () => {
    let mockContract;

    beforeEach(() => {
      mockContract = {
        interface: {
          parseLog: sandbox.stub()
        }
      };
    });

    it('should detect and return validator switch events', async () => {
      const mockReceipt = {
        logs: [
          { data: '0x123' },
          { data: '0x456' }
        ]
      };

      mockContract.interface.parseLog
        .onFirstCall().returns({
          name: 'ValidatorSwitched',
          args: {
            oldHotkey: '0xold',
            newHotkey: '0xnew',
            newUid: BigInt(100),
            reason: 'Test switch'
          }
        })
        .onSecondCall().returns(null);

      const result = await monitorValidatorSwitches(mockContract, mockReceipt);

      expect(result).to.have.length(1);
      expect(result[0]).to.deep.equal({
        oldHotkey: '0xold',
        newHotkey: '0xnew',
        newUid: '100',
        reason: 'Test switch'
      });
    });

    it('should return empty array when monitoring is disabled', async () => {
      const originalConfig = CONFIG.monitorValidatorSwitches;
      CONFIG.monitorValidatorSwitches = false;

      const result = await monitorValidatorSwitches(mockContract, {});

      expect(result).to.be.an('array').that.is.empty;

      // Restore original config
      CONFIG.monitorValidatorSwitches = originalConfig;
    });
  });

  describe('Distribution Count', () => {
    it('should get and set distribution count', () => {
      expect(getDistributionCount()).to.equal(0);
      
      setDistributionCount(5);
      expect(getDistributionCount()).to.equal(5);
      
      setDistributionCount(10);
      expect(getDistributionCount()).to.equal(10);
    });
  });
});
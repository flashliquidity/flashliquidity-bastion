import { ethers, network } from "hardhat"
import { expect } from "chai"
import {
    time,
    impersonateAccount,
    stopImpersonatingAccount,
    setStorageAt,
} from "@nomicfoundation/hardhat-network-helpers"
import {
    ADDRESS_ZERO,
    FACTORY_ADDR,
    ROUTER_ADDR,
    FARMFACTORY_ADDR,
    PEGSWAP_ADDR,
    LINKERC20,
    LINKERC667,
} from "./utilities"

describe("Bastion V2", function () {
    before(async function () {
        this.signers = await ethers.getSigners()
        this.governor = this.signers[0]
        this.guardian = this.signers[1]
        this.fliqPropulsionSystem = this.signers[3]
        this.bob = this.signers[5]
        this.upkeepsStationFactory = this.signers[6]
        this.allocExecDelay = 60
        this.transferGovernanceDelay = 60
        this.withdrawalDelay = 60
        this.dev = this.signers[11]
        this.minter = this.signers[12]
        this.alice = this.signers[13]
        this.ERC20Mock = await ethers.getContractFactory("ERC20Mock", this.minter)
        this.Bastion = await ethers.getContractFactory("BastionV2")
    })

    beforeEach(async function () {
        this.factory = await ethers.getContractAt("IFlashLiquidityFactory", FACTORY_ADDR)
        this.router = await ethers.getContractAt("IFlashLiquidityRouter", ROUTER_ADDR)
        this.stakingFactory = await ethers.getContractAt("ILiquidFarmFactory", FARMFACTORY_ADDR)
        this.govFactory = await ethers.getContractAt("Governable", FARMFACTORY_ADDR)
        this.bastion = await this.Bastion.deploy(
            this.governor.address,
            this.factory.address,
            this.router.address,
            this.stakingFactory.address,
            LINKERC20,
            LINKERC667,
            PEGSWAP_ADDR,
            this.transferGovernanceDelay,
            this.withdrawalDelay
        )
        await this.bastion.deployed()
        await setStorageAt(
            this.factory.address,
            2,
            ethers.utils.hexlify(ethers.utils.zeroPad(this.governor.address, 32))
        )
        await this.factory.setPairManagerSetter(this.bastion.address);
        await this.bastion.setExtManagerSetter(this.governor.address, true)

        this.token1 = await this.ERC20Mock.deploy("Mock token", "MOCK1", 1000000000)
        this.token2 = await this.ERC20Mock.deploy("Mock token", "MOCK2", 1000000000)
        await this.token1.deployed()
        await this.token2.deployed()
        await this.token1.connect(this.minter).transfer(this.bastion.address, 2000000)
        await this.token2.connect(this.minter).transfer(this.bastion.address, 2000000)
    })

    it("Should allow only Governor to set main manager setter", async function () {
        await expect(
            this.bastion.connect(this.bob).setMainManagerSetter(this.bob.address)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).setMainManagerSetter(this.bob.address)
    })

    it("Should allow only Governor to set external manager setters", async function () {
        await expect(
            this.bastion.connect(this.bob).setExtManagerSetter(this.bob.address, true)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).setExtManagerSetter(this.bob.address, true)
    })

    it("Should allow only Governor or external manger setters to set pairs manager", async function () {
        const pair = await this.factory.allPairs(0)
        await expect(
            this.bastion.connect(this.bob).setPairManager(pair, this.alice.address)
        ).to.be.revertedWith("NotManagerSetter()")
        await this.bastion.connect(this.governor).setPairManager(pair, this.alice.address)
        await this.bastion.connect(this.governor).setExtManagerSetter(this.bob.address, true)
        await this.bastion.connect(this.bob).setPairManager(pair, this.alice.address)
    })

    it("Should allow only Governor to request governance transfer", async function () {
        await expect(
            this.bastion.connect(this.bob).setPendingGovernor(this.bob.address)
        ).to.be.revertedWith("NotAuthorized()")
        expect(await this.bastion.pendingGovernor()).to.not.be.equal(this.bob.address)
        await this.bastion.connect(this.governor).setPendingGovernor(this.bob.address)
        expect(await this.bastion.pendingGovernor()).to.be.equal(this.bob.address)
        expect(await this.bastion.govTransferReqTimestamp()).to.not.be.equal(0)
    })

    it("Should not allow to set pendingGovernor to zero address", async function () {
        await expect(
            this.bastion.connect(this.governor).setPendingGovernor(ADDRESS_ZERO)
        ).to.be.revertedWith("ZeroAddress()")
    })

    it("Should allow to transfer governance only after min delay has passed from request", async function () {
        await this.bastion.connect(this.governor).setPendingGovernor(this.bob.address)
        await expect(this.bastion.transferGovernance()).to.be.revertedWith("TooEarly()")
        await time.increase(this.transferGovernanceDelay + 1)
        await this.bastion.transferGovernance()
        expect(await this.bastion.governor()).to.be.equal(this.bob.address)
    })

    it("Should allow only Governor to pause/unpause Bastion", async function () {
        expect(await this.bastion.paused()).to.be.false
        await expect(
            this.bastion.connect(this.bob).pause()
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).pause()
        expect(await this.bastion.paused()).to.be.true
        await expect(this.bastion.connect(this.governor).pause()).to.be.revertedWith("Paused()")
        await expect(
            this.bastion.connect(this.bob).unpause()
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).unpause()
        await expect(this.bastion.connect(this.governor).unpause()).to.be.revertedWith("NotPaused()")
    })

    it("Should allow only Governor to request emergency withdrawal and only if the Bastion is paused", async function () {
        expect(await this.bastion.paused()).to.be.false
        await expect(
            this.bastion.connect(this.guardian).requestEmergencyWithdrawal(this.dev.address)
        ).to.be.revertedWith("NotAuthorized()")
        await expect(
            this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        ).to.be.revertedWith("NotPaused()")
        await this.bastion.connect(this.governor).pause()
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        expect(await this.bastion.withdrawalRequestTimestamp()).to.not.be.equal(0)
    })

    it("Should allow only Governor to abort emergency withdrawal and only if emergency has been declared", async function () {
        expect(await this.bastion.paused()).to.be.false
        await expect(
            this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        ).to.be.revertedWith("NotPaused()")
        await this.bastion.connect(this.governor).pause()
        await expect(
            this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        ).to.be.revertedWith("NotRequested()")
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        await expect(
            this.bastion.connect(this.guardian).abortEmergencyWithdrawal()
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        expect(await this.bastion.withdrawalRequestTimestamp()).to.be.equal(0)
    })

    it("Should not allow to execute withdrawal until min delay has passed", async function () {
        expect(await this.bastion.paused()).to.be.false
        await this.bastion.connect(this.governor).pause()
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.governor.address)
        await expect(
            this.bastion
                .connect(this.governor)
                .emergencyWithdraw([this.token1.address, this.token2.address], [1000, 1000])
        ).to.be.revertedWith("TooEarly()")
    })

    it("Should send funds to recipient upon emergency withdrawal execution", async function () {
        expect(await this.bastion.paused()).to.be.false
        await this.bastion.connect(this.governor).pause()
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        await time.increase(this.withdrawalDelay + 1)
        await this.bastion
            .connect(this.governor)
            .emergencyWithdraw([this.token1.address, this.token2.address], [1000, 1000])
        expect(await this.token1.balanceOf(this.dev.address)).to.be.equal(1000)
        expect(await this.token2.balanceOf(this.dev.address)).to.be.equal(1000)
        await this.bastion
            .connect(this.governor)
            .emergencyWithdraw([this.token1.address, this.token2.address], [1000, 1000])
        expect(await this.token1.balanceOf(this.dev.address)).to.be.equal(2000)
        expect(await this.token2.balanceOf(this.dev.address)).to.be.equal(2000)
    })

    it("Should allow only Governor to abort emergency withdrawal and only if emergency has been declared", async function () {
        expect(await this.bastion.paused()).to.be.false
        await expect(
            this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        ).to.be.revertedWith("NotPaused()")
        await this.bastion.connect(this.governor).pause()
        await expect(
            this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        ).to.be.revertedWith("NotRequested()")
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        await expect(
            this.bastion.connect(this.guardian).abortEmergencyWithdrawal()
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        expect(await this.bastion.withdrawalRequestTimestamp()).to.be.equal(0)
    })

    it("Should allow only Governor to use Bastion funds to add liquidity", async function () {
        await expect(
            this.bastion
                .connect(this.bob)
                .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion
            .connect(this.governor)
            .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
    })

    it("Should allow only Governor to remove liquidity from Bastion LP tokens", async function () {
        await this.bastion
            .connect(this.governor)
            .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
        expect(await this.token1.balanceOf(this.bastion.address)).to.be.equal(1000000)
        expect(await this.token2.balanceOf(this.bastion.address)).to.be.equal(1000000)
        await this.bastion
            .connect(this.governor)
            .removeLiquidity(this.token1.address, this.token2.address, 1000, 1, 1)
        expect(await this.token1.balanceOf(this.bastion.address)).to.not.be.equal(1000000)
        expect(await this.token2.balanceOf(this.bastion.address)).to.not.be.equal(1000000)
    })

    it("Should allow only Governor to stake Bastion LP Tokens and only on already deployed farms", async function () {
        await this.bastion
            .connect(this.governor)
            .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
        const lpToken = await this.factory.getPair(this.token1.address, this.token2.address)
        await expect(
            this.bastion.connect(this.bob).stakeLpTokens(lpToken, 100)
        ).to.be.revertedWith("NotAuthorized()")

        await expect(
            this.bastion.connect(this.governor).stakeLpTokens(lpToken, 100)
        ).to.be.revertedWith("FarmNotDeployed()")
        const gov = await this.govFactory.governor()
        await impersonateAccount(gov)
        await this.stakingFactory
            .connect(ethers.provider.getSigner(gov))
            .deploy("MOCK", "MOCK", lpToken, this.token1.address)
        await stopImpersonatingAccount(gov)
        await this.bastion.connect(this.governor).stakeLpTokens(lpToken, 100)
    })

    it("Should allow only Governor to unstake Bastion LP Tokens and claim farming rewards", async function () {
        await this.bastion
            .connect(this.governor)
            .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
        const lpToken = await this.factory.getPair(this.token1.address, this.token2.address)
        const gov = await this.govFactory.governor()
        await impersonateAccount(gov)
        await this.stakingFactory
            .connect(ethers.provider.getSigner(gov))
            .deploy("MOCK", "MOCK", lpToken, this.token1.address)
        await stopImpersonatingAccount(gov)
        await this.bastion.connect(this.governor).stakeLpTokens(lpToken, 100)
        await expect(
            this.bastion.connect(this.bob).claimStakingRewards(lpToken)
        ).to.be.revertedWith("NotAuthorized()")
        await expect(
            this.bastion.connect(this.bob).unstakeLpTokens(lpToken, 100)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).claimStakingRewards(lpToken)
        await this.bastion.connect(this.governor).unstakeLpTokens(lpToken, 100)
    })

    it("Should allow only Governor to swap tokens from Bastion balances on open/managed pairs", async function () {
        await this.bastion
            .connect(this.governor)
            .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
        const pair = await this.factory.getPair(this.token1.address, this.token2.address)
        await expect(
            this.bastion
                .connect(this.bob)
                .swapOnLockedPair(100, 10, this.token1.address, this.token2.address)
        ).to.be.revertedWith("NotAuthorized()")
        await expect(
            this.bastion
                .connect(this.governor)
                .swapOnLockedPair(100, 10, this.token1.address, this.token2.address)
        ).to.be.revertedWith("CannotConvert()")
        await expect(
            this.bastion
                .connect(this.bob)
                .swapExactTokensForTokens(100, 10, [this.token1.address, this.token2.address])
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion
            .connect(this.governor)
            .swapExactTokensForTokens(100, 10, [this.token1.address, this.token2.address])
        await this.bastion.connect(this.governor).setPairManager(pair, this.alice.address)
        await expect(
            this.bastion
                .connect(this.governor)
                .swapExactTokensForTokens(100, 10, [this.token1.address, this.token2.address])
        ).to.be.revertedWith("ONLY MANAGER")
        await this.bastion
            .connect(this.governor)
            .swapOnLockedPair(100, 10, this.token1.address, this.token2.address)
    })
})

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
    STAKING_ADDR,
    PEGSWAP_ADDR,
    LINKERC20,
    LINKERC667,
} from "./utilities"

const factoryJson = require("./core-deployments/FlashLiquidityFactory.json")
const routerJson = require("./core-deployments/FlashLiquidityRouter.json")
const stakingJson = require("./core-deployments/StakingRewardsFactory.json")

describe("FlashLiquidityBastion", function () {
    before(async function () {
        this.signers = await ethers.getSigners()
        this.governor = this.signers[0]
        this.guardian = this.signers[1]
        this.fliqPropulsionSystem = this.signers[3]
        this.flashBotFactory = this.signers[5]
        this.upkeepsStationFactory = this.signers[6]
        this.allocExecDelay = 60
        this.transferGovernanceDelay = 60
        this.withdrawalDelay = 60
        this.bob = this.signers[10]
        this.dev = this.signers[11]
        this.minter = this.signers[12]
        this.alice = this.signers[13]
        this.ERC20Mock = await ethers.getContractFactory("ERC20Mock", this.minter)
        this.Bastion = await ethers.getContractFactory("FlashLiquidityBastion")
    })

    beforeEach(async function () {
        this.factory = new ethers.Contract(FACTORY_ADDR, factoryJson.abi, this.dev)
        this.router = new ethers.Contract(ROUTER_ADDR, routerJson.abi, this.dev)
        this.stakingFactory = new ethers.Contract(STAKING_ADDR, stakingJson.abi, this.dev)
        this.bastion = await this.Bastion.deploy(
            this.governor.address,
            this.guardian.address,
            this.router.address,
            this.fliqPropulsionSystem.address,
            this.stakingFactory.address,
            this.flashBotFactory.address,
            this.upkeepsStationFactory.address,
            LINKERC20,
            LINKERC667,
            PEGSWAP_ADDR,
            this.allocExecDelay,
            this.transferGovernanceDelay,
            this.withdrawalDelay
        )
        await this.bastion.deployed()
        await setStorageAt(
            this.factory.address,
            2,
            ethers.utils.hexlify(ethers.utils.zeroPad(this.bastion.address, 32))
        )
        await this.bastion.setExtFlashbotSetter(this.governor.address, true)

        this.token1 = await this.ERC20Mock.deploy("Mock token", "MOCK1", 1000000000)
        this.token2 = await this.ERC20Mock.deploy("Mock token", "MOCK2", 1000000000)
        await this.token1.deployed()
        await this.token2.deployed()
        await this.token1.connect(this.minter).transfer(this.bastion.address, 2000000)
        await this.token2.connect(this.minter).transfer(this.bastion.address, 2000000)
    })

    it("Should set Governor and Guardian correctly", async function () {
        expect(await this.bastion.governor()).to.equal(this.governor.address)
        expect(await this.bastion.guardian()).to.equal(this.guardian.address)
    })

    it("Should allow only Governor to set main flashbot setters", async function () {
        await expect(
            this.bastion.connect(this.bob).setMainFlashbotSetter(this.bob.address)
        ).to.be.revertedWith("Only Governor")
        await this.bastion.connect(this.governor).setMainFlashbotSetter(this.bob.address)
    })

    it("Should allow only Governor to set external flashbot setters", async function () {
        await expect(
            this.bastion.connect(this.bob).setExtFlashbotSetter(this.bob.address, true)
        ).to.be.revertedWith("Only Governor")
        await this.bastion.connect(this.governor).setExtFlashbotSetter(this.bob.address, true)
    })

    it("Should allow only Governor or external flashbot setters to set flashbots", async function () {
        const pair = await this.factory.allPairs(0)
        await expect(
            this.bastion.connect(this.bob).setFlashbot(pair, this.alice.address)
        ).to.be.revertedWith("Not Authorized")
        await this.bastion.connect(this.governor).setFlashbot(pair, this.alice.address)
        await this.bastion.connect(this.governor).setExtFlashbotSetter(this.bob.address, true)
        await this.bastion.connect(this.bob).setFlashbot(pair, this.alice.address)
    })

    it("Should allow only Governor to request governance transfer", async function () {
        await expect(
            this.bastion.connect(this.bob).setPendingGovernor(this.bob.address)
        ).to.be.revertedWith("Only Governor")
        expect(await this.bastion.pendingGovernor()).to.not.be.equal(this.bob.address)
        await this.bastion.connect(this.governor).setPendingGovernor(this.bob.address)
        expect(await this.bastion.pendingGovernor()).to.be.equal(this.bob.address)
        expect(await this.bastion.govTransferReqTimestamp()).to.not.be.equal(0)
    })

    it("Should not allow to set pendingGovernor to zero address", async function () {
        await expect(
            this.bastion.connect(this.governor).setPendingGovernor(ADDRESS_ZERO)
        ).to.be.revertedWith("Zero Address")
    })

    it("Should allow to transfer governance only after min delay has passed from request", async function () {
        await this.bastion.connect(this.governor).setPendingGovernor(this.bob.address)
        await expect(this.bastion.transferGovernance()).to.be.revertedWith("Too Early")
        await time.increase(this.transferGovernanceDelay + 1)
        await this.bastion.transferGovernance()
        expect(await this.bastion.governor()).to.be.equal(this.bob.address)
    })

    it("Should allow only Guardian to pause/unpause Bastion", async function () {
        expect(await this.bastion.paused()).to.be.false
        await expect(this.bastion.connect(this.governor).pause()).to.be.revertedWith(
            "Only Guardian"
        )
        await this.bastion.connect(this.guardian).pause()
        expect(await this.bastion.paused()).to.be.true
        await expect(this.bastion.connect(this.guardian).pause()).to.be.revertedWith("Paused")
        await expect(this.bastion.connect(this.governor).unpause()).to.be.revertedWith(
            "Only Guardian"
        )
        await this.bastion.connect(this.guardian).unpause()
        await expect(this.bastion.connect(this.guardian).unpause()).to.be.revertedWith("Not Paused")
    })

    it("Should allow only Governor to request emergency withdrawal and only if the Bastion is paused", async function () {
        expect(await this.bastion.paused()).to.be.false
        await expect(
            this.bastion.connect(this.guardian).requestEmergencyWithdrawal(this.dev.address)
        ).to.be.revertedWith("Only Governor")
        await expect(
            this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        ).to.be.revertedWith("Not Paused")
        await this.bastion.connect(this.guardian).pause()
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        expect(await this.bastion.withdrawalRequestTimestamp()).to.not.be.equal(0)
    })

    it("Should allow only Governor to abort emergency withdrawal and only if emergency has been declared", async function () {
        expect(await this.bastion.paused()).to.be.false
        await expect(
            this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        ).to.be.revertedWith("Not Paused")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        ).to.be.revertedWith("Withdrawal Not Requested")
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        await expect(
            this.bastion.connect(this.guardian).abortEmergencyWithdrawal()
        ).to.be.revertedWith("Only Governor")
        await this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        expect(await this.bastion.withdrawalRequestTimestamp()).to.be.equal(0)
    })

    it("Should not allow to execute withdrawal until min delay has passed", async function () {
        expect(await this.bastion.paused()).to.be.false
        await this.bastion.connect(this.guardian).pause()
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        await expect(
            this.bastion
                .connect(this.governor)
                .emergencyWithdraw([this.token1.address, this.token2.address], [1000, 1000])
        ).to.be.revertedWith("Too Early")
    })

    it("Should send funds to recipient upon emergency withdrawal execution", async function () {
        expect(await this.bastion.paused()).to.be.false
        await this.bastion.connect(this.guardian).pause()
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
        ).to.be.revertedWith("Not Paused")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        ).to.be.revertedWith("Withdrawal Not Requested")
        await this.bastion.connect(this.governor).requestEmergencyWithdrawal(this.dev.address)
        await expect(
            this.bastion.connect(this.guardian).abortEmergencyWithdrawal()
        ).to.be.revertedWith("Only Governor")
        await this.bastion.connect(this.governor).abortEmergencyWithdrawal()
        expect(await this.bastion.withdrawalRequestTimestamp()).to.be.equal(0)
    })

    it("Should allow only Governor to request funds allocations", async function () {
        expect(await this.token1.balanceOf(this.bastion.address)).to.be.equal(2000000)
        expect(await this.token2.balanceOf(this.bastion.address)).to.be.equal(2000000)
        await expect(
            this.bastion
                .connect(this.guardian)
                .requestAllocation(
                    this.bob.address,
                    [this.token1.address, this.token2.address],
                    [1000, 1000]
                )
        ).to.be.revertedWith("Only Governor")
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [1000, 1000]
            )
    })

    it("Should not allow to execute next empty allocations", async function () {
        await expect(this.bastion.connect(this.guardian).executeAllocation()).to.be.revertedWith(
            "No Pending Allocation"
        )
    })

    it("Should not allow Governor to request funds already allocated or in pending allocations", async function () {
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        await expect(
            this.bastion
                .connect(this.governor)
                .requestAllocation(
                    this.bob.address,
                    [this.token1.address, this.token2.address],
                    [2000000, 2000000]
                )
        ).to.be.revertedWith("Amount Exceeds Unallocated Balance")
    })

    it("Should allow only Guardian to execute funds allocation after min delay", async function () {
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        await expect(this.bastion.connect(this.bob).executeAllocation()).to.be.revertedWith(
            "Only Guardian"
        )
        await expect(this.bastion.connect(this.guardian).executeAllocation()).to.be.revertedWith(
            "Too Early"
        )
        time.increase(this.allocExecDelay)
        expect(await this.token1.balanceOf(this.bob.address)).to.be.equal(0)
        expect(await this.token2.balanceOf(this.bob.address)).to.be.equal(0)
        await this.bastion.connect(this.guardian).executeAllocation()
        expect(await this.token1.balanceOf(this.bob.address)).to.be.equal(2000000)
        expect(await this.token2.balanceOf(this.bob.address)).to.be.equal(2000000)
    })

    it("Should allow only Guardian to abort funds allocations", async function () {
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        await expect(this.bastion.connect(this.bob).executeAllocation()).to.be.revertedWith(
            "Only Guardian"
        )
        await expect(this.bastion.connect(this.guardian).executeAllocation()).to.be.revertedWith(
            "Too Early"
        )
        time.increase(this.allocExecDelay)
        expect(await this.token1.balanceOf(this.bob.address)).to.be.equal(0)
        expect(await this.token2.balanceOf(this.bob.address)).to.be.equal(0)
        await this.bastion.connect(this.guardian).executeAllocation()
        expect(await this.token1.balanceOf(this.bob.address)).to.be.equal(2000000)
        expect(await this.token2.balanceOf(this.bob.address)).to.be.equal(2000000)
    })

    it("Should allow only Guardian to skip single allocation only if it's aborted", async function () {
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        await this.bastion.connect(this.guardian).abortAllocation(0)
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        await this.bastion.connect(this.guardian).abortAllocation(1)
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        await this.bastion.connect(this.guardian).skipAbortedAllocation()
        await this.bastion.connect(this.guardian).skipAbortedAllocation()
        await expect(
            this.bastion.connect(this.guardian).skipAbortedAllocation()
        ).to.be.revertedWith("Not Aborted")
    })

    it("Should skip aborted allocations and execute the first mature pending allocation", async function () {
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        await this.bastion.connect(this.guardian).abortAllocation(0)
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [2000000, 2000000]
            )
        time.increase(this.allocExecDelay + 1)
        await this.bastion.connect(this.guardian).executeAllocation()
        expect(await this.token1.balanceOf(this.bob.address)).to.be.equal(2000000)
        expect(await this.token2.balanceOf(this.bob.address)).to.be.equal(2000000)
    })

    it("Should not panic with multiple aborted/pending allocations with different recipients", async function () {
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [500, 500]
            )
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [500, 500]
            )
        await this.bastion.connect(this.guardian).abortAllocation(0)
        await this.bastion.connect(this.guardian).abortAllocation(1)
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [500, 500]
            )
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.bob.address,
                [this.token1.address, this.token2.address],
                [100, 100]
            )
        await this.bastion.connect(this.guardian).abortAllocation(3)
        await this.bastion
            .connect(this.governor)
            .requestAllocation(
                this.alice.address,
                [this.token1.address, this.token2.address],
                [500, 500]
            )
        time.increase(this.allocExecDelay + 1)
        await this.bastion.connect(this.guardian).executeAllocation()
        await this.bastion.connect(this.guardian).executeAllocation()
        expect(await this.token1.balanceOf(this.bob.address)).to.be.equal(500)
        expect(await this.token2.balanceOf(this.bob.address)).to.be.equal(500)
        expect(await this.token1.balanceOf(this.alice.address)).to.be.equal(500)
        expect(await this.token2.balanceOf(this.alice.address)).to.be.equal(500)
    })

    it("Should allow only Governor to use Bastion funds to add liquidity", async function () {
        await expect(
            this.bastion
                .connect(this.bob)
                .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
        ).to.be.revertedWith("Only Governor")
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
        await expect(this.bastion.connect(this.bob).stakeLpTokens(lpToken, 100)).to.be.revertedWith(
            "Only Governor"
        )
        await expect(
            this.bastion.connect(this.governor).stakeLpTokens(lpToken, 100)
        ).to.be.revertedWith("Farm not deployed")
        const owner = await this.stakingFactory.owner()
        await impersonateAccount(owner)
        await this.stakingFactory
            .connect(ethers.provider.getSigner(owner))
            .deploy(lpToken, this.token1.address, this.bastion.address)
        await stopImpersonatingAccount(owner)
        await this.bastion.connect(this.governor).stakeLpTokens(lpToken, 100)
    })

    it("Should allow only Governor to unstake Bastion LP Tokens and claim farming rewards", async function () {
        await this.bastion
            .connect(this.governor)
            .addLiquidity(this.token1.address, this.token2.address, 1000000, 1000000, 1, 1)
        const lpToken = await this.factory.getPair(this.token1.address, this.token2.address)
        const owner = await this.stakingFactory.owner()
        await impersonateAccount(owner)
        await this.stakingFactory
            .connect(ethers.provider.getSigner(owner))
            .deploy(lpToken, this.token1.address, this.bastion.address)
        await stopImpersonatingAccount(owner)
        await this.bastion.connect(this.governor).stakeLpTokens(lpToken, 100)
        await expect(
            this.bastion.connect(this.bob).claimStakingRewards(lpToken)
        ).to.be.revertedWith("Only Governor")
        await expect(
            this.bastion.connect(this.bob).unstakeLpTokens(lpToken, 100)
        ).to.be.revertedWith("Only Governor")
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
        ).to.be.revertedWith("Only Governor")
        await expect(
            this.bastion
                .connect(this.governor)
                .swapOnLockedPair(100, 10, this.token1.address, this.token2.address)
        ).to.be.revertedWith("Cannot use swapOnLockedPair with open pairs")
        await expect(
            this.bastion
                .connect(this.bob)
                .swapExactTokensForTokens(100, 10, [this.token1.address, this.token2.address])
        ).to.be.revertedWith("Only Governor")
        await this.bastion
            .connect(this.governor)
            .swapExactTokensForTokens(100, 10, [this.token1.address, this.token2.address])
        await this.bastion.connect(this.governor).setFlashbot(pair, this.alice.address)
        await expect(
            this.bastion
                .connect(this.governor)
                .swapExactTokensForTokens(100, 10, [this.token1.address, this.token2.address])
        ).to.be.revertedWith("FlashLiquidity: not from flashbot")
        await this.bastion
            .connect(this.governor)
            .swapOnLockedPair(100, 10, this.token1.address, this.token2.address)
    })
})

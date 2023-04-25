import { ethers, network } from "hardhat"
import { expect } from "chai"
import { time, setStorageAt } from "@nomicfoundation/hardhat-network-helpers"
import { ADDRESS_ZERO, FACTORY_ADDR, FARMFACTORY_ADDR, ROUTER_ADDR, WETH_ADDR } from "./utilities"
import "dotenv/config"

describe("BastionV3", function () {
    before(async function () {
        this.signers = await ethers.getSigners()
        this.governor = this.signers[0]
        this.guardian = this.signers[1]
        this.bob = this.signers[2]
        this.alice = this.signers[3]
        this.maxDeviationFactor = 50
        this.maxStaleness = 60
        this.transferGovernanceDelay = 60
        this.Bastion = await ethers.getContractFactory("BastionV3")
    })

    beforeEach(async function () {
        await network.provider.request({
            method: "hardhat_reset",
            params: [
                {
                    forking: {
                        enabled: true,
                        jsonRpcUrl: process.env.ALCHEMY_MAINNET_RPC_URL,
                        blockNumber: 41900000,
                    },
                },
            ],
        })
        this.factory = await ethers.getContractAt("IFlashLiquidityFactory", FACTORY_ADDR)
        this.router = await ethers.getContractAt("IFlashLiquidityRouter", ROUTER_ADDR)
        this.farmFactory = await ethers.getContractAt("ILiquidFarmFactory", FARMFACTORY_ADDR)
        this.extRouter = await ethers.getContractAt(
            "IFlashLiquidityRouter",
            "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"
        )
        this.maticUsdcPair = await ethers.getContractAt(
            "IFlashLiquidityPair",
            "0x0C9580eC848bd48EBfCB85A4aE1f0354377315fD"
        )
        this.usdc = await ethers.getContractAt(
            "IERC20",
            "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
        )
        this.weth = await ethers.getContractAt("IERC20", WETH_ADDR)
        this.wethPriceFeed = "0xAB594600376Ec9fD91F8e885dADF0CE036862dE0"
        this.usdcPriceFeed = "0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7"
        this.bastion = await this.Bastion.deploy(
            this.governor.address,
            this.guardian.address,
            this.factory.address,
            this.router.address,
            this.farmFactory.address,
            WETH_ADDR,
            this.maxDeviationFactor,
            this.maxStaleness,
            this.transferGovernanceDelay
        )
        await this.bastion.deployed()
        await setStorageAt(
            this.factory.address,
            2,
            ethers.utils.hexlify(ethers.utils.zeroPad(this.governor.address, 32))
        )
        await this.factory.setPairManagerSetter(this.bastion.address)
        await this.bastion.setExtManagerSetters([this.governor.address], [true])
        await this.extRouter
            .connect(this.governor)
            .swapExactETHForTokens(
                0,
                [WETH_ADDR, this.usdc.address],
                this.governor.address,
                2000000000,
                { value: ethers.utils.parseEther("100") }
            )
        await this.usdc.connect(this.governor).approve(this.extRouter.address, 5000000)
        await this.extRouter
            .connect(this.governor)
            .swapExactTokensForTokens(
                5000000,
                0,
                [this.usdc.address, WETH_ADDR],
                this.bastion.address,
                2000000000
            )
        const balance = await this.usdc.balanceOf(this.governor.address)
        await this.usdc.connect(this.governor).transfer(this.bastion.address, balance)
        this.wethBalance = await this.weth.balanceOf(this.bastion.address)
        this.usdcBalance = await this.usdc.balanceOf(this.bastion.address)
    })

    it("Should allow only Governor to set main manager setter", async function () {
        await expect(
            this.bastion.connect(this.bob).setMainManagerSetter(this.bob.address)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).setMainManagerSetter(this.bob.address)
    })

    it("Should allow only Governor to set external manager setters", async function () {
        await expect(
            this.bastion.connect(this.bob).setExtManagerSetters([this.bob.address], [true])
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).setExtManagerSetters([this.bob.address], [true])
    })

    it("Should allow only Governor or external manager setters to set pairs manager", async function () {
        await expect(
            this.bastion
                .connect(this.bob)
                .setPairManager(this.maticUsdcPair.address, this.alice.address)
        ).to.be.revertedWith("NotManagerSetter()")
        await this.bastion
            .connect(this.governor)
            .setPairManager(this.maticUsdcPair.address, this.alice.address)
        await this.bastion.connect(this.governor).setExtManagerSetters([this.bob.address], [true])
        await this.bastion
            .connect(this.bob)
            .setPairManager(this.maticUsdcPair.address, this.alice.address)
    })

    it("Should allow only Guardian to set new guardian address", async function () {
        await expect(
            this.bastion.connect(this.bob).setGuardian(this.alice.address)
        ).to.be.revertedWith("NotGuardian()")
        expect(await this.bastion.guardian()).to.not.be.equal(this.alice.address)
        await this.bastion.connect(this.guardian).setGuardian(this.alice.address)
        expect(await this.bastion.guardian()).to.be.equal(this.alice.address)
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

    it("Should allow only Guardian to pause/unpause Bastion", async function () {
        expect(await this.bastion.isPaused()).to.be.false
        await expect(this.bastion.connect(this.bob).pause()).to.be.revertedWith("NotGuardian()")
        await this.bastion.connect(this.guardian).pause()
        expect(await this.bastion.isPaused()).to.be.true
        await expect(this.bastion.connect(this.guardian).pause()).to.be.revertedWith("Paused()")
        await expect(this.bastion.connect(this.bob).unpause()).to.be.revertedWith("NotGuardian()")
        await this.bastion.connect(this.guardian).unpause()
        expect(await this.bastion.isPaused()).to.be.false
        await expect(this.bastion.connect(this.guardian).unpause()).to.be.revertedWith(
            "NotPaused()"
        )
    })

    it("Should allow only Guardian to request whitelisting", async function () {
        expect(await this.bastion.isWhitelisted(this.alice.address)).to.be.false
        await expect(
            this.bastion.connect(this.bob).requestWhitelisting([this.alice.address])
        ).to.be.revertedWith("NotGuardian()")
        await this.bastion.connect(this.guardian).requestWhitelisting([this.alice.address])
        await expect(
            this.bastion.connect(this.guardian).requestWhitelisting([this.alice.address])
        ).to.be.revertedWith("AlreadyRequested()")
        expect(await this.bastion.whitelistReqTimestamp(this.alice.address)).to.not.be.equal(0)
    })

    it("Should allow only Governor to execute whitelisting when requested, after min delay has passed and when not paused", async function () {
        await expect(
            this.bastion.connect(this.governor).executeWhitelisting([this.bob.address])
        ).to.be.revertedWith("NotRequested()")
        await this.bastion.connect(this.guardian).requestWhitelisting([this.bob.address])
        await expect(
            this.bastion.connect(this.guardian).executeWhitelisting([this.bob.address])
        ).to.be.revertedWith("NotAuthorized()")
        await expect(
            this.bastion.connect(this.governor).executeWhitelisting([this.bob.address])
        ).to.be.revertedWith("TooEarly()")
        await time.increase(await this.bastion.whitelistDelay())
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).executeWhitelisting([this.bob.address])
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion.connect(this.governor).executeWhitelisting([this.bob.address])
    })

    it("Should allow only Guardian to abort whitelisting", async function () {
        await expect(
            this.bastion.connect(this.guardian).abortWhitelisting([this.bob.address])
        ).to.be.revertedWith("NotRequested()")
        await this.bastion.connect(this.guardian).requestWhitelisting([this.bob.address])
        expect(await this.bastion.whitelistReqTimestamp(this.bob.address)).to.not.be.equal(0)
        await expect(
            this.bastion.connect(this.governor).abortWhitelisting([this.bob.address])
        ).to.be.revertedWith("NotGuardian()")
        await this.bastion.connect(this.guardian).abortWhitelisting([this.bob.address])
        expect(await this.bastion.whitelistReqTimestamp(this.bob.address)).to.be.equal(0)
    })

    it("Should allow only Guardian to remove whitelisted address", async function () {
        await this.bastion.connect(this.guardian).requestWhitelisting([this.bob.address])
        await time.increase(await this.bastion.whitelistDelay())
        await this.bastion.connect(this.governor).executeWhitelisting([this.bob.address])
        await expect(
            this.bastion.connect(this.governor).removeFromWhitelist([this.bob.address])
        ).to.be.revertedWith("NotGuardian()")
        expect(await this.bastion.isWhitelisted(this.bob.address)).to.be.true
        await this.bastion.connect(this.guardian).removeFromWhitelist([this.bob.address])
        expect(await this.bastion.isWhitelisted(this.bob.address)).to.be.false
    })

    it("Should allow only Governor to transfer tokens only to whitelisted address and when not paused", async function () {
        await expect(
            this.bastion
                .connect(this.governor)
                .transferToWhitelisted(this.bob.address, [this.usdc.address], [1])
        ).to.be.revertedWith("NotWhitelisted()")
        await this.bastion.connect(this.guardian).requestWhitelisting([this.bob.address])
        await time.increase(await this.bastion.whitelistDelay())
        await this.bastion.connect(this.governor).executeWhitelisting([this.bob.address])
        expect(await this.usdc.balanceOf(this.bob.address)).to.be.equal(0)
        await expect(
            this.bastion
                .connect(this.guardian)
                .transferToWhitelisted(this.bob.address, [this.usdc.address], [1])
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion
                .connect(this.governor)
                .transferToWhitelisted(this.bob.address, [this.usdc.address], [1])
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion
            .connect(this.governor)
            .transferToWhitelisted(this.bob.address, [this.usdc.address], [1])
        expect(await this.usdc.balanceOf(this.bob.address)).to.be.equal(1)
    })

    it("Should allow only Governor to change max deviation factor", async function () {
        expect(await this.bastion.maxDeviationFactor()).to.be.equal(this.maxDeviationFactor)
        await expect(
            this.bastion.connect(this.guardian).setMaxDeviationFactor(200)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).setMaxDeviationFactor(200)
        expect(await this.bastion.maxDeviationFactor()).to.be.equal(200)
    })

    it("Should allow only Governor to change max staleness for price feeds data", async function () {
        expect(await this.bastion.maxStaleness()).to.be.equal(this.maxStaleness)
        await expect(this.bastion.connect(this.guardian).setMaxStaleness(120)).to.be.revertedWith(
            "NotAuthorized()"
        )
        await this.bastion.connect(this.governor).setMaxStaleness(120)
        expect(await this.bastion.maxStaleness()).to.be.equal(120)
    })

    it("Should allow only Governor to set price feeds", async function () {
        await expect(
            this.bastion
                .connect(this.guardian)
                .setPriceFeeds([this.weth.address], [this.wethPriceFeed])
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion
            .connect(this.governor)
            .setPriceFeeds([this.weth.address], [this.wethPriceFeed])
    })

    it("Should allow only Governor to set tokens decimals", async function () {
        await expect(
            this.bastion.connect(this.guardian).setTokensDecimals([this.usdc.address], [1000000])
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).setTokensDecimals([this.usdc.address], [1000000])
    })

    it("Should allow only Governor to swap tokens when not paused (open pool)", async function () {
        await this.bastion
            .connect(this.governor)
            .setPairManager(this.maticUsdcPair.address, ADDRESS_ZERO)
        await this.bastion
            .connect(this.governor)
            .setPriceFeeds(
                [this.weth.address, this.usdc.address],
                [this.wethPriceFeed, this.usdcPriceFeed]
            )
        await expect(
            this.bastion.connect(this.bob).swap(this.usdc.address, this.weth.address, "100000000")
        ).to.be.revertedWith("NotAuthorized()")
        await expect(
            this.bastion
                .connect(this.governor)
                .swap(this.usdc.address, this.weth.address, "100000000")
        ).to.be.revertedWith("AmountOutTooLow()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion
                .connect(this.governor)
                .swap(this.usdc.address, this.weth.address, "10000000")
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion
            .connect(this.governor)
            .swap(this.usdc.address, this.weth.address, "10000000")
    })

    it("Should allow only Governor to swap tokens when not paused (self balancing pool)", async function () {
        await this.bastion
            .connect(this.governor)
            .setPriceFeeds(
                [this.weth.address, this.usdc.address],
                [this.wethPriceFeed, this.usdcPriceFeed]
            )
        await expect(
            this.bastion.connect(this.bob).swap(this.usdc.address, this.weth.address, "80000000")
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion
                .connect(this.governor)
                .swap(this.usdc.address, this.weth.address, "80000000")
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion
            .connect(this.governor)
            .swap(this.usdc.address, this.weth.address, "80000000")
    })

    it("Should allow only Governor to add liquidity when not paused (open pool)", async function () {
        await this.bastion
            .connect(this.governor)
            .setPairManager(this.maticUsdcPair.address, ADDRESS_ZERO)
        await this.bastion
            .connect(this.governor)
            .setPriceFeeds(
                [this.weth.address, this.usdc.address],
                [this.wethPriceFeed, this.usdcPriceFeed]
            )
        await expect(
            this.bastion
                .connect(this.bob)
                .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion
                .connect(this.governor)
                .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion
            .connect(this.governor)
            .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
    })

    it("Should allow only Governor to add liquidity when not paused (self balancing pool)", async function () {
        await this.bastion
            .connect(this.governor)
            .setPriceFeeds(
                [this.weth.address, this.usdc.address],
                [this.wethPriceFeed, this.usdcPriceFeed]
            )
        await expect(
            this.bastion
                .connect(this.bob)
                .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion
                .connect(this.governor)
                .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion
            .connect(this.governor)
            .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
    })

    it("Should allow only Governor to remove liquidity when not paused (open pool)", async function () {
        await this.bastion
            .connect(this.governor)
            .setPairManager(this.maticUsdcPair.address, ADDRESS_ZERO)
        await this.bastion
            .connect(this.governor)
            .setPriceFeeds(
                [this.weth.address, this.usdc.address],
                [this.wethPriceFeed, this.usdcPriceFeed]
            )
        await this.bastion
            .connect(this.governor)
            .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        const balance = await this.maticUsdcPair.balanceOf(this.bastion.address)
        await expect(
            this.bastion.connect(this.guardian).solidify(this.maticUsdcPair.address, balance)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).solidify(this.maticUsdcPair.address, balance)
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion.connect(this.governor).solidify(this.maticUsdcPair.address, balance)
    })

    it("Should allow only Governor to remove liquidity (self balancing pool)", async function () {
        await this.bastion
            .connect(this.governor)
            .setPriceFeeds(
                [this.weth.address, this.usdc.address],
                [this.wethPriceFeed, this.usdcPriceFeed]
            )
        await this.bastion
            .connect(this.governor)
            .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        const balance = await this.maticUsdcPair.balanceOf(this.bastion.address)
        await expect(
            this.bastion.connect(this.guardian).solidify(this.maticUsdcPair.address, balance)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).solidify(this.maticUsdcPair.address, balance)
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion.connect(this.governor).solidify(this.maticUsdcPair.address, balance)
    })

    it("Should allow only Governor to stake LPs and only on already deployed farms", async function () {
        await this.bastion
            .connect(this.governor)
            .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        await expect(
            this.bastion.connect(this.bob).stakeLpTokens(this.maticUsdcPair.address, 100)
        ).to.be.revertedWith("NotAuthorized()")
        await expect(
            this.bastion.connect(this.governor).stakeLpTokens(this.usdc.address, 100)
        ).to.be.revertedWith("InvalidFarm()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).stakeLpTokens(this.maticUsdcPair.address, 100)
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion.connect(this.governor).stakeLpTokens(this.maticUsdcPair.address, 100)
    })

    it("Should allow only Governor to unstake LPs and claim farming rewards", async function () {
        await this.bastion
            .connect(this.governor)
            .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        await this.bastion.connect(this.governor).stakeLpTokens(this.maticUsdcPair.address, 100)
        await time.increase(1000)
        await expect(
            this.bastion.connect(this.bob).unstakeLpTokens(this.maticUsdcPair.address, 100)
        ).to.be.revertedWith("NotAuthorized()")
        await expect(
            this.bastion.connect(this.bob).claimStakingRewards(this.maticUsdcPair.address)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).unstakeLpTokens(this.maticUsdcPair.address, 100)
        ).to.be.revertedWith("Paused()")
        await expect(
            this.bastion.connect(this.governor).claimStakingRewards(this.maticUsdcPair.address)
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion.connect(this.governor).unstakeLpTokens(this.maticUsdcPair.address, 100)
        await this.bastion.connect(this.governor).claimStakingRewards(this.maticUsdcPair.address)
    })

    it("Should allow only Governor to exit staking position from farm", async function () {
        await this.bastion
            .connect(this.governor)
            .liquefy(this.weth.address, this.usdc.address, this.wethBalance, this.usdcBalance)
        await this.bastion.connect(this.governor).stakeLpTokens(this.maticUsdcPair.address, 100)
        await time.increase(1000)
        await expect(
            this.bastion.connect(this.bob).exitStaking(this.maticUsdcPair.address)
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.guardian).pause()
        await expect(
            this.bastion.connect(this.governor).exitStaking(this.maticUsdcPair.address)
        ).to.be.revertedWith("Paused()")
        await this.bastion.connect(this.guardian).unpause()
        await this.bastion.connect(this.governor).exitStaking(this.maticUsdcPair.address)
    })

    it("Should allow only Governor to wrap ETH", async function () {
        await this.governor.sendTransaction({
            to: this.bastion.address,
            value: ethers.utils.parseEther("1.0"),
        })
        await expect(
            this.bastion.connect(this.bob).wrapETH(ethers.utils.parseEther("1.0"))
        ).to.be.revertedWith("NotAuthorized()")
        await this.bastion.connect(this.governor).wrapETH(ethers.utils.parseEther("1.0"))
    })
})

// SPDX-License-Identifier: MIT
// Hardhat + ethers v6 + chai tests for RnxStaking (Synthetix StakingRewards-style).
//
// Staking token: WRNX (TEST asset, wrapped via deposit()).
// Reward token:  qUSD (TEST asset, minted by its documented minter role).
//
// Coverage:
//   - stake
//   - earn over time
//   - getReward pays exactly what was funded
//   - withdraw principal
//   - exit (withdraw + getReward)
//   - cannot withdraw more than staked
//   - reward accounting invariant: sum of earned <= funded
//   - only rewardsDistribution can notifyRewardAmount
//   - no principal drain (owner cannot recover staking token; no owner path to principal)

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const WEEK = 7 * 24 * 60 * 60;

describe("RnxStaking (Synthetix StakingRewards-style)", function () {
  let wrnx, qusd, staking;
  let owner, distribution, alice, bob, carol;

  // Helper: give `signer` `amount` WRNX by depositing native RNX 1:1.
  async function fundWrnx(signer, amount) {
    await wrnx.connect(signer).deposit({ value: amount });
  }

  beforeEach(async function () {
    [owner, distribution, alice, bob, carol] = await ethers.getSigners();

    const WRNX = await ethers.getContractFactory("WRNX");
    wrnx = await WRNX.deploy();
    await wrnx.waitForDeployment();

    // qUSD minter = owner (owner mints the reward pool and pre-funds the staker).
    const QuoteUSD = await ethers.getContractFactory("QuoteUSD");
    qusd = await QuoteUSD.deploy(owner.address);
    await qusd.waitForDeployment();

    const RnxStaking = await ethers.getContractFactory("RnxStaking");
    staking = await RnxStaking.deploy(
      owner.address,
      distribution.address,
      await wrnx.getAddress(),
      await qusd.getAddress()
    );
    await staking.waitForDeployment();
  });

  // Pre-fund the staking contract with `amount` qUSD and start a WEEK period.
  async function fundAndNotify(amount) {
    await qusd.connect(owner).mint(await staking.getAddress(), amount);
    await staking.connect(distribution).notifyRewardAmount(amount);
  }

  describe("construction & roles", function () {
    it("records both documented roles and the two TEST tokens", async function () {
      expect(await staking.owner()).to.equal(owner.address);
      expect(await staking.rewardsDistribution()).to.equal(distribution.address);
      expect(await staking.stakingToken()).to.equal(await wrnx.getAddress());
      expect(await staking.rewardsToken()).to.equal(await qusd.getAddress());
      expect(await staking.rewardsDuration()).to.equal(BigInt(WEEK));
    });

    it("rejects zero addresses and identical tokens", async function () {
      const RnxStaking = await ethers.getContractFactory("RnxStaking");
      const w = await wrnx.getAddress();
      const q = await qusd.getAddress();
      await expect(RnxStaking.deploy(ethers.ZeroAddress, distribution.address, w, q))
        .to.be.revertedWith("RnxStaking: owner is zero");
      await expect(RnxStaking.deploy(owner.address, ethers.ZeroAddress, w, q))
        .to.be.revertedWith("RnxStaking: distribution is zero");
      await expect(RnxStaking.deploy(owner.address, distribution.address, w, w))
        .to.be.revertedWith("RnxStaking: tokens must differ");
    });
  });

  describe("stake", function () {
    it("accepts a stake, updates balances/totalSupply, emits Staked", async function () {
      const amt = ethers.parseEther("100");
      await fundWrnx(alice, amt);
      await wrnx.connect(alice).approve(await staking.getAddress(), amt);

      await expect(staking.connect(alice).stake(amt))
        .to.emit(staking, "Staked").withArgs(alice.address, amt);

      expect(await staking.balanceOf(alice.address)).to.equal(amt);
      expect(await staking.totalSupply()).to.equal(amt);
      // Principal is now held by the contract.
      expect(await wrnx.balanceOf(await staking.getAddress())).to.equal(amt);
    });

    it("reverts on staking zero", async function () {
      await expect(staking.connect(alice).stake(0))
        .to.be.revertedWith("RnxStaking: cannot stake 0");
    });
  });

  describe("earn over time", function () {
    it("accrues rewards proportional to elapsed time for a sole staker", async function () {
      const stakeAmt = ethers.parseEther("100");
      const rewardAmt = ethers.parseEther("700"); // 700 qUSD over 1 week
      await fundWrnx(alice, stakeAmt);
      await wrnx.connect(alice).approve(await staking.getAddress(), stakeAmt);
      await staking.connect(alice).stake(stakeAmt);

      await fundAndNotify(rewardAmt);

      expect(await staking.earned(alice.address)).to.equal(0n);

      // Advance half the week.
      await time.increase(WEEK / 2);
      const half = await staking.earned(alice.address);
      // ~ half the pool. Allow small rounding (rate = reward/duration truncation).
      const expectedHalf = rewardAmt / 2n;
      const diff = half > expectedHalf ? half - expectedHalf : expectedHalf - half;
      expect(diff).to.be.lessThan(ethers.parseEther("0.001"));

      // Advance to the end of the period.
      await time.increase(WEEK);
      const full = await staking.earned(alice.address);
      const diffFull = full > rewardAmt ? full - rewardAmt : rewardAmt - full;
      expect(diffFull).to.be.lessThan(ethers.parseEther("0.001"));
    });

    it("splits rewards proportionally between two stakers", async function () {
      const a = ethers.parseEther("100");
      const b = ethers.parseEther("300"); // bob has 3x alice => 25% / 75%
      const rewardAmt = ethers.parseEther("400");

      await fundWrnx(alice, a);
      await fundWrnx(bob, b);
      await wrnx.connect(alice).approve(await staking.getAddress(), a);
      await wrnx.connect(bob).approve(await staking.getAddress(), b);
      await staking.connect(alice).stake(a);
      await staking.connect(bob).stake(b);

      await fundAndNotify(rewardAmt);
      await time.increase(WEEK + 10);

      const ea = await staking.earned(alice.address);
      const eb = await staking.earned(bob.address);
      // bob should earn ~3x alice.
      const ratio = (eb * 1000n) / ea;
      expect(ratio).to.be.greaterThan(2990n);
      expect(ratio).to.be.lessThan(3010n);
    });
  });

  describe("getReward pays exactly what was funded", function () {
    it("pays out the full funded amount (within rounding) and no more", async function () {
      const stakeAmt = ethers.parseEther("100");
      const rewardAmt = ethers.parseEther("700");
      await fundWrnx(alice, stakeAmt);
      await wrnx.connect(alice).approve(await staking.getAddress(), stakeAmt);
      await staking.connect(alice).stake(stakeAmt);

      await fundAndNotify(rewardAmt);
      await time.increase(WEEK + 10); // run past period end

      const before = await qusd.balanceOf(alice.address);
      await expect(staking.connect(alice).getReward()).to.emit(staking, "RewardPaid");
      const after = await qusd.balanceOf(alice.address);
      const paid = after - before;

      // Paid is <= funded (never more) and within rounding of the full amount.
      expect(paid).to.be.lessThanOrEqual(rewardAmt);
      const diff = rewardAmt - paid;
      expect(diff).to.be.lessThan(ethers.parseEther("0.001"));
    });
  });

  describe("withdraw principal", function () {
    it("returns the exact staked principal to the staker", async function () {
      const amt = ethers.parseEther("100");
      await fundWrnx(alice, amt);
      await wrnx.connect(alice).approve(await staking.getAddress(), amt);
      await staking.connect(alice).stake(amt);

      await expect(staking.connect(alice).withdraw(amt))
        .to.emit(staking, "Withdrawn").withArgs(alice.address, amt);

      expect(await staking.balanceOf(alice.address)).to.equal(0n);
      expect(await staking.totalSupply()).to.equal(0n);
      expect(await wrnx.balanceOf(alice.address)).to.equal(amt);
    });

    it("reverts on withdrawing zero", async function () {
      await expect(staking.connect(alice).withdraw(0))
        .to.be.revertedWith("RnxStaking: cannot withdraw 0");
    });
  });

  describe("exit", function () {
    it("withdraws all principal and claims all rewards in one call", async function () {
      const stakeAmt = ethers.parseEther("100");
      const rewardAmt = ethers.parseEther("700");
      await fundWrnx(alice, stakeAmt);
      await wrnx.connect(alice).approve(await staking.getAddress(), stakeAmt);
      await staking.connect(alice).stake(stakeAmt);

      await fundAndNotify(rewardAmt);
      await time.increase(WEEK + 10);

      await staking.connect(alice).exit();

      expect(await staking.balanceOf(alice.address)).to.equal(0n);
      expect(await wrnx.balanceOf(alice.address)).to.equal(stakeAmt);
      // Received close to the full reward pool.
      const reward = await qusd.balanceOf(alice.address);
      const diff = rewardAmt - reward;
      expect(diff).to.be.lessThan(ethers.parseEther("0.001"));
    });
  });

  describe("cannot withdraw more than staked", function () {
    it("reverts when withdrawing more than the staked balance", async function () {
      const amt = ethers.parseEther("100");
      await fundWrnx(alice, amt);
      await wrnx.connect(alice).approve(await staking.getAddress(), amt);
      await staking.connect(alice).stake(amt);

      await expect(staking.connect(alice).withdraw(amt + 1n))
        .to.be.revertedWith("RnxStaking: insufficient staked balance");
    });

    it("one staker cannot withdraw another staker's principal", async function () {
      const a = ethers.parseEther("100");
      const b = ethers.parseEther("50");
      await fundWrnx(alice, a);
      await fundWrnx(bob, b);
      await wrnx.connect(alice).approve(await staking.getAddress(), a);
      await wrnx.connect(bob).approve(await staking.getAddress(), b);
      await staking.connect(alice).stake(a);
      await staking.connect(bob).stake(b);

      // bob tries to pull more than his own balance (even though contract holds a+b).
      await expect(staking.connect(bob).withdraw(b + 1n))
        .to.be.revertedWith("RnxStaking: insufficient staked balance");
    });
  });

  describe("reward accounting invariant: sum of earned <= funded", function () {
    it("total claimed across all stakers never exceeds the funded amount", async function () {
      const a = ethers.parseEther("123");
      const b = ethers.parseEther("77");
      const c = ethers.parseEther("200");
      const rewardAmt = ethers.parseEther("1000");

      for (const [s, amt] of [[alice, a], [bob, b], [carol, c]]) {
        await fundWrnx(s, amt);
        await wrnx.connect(s).approve(await staking.getAddress(), amt);
        await staking.connect(s).stake(amt);
      }

      await fundAndNotify(rewardAmt);
      await time.increase(WEEK + 100); // well past period end

      const earnedSum =
        (await staking.earned(alice.address)) +
        (await staking.earned(bob.address)) +
        (await staking.earned(carol.address));

      // INVARIANT: nobody can earn, in aggregate, more than was funded.
      expect(earnedSum).to.be.lessThanOrEqual(rewardAmt);

      // And actually claim it all; contract must stay solvent for every claim.
      await staking.connect(alice).getReward();
      await staking.connect(bob).getReward();
      await staking.connect(carol).getReward();

      const claimedSum =
        (await qusd.balanceOf(alice.address)) +
        (await qusd.balanceOf(bob.address)) +
        (await qusd.balanceOf(carol.address));
      expect(claimedSum).to.be.lessThanOrEqual(rewardAmt);
    });

    it("notifyRewardAmount reverts if rewards are NOT pre-funded (no mint path)", async function () {
      // Promise rewards without transferring any qUSD into the contract.
      await expect(staking.connect(distribution).notifyRewardAmount(ethers.parseEther("100")))
        .to.be.revertedWith("RnxStaking: provided reward too high (not pre-funded)");
    });
  });

  describe("only rewardsDistribution can notify", function () {
    it("reverts for owner, stakers, and random accounts", async function () {
      await qusd.connect(owner).mint(await staking.getAddress(), ethers.parseEther("700"));
      const amt = ethers.parseEther("700");
      await expect(staking.connect(owner).notifyRewardAmount(amt))
        .to.be.revertedWith("RnxStaking: caller is not rewardsDistribution");
      await expect(staking.connect(alice).notifyRewardAmount(amt))
        .to.be.revertedWith("RnxStaking: caller is not rewardsDistribution");
    });

    it("allows the rewardsDistribution role to notify once pre-funded", async function () {
      await qusd.connect(owner).mint(await staking.getAddress(), ethers.parseEther("700"));
      await expect(staking.connect(distribution).notifyRewardAmount(ethers.parseEther("700")))
        .to.emit(staking, "RewardAdded");
      expect(await staking.rewardRate()).to.be.greaterThan(0n);
    });
  });

  describe("no principal drain", function () {
    it("owner CANNOT recover the staking token (principal is untouchable)", async function () {
      const amt = ethers.parseEther("100");
      await fundWrnx(alice, amt);
      await wrnx.connect(alice).approve(await staking.getAddress(), amt);
      await staking.connect(alice).stake(amt);

      await expect(staking.connect(owner).recoverERC20(await wrnx.getAddress(), amt))
        .to.be.revertedWith("RnxStaking: cannot recover staking token");

      // Principal still fully held and still withdrawable by alice.
      expect(await wrnx.balanceOf(await staking.getAddress())).to.equal(amt);
      await staking.connect(alice).withdraw(amt);
      expect(await wrnx.balanceOf(alice.address)).to.equal(amt);
    });

    it("owner CAN recover a stray NON-staking token only", async function () {
      // Mint stray qUSD beyond what any reward period needs, send to contract.
      const stray = ethers.parseEther("5");
      await qusd.connect(owner).mint(await staking.getAddress(), stray);
      await expect(staking.connect(owner).recoverERC20(await qusd.getAddress(), stray))
        .to.emit(staking, "Recovered");
      expect(await qusd.balanceOf(owner.address)).to.equal(stray);
    });

    it("recoverERC20 is owner-gated", async function () {
      await expect(staking.connect(alice).recoverERC20(await qusd.getAddress(), 1n))
        .to.be.revertedWith("RnxStaking: caller is not owner");
    });
  });
});

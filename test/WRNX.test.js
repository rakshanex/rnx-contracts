// SPDX-License-Identifier: MIT
// Hardhat + ethers v6 + chai tests for WRNX (Wrapped RNX).
//
// Coverage: wrap/unwrap invariant, supply conservation, transfer, approve,
// transferFrom, insufficient balance, insufficient allowance, zero address,
// and event correctness.

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("WRNX", function () {
  let wrnx, deployer, alice, bob, carol;

  beforeEach(async function () {
    [deployer, alice, bob, carol] = await ethers.getSigners();
    const WRNX = await ethers.getContractFactory("WRNX");
    wrnx = await WRNX.deploy();
    await wrnx.waitForDeployment();
  });

  // ---- invariant helper -------------------------------------------------
  async function assertInvariant() {
    const supply = await wrnx.totalSupply();
    const bal = await ethers.provider.getBalance(await wrnx.getAddress());
    expect(supply).to.equal(bal, "invariant totalSupply == contract RNX balance broken");
  }

  describe("metadata", function () {
    it("exposes WETH-style metadata (name, symbol, 18 decimals)", async function () {
      expect(await wrnx.name()).to.equal("Wrapped RNX");
      expect(await wrnx.symbol()).to.equal("WRNX");
      expect(await wrnx.decimals()).to.equal(18n);
    });
  });

  describe("wrap / unwrap invariant", function () {
    it("deposit() mints 1:1 and emits Transfer(0->sender) + Deposit", async function () {
      const amt = ethers.parseEther("3");
      await expect(wrnx.connect(alice).deposit({ value: amt }))
        .to.emit(wrnx, "Transfer").withArgs(ethers.ZeroAddress, alice.address, amt)
        .and.to.emit(wrnx, "Deposit").withArgs(alice.address, amt);

      expect(await wrnx.balanceOf(alice.address)).to.equal(amt);
      expect(await wrnx.totalSupply()).to.equal(amt);
      await assertInvariant();
    });

    it("receive() (plain send) wraps native RNX", async function () {
      const amt = ethers.parseEther("1.5");
      await alice.sendTransaction({ to: await wrnx.getAddress(), value: amt });
      expect(await wrnx.balanceOf(alice.address)).to.equal(amt);
      await assertInvariant();
    });

    it("withdraw() burns 1:1, returns native RNX, emits Transfer(sender->0) + Withdrawal", async function () {
      const amt = ethers.parseEther("2");
      await wrnx.connect(alice).deposit({ value: amt });

      const before = await ethers.provider.getBalance(alice.address);
      const tx = await wrnx.connect(alice).withdraw(amt);
      const rc = await tx.wait();
      const gas = rc.gasUsed * rc.gasPrice;
      const after = await ethers.provider.getBalance(alice.address);

      expect(await wrnx.balanceOf(alice.address)).to.equal(0n);
      expect(await wrnx.totalSupply()).to.equal(0n);
      expect(after).to.equal(before + amt - gas);
      await assertInvariant();
    });

    it("emits Withdrawal event", async function () {
      const amt = ethers.parseEther("1");
      await wrnx.connect(alice).deposit({ value: amt });
      await expect(wrnx.connect(alice).withdraw(amt))
        .to.emit(wrnx, "Transfer").withArgs(alice.address, ethers.ZeroAddress, amt)
        .and.to.emit(wrnx, "Withdrawal").withArgs(alice.address, amt);
    });

    it("reverts withdraw on insufficient balance", async function () {
      await wrnx.connect(alice).deposit({ value: ethers.parseEther("1") });
      await expect(wrnx.connect(alice).withdraw(ethers.parseEther("2")))
        .to.be.revertedWith("WRNX: insufficient balance");
    });
  });

  describe("supply conservation", function () {
    it("holds invariant across interleaved deposits, transfers and withdrawals", async function () {
      await wrnx.connect(alice).deposit({ value: ethers.parseEther("5") });
      await assertInvariant();
      await wrnx.connect(bob).deposit({ value: ethers.parseEther("2") });
      await assertInvariant();
      await wrnx.connect(alice).transfer(carol.address, ethers.parseEther("1"));
      await assertInvariant();
      await wrnx.connect(alice).withdraw(ethers.parseEther("3"));
      await assertInvariant();

      // total supply == sum of balances
      const sum =
        (await wrnx.balanceOf(alice.address)) +
        (await wrnx.balanceOf(bob.address)) +
        (await wrnx.balanceOf(carol.address));
      expect(await wrnx.totalSupply()).to.equal(sum);
    });
  });

  describe("transfer", function () {
    beforeEach(async function () {
      await wrnx.connect(alice).deposit({ value: ethers.parseEther("10") });
    });

    it("moves tokens and emits Transfer", async function () {
      const amt = ethers.parseEther("4");
      await expect(wrnx.connect(alice).transfer(bob.address, amt))
        .to.emit(wrnx, "Transfer").withArgs(alice.address, bob.address, amt);
      expect(await wrnx.balanceOf(bob.address)).to.equal(amt);
      expect(await wrnx.balanceOf(alice.address)).to.equal(ethers.parseEther("6"));
    });

    it("reverts on insufficient balance", async function () {
      await expect(wrnx.connect(alice).transfer(bob.address, ethers.parseEther("11")))
        .to.be.revertedWith("WRNX: insufficient balance");
    });

    it("reverts on transfer to zero address", async function () {
      await expect(wrnx.connect(alice).transfer(ethers.ZeroAddress, 1n))
        .to.be.revertedWith("WRNX: transfer to zero address");
    });
  });

  describe("approve / allowance", function () {
    it("sets allowance and emits Approval", async function () {
      const amt = ethers.parseEther("7");
      await expect(wrnx.connect(alice).approve(bob.address, amt))
        .to.emit(wrnx, "Approval").withArgs(alice.address, bob.address, amt);
      expect(await wrnx.allowance(alice.address, bob.address)).to.equal(amt);
    });
  });

  describe("transferFrom", function () {
    beforeEach(async function () {
      await wrnx.connect(alice).deposit({ value: ethers.parseEther("10") });
    });

    it("spends allowance and transfers", async function () {
      await wrnx.connect(alice).approve(bob.address, ethers.parseEther("5"));
      const amt = ethers.parseEther("3");
      await expect(wrnx.connect(bob).transferFrom(alice.address, carol.address, amt))
        .to.emit(wrnx, "Transfer").withArgs(alice.address, carol.address, amt);
      expect(await wrnx.balanceOf(carol.address)).to.equal(amt);
      expect(await wrnx.allowance(alice.address, bob.address)).to.equal(ethers.parseEther("2"));
    });

    it("reverts on insufficient allowance", async function () {
      await wrnx.connect(alice).approve(bob.address, ethers.parseEther("1"));
      await expect(wrnx.connect(bob).transferFrom(alice.address, carol.address, ethers.parseEther("2")))
        .to.be.revertedWith("WRNX: insufficient allowance");
    });

    it("reverts on insufficient balance even with allowance", async function () {
      await wrnx.connect(alice).approve(bob.address, ethers.MaxUint256);
      await expect(wrnx.connect(bob).transferFrom(alice.address, carol.address, ethers.parseEther("11")))
        .to.be.revertedWith("WRNX: insufficient balance");
    });

    it("reverts on transfer to zero address", async function () {
      await wrnx.connect(alice).approve(bob.address, ethers.parseEther("5"));
      await expect(wrnx.connect(bob).transferFrom(alice.address, ethers.ZeroAddress, 1n))
        .to.be.revertedWith("WRNX: transfer to zero address");
    });

    it("infinite allowance (max uint) is not decremented", async function () {
      await wrnx.connect(alice).approve(bob.address, ethers.MaxUint256);
      await wrnx.connect(bob).transferFrom(alice.address, carol.address, ethers.parseEther("4"));
      expect(await wrnx.allowance(alice.address, bob.address)).to.equal(ethers.MaxUint256);
    });
  });

  describe("access control (negative)", function () {
    it("has no owner/mint/pause surface — mint-like paths are only deposit", async function () {
      // No `mint`, `owner`, or `pause` function should exist on the ABI.
      const fns = wrnx.interface.fragments
        .filter((f) => f.type === "function")
        .map((f) => f.name);
      expect(fns).to.not.include("mint");
      expect(fns).to.not.include("owner");
      expect(fns).to.not.include("pause");
    });
  });
});

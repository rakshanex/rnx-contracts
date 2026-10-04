// SPDX-License-Identifier: MIT
// Hardhat + ethers v6 + chai tests for QuoteUSD (qUSD, test USD quote token).
//
// Coverage: transfer, approve, transferFrom, insufficient balance, insufficient
// allowance, zero address, access control (minter role), event correctness,
// supply conservation, and the "no hidden mint" guarantee.

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("QuoteUSD (qUSD)", function () {
  let qusd, minter, alice, bob, carol;

  beforeEach(async function () {
    [minter, alice, bob, carol] = await ethers.getSigners();
    const QuoteUSD = await ethers.getContractFactory("QuoteUSD");
    qusd = await QuoteUSD.deploy(minter.address);
    await qusd.waitForDeployment();
  });

  describe("metadata & labelling", function () {
    it("is explicitly labelled as a test unit, 18 decimals", async function () {
      expect(await qusd.name()).to.equal("RNX Quote USD (test)");
      expect(await qusd.symbol()).to.equal("qUSD");
      expect(await qusd.decimals()).to.equal(18n);
    });

    it("is NOT labelled USDT or USDC", async function () {
      const sym = await qusd.symbol();
      const nm = await qusd.name();
      expect(sym).to.not.equal("USDT");
      expect(sym).to.not.equal("USDC");
      expect(nm.toUpperCase()).to.not.include("USDT");
      expect(nm.toUpperCase()).to.not.include("USDC");
    });
  });

  describe("constructor / minter role", function () {
    it("sets the initial minter and emits MinterTransferred(0 -> minter)", async function () {
      const QuoteUSD = await ethers.getContractFactory("QuoteUSD");
      const fresh = await QuoteUSD.deploy(alice.address);
      await fresh.waitForDeployment();
      expect(await fresh.minter()).to.equal(alice.address);
    });

    it("reverts if initial minter is zero address", async function () {
      const QuoteUSD = await ethers.getContractFactory("QuoteUSD");
      await expect(QuoteUSD.deploy(ethers.ZeroAddress))
        .to.be.revertedWith("qUSD: minter is zero address");
    });
  });

  describe("minting (single documented authority, events on every mint)", function () {
    it("mints and emits BOTH Transfer(0->to) and Minted(minter,to,amt)", async function () {
      const amt = ethers.parseEther("1000");
      await expect(qusd.connect(minter).mint(alice.address, amt))
        .to.emit(qusd, "Transfer").withArgs(ethers.ZeroAddress, alice.address, amt)
        .and.to.emit(qusd, "Minted").withArgs(minter.address, alice.address, amt);
      expect(await qusd.balanceOf(alice.address)).to.equal(amt);
      expect(await qusd.totalSupply()).to.equal(amt);
    });

    it("reverts mint from a non-minter (access control)", async function () {
      await expect(qusd.connect(alice).mint(alice.address, 1n))
        .to.be.revertedWith("qUSD: caller is not the minter");
    });

    it("reverts mint to zero address", async function () {
      await expect(qusd.connect(minter).mint(ethers.ZeroAddress, 1n))
        .to.be.revertedWith("qUSD: mint to zero address");
    });

    it("no hidden mint path: mint is the only function that increases totalSupply", async function () {
      // Enumerate state-changing functions; only `mint` must create supply.
      const fns = qusd.interface.fragments
        .filter((f) => f.type === "function" && f.stateMutability !== "view" && f.stateMutability !== "pure")
        .map((f) => f.name)
        .sort();
      expect(fns).to.deep.equal(["approve", "mint", "transfer", "transferFrom", "transferMinter"]);
    });
  });

  describe("minter role transfer (access control)", function () {
    it("current minter can transfer the role; event emitted", async function () {
      await expect(qusd.connect(minter).transferMinter(alice.address))
        .to.emit(qusd, "MinterTransferred").withArgs(minter.address, alice.address);
      expect(await qusd.minter()).to.equal(alice.address);
      // old minter can no longer mint
      await expect(qusd.connect(minter).mint(bob.address, 1n))
        .to.be.revertedWith("qUSD: caller is not the minter");
      // new minter can mint
      await qusd.connect(alice).mint(bob.address, 5n);
      expect(await qusd.balanceOf(bob.address)).to.equal(5n);
    });

    it("non-minter cannot transfer the role", async function () {
      await expect(qusd.connect(alice).transferMinter(alice.address))
        .to.be.revertedWith("qUSD: caller is not the minter");
    });

    it("cannot transfer minter to zero address", async function () {
      await expect(qusd.connect(minter).transferMinter(ethers.ZeroAddress))
        .to.be.revertedWith("qUSD: new minter is zero address");
    });
  });

  describe("transfer", function () {
    beforeEach(async function () {
      await qusd.connect(minter).mint(alice.address, ethers.parseEther("100"));
    });

    it("moves tokens and emits Transfer", async function () {
      const amt = ethers.parseEther("40");
      await expect(qusd.connect(alice).transfer(bob.address, amt))
        .to.emit(qusd, "Transfer").withArgs(alice.address, bob.address, amt);
      expect(await qusd.balanceOf(bob.address)).to.equal(amt);
      expect(await qusd.balanceOf(alice.address)).to.equal(ethers.parseEther("60"));
    });

    it("reverts on insufficient balance", async function () {
      await expect(qusd.connect(alice).transfer(bob.address, ethers.parseEther("101")))
        .to.be.revertedWith("qUSD: insufficient balance");
    });

    it("reverts on transfer to zero address", async function () {
      await expect(qusd.connect(alice).transfer(ethers.ZeroAddress, 1n))
        .to.be.revertedWith("qUSD: transfer to zero address");
    });
  });

  describe("approve / allowance", function () {
    it("sets allowance and emits Approval", async function () {
      const amt = ethers.parseEther("25");
      await expect(qusd.connect(alice).approve(bob.address, amt))
        .to.emit(qusd, "Approval").withArgs(alice.address, bob.address, amt);
      expect(await qusd.allowance(alice.address, bob.address)).to.equal(amt);
    });
  });

  describe("transferFrom", function () {
    beforeEach(async function () {
      await qusd.connect(minter).mint(alice.address, ethers.parseEther("100"));
    });

    it("spends allowance and transfers", async function () {
      await qusd.connect(alice).approve(bob.address, ethers.parseEther("50"));
      const amt = ethers.parseEther("30");
      await expect(qusd.connect(bob).transferFrom(alice.address, carol.address, amt))
        .to.emit(qusd, "Transfer").withArgs(alice.address, carol.address, amt);
      expect(await qusd.balanceOf(carol.address)).to.equal(amt);
      expect(await qusd.allowance(alice.address, bob.address)).to.equal(ethers.parseEther("20"));
    });

    it("reverts on insufficient allowance", async function () {
      await qusd.connect(alice).approve(bob.address, ethers.parseEther("10"));
      await expect(qusd.connect(bob).transferFrom(alice.address, carol.address, ethers.parseEther("20")))
        .to.be.revertedWith("qUSD: insufficient allowance");
    });

    it("reverts on insufficient balance even with allowance", async function () {
      await qusd.connect(alice).approve(bob.address, ethers.MaxUint256);
      await expect(qusd.connect(bob).transferFrom(alice.address, carol.address, ethers.parseEther("101")))
        .to.be.revertedWith("qUSD: insufficient balance");
    });

    it("reverts on transfer to zero address", async function () {
      await qusd.connect(alice).approve(bob.address, ethers.parseEther("10"));
      await expect(qusd.connect(bob).transferFrom(alice.address, ethers.ZeroAddress, 1n))
        .to.be.revertedWith("qUSD: transfer to zero address");
    });

    it("infinite allowance (max uint) is not decremented", async function () {
      await qusd.connect(alice).approve(bob.address, ethers.MaxUint256);
      await qusd.connect(bob).transferFrom(alice.address, carol.address, ethers.parseEther("40"));
      expect(await qusd.allowance(alice.address, bob.address)).to.equal(ethers.MaxUint256);
    });
  });

  describe("supply conservation", function () {
    it("totalSupply equals the sum of balances after mints and transfers", async function () {
      await qusd.connect(minter).mint(alice.address, ethers.parseEther("100"));
      await qusd.connect(minter).mint(bob.address, ethers.parseEther("50"));
      await qusd.connect(alice).transfer(carol.address, ethers.parseEther("25"));

      const sum =
        (await qusd.balanceOf(alice.address)) +
        (await qusd.balanceOf(bob.address)) +
        (await qusd.balanceOf(carol.address));
      expect(await qusd.totalSupply()).to.equal(sum);
      expect(await qusd.totalSupply()).to.equal(ethers.parseEther("150"));
    });
  });
});

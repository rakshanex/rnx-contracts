// SPDX-License-Identifier: MIT
// Hardhat + ethers v6 + chai tests for RNX governance contracts:
//   - RnxTimelock  (TimelockController-style delay queue)
//   - RnxMultisig  (M-of-N multisignature wallet)
//
// Scope: in-process Hardhat network only. No deployment to any live chain, no
// private keys, no real transactions. Uses only ephemeral test signers.

const { expect } = require("chai");
const { ethers } = require("hardhat");

const ZERO = ethers.ZeroAddress;
const SALT = ethers.ZeroHash;
const PRED = ethers.ZeroHash;

async function latestTime() {
  const block = await ethers.provider.getBlock("latest");
  return block.timestamp;
}

describe("RNX Governance", function () {
  // ======================================================================
  //                              RnxTimelock
  // ======================================================================
  describe("RnxTimelock (delay queue)", function () {
    const MIN_DELAY = 3600; // 1 hour
    let timelock, qusd;
    let admin, proposer, executor, outsider;

    beforeEach(async function () {
      [admin, proposer, executor, outsider] = await ethers.getSigners();

      const Timelock = await ethers.getContractFactory("RnxTimelock");
      timelock = await Timelock.deploy(MIN_DELAY, [proposer.address], [executor.address]);
      await timelock.waitForDeployment();

      // A target the timelock will own/drive: QuoteUSD minter role transfer.
      const QuoteUSD = await ethers.getContractFactory("QuoteUSD");
      // Give the timelock minter authority so it can drive privileged action.
      qusd = await QuoteUSD.deploy(await timelock.getAddress());
      await qusd.waitForDeployment();
    });

    it("enforces roles at construction (proposer & executor set)", async function () {
      const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
      const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();
      expect(await timelock.hasRole(PROPOSER_ROLE, proposer.address)).to.equal(true);
      expect(await timelock.hasRole(EXECUTOR_ROLE, executor.address)).to.equal(true);
      expect(await timelock.minDelay()).to.equal(BigInt(MIN_DELAY));
    });

    it("only a proposer can schedule", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 1n]);
      const eta = (await latestTime()) + MIN_DELAY + 10;
      await expect(
        timelock.connect(outsider).schedule(await qusd.getAddress(), 0, data, PRED, SALT, eta)
      ).to.be.revertedWith("RnxTimelock: missing role");
    });

    it("rejects scheduling with insufficient delay", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 1n]);
      const eta = (await latestTime()) + 10; // less than MIN_DELAY
      await expect(
        timelock.connect(proposer).schedule(await qusd.getAddress(), 0, data, PRED, SALT, eta)
      ).to.be.revertedWith("RnxTimelock: insufficient delay");
    });

    it("rejects execute BEFORE the delay has elapsed", async function () {
      const target = await qusd.getAddress();
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 100n]);
      const eta = (await latestTime()) + MIN_DELAY + 10;

      await timelock.connect(proposer).schedule(target, 0, data, PRED, SALT, eta);

      // No time advance -> not ready
      await expect(
        timelock.connect(executor).execute(target, 0, data, PRED, SALT)
      ).to.be.revertedWith("RnxTimelock: operation is not ready");
    });

    it("executes AFTER the delay has elapsed (privileged action succeeds)", async function () {
      const target = await qusd.getAddress();
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 100n]);
      const eta = (await latestTime()) + MIN_DELAY + 10;

      await timelock.connect(proposer).schedule(target, 0, data, PRED, SALT, eta);

      // advance time beyond eta
      await ethers.provider.send("evm_increaseTime", [MIN_DELAY + 20]);
      await ethers.provider.send("evm_mine", []);

      await expect(timelock.connect(executor).execute(target, 0, data, PRED, SALT))
        .to.emit(timelock, "CallExecuted");

      // The privileged action took effect: outsider received 100 qUSD.
      expect(await qusd.balanceOf(outsider.address)).to.equal(100n);
    });

    it("only an executor can execute", async function () {
      const target = await qusd.getAddress();
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 100n]);
      const eta = (await latestTime()) + MIN_DELAY + 10;

      await timelock.connect(proposer).schedule(target, 0, data, PRED, SALT, eta);
      await ethers.provider.send("evm_increaseTime", [MIN_DELAY + 20]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        timelock.connect(outsider).execute(target, 0, data, PRED, SALT)
      ).to.be.revertedWith("RnxTimelock: missing role");
    });

    it("supports cancel of a pending operation (and then it cannot execute)", async function () {
      const target = await qusd.getAddress();
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 100n]);
      const eta = (await latestTime()) + MIN_DELAY + 10;

      const id = await timelock.hashOperation(target, 0, data, PRED, SALT);
      await timelock.connect(proposer).schedule(target, 0, data, PRED, SALT, eta);
      expect(await timelock.isOperationPending(id)).to.equal(true);

      await expect(timelock.connect(proposer).cancel(id)).to.emit(timelock, "Cancelled");
      expect(await timelock.isOperation(id)).to.equal(false);

      // After cancel + time advance, execution still fails (op unset).
      await ethers.provider.send("evm_increaseTime", [MIN_DELAY + 20]);
      await ethers.provider.send("evm_mine", []);
      await expect(
        timelock.connect(executor).execute(target, 0, data, PRED, SALT)
      ).to.be.revertedWith("RnxTimelock: operation is not ready");
    });

    it("non-proposer cannot cancel", async function () {
      const target = await qusd.getAddress();
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 100n]);
      const eta = (await latestTime()) + MIN_DELAY + 10;
      const id = await timelock.hashOperation(target, 0, data, PRED, SALT);
      await timelock.connect(proposer).schedule(target, 0, data, PRED, SALT, eta);

      await expect(timelock.connect(outsider).cancel(id)).to.be.revertedWith(
        "RnxTimelock: missing role"
      );
    });

    it("prevents instant privileged action: no path executes without a prior scheduled+ready op", async function () {
      const target = await qusd.getAddress();
      const data = qusd.interface.encodeFunctionData("mint", [outsider.address, 100n]);
      // Never scheduled -> cannot execute.
      await expect(
        timelock.connect(executor).execute(target, 0, data, PRED, SALT)
      ).to.be.revertedWith("RnxTimelock: operation is not ready");
    });

    it("updateDelay is only reachable via the timelock itself", async function () {
      await expect(timelock.connect(admin).updateDelay(1)).to.be.revertedWith(
        "RnxTimelock: caller must be timelock"
      );
    });
  });

  // ======================================================================
  //                              RnxMultisig
  // ======================================================================
  describe("RnxMultisig (M-of-N)", function () {
    const M = 2; // threshold
    let multisig, qusd;
    let o1, o2, o3, outsider, recipient;

    beforeEach(async function () {
      [o1, o2, o3, outsider, recipient] = await ethers.getSigners();

      const Multisig = await ethers.getContractFactory("RnxMultisig");
      multisig = await Multisig.deploy([o1.address, o2.address, o3.address], M);
      await multisig.waitForDeployment();

      // Multisig owns the qUSD minter role (a privileged RNX role).
      const QuoteUSD = await ethers.getContractFactory("QuoteUSD");
      qusd = await QuoteUSD.deploy(await multisig.getAddress());
      await qusd.waitForDeployment();
    });

    it("sets owners and threshold at construction (3 owners, M=2)", async function () {
      const owners = await multisig.getOwners();
      expect(owners.length).to.equal(3);
      expect(await multisig.threshold()).to.equal(BigInt(M));
      expect(await multisig.isOwner(o1.address)).to.equal(true);
      expect(await multisig.isOwner(outsider.address)).to.equal(false);
    });

    it("rejects construction with invalid threshold (M > N)", async function () {
      const Multisig = await ethers.getContractFactory("RnxMultisig");
      await expect(Multisig.deploy([o1.address, o2.address], 3)).to.be.revertedWith(
        "RnxMultisig: invalid threshold"
      );
    });

    it("only owners may submit", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await expect(
        multisig.connect(outsider).submit(await qusd.getAddress(), 0, data)
      ).to.be.revertedWith("RnxMultisig: not an owner");
    });

    it("non-owner cannot confirm", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await multisig.connect(o1).submit(await qusd.getAddress(), 0, data);
      await expect(multisig.connect(outsider).confirm(0)).to.be.revertedWith(
        "RnxMultisig: not an owner"
      );
    });

    it("rejects execution below threshold (single confirmation)", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await multisig.connect(o1).submit(await qusd.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0); // only 1 of 2
      await expect(multisig.connect(o1).execute(0)).to.be.revertedWith(
        "RnxMultisig: insufficient confirmations"
      );
    });

    it("no single-owner execution: one owner cannot drive a privileged mint alone", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await multisig.connect(o1).submit(await qusd.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0);
      await expect(multisig.connect(o1).execute(0)).to.be.revertedWith(
        "RnxMultisig: insufficient confirmations"
      );
      // mint did not happen
      expect(await qusd.balanceOf(recipient.address)).to.equal(0n);
    });

    it("executes with M confirmations (privileged mint succeeds)", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await multisig.connect(o1).submit(await qusd.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0);
      await multisig.connect(o2).confirm(0); // reaches M=2

      await expect(multisig.connect(o2).execute(0)).to.emit(multisig, "Execute");
      expect(await qusd.balanceOf(recipient.address)).to.equal(50n);
    });

    it("revoke lowers confirmations below threshold and blocks execution", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await multisig.connect(o1).submit(await qusd.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0);
      await multisig.connect(o2).confirm(0);
      await multisig.connect(o2).revoke(0); // back to 1

      await expect(multisig.connect(o1).execute(0)).to.be.revertedWith(
        "RnxMultisig: insufficient confirmations"
      );
    });

    it("add owner ONLY via the multisig itself (direct call reverts)", async function () {
      await expect(multisig.connect(o1).addOwner(outsider.address)).to.be.revertedWith(
        "RnxMultisig: only via multisig"
      );
    });

    it("remove owner ONLY via the multisig itself (direct call reverts)", async function () {
      await expect(multisig.connect(o1).removeOwner(o3.address)).to.be.revertedWith(
        "RnxMultisig: only via multisig"
      );
    });

    it("adds an owner through an M-of-N self-call", async function () {
      const data = multisig.interface.encodeFunctionData("addOwner", [outsider.address]);
      await multisig.connect(o1).submit(await multisig.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0);
      await multisig.connect(o2).confirm(0);

      await expect(multisig.connect(o1).execute(0)).to.emit(multisig, "OwnerAdded");
      expect(await multisig.isOwner(outsider.address)).to.equal(true);
      expect(await multisig.ownerCount()).to.equal(4n);
    });

    it("removes an owner through an M-of-N self-call", async function () {
      const data = multisig.interface.encodeFunctionData("removeOwner", [o3.address]);
      await multisig.connect(o1).submit(await multisig.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0);
      await multisig.connect(o2).confirm(0);

      await expect(multisig.connect(o2).execute(0)).to.emit(multisig, "OwnerRemoved");
      expect(await multisig.isOwner(o3.address)).to.equal(false);
      expect(await multisig.ownerCount()).to.equal(2n);
    });

    it("cannot confirm the same tx twice", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await multisig.connect(o1).submit(await qusd.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0);
      await expect(multisig.connect(o1).confirm(0)).to.be.revertedWith(
        "RnxMultisig: already confirmed"
      );
    });

    it("cannot re-execute an executed tx (replay guard)", async function () {
      const data = qusd.interface.encodeFunctionData("mint", [recipient.address, 50n]);
      await multisig.connect(o1).submit(await qusd.getAddress(), 0, data);
      await multisig.connect(o1).confirm(0);
      await multisig.connect(o2).confirm(0);
      await multisig.connect(o1).execute(0);
      await expect(multisig.connect(o1).execute(0)).to.be.revertedWith(
        "RnxMultisig: tx already executed"
      );
    });
  });
});

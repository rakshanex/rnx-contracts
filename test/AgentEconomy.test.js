// SPDX-License-Identifier: MIT
// Hardhat + ethers v6 + chai tests for the AI Agent economy:
//   - AgentRegistry        (self-sovereign agent identity)
//   - AgentPaymentEscrow   (agent-to-agent / M2M WRNX escrow, pull-payment)
//
// SCOPE: local in-process tests ONLY. No deployment to any live network, no
// keys, no real money. WRNX is funded here by wrapping ephemeral Hardhat test
// RNX; qUSD is NOT used; chainId 194151 (future mainnet) is NOT targeted.
//
// Required coverage (per task):
//   register, duplicate-register revert, revoke by owner only,
//   non-owner revoke revert, escrow deposit, release to payee,
//   refund after expiry, reentrancy guard, no-admin-drain.

const { expect } = require("chai");
const { ethers } = require("hardhat");

const LABEL_A = ethers.encodeBytes32String("agent-a");
const LABEL_B = ethers.encodeBytes32String("agent-b");
const REF_1 = ethers.encodeBytes32String("invoice-1");
const ZERO32 = ethers.ZeroHash;

describe("AI Agent economy", function () {
  let deployer, owner, other, payer, payee;

  beforeEach(async function () {
    [deployer, owner, other, payer, payee] = await ethers.getSigners();
  });

  // =========================================================================
  //                            AgentRegistry
  // =========================================================================
  describe("AgentRegistry", function () {
    let registry;

    beforeEach(async function () {
      const Registry = await ethers.getContractFactory("AgentRegistry");
      registry = await Registry.deploy();
      await registry.waitForDeployment();
    });

    it("register: records owner, commitment, metadata and emits AgentRegistered", async function () {
      const commit = ethers.keccak256(ethers.toUtf8Bytes("veridex-commit"));
      const uri = "ipfs://agent-card-a";
      const expectedId = await registry.computeAgentId(owner.address, LABEL_A);

      await expect(registry.connect(owner).registerAgent(LABEL_A, commit, uri))
        .to.emit(registry, "AgentRegistered")
        .withArgs(expectedId, owner.address, commit, uri);

      const a = await registry.getAgent(expectedId);
      expect(a.owner).to.equal(owner.address);
      expect(a.veridexCommit).to.equal(commit);
      expect(a.metadataURI).to.equal(uri);
      expect(a.registered).to.equal(true);
      expect(a.revoked).to.equal(false);
      expect(await registry.isActive(expectedId)).to.equal(true);
      expect(await registry.ownerOf(expectedId)).to.equal(owner.address);
    });

    it("register: VERIDEX commitment is optional (bytes32(0) allowed)", async function () {
      const uri = "https://example.invalid/agent";
      await registry.connect(owner).registerAgent(LABEL_B, ZERO32, uri);
      const id = await registry.computeAgentId(owner.address, LABEL_B);
      const a = await registry.getAgent(id);
      expect(a.veridexCommit).to.equal(ZERO32);
      expect(a.registered).to.equal(true);
    });

    it("duplicate-register revert: same owner + label cannot re-register", async function () {
      await registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a");
      await expect(
        registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a2")
      ).to.be.revertedWith("AgentRegistry: already registered");
    });

    it("different owners may use the same label without colliding", async function () {
      await registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a");
      await registry.connect(other).registerAgent(LABEL_A, ZERO32, "ipfs://b");
      const idOwner = await registry.computeAgentId(owner.address, LABEL_A);
      const idOther = await registry.computeAgentId(other.address, LABEL_A);
      expect(idOwner).to.not.equal(idOther);
      expect(await registry.ownerOf(idOwner)).to.equal(owner.address);
      expect(await registry.ownerOf(idOther)).to.equal(other.address);
    });

    it("revoke by owner only: owner can revoke and emits AgentRevoked", async function () {
      await registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a");
      const id = await registry.computeAgentId(owner.address, LABEL_A);

      await expect(registry.connect(owner).revokeAgent(id))
        .to.emit(registry, "AgentRevoked")
        .withArgs(id, owner.address);

      expect(await registry.isActive(id)).to.equal(false);
      const a = await registry.getAgent(id);
      expect(a.revoked).to.equal(true);
    });

    it("non-owner revoke revert: a different EOA cannot revoke", async function () {
      await registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a");
      const id = await registry.computeAgentId(owner.address, LABEL_A);
      await expect(
        registry.connect(other).revokeAgent(id)
      ).to.be.revertedWith("AgentRegistry: not agent owner");
      expect(await registry.isActive(id)).to.equal(true);
    });

    it("no-admin-backdoor: deployer has no special revoke power", async function () {
      await registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a");
      const id = await registry.computeAgentId(owner.address, LABEL_A);
      await expect(
        registry.connect(deployer).revokeAgent(id)
      ).to.be.revertedWith("AgentRegistry: not agent owner");
    });

    it("revocation is one-way: cannot double-revoke and cannot re-register", async function () {
      await registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a");
      const id = await registry.computeAgentId(owner.address, LABEL_A);
      await registry.connect(owner).revokeAgent(id);

      await expect(
        registry.connect(owner).revokeAgent(id)
      ).to.be.revertedWith("AgentRegistry: already revoked");

      // id is never recycled even after revocation
      await expect(
        registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a-new")
      ).to.be.revertedWith("AgentRegistry: already registered");
    });

    it("owner-only mutations: only owner can set commitment / metadata", async function () {
      await registry.connect(owner).registerAgent(LABEL_A, ZERO32, "ipfs://a");
      const id = await registry.computeAgentId(owner.address, LABEL_A);
      const newCommit = ethers.keccak256(ethers.toUtf8Bytes("new-commit"));

      await expect(
        registry.connect(other).setVeridexCommitment(id, newCommit)
      ).to.be.revertedWith("AgentRegistry: not agent owner");
      await expect(
        registry.connect(other).setMetadataURI(id, "ipfs://evil")
      ).to.be.revertedWith("AgentRegistry: not agent owner");

      await expect(registry.connect(owner).setVeridexCommitment(id, newCommit))
        .to.emit(registry, "AgentCommitmentUpdated").withArgs(id, newCommit);
      await expect(registry.connect(owner).setMetadataURI(id, "ipfs://a2"))
        .to.emit(registry, "AgentMetadataUpdated").withArgs(id, "ipfs://a2");
    });
  });

  // =========================================================================
  //                          AgentPaymentEscrow
  // =========================================================================
  describe("AgentPaymentEscrow", function () {
    let wrnx, escrow;
    const AMOUNT = ethers.parseEther("5");

    async function futureDeadline(secondsAhead = 3600) {
      const now = (await ethers.provider.getBlock("latest")).timestamp;
      return BigInt(now + secondsAhead);
    }

    beforeEach(async function () {
      const WRNX = await ethers.getContractFactory("WRNX");
      wrnx = await WRNX.deploy();
      await wrnx.waitForDeployment();

      const Escrow = await ethers.getContractFactory("AgentPaymentEscrow");
      escrow = await Escrow.deploy();
      await escrow.waitForDeployment();

      // Fund the payer with WRNX by wrapping ephemeral test RNX.
      await wrnx.connect(payer).deposit({ value: AMOUNT });
      await wrnx.connect(payer).approve(await escrow.getAddress(), AMOUNT);
    });

    it("escrow deposit: pulls WRNX, stores Funded escrow, emits EscrowDeposited", async function () {
      const deadline = await futureDeadline();
      const escrowAddr = await escrow.getAddress();
      const id = await escrow.computeEscrowId(LABEL_A, LABEL_B, REF_1);

      await expect(
        escrow.connect(payer).deposit(
          await wrnx.getAddress(), payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
        )
      )
        .to.emit(escrow, "EscrowDeposited")
        .withArgs(
          id, payer.address, payee.address, await wrnx.getAddress(),
          LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
        );

      expect(await wrnx.balanceOf(escrowAddr)).to.equal(AMOUNT);
      const e = await escrow.getEscrow(id);
      expect(e.payer).to.equal(payer.address);
      expect(e.payee).to.equal(payee.address);
      expect(e.amount).to.equal(AMOUNT);
      expect(e.status).to.equal(1n); // Funded
    });

    it("escrow deposit revert: duplicate (fromAgent,toAgent,ref) cannot be re-created", async function () {
      const deadline = await futureDeadline();
      await escrow.connect(payer).deposit(
        await wrnx.getAddress(), payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
      );
      // top up allowance for the second attempt
      await wrnx.connect(payer).deposit({ value: AMOUNT });
      await wrnx.connect(payer).approve(await escrow.getAddress(), AMOUNT);
      await expect(
        escrow.connect(payer).deposit(
          await wrnx.getAddress(), payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
        )
      ).to.be.revertedWith("Escrow: already exists");
    });

    it("release to payee: only payer can release; funds become payee-withdrawable (pull)", async function () {
      const deadline = await futureDeadline();
      const wrnxAddr = await wrnx.getAddress();
      const id = await escrow.computeEscrowId(LABEL_A, LABEL_B, REF_1);
      await escrow.connect(payer).deposit(
        wrnxAddr, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
      );

      // non-payer cannot release
      await expect(escrow.connect(other).release(id)).to.be.revertedWith("Escrow: not payer");

      await expect(escrow.connect(payer).release(id))
        .to.emit(escrow, "EscrowReleased").withArgs(id, payee.address, AMOUNT);

      // pull-payment: payee has a withdrawable credit, not an auto-transfer
      expect(await escrow.withdrawable(wrnxAddr, payee.address)).to.equal(AMOUNT);
      expect(await wrnx.balanceOf(payee.address)).to.equal(0n);

      // payee pulls
      await expect(escrow.connect(payee).withdraw(wrnxAddr))
        .to.emit(escrow, "Withdrawn").withArgs(wrnxAddr, payee.address, AMOUNT);
      expect(await wrnx.balanceOf(payee.address)).to.equal(AMOUNT);
      expect(await escrow.withdrawable(wrnxAddr, payee.address)).to.equal(0n);
    });

    it("release revert: cannot release before funded / cannot double-release", async function () {
      const deadline = await futureDeadline();
      const wrnxAddr = await wrnx.getAddress();
      const id = await escrow.computeEscrowId(LABEL_A, LABEL_B, REF_1);
      await escrow.connect(payer).deposit(
        wrnxAddr, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
      );
      await escrow.connect(payer).release(id);
      await expect(escrow.connect(payer).release(id)).to.be.revertedWith("Escrow: not funded");
    });

    it("refund after expiry: before deadline reverts; after deadline funds return to payer (pull)", async function () {
      const deadline = await futureDeadline(1000);
      const wrnxAddr = await wrnx.getAddress();
      const id = await escrow.computeEscrowId(LABEL_A, LABEL_B, REF_1);
      await escrow.connect(payer).deposit(
        wrnxAddr, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
      );

      await expect(escrow.connect(payer).refund(id)).to.be.revertedWith("Escrow: not expired");

      // advance time past the deadline
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(deadline) + 1]);
      await ethers.provider.send("evm_mine", []);

      // permissionless trigger, but funds can only ever go back to the payer
      await expect(escrow.connect(other).refund(id))
        .to.emit(escrow, "EscrowRefunded").withArgs(id, payer.address, AMOUNT);
      expect(await escrow.withdrawable(wrnxAddr, payer.address)).to.equal(AMOUNT);

      await escrow.connect(payer).withdraw(wrnxAddr);
      expect(await wrnx.balanceOf(payer.address)).to.equal(AMOUNT);
    });

    it("release and refund are mutually exclusive (one-shot settlement)", async function () {
      const deadline = await futureDeadline(1000);
      const wrnxAddr = await wrnx.getAddress();
      const id = await escrow.computeEscrowId(LABEL_A, LABEL_B, REF_1);
      await escrow.connect(payer).deposit(
        wrnxAddr, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
      );
      await escrow.connect(payer).release(id);

      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(deadline) + 1]);
      await ethers.provider.send("evm_mine", []);
      await expect(escrow.connect(payer).refund(id)).to.be.revertedWith("Escrow: not funded");
    });

    it("reentrancy guard: a malicious token re-entering withdraw() is rejected", async function () {
      // Use a malicious ERC-20 that re-enters withdraw() during its transfer().
      const Reent = await ethers.getContractFactory("ReentrantToken");
      const bad = await Reent.deploy();
      await bad.waitForDeployment();
      const badAddr = await bad.getAddress();
      const escrowAddr = await escrow.getAddress();

      await bad.setEscrow(escrowAddr);
      // fund payer with the malicious token and approve the escrow
      await bad.mint(payer.address, AMOUNT);
      await bad.connect(payer).approve(escrowAddr, AMOUNT);

      const deadline = await futureDeadline();
      const id = await escrow.computeEscrowId(LABEL_A, LABEL_B, REF_1);
      await escrow.connect(payer).deposit(
        badAddr, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
      );
      await escrow.connect(payer).release(id);

      // Arm the attack: when the escrow pays the payee via transfer(), the token
      // re-enters withdraw(). The guard must make that inner call revert.
      await bad.setAttackOnTransfer(true);

      // The payee withdraw triggers transfer() -> re-entrant withdraw() -> revert
      // caught inside the token. Outer withdraw still succeeds exactly once.
      await escrow.connect(payee).withdraw(badAddr);

      expect(await bad.reentryAttempted()).to.equal(true);
      expect(await bad.reentryReverted()).to.equal(true);
      // No double-spend: escrow paid out exactly AMOUNT, holds 0, ledger zeroed.
      expect(await bad.balanceOf(payee.address)).to.equal(AMOUNT);
      expect(await bad.balanceOf(escrowAddr)).to.equal(0n);
      expect(await escrow.withdrawable(badAddr, payee.address)).to.equal(0n);
    });

    it("no-admin-drain: there is no owner/admin and no sweep of escrowed funds", async function () {
      const wrnxAddr = await wrnx.getAddress();
      const escrowAddr = await escrow.getAddress();
      const deadline = await futureDeadline();
      await escrow.connect(payer).deposit(
        wrnxAddr, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, deadline
      );

      // The contract exposes no owner()/admin()/sweep()/withdrawTo() surface.
      expect(escrow.interface.fragments.some((f) => f.type === "function" && f.name === "owner"))
        .to.equal(false);
      for (const banned of ["sweep", "drain", "rescue", "withdrawTo", "adminWithdraw", "mint", "setOwner"]) {
        expect(
          escrow.interface.fragments.some((f) => f.type === "function" && f.name === banned),
          `escrow must not expose ${banned}()`
        ).to.equal(false);
      }

      // Deployer cannot withdraw escrowed funds: it has no pull-balance.
      await expect(escrow.connect(deployer).withdraw(wrnxAddr))
        .to.be.revertedWith("Escrow: nothing to withdraw");
      // The escrowed WRNX is still fully held by the escrow (nothing drained).
      expect(await wrnx.balanceOf(escrowAddr)).to.equal(AMOUNT);
    });

    it("deposit input validation: rejects zero token/payee/amount and past deadline", async function () {
      const wrnxAddr = await wrnx.getAddress();
      const good = await futureDeadline();
      await expect(
        escrow.connect(payer).deposit(ethers.ZeroAddress, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, good)
      ).to.be.revertedWith("Escrow: token=0");
      await expect(
        escrow.connect(payer).deposit(wrnxAddr, ethers.ZeroAddress, LABEL_A, LABEL_B, REF_1, AMOUNT, good)
      ).to.be.revertedWith("Escrow: payee=0");
      await expect(
        escrow.connect(payer).deposit(wrnxAddr, payee.address, LABEL_A, LABEL_B, REF_1, 0n, good)
      ).to.be.revertedWith("Escrow: amount=0");
      const now = (await ethers.provider.getBlock("latest")).timestamp;
      await expect(
        escrow.connect(payer).deposit(wrnxAddr, payee.address, LABEL_A, LABEL_B, REF_1, AMOUNT, BigInt(now))
      ).to.be.revertedWith("Escrow: deadline in past");
    });
  });
});

// SPDX-License-Identifier: MIT
// Hardhat + ethers v6 + chai tests for AuditAnchor (AgentTrace anchoring bridge).
//
// Coverage:
//   - anchor() happy path: genesis + chained batch, state + event emission
//   - only-writer gating (revert NotWriter for non-writer sender)
//   - monotonic seq enforcement (wrong seq reverts; must use nextSeq)
//   - prevRoot hash-link enforcement (wrong prevRoot reverts)
//   - zero batchRoot rejected
//   - verifyInclusion() Merkle proof: valid proof true, tampered leaf false
//   - no admin/owner surface (no transfer / no pause present)
//
// No deployment to any live network: all tests run on the in-process Hardhat
// network. No private keys, no funds.

const { expect } = require("chai");
const { ethers } = require("hardhat");

const ZERO32 = ethers.ZeroHash;

describe("AuditAnchor", function () {
  let anchor, writer, outsider, other;

  beforeEach(async function () {
    [writer, outsider, other] = await ethers.getSigners();
    const AuditAnchor = await ethers.getContractFactory("AuditAnchor");
    anchor = await AuditAnchor.deploy(writer.address);
    await anchor.waitForDeployment();
  });

  describe("construction", function () {
    it("stores the immutable writer and starts at seq 0 with zero latestRoot", async function () {
      expect(await anchor.writer()).to.equal(writer.address);
      expect(await anchor.nextSeq()).to.equal(0n);
      expect(await anchor.latestRoot()).to.equal(ZERO32);
    });

    it("rejects a zero writer at construction", async function () {
      const AuditAnchor = await ethers.getContractFactory("AuditAnchor");
      await expect(AuditAnchor.deploy(ethers.ZeroAddress)).to.be.revertedWith("writer=0");
    });

    it("exposes no owner/admin/pause/transfer surface", async function () {
      // No admin backdoor beyond the immutable writer.
      expect(anchor.interface.hasFunction("owner")).to.equal(false);
      expect(anchor.interface.hasFunction("transferOwnership")).to.equal(false);
      expect(anchor.interface.hasFunction("pause")).to.equal(false);
      expect(anchor.interface.hasFunction("setWriter")).to.equal(false);
    });
  });

  describe("anchor()", function () {
    it("anchors the genesis batch (seq 0, prevRoot 0) and emits Anchored", async function () {
      const root0 = ethers.id("batch-0");
      // Emits the event (indexed seq/root/prevRoot checked precisely here; the
      // block-number arg is asserted via state below to stay deterministic).
      await expect(anchor.connect(writer).anchor(root0, ZERO32, 0))
        .to.emit(anchor, "Anchored");

      // Deterministic state assertions (block number independent).
      const [batchRoot, prevRoot, blockNumber] = await anchor.getBatch(0);
      expect(batchRoot).to.equal(root0);
      expect(prevRoot).to.equal(ZERO32);
      expect(blockNumber).to.be.gt(0n);
      expect(await anchor.latestRoot()).to.equal(root0);
      expect(await anchor.nextSeq()).to.equal(1n);
    });

    it("emits Anchored with the correct seq/root/prevRoot indexed args", async function () {
      const root0 = ethers.id("batch-0");
      const tx = await anchor.connect(writer).anchor(root0, ZERO32, 0);
      const receipt = await tx.wait();
      const ev = receipt.logs
        .map((l) => {
          try { return anchor.interface.parseLog(l); } catch { return null; }
        })
        .find((p) => p && p.name === "Anchored");
      expect(ev, "Anchored event not found").to.not.equal(undefined);
      expect(ev.args.seq).to.equal(0n);
      expect(ev.args.batchRoot).to.equal(root0);
      expect(ev.args.prevRoot).to.equal(ZERO32);
      expect(ev.args.blockNumber).to.be.gt(0n);
    });

    it("chains a second batch where prevRoot == previous batchRoot", async function () {
      const root0 = ethers.id("batch-0");
      const root1 = ethers.id("batch-1");
      await anchor.connect(writer).anchor(root0, ZERO32, 0);
      await anchor.connect(writer).anchor(root1, root0, 1);

      expect(await anchor.latestRoot()).to.equal(root1);
      expect(await anchor.nextSeq()).to.equal(2n);

      const [b0] = await anchor.getBatch(0);
      const [b1root, b1prev] = await anchor.getBatch(1);
      expect(b0).to.equal(root0);
      expect(b1root).to.equal(root1);
      expect(b1prev).to.equal(root0);
    });
  });

  describe("writer gating", function () {
    it("reverts NotWriter when a non-writer tries to anchor", async function () {
      const root0 = ethers.id("batch-0");
      await expect(anchor.connect(outsider).anchor(root0, ZERO32, 0))
        .to.be.revertedWithCustomError(anchor, "NotWriter");
      await expect(anchor.connect(other).anchor(root0, ZERO32, 0))
        .to.be.revertedWithCustomError(anchor, "NotWriter");
    });
  });

  describe("input + sequencing guards", function () {
    it("rejects a zero batchRoot", async function () {
      await expect(anchor.connect(writer).anchor(ZERO32, ZERO32, 0))
        .to.be.revertedWithCustomError(anchor, "ZeroBatchRoot");
    });

    it("enforces monotonic seq (must equal nextSeq)", async function () {
      const root0 = ethers.id("batch-0");
      // Skipping seq 0 and jumping to 1 must revert.
      await expect(anchor.connect(writer).anchor(root0, ZERO32, 1))
        .to.be.revertedWithCustomError(anchor, "NonMonotonicSeq")
        .withArgs(1n, 0n);

      await anchor.connect(writer).anchor(root0, ZERO32, 0);

      // Re-using seq 0 (replay) must revert.
      const root1 = ethers.id("batch-1");
      await expect(anchor.connect(writer).anchor(root1, root0, 0))
        .to.be.revertedWithCustomError(anchor, "NonMonotonicSeq")
        .withArgs(0n, 1n);
    });

    it("enforces the prevRoot hash-link", async function () {
      const root0 = ethers.id("batch-0");
      const root1 = ethers.id("batch-1");
      await anchor.connect(writer).anchor(root0, ZERO32, 0);

      // Wrong prevRoot (should be root0) must revert.
      await expect(anchor.connect(writer).anchor(root1, ethers.id("wrong"), 1))
        .to.be.revertedWithCustomError(anchor, "PrevRootMismatch")
        .withArgs(ethers.id("wrong"), root0);
    });
  });

  describe("verifyInclusion() Merkle proof", function () {
    // Build a tiny Merkle tree with the same sorted-pair keccak256 convention
    // the contract uses, so an independent verifier can confirm membership.
    function hashPair(a, b) {
      const [x, y] = a <= b ? [a, b] : [b, a];
      return ethers.keccak256(ethers.concat([x, y]));
    }

    it("accepts a valid proof and rejects a tampered leaf", async function () {
      // Four leaves (canonical event hashes).
      const leaves = ["e0", "e1", "e2", "e3"].map((s) => ethers.id(s));
      // Level 1
      const n01 = hashPair(leaves[0], leaves[1]);
      const n23 = hashPair(leaves[2], leaves[3]);
      // Root
      const root = hashPair(n01, n23);

      // Proof for leaf e0: sibling e1, then sibling n23.
      const proof = [leaves[1], n23];
      expect(await anchor.verifyInclusion(proof, root, leaves[0])).to.equal(true);

      // Tampered leaf must fail.
      const tampered = ethers.id("e0-tampered");
      expect(await anchor.verifyInclusion(proof, root, tampered)).to.equal(false);

      // Wrong proof must fail.
      expect(await anchor.verifyInclusion([leaves[2], n23], root, leaves[0])).to.equal(false);
    });
  });
});

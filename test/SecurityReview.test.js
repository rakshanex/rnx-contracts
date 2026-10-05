// Targeted adversarial security review — money-sensitive contracts (pre-merge).
// AgentPaymentEscrow · RnxStaking · DEX (RnxPair/Router). No deploy; local hardhat.
const { expect } = require("chai");
const { ethers } = require("hardhat");

async function mintToken(name, sym) {
  const T = await ethers.getContractFactory("TestERC20");
  return T.deploy(name, sym);
}

describe("SECURITY: AgentPaymentEscrow money-safety", function () {
  let tok, esc, payer, payee, attacker;
  beforeEach(async () => {
    [payer, payee, attacker] = await ethers.getSigners();
    tok = await mintToken("TestWRNX", "tWRNX");
    await tok.mint(payer.address, 1000n);
    const E = await ethers.getContractFactory("AgentPaymentEscrow");
    esc = await E.deploy();
    await tok.connect(payer).approve(await esc.getAddress(), 1000n);
  });

  it("funds held exactly; release credits only payee; no double release", async () => {
    const dl = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    const id = await esc.connect(payer).deposit.staticCall(
      await tok.getAddress(), payee.address, ethers.id("A"), ethers.id("B"), ethers.id("ref"), 100n, dl);
    await esc.connect(payer).deposit(await tok.getAddress(), payee.address, ethers.id("A"), ethers.id("B"), ethers.id("ref"), 100n, dl);
    expect(await tok.balanceOf(await esc.getAddress())).to.equal(100n);
    await esc.connect(payer).release(id);
    // double release must fail
    await expect(esc.connect(payer).release(id)).to.be.reverted;
    // payee pulls exactly 100, nobody else can
    await esc.connect(payee).withdraw(await tok.getAddress());
    expect(await tok.balanceOf(payee.address)).to.equal(100n);
  });

  it("attacker cannot release or refund someone else's escrow", async () => {
    const dl = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    const id = await esc.connect(payer).deposit.staticCall(
      await tok.getAddress(), payee.address, ethers.id("A"), ethers.id("B"), ethers.id("ref"), 100n, dl);
    await esc.connect(payer).deposit(await tok.getAddress(), payee.address, ethers.id("A"), ethers.id("B"), ethers.id("ref"), 100n, dl);
    await expect(esc.connect(attacker).release(id)).to.be.reverted;      // not payer
    await expect(esc.connect(attacker).refund(id)).to.be.reverted;       // not expired
  });

  it("refund returns funds ONLY to payer after expiry (not to anyone else)", async () => {
    const dl = (await ethers.provider.getBlock("latest")).timestamp + 2;
    const id = await esc.connect(payer).deposit.staticCall(
      await tok.getAddress(), payee.address, ethers.id("A"), ethers.id("B"), ethers.id("ref"), 100n, dl);
    await esc.connect(payer).deposit(await tok.getAddress(), payee.address, ethers.id("A"), ethers.id("B"), ethers.id("ref"), 100n, dl);
    await ethers.provider.send("evm_increaseTime", [5]); await ethers.provider.send("evm_mine", []);
    await esc.connect(attacker).refund(id);           // refund is permissionless after expiry...
    await esc.connect(payer).withdraw(await tok.getAddress());  // ...but credits ONLY payer
    expect(await tok.balanceOf(payer.address)).to.equal(1000n); // got everything back
    expect(await tok.balanceOf(attacker.address)).to.equal(0n);
  });
});

describe("SECURITY: RnxStaking fund-safety", function () {
  let stake, reward, st, owner, dist, a, b;
  beforeEach(async () => {
    [owner, dist, a, b] = await ethers.getSigners();
    stake = await mintToken("Stake", "STK");
    reward = await mintToken("Reward", "RWD");
    const S = await ethers.getContractFactory("RnxStaking");
    st = await S.deploy(owner.address, dist.address, await stake.getAddress(), await reward.getAddress());
    for (const u of [a, b]) { await stake.mint(u.address, 1000n); await stake.connect(u).approve(await st.getAddress(), 1000n); }
  });

  it("notifyRewardAmount reverts if rewards not pre-funded (solvency)", async () => {
    await expect(st.connect(dist).notifyRewardAmount(100000000n)).to.be.reverted; // >duration, nothing funded
  });

  it("reward paid never exceeds funded; principal not drainable by others", async () => {
    await reward.mint(await st.getAddress(), 100000000n);      // pre-fund
    await st.connect(dist).notifyRewardAmount(100000000n);
    await st.connect(a).stake(100n);
    await ethers.provider.send("evm_increaseTime", [1000]); await ethers.provider.send("evm_mine", []);
    const earned = await st.earned(a.address);
    expect(earned).to.be.lte(100000000n);                    // never more than funded
    await st.connect(a).getReward();
    // b cannot withdraw a's stake
    await expect(st.connect(b).withdraw(100n)).to.be.reverted;
    // a gets exactly their principal back
    await st.connect(a).withdraw(100n);
    expect(await stake.balanceOf(a.address)).to.equal(1000n);
  });

  it("only rewardsDistribution can notify; owner cannot drain staked principal", async () => {
    await reward.mint(await st.getAddress(), 100000000n);
    await expect(st.connect(a).notifyRewardAmount(100000000n)).to.be.reverted;   // not distribution
    await st.connect(a).stake(500n);
    // recoverERC20 must refuse the staking token
    await expect(st.connect(owner).recoverERC20(await stake.getAddress(), 500n)).to.be.reverted;
  });
});

describe("SECURITY: DEX k-invariant", function () {
  it("swap cannot extract value for free (k never decreases)", async () => {
    const [u] = await ethers.getSigners();
    const t0 = await mintToken("T0", "T0"); const t1 = await mintToken("T1", "T1");
    const F = await ethers.getContractFactory("RnxFactory");
    const factory = await F.deploy();
    await factory.createPair(await t0.getAddress(), await t1.getAddress());
    const pairAddr = await factory.getPair(await t0.getAddress(), await t1.getAddress());
    const pair = await ethers.getContractAt("RnxPair", pairAddr);
    await t0.mint(u.address, 1000000n); await t1.mint(u.address, 1000000n);
    await t0.transfer(pairAddr, 100000n); await t1.transfer(pairAddr, 100000n);
    await pair.mint(u.address);
    const [r0a, r1a] = await pair.getReserves();
    const kBefore = r0a * r1a;
    // honest swap: send input, take correct output
    await t0.transfer(pairAddr, 1000n);
    // compute output via router formula 0.3% fee
    const amtOut = (1000n * 997n * r1a) / (r0a * 1000n + 1000n * 997n);
    await pair.swap(0n, amtOut, u.address, "0x");
    const [r0b, r1b] = await pair.getReserves();
    expect(r0b * r1b).to.be.gte(kBefore); // k preserved/grew
    // greedy swap (take too much) must revert (K check)
    await t0.transfer(pairAddr, 1000n);
    await expect(pair.swap(0n, amtOut * 3n, u.address, "0x")).to.be.reverted;
  });
});

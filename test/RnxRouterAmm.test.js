// SPDX-License-Identifier: MIT
// Hardhat + ethers v6 + chai tests for the RNX constant-product AMM
// (RnxFactory + RnxPair + RnxRouter).
//
// Coverage (per task spec):
//   - addLiquidity (first + subsequent provision, ratio enforcement)
//   - removeLiquidity (pro-rata return)
//   - swap output == router.getAmountOut (0.3% fee), exact
//   - constant-product k invariant preserved / increases
//   - slippage: swapExactTokensForTokens min-out revert
//   - slippage: swapTokensForExactTokens max-in revert
//   - deadline revert
//   - reentrancy guard (lock modifier) blocks re-entry into swap()
//   - LP mint/burn accounting
//   - MINIMUM_LIQUIDITY lock
//   - factory: one pair per token-pair, getPair symmetry, allPairs
//
// SCOPE: local in-process hardhat network ONLY. No deploy to any live chain,
// no keys, no real transactions. Uses freely-mintable TestERC20 helpers so the
// suite never asserts a real-world price or seeds real liquidity. qUSD is a
// TEST asset (not USDT/USDC); amounts here are synthetic.

const { expect } = require("chai");
const { ethers } = require("hardhat");

const MAX_UINT = ethers.MaxUint256;
const MINIMUM_LIQUIDITY = 1000n;

// integer sqrt (matches the on-chain Babylonian method result for our inputs)
function isqrt(value) {
  if (value < 0n) throw new Error("negative");
  if (value < 2n) return value;
  let x0 = value / 2n;
  let x1 = (x0 + value / x0) / 2n;
  while (x1 < x0) {
    x0 = x1;
    x1 = (x0 + value / x0) / 2n;
  }
  return x0;
}

async function futureDeadline(secondsAhead = 3600) {
  const block = await ethers.provider.getBlock("latest");
  return BigInt(block.timestamp) + BigInt(secondsAhead);
}

describe("RNX AMM (RnxFactory / RnxPair / RnxRouter)", function () {
  let deployer, lp, trader, other;
  let factory, router;
  let tokenA, tokenB;

  async function deployTokens() {
    const TestERC20 = await ethers.getContractFactory("TestERC20");
    const t1 = await TestERC20.deploy("Mock WRNX", "mWRNX");
    const t2 = await TestERC20.deploy("Mock qUSD", "mqUSD");
    await t1.waitForDeployment();
    await t2.waitForDeployment();
    return [t1, t2];
  }

  beforeEach(async function () {
    [deployer, lp, trader, other] = await ethers.getSigners();

    const RnxFactory = await ethers.getContractFactory("RnxFactory");
    factory = await RnxFactory.deploy();
    await factory.waitForDeployment();

    const RnxRouter = await ethers.getContractFactory("RnxRouter");
    router = await RnxRouter.deploy(await factory.getAddress());
    await router.waitForDeployment();

    [tokenA, tokenB] = await deployTokens();
  });

  // ----------------------------------------------------------------------
  //                               Factory
  // ----------------------------------------------------------------------
  describe("RnxFactory", function () {
    it("creates one pair per token-pair with symmetric getPair + allPairs", async function () {
      const a = await tokenA.getAddress();
      const b = await tokenB.getAddress();

      expect(await factory.allPairsLength()).to.equal(0n);
      await expect(factory.createPair(a, b)).to.emit(factory, "PairCreated");

      const pair = await factory.getPair(a, b);
      expect(pair).to.not.equal(ethers.ZeroAddress);
      expect(await factory.getPair(b, a)).to.equal(pair); // symmetric
      expect(await factory.allPairsLength()).to.equal(1n);
      expect(await factory.allPairs(0)).to.equal(pair);
    });

    it("reverts on identical addresses and on duplicate pair", async function () {
      const a = await tokenA.getAddress();
      const b = await tokenB.getAddress();
      await expect(factory.createPair(a, a)).to.be.revertedWith("RnxFactory: IDENTICAL_ADDRESSES");
      await factory.createPair(a, b);
      await expect(factory.createPair(a, b)).to.be.revertedWith("RnxFactory: PAIR_EXISTS");
      await expect(factory.createPair(b, a)).to.be.revertedWith("RnxFactory: PAIR_EXISTS");
    });

    it("orders token0 < token1", async function () {
      const a = await tokenA.getAddress();
      const b = await tokenB.getAddress();
      await factory.createPair(a, b);
      const RnxPair = await ethers.getContractFactory("RnxPair");
      const pair = RnxPair.attach(await factory.getPair(a, b));
      const t0 = await pair.token0();
      const t1 = await pair.token1();
      expect(BigInt(t0)).to.be.lessThan(BigInt(t1));
    });
  });

  // ----------------------------------------------------------------------
  //                          Liquidity provision
  // ----------------------------------------------------------------------
  describe("addLiquidity / MINIMUM_LIQUIDITY / LP accounting", function () {
    const amountA = ethers.parseEther("1000");
    const amountB = ethers.parseEther("4000");

    beforeEach(async function () {
      await tokenA.mint(lp.address, amountA);
      await tokenB.mint(lp.address, amountB);
      await tokenA.connect(lp).approve(await router.getAddress(), MAX_UINT);
      await tokenB.connect(lp).approve(await router.getAddress(), MAX_UINT);
    });

    it("first provision mints sqrt(a*b) - MINIMUM_LIQUIDITY and locks MINIMUM_LIQUIDITY", async function () {
      const dl = await futureDeadline();
      await router.connect(lp).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        amountA, amountB, 0, 0, lp.address, dl
      );

      const RnxPair = await ethers.getContractFactory("RnxPair");
      const pair = RnxPair.attach(await factory.getPair(await tokenA.getAddress(), await tokenB.getAddress()));

      const expectedTotal = isqrt(amountA * amountB);
      const expectedLp = expectedTotal - MINIMUM_LIQUIDITY;

      expect(await pair.totalSupply()).to.equal(expectedTotal);
      expect(await pair.balanceOf(lp.address)).to.equal(expectedLp);
      // MINIMUM_LIQUIDITY permanently locked at the zero address
      expect(await pair.balanceOf(ethers.ZeroAddress)).to.equal(MINIMUM_LIQUIDITY);
      expect(await pair.MINIMUM_LIQUIDITY()).to.equal(MINIMUM_LIQUIDITY);
    });

    it("reflects reserves after provision", async function () {
      const dl = await futureDeadline();
      await router.connect(lp).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        amountA, amountB, 0, 0, lp.address, dl
      );
      const [rA, rB] = await router.getReserves(await tokenA.getAddress(), await tokenB.getAddress());
      expect(rA).to.equal(amountA);
      expect(rB).to.equal(amountB);
    });

    it("second provision mints proportional LP and enforces ratio via quote()", async function () {
      const dl = await futureDeadline();
      await router.connect(lp).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        amountA, amountB, 0, 0, lp.address, dl
      );
      const RnxPair = await ethers.getContractFactory("RnxPair");
      const pair = RnxPair.attach(await factory.getPair(await tokenA.getAddress(), await tokenB.getAddress()));
      const supplyBefore = await pair.totalSupply();

      const addA = ethers.parseEther("500");
      const addBDesired = ethers.parseEther("5000"); // excess; router uses optimal 2000
      await tokenA.mint(lp.address, addA);
      await tokenB.mint(lp.address, addBDesired);

      const dl2 = await futureDeadline();
      await router.connect(lp).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        addA, addBDesired, 0, 0, lp.address, dl2
      );

      const rA = amountA, rB = amountB;
      const addBUsed = (addA * rB) / rA;
      expect(addBUsed).to.equal(ethers.parseEther("2000"));

      const expectedMinted = (addA * supplyBefore) / rA;
      const lpBal = await pair.balanceOf(lp.address);
      expect(lpBal).to.equal((supplyBefore - MINIMUM_LIQUIDITY) + expectedMinted);
    });

    it("enforces amountMin slippage on provisioning", async function () {
      const dl = await futureDeadline();
      await router.connect(lp).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        amountA, amountB, 0, 0, lp.address, dl
      );
      const addA = ethers.parseEther("500");
      await tokenA.mint(lp.address, addA);
      await tokenB.mint(lp.address, ethers.parseEther("1000"));
      const dl2 = await futureDeadline();
      // desired B (1000) < optimal B for 500 A (2000) => router takes the other
      // branch (optimal A for 1000 B = 250) and checks amountAMin (400 > 250).
      await expect(
        router.connect(lp).addLiquidity(
          await tokenA.getAddress(), await tokenB.getAddress(),
          addA, ethers.parseEther("1000"),
          ethers.parseEther("400"), 0,
          lp.address, dl2
        )
      ).to.be.revertedWith("RnxRouter: INSUFFICIENT_A_AMOUNT");
    });
  });

  // ----------------------------------------------------------------------
  //                          removeLiquidity
  // ----------------------------------------------------------------------
  describe("removeLiquidity", function () {
    const amountA = ethers.parseEther("1000");
    const amountB = ethers.parseEther("4000");
    let pair;

    beforeEach(async function () {
      await tokenA.mint(lp.address, amountA);
      await tokenB.mint(lp.address, amountB);
      await tokenA.connect(lp).approve(await router.getAddress(), MAX_UINT);
      await tokenB.connect(lp).approve(await router.getAddress(), MAX_UINT);
      const dl = await futureDeadline();
      await router.connect(lp).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        amountA, amountB, 0, 0, lp.address, dl
      );
      const RnxPair = await ethers.getContractFactory("RnxPair");
      pair = RnxPair.attach(await factory.getPair(await tokenA.getAddress(), await tokenB.getAddress()));
    });

    it("burns LP and returns proportional reserves (pro-rata accounting)", async function () {
      const lpBal = await pair.balanceOf(lp.address);
      const totalSupply = await pair.totalSupply();

      const expA = (lpBal * amountA) / totalSupply;
      const expB = (lpBal * amountB) / totalSupply;

      await pair.connect(lp).approve(await router.getAddress(), MAX_UINT);
      const dl = await futureDeadline();

      const beforeA = await tokenA.balanceOf(lp.address);
      const beforeB = await tokenB.balanceOf(lp.address);
      await router.connect(lp).removeLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        lpBal, 0, 0, lp.address, dl
      );
      const afterA = await tokenA.balanceOf(lp.address);
      const afterB = await tokenB.balanceOf(lp.address);

      expect(afterA - beforeA).to.equal(expA);
      expect(afterB - beforeB).to.equal(expB);
      expect(await pair.balanceOf(lp.address)).to.equal(0n);
      // MINIMUM_LIQUIDITY stays locked -> pool never fully drained
      expect(await pair.totalSupply()).to.equal(MINIMUM_LIQUIDITY);
    });

    it("reverts when returned amount is below the minimum (slippage)", async function () {
      const lpBal = await pair.balanceOf(lp.address);
      await pair.connect(lp).approve(await router.getAddress(), MAX_UINT);
      const dl = await futureDeadline();
      await expect(
        router.connect(lp).removeLiquidity(
          await tokenA.getAddress(), await tokenB.getAddress(),
          lpBal, amountA + 1n, 0, lp.address, dl
        )
      ).to.be.revertedWith("RnxRouter: INSUFFICIENT_A_AMOUNT");
    });
  });

  // ----------------------------------------------------------------------
  //                 swaps: output == getAmountOut, k invariant
  // ----------------------------------------------------------------------
  describe("swaps + 0.3% fee + k invariant", function () {
    const resA = ethers.parseEther("1000");
    const resB = ethers.parseEther("4000");
    let pair, aAddr, bAddr;

    beforeEach(async function () {
      aAddr = await tokenA.getAddress();
      bAddr = await tokenB.getAddress();
      await tokenA.mint(lp.address, resA);
      await tokenB.mint(lp.address, resB);
      await tokenA.connect(lp).approve(await router.getAddress(), MAX_UINT);
      await tokenB.connect(lp).approve(await router.getAddress(), MAX_UINT);
      const dl = await futureDeadline();
      await router.connect(lp).addLiquidity(aAddr, bAddr, resA, resB, 0, 0, lp.address, dl);
      const RnxPair = await ethers.getContractFactory("RnxPair");
      pair = RnxPair.attach(await factory.getPair(aAddr, bAddr));
    });

    it("swapExactTokensForTokens delivers exactly getAmountOut (0.3% fee)", async function () {
      const amountIn = ethers.parseEther("10");
      await tokenA.mint(trader.address, amountIn);
      await tokenA.connect(trader).approve(await router.getAddress(), MAX_UINT);

      const [rIn, rOut] = await router.getReserves(aAddr, bAddr);
      const quoted = await router.getAmountOut(amountIn, rIn, rOut);

      const amountInWithFee = amountIn * 997n;
      const expected = (amountInWithFee * rOut) / (rIn * 1000n + amountInWithFee);
      expect(quoted).to.equal(expected);

      const beforeOut = await tokenB.balanceOf(trader.address);
      const dl = await futureDeadline();
      await router.connect(trader).swapExactTokensForTokens(
        amountIn, 0, aAddr, bAddr, trader.address, dl
      );
      const afterOut = await tokenB.balanceOf(trader.address);
      expect(afterOut - beforeOut).to.equal(quoted);
    });

    it("preserves/increases the constant product k across a swap", async function () {
      const [r0Before, r1Before] = await pair.getReserves();
      const kBefore = r0Before * r1Before;

      const amountIn = ethers.parseEther("25");
      await tokenA.mint(trader.address, amountIn);
      await tokenA.connect(trader).approve(await router.getAddress(), MAX_UINT);
      const dl = await futureDeadline();
      await router.connect(trader).swapExactTokensForTokens(amountIn, 0, aAddr, bAddr, trader.address, dl);

      const [r0After, r1After] = await pair.getReserves();
      const kAfter = r0After * r1After;
      // with a positive fee, k must strictly grow
      expect(kAfter).to.be.greaterThan(kBefore);
    });

    it("swapTokensForExactTokens pulls exactly getAmountIn", async function () {
      const amountOut = ethers.parseEther("100");
      const [rIn, rOut] = await router.getReserves(aAddr, bAddr);
      const quotedIn = await router.getAmountIn(amountOut, rIn, rOut);

      await tokenA.mint(trader.address, quotedIn);
      await tokenA.connect(trader).approve(await router.getAddress(), MAX_UINT);

      const beforeIn = await tokenA.balanceOf(trader.address);
      const beforeOut = await tokenB.balanceOf(trader.address);
      const dl = await futureDeadline();
      await router.connect(trader).swapTokensForExactTokens(
        amountOut, quotedIn, aAddr, bAddr, trader.address, dl
      );
      const afterIn = await tokenA.balanceOf(trader.address);
      const afterOut = await tokenB.balanceOf(trader.address);

      expect(beforeIn - afterIn).to.equal(quotedIn);
      expect(afterOut - beforeOut).to.equal(amountOut);
    });

    it("quote() returns the no-fee ratio amount", async function () {
      const q = await router.quote(ethers.parseEther("10"), resA, resB);
      expect(q).to.equal(ethers.parseEther("40")); // 10 * 4000/1000
    });

    // ---------------- slippage ----------------
    it("swapExactTokensForTokens reverts when output < amountOutMin", async function () {
      const amountIn = ethers.parseEther("10");
      await tokenA.mint(trader.address, amountIn);
      await tokenA.connect(trader).approve(await router.getAddress(), MAX_UINT);
      const [rIn, rOut] = await router.getReserves(aAddr, bAddr);
      const quoted = await router.getAmountOut(amountIn, rIn, rOut);
      const dl = await futureDeadline();
      await expect(
        router.connect(trader).swapExactTokensForTokens(
          amountIn, quoted + 1n, aAddr, bAddr, trader.address, dl
        )
      ).to.be.revertedWith("RnxRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    });

    it("swapTokensForExactTokens reverts when input > amountInMax", async function () {
      const amountOut = ethers.parseEther("100");
      const [rIn, rOut] = await router.getReserves(aAddr, bAddr);
      const quotedIn = await router.getAmountIn(amountOut, rIn, rOut);
      await tokenA.mint(trader.address, quotedIn);
      await tokenA.connect(trader).approve(await router.getAddress(), MAX_UINT);
      const dl = await futureDeadline();
      await expect(
        router.connect(trader).swapTokensForExactTokens(
          amountOut, quotedIn - 1n, aAddr, bAddr, trader.address, dl
        )
      ).to.be.revertedWith("RnxRouter: EXCESSIVE_INPUT_AMOUNT");
    });

    // ---------------- deadline ----------------
    it("reverts a swap whose deadline has passed", async function () {
      const amountIn = ethers.parseEther("1");
      await tokenA.mint(trader.address, amountIn);
      await tokenA.connect(trader).approve(await router.getAddress(), MAX_UINT);
      const block = await ethers.provider.getBlock("latest");
      const past = BigInt(block.timestamp) - 1n;
      await expect(
        router.connect(trader).swapExactTokensForTokens(amountIn, 0, aAddr, bAddr, trader.address, past)
      ).to.be.revertedWith("RnxRouter: EXPIRED");
    });

    it("reverts addLiquidity whose deadline has passed", async function () {
      await tokenA.mint(lp.address, 1n);
      await tokenB.mint(lp.address, 1n);
      const block = await ethers.provider.getBlock("latest");
      const past = BigInt(block.timestamp) - 1n;
      await expect(
        router.connect(lp).addLiquidity(aAddr, bAddr, 1n, 1n, 0, 0, lp.address, past)
      ).to.be.revertedWith("RnxRouter: EXPIRED");
    });
  });

  // ----------------------------------------------------------------------
  //                        Reentrancy guard (lock)
  // ----------------------------------------------------------------------
  describe("reentrancy guard (lock modifier)", function () {
    it("blocks re-entry into swap() during the flash-swap callback", async function () {
      const TestERC20 = await ethers.getContractFactory("TestERC20");
      const t1 = await TestERC20.deploy("Flash A", "FA");
      const t2 = await TestERC20.deploy("Flash B", "FB");
      await t1.waitForDeployment();
      await t2.waitForDeployment();

      await factory.createPair(await t1.getAddress(), await t2.getAddress());
      const RnxPair = await ethers.getContractFactory("RnxPair");
      const pair = RnxPair.attach(await factory.getPair(await t1.getAddress(), await t2.getAddress()));

      // Seed reserves.
      await t1.mint(await pair.getAddress(), ethers.parseEther("1000"));
      await t2.mint(await pair.getAddress(), ethers.parseEther("1000"));
      await pair.mint(deployer.address);

      // Deploy the flash-callback attacker and point it at the pair.
      const Attacker = await ethers.getContractFactory("ReentrantCallee");
      const atk = await Attacker.deploy();
      await atk.waitForDeployment();
      await atk.setTarget(await pair.getAddress());

      // Flash-borrow 1e18 of token0 and repay in token0. To satisfy the pair's
      // 0.3% fee K-check when repaying in the SAME token, send back
      // ceil(out * 1000 / 997) + buffer. Fund the attacker with that.
      const out = ethers.parseEther("1");
      const token0Addr = await pair.token0();
      const token0 = token0Addr.toLowerCase() === (await t1.getAddress()).toLowerCase() ? t1 : t2;
      const repay = (out * 1000n) / 997n + 2n;
      await token0.mint(await atk.getAddress(), repay);
      await atk.setRepayment(await token0.getAddress(), repay);

      // swap() with non-empty data invokes atk.rnxCall WHILE the lock is held.
      // The attacker re-enters swap() -> MUST revert with LOCKED (caught). The
      // attacker then repays, so the OUTER swap commits and the recorded state
      // persists for the assertions below.
      await expect(
        pair.swap(out, 0, await atk.getAddress(), "0x01")
      ).to.emit(atk, "ReentryAttempted").withArgs(true);

      expect(await atk.reentryObserved()).to.equal(true);
      expect(await atk.reentryReverted()).to.equal(true);
    });

    it("a normal (non-reentrant) sync succeeds under the lock", async function () {
      const TestERC20 = await ethers.getContractFactory("TestERC20");
      const t1 = await TestERC20.deploy("A", "A");
      const t2 = await TestERC20.deploy("B", "B");
      await t1.waitForDeployment();
      await t2.waitForDeployment();
      await factory.createPair(await t1.getAddress(), await t2.getAddress());
      const RnxPair = await ethers.getContractFactory("RnxPair");
      const pair = RnxPair.attach(await factory.getPair(await t1.getAddress(), await t2.getAddress()));
      await t1.mint(await pair.getAddress(), ethers.parseEther("5"));
      await t2.mint(await pair.getAddress(), ethers.parseEther("5"));
      await expect(pair.sync()).to.emit(pair, "Sync");
    });
  });

  // ----------------------------------------------------------------------
  //                             skim / sync
  // ----------------------------------------------------------------------
  describe("skim / sync", function () {
    it("skim sends surplus over reserves to the caller", async function () {
      const TestERC20 = await ethers.getContractFactory("TestERC20");
      const t1 = await TestERC20.deploy("A", "A");
      const t2 = await TestERC20.deploy("B", "B");
      await t1.waitForDeployment();
      await t2.waitForDeployment();
      await factory.createPair(await t1.getAddress(), await t2.getAddress());
      const RnxPair = await ethers.getContractFactory("RnxPair");
      const pair = RnxPair.attach(await factory.getPair(await t1.getAddress(), await t2.getAddress()));

      await t1.mint(await pair.getAddress(), ethers.parseEther("100"));
      await t2.mint(await pair.getAddress(), ethers.parseEther("100"));
      await pair.mint(deployer.address);

      await t1.mint(await pair.getAddress(), ethers.parseEther("7"));
      const before = await t1.balanceOf(other.address);
      await pair.skim(other.address);
      const after = await t1.balanceOf(other.address);
      expect(after - before).to.equal(ethers.parseEther("7"));
    });
  });
});

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../contracts/RnxFactory.sol";
import "../contracts/RnxPair.sol";
import "../contracts/test/TestHelpers.sol";

contract DexKFuzz is Test {
    RnxFactory factory; RnxPair pair; TestERC20 t0; TestERC20 t1;
    function setUp() public {
        t0 = new TestERC20("T0","T0"); t1 = new TestERC20("T1","T1");
        factory = new RnxFactory();
        factory.createPair(address(t0), address(t1));
        pair = RnxPair(factory.getPair(address(t0), address(t1)));
        t0.mint(address(this), 1e30); t1.mint(address(this), 1e30);
        t0.transfer(address(pair), 1e24); t1.transfer(address(pair), 1e24);
        pair.mint(address(this));
    }
    // INVARIANT: an honest swap (correct getAmountOut) never decreases k
    function testFuzz_swap_preserves_k(uint96 amountIn) public {
        vm.assume(amountIn > 1e6 && amountIn < 1e23);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);
        uint256 amtOut = (uint256(amountIn) * 997 * r1) / (uint256(r0) * 1000 + uint256(amountIn) * 997);
        vm.assume(amtOut > 0 && amtOut < r1);
        t0.transfer(address(pair), amountIn);
        pair.swap(0, amtOut, address(this), "");
        (uint112 r0b, uint112 r1b,) = pair.getReserves();
        assertGe(uint256(r0b) * uint256(r1b), kBefore); // k never decreases
    }
    function testFuzz_greedy_swap_reverts(uint96 amountIn) public {
        vm.assume(amountIn > 1e6 && amountIn < 1e23);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 fair = (uint256(amountIn) * 997 * r1) / (uint256(r0) * 1000 + uint256(amountIn) * 997);
        vm.assume(fair > 0 && fair * 2 < r1);
        t0.transfer(address(pair), amountIn);
        vm.expectRevert();
        pair.swap(0, fair * 2, address(this), ""); // taking 2x fair must break K -> revert
    }
}

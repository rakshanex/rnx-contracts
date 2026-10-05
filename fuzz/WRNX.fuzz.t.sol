// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../contracts/WRNX.sol";

contract WRNXFuzz is Test {
    WRNX w;
    function setUp() public { w = new WRNX(); }

    // INVARIANT: WRNX totalSupply must always equal native coin locked in the contract
    function testFuzz_wrap_unwrap_conserves(uint96 amt) public {
        vm.assume(amt > 0);
        vm.deal(address(this), amt);
        w.deposit{value: amt}();
        assertEq(w.totalSupply(), amt);
        assertEq(w.totalSupply(), address(w).balance); // supply == backing
        w.withdraw(amt);
        assertEq(w.totalSupply(), 0);
        assertEq(address(w).balance, 0);
    }

    function testFuzz_cannot_withdraw_more_than_balance(uint96 a, uint96 b) public {
        vm.assume(a > 0 && b > a);
        vm.deal(address(this), a);
        w.deposit{value: a}();
        vm.expectRevert();
        w.withdraw(b); // more than deposited -> revert
    }
    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/RnxStaking.sol";
import "../contracts/test/TestHelpers.sol";

/// @title RnxStaking fuzz / property tests
/// @notice Properties under test (Synthetix StakingRewards accounting):
///   1. SOLVENCY — the sum of reward tokens actually paid out to stakers can
///      never exceed the reward tokens that were funded into the contract. The
///      `notifyRewardAmount` pre-funding solvency check must hold under arbitrary
///      stake amounts and time warps.
///   2. PRINCIPAL CONSERVATION — staked principal is always fully withdrawable
///      by its owner; no amount of reward accrual, time warping, or claiming can
///      reduce the staking-token principal a user can recover.
///
/// stakingToken (WRNX-like) and rewardsToken (qUSD-like) are distinct TEST
/// ERC-20s (TestHelpers.TestERC20). No deploy, no keys, no real value.
contract StakingFuzz is Test {
    RnxStaking staking;
    TestERC20 stakeTok; // staking token (e.g. WRNX, TEST asset)
    TestERC20 rewardTok; // reward token  (e.g. qUSD, TEST asset)

    address owner = address(0xA11CE);
    address distributor = address(0xB0B);
    address alice = address(0xA1);
    address bob = address(0xB2);

    uint256 constant DURATION = 7 days;

    function setUp() public {
        stakeTok = new TestERC20("StakeTok", "STK");
        rewardTok = new TestERC20("RewardTok", "RWD");
        staking = new RnxStaking(owner, distributor, address(stakeTok), address(rewardTok));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _stakeAs(address who, uint256 amount) internal {
        stakeTok.mint(who, amount);
        vm.startPrank(who);
        stakeTok.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _fundAndNotify(uint256 rewardAmount) internal {
        // Pre-fund the contract with reward tokens, then notify.
        rewardTok.mint(address(staking), rewardAmount);
        vm.prank(distributor);
        staking.notifyRewardAmount(rewardAmount);
    }

    // ------------------------------------------------------------------
    // PROPERTY 1: SOLVENCY — rewards paid out <= rewards funded
    // ------------------------------------------------------------------

    /// @notice Fuzz two stake amounts, a reward budget, and a time warp. After
    ///         warping past period end, both stakers claim. The sum of reward
    ///         tokens leaving the contract must never exceed what was funded,
    ///         and the contract must remain solvent (never underflow/revert on
    ///         an honest claim).
    function testFuzz_solvency_rewardsNeverExceedFunded(
        uint96 stakeA,
        uint96 stakeB,
        uint96 reward,
        uint64 warp
    ) public {
        stakeA = uint96(bound(stakeA, 1e12, 1e24));
        stakeB = uint96(bound(stakeB, 1e12, 1e24));
        // reward must be large enough that reward/DURATION > 0 for a meaningful
        // schedule, and bounded so the funded amount is realistic.
        reward = uint96(bound(reward, DURATION, 1e24));
        warp = uint64(bound(warp, 1, 30 days));

        _stakeAs(alice, stakeA);
        _stakeAs(bob, stakeB);

        uint256 funded = reward;
        _fundAndNotify(reward);

        // Advance time by an arbitrary amount (may exceed the period).
        vm.warp(block.timestamp + warp);

        // Both stakers claim all accrued rewards.
        vm.prank(alice);
        staking.getReward();
        vm.prank(bob);
        staking.getReward();

        uint256 paidOut = rewardTok.balanceOf(alice) + rewardTok.balanceOf(bob);

        // SOLVENCY: total paid out can never exceed total funded.
        assertLe(paidOut, funded, "rewards paid out exceeded rewards funded");

        // The contract must still hold the un-emitted remainder (no deficit).
        uint256 remaining = rewardTok.balanceOf(address(staking));
        assertEq(paidOut + remaining, funded, "reward token conservation violated");
    }

    /// @notice Even across multiple sequential notify periods and warps, the
    ///         cumulative payout stays within cumulative funding.
    function testFuzz_solvency_multiPeriod(
        uint96 reward1,
        uint96 reward2,
        uint64 warp1,
        uint64 warp2
    ) public {
        reward1 = uint96(bound(reward1, DURATION, 1e23));
        reward2 = uint96(bound(reward2, DURATION, 1e23));
        warp1 = uint64(bound(warp1, 1, 20 days));
        warp2 = uint64(bound(warp2, 1, 20 days));

        _stakeAs(alice, 1e21);

        uint256 funded;

        funded += reward1;
        _fundAndNotify(reward1);
        vm.warp(block.timestamp + warp1);

        funded += reward2;
        _fundAndNotify(reward2);
        vm.warp(block.timestamp + warp2);

        vm.prank(alice);
        staking.getReward();

        uint256 paidOut = rewardTok.balanceOf(alice);
        assertLe(paidOut, funded, "cumulative payout exceeded cumulative funding");
        assertEq(
            paidOut + rewardTok.balanceOf(address(staking)),
            funded,
            "reward token conservation violated across periods"
        );
    }

    // ------------------------------------------------------------------
    // PROPERTY 2: PRINCIPAL CONSERVATION — staked principal fully withdrawable
    // ------------------------------------------------------------------

    /// @notice No matter the stake amounts, reward funding, time warps, or
    ///         reward claims, each staker can always withdraw exactly their
    ///         principal and the staking token is conserved.
    function testFuzz_principalFullyWithdrawable(
        uint96 stakeA,
        uint96 stakeB,
        uint96 reward,
        uint64 warp
    ) public {
        stakeA = uint96(bound(stakeA, 1, 1e24));
        stakeB = uint96(bound(stakeB, 1, 1e24));
        reward = uint96(bound(reward, DURATION, 1e24));
        warp = uint64(bound(warp, 0, 30 days));

        _stakeAs(alice, stakeA);
        _stakeAs(bob, stakeB);

        _fundAndNotify(reward);
        vm.warp(block.timestamp + warp);

        // The staking token held by the contract equals total staked principal.
        assertEq(
            stakeTok.balanceOf(address(staking)),
            uint256(stakeA) + uint256(stakeB),
            "contract principal != total staked"
        );

        // Alice withdraws her full principal — must succeed and return exactly stakeA.
        uint256 aliceBefore = stakeTok.balanceOf(alice);
        vm.prank(alice);
        staking.withdraw(stakeA);
        assertEq(
            stakeTok.balanceOf(alice) - aliceBefore,
            stakeA,
            "alice did not recover full principal"
        );

        // Bob exits (withdraw + getReward) — must recover exactly his principal.
        uint256 bobBefore = stakeTok.balanceOf(bob);
        vm.prank(bob);
        staking.exit();
        assertEq(
            stakeTok.balanceOf(bob) - bobBefore,
            stakeB,
            "bob did not recover full principal via exit"
        );

        // After everyone exits, no principal is stranded in the contract.
        assertEq(
            stakeTok.balanceOf(address(staking)),
            0,
            "principal stranded in contract after full withdrawal"
        );
        assertEq(staking.totalSupply(), 0, "totalSupply nonzero after full exit");
    }

    /// @notice A staker can never withdraw more principal than they staked
    ///         (checked subtraction / explicit balance guard must revert).
    function testFuzz_cannotWithdrawMoreThanStaked(uint96 stakeAmt, uint96 extra) public {
        stakeAmt = uint96(bound(stakeAmt, 1, 1e24));
        extra = uint96(bound(extra, 1, 1e24));

        _stakeAs(alice, stakeAmt);

        vm.prank(alice);
        vm.expectRevert(bytes("RnxStaking: insufficient staked balance"));
        staking.withdraw(uint256(stakeAmt) + uint256(extra));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// =============================================================================
// RnxStaking — Synthetix-style single-sided staking rewards for the RNX economy
// =============================================================================
//
// WELL-KNOWN PATTERN CITATION
// ---------------------------
// The reward-accounting math in this contract (rewardPerToken / earned /
// userRewardPerTokenPaid, the `updateReward` modifier, finite reward periods
// driven by `notifyRewardAmount`, and the `lastTimeRewardApplicable` clamp) is
// the well-known "Synthetix StakingRewards" algorithm, which is public and
// widely reused across DeFi.
//
//   Source:  Synthetix StakingRewards.sol
//   Repo:    https://github.com/Synthetixio/synthetix
//   File:    contracts/StakingRewards.sol
//   License: MIT
//
// This is an independent, dependency-free re-implementation written in the
// OpenZeppelin / Synthetix idiom for Solidity 0.8.x. It uses no proprietary
// code. The checked arithmetic of Solidity 0.8.20 replaces the SafeMath that
// the original (0.5.x) contract relied upon.
//
// TRANSPARENCY / SAFETY GUARANTEES
// --------------------------------
//   - NO MINT: this contract cannot mint either the staking token or the reward
//     token. Rewards must be PRE-FUNDED by transferring the reward token into
//     this contract BEFORE (or at) the time `notifyRewardAmount` is called. The
//     `notifyRewardAmount` function reverts if the contract's reward-token
//     balance cannot cover the promised rewardRate over the period (the same
//     solvency check used by Synthetix).
//   - NO OWNER DRAIN OF PRINCIPAL: staked principal (the staking token) can only
//     ever leave this contract via `withdraw` / `exit` called by the staker who
//     owns that balance. The `recoverERC20` escape hatch EXPLICITLY forbids
//     recovering the staking token, so no role can touch user principal.
//   - EXPLICIT DOCUMENTED ROLES: there are exactly two roles, both set at
//     construction and both transferable only by their current holder:
//         * `owner`                — may set the reward duration and recover
//                                     NON-staking stray tokens only.
//         * `rewardsDistribution`  — the ONLY account allowed to call
//                                     `notifyRewardAmount`.
//   - REENTRANCY GUARD: a minimal non-reentrant lock protects every state-
//     mutating external entry point (stake / withdraw / getReward / exit).
//
// SCOPE: local testing / files only. This is a TEST module. No deployment, no
// keys, no live transactions, no real staking, liquidity, or money. The reward
// token is expected to be a TEST asset (e.g. qUSD) and the staking token a TEST
// asset (e.g. WRNX). Nothing here is custodial of real-world value and nothing
// here is "decentralized".
// =============================================================================

/// @dev Minimal ERC-20 surface used by this contract. Matches the WRNX / qUSD /
///      TestERC20 implementations in this repo (all return bool and revert on
///      failure), so no SafeERC20 wrapper is required for them.
interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract RnxStaking {
    // ----------------------------------------------------------------------
    //                              Immutables
    // ----------------------------------------------------------------------

    /// @notice Token that users stake (expected: WRNX, a TEST asset).
    IERC20Min public immutable stakingToken;

    /// @notice Token paid out as rewards (expected: qUSD, a TEST asset).
    IERC20Min public immutable rewardsToken;

    // ----------------------------------------------------------------------
    //                          Documented roles
    // ----------------------------------------------------------------------

    /// @notice Administrative role: may set rewards duration and recover stray
    ///         NON-staking tokens. CANNOT touch staked principal and CANNOT mint.
    address public owner;

    /// @notice The ONLY account permitted to call `notifyRewardAmount`.
    address public rewardsDistribution;

    // ----------------------------------------------------------------------
    //                          Reward accounting
    // ----------------------------------------------------------------------

    /// @notice Timestamp at which the current reward period ends.
    uint256 public periodFinish;

    /// @notice Reward token emitted per second across all stakers.
    uint256 public rewardRate;

    /// @notice Duration (seconds) of a reward period. Default 7 days.
    uint256 public rewardsDuration = 7 days;

    /// @notice Last time reward accounting was updated.
    uint256 public lastUpdateTime;

    /// @notice Accumulated reward per staked token, scaled by 1e18.
    uint256 public rewardPerTokenStored;

    /// @dev Per-user snapshot of rewardPerTokenStored at their last interaction.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @dev Per-user accrued but unclaimed rewards.
    mapping(address => uint256) public rewards;

    // ----------------------------------------------------------------------
    //                          Stake accounting
    // ----------------------------------------------------------------------

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    // ----------------------------------------------------------------------
    //                          Reentrancy guard
    // ----------------------------------------------------------------------

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "RnxStaking: REENTRANCY");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ----------------------------------------------------------------------
    //                               Events
    // ----------------------------------------------------------------------

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address indexed token, uint256 amount);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event RewardsDistributionTransferred(address indexed previous, address indexed current);

    // ----------------------------------------------------------------------
    //                             Constructor
    // ----------------------------------------------------------------------

    /// @param _owner               Administrative role holder.
    /// @param _rewardsDistribution Account allowed to call notifyRewardAmount.
    /// @param _stakingToken        Token to be staked (TEST asset, e.g. WRNX).
    /// @param _rewardsToken        Token paid as reward (TEST asset, e.g. qUSD).
    constructor(
        address _owner,
        address _rewardsDistribution,
        address _stakingToken,
        address _rewardsToken
    ) {
        require(_owner != address(0), "RnxStaking: owner is zero");
        require(_rewardsDistribution != address(0), "RnxStaking: distribution is zero");
        require(_stakingToken != address(0), "RnxStaking: staking token is zero");
        require(_rewardsToken != address(0), "RnxStaking: rewards token is zero");
        require(_stakingToken != _rewardsToken, "RnxStaking: tokens must differ");

        owner = _owner;
        rewardsDistribution = _rewardsDistribution;
        stakingToken = IERC20Min(_stakingToken);
        rewardsToken = IERC20Min(_rewardsToken);

        emit OwnerTransferred(address(0), _owner);
        emit RewardsDistributionTransferred(address(0), _rewardsDistribution);
    }

    // ----------------------------------------------------------------------
    //                          Access control
    // ----------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "RnxStaking: caller is not owner");
        _;
    }

    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "RnxStaking: caller is not rewardsDistribution");
        _;
    }

    /// @notice Hand the administrative role to a new account.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "RnxStaking: new owner is zero");
        address previous = owner;
        owner = newOwner;
        emit OwnerTransferred(previous, newOwner);
    }

    /// @notice Hand the rewards-distribution role to a new account.
    function setRewardsDistribution(address newDistribution) external onlyOwner {
        require(newDistribution != address(0), "RnxStaking: new distribution is zero");
        address previous = rewardsDistribution;
        rewardsDistribution = newDistribution;
        emit RewardsDistributionTransferred(previous, newDistribution);
    }

    // ----------------------------------------------------------------------
    //                        Reward-update modifier
    // ----------------------------------------------------------------------

    /// @dev Synthetix "updateReward": settle global and per-account reward
    ///      accounting before any balance-changing action.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ----------------------------------------------------------------------
    //                               Views
    // ----------------------------------------------------------------------

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice min(now, periodFinish) — rewards stop accruing after periodFinish.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Accumulated reward per staked token, scaled by 1e18.
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply);
    }

    /// @notice Rewards earned by `account` but not yet claimed.
    function earned(address account) public view returns (uint256) {
        return
            ((_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) +
            rewards[account];
    }

    /// @notice Total reward token promised across the whole current period.
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // ----------------------------------------------------------------------
    //                          Staker actions
    // ----------------------------------------------------------------------

    /// @notice Stake `amount` of the staking token. Caller must have approved
    ///         this contract for `amount` of the staking token first.
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "RnxStaking: cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        // Pull principal in. Reverts on failure (checked bool).
        require(
            stakingToken.transferFrom(msg.sender, address(this), amount),
            "RnxStaking: stake transfer failed"
        );
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw `amount` of previously staked principal.
    /// @dev Reverts if `amount` exceeds the caller's staked balance (checked
    ///      subtraction under 0.8.x). Principal is only ever returned to its
    ///      owner — no role can redirect it.
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "RnxStaking: cannot withdraw 0");
        require(_balances[msg.sender] >= amount, "RnxStaking: insufficient staked balance");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        require(
            stakingToken.transfer(msg.sender, amount),
            "RnxStaking: withdraw transfer failed"
        );
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim all accrued rewards for the caller.
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            require(
                rewardsToken.transfer(msg.sender, reward),
                "RnxStaking: reward transfer failed"
            );
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Withdraw entire staked balance and claim all rewards in one call.
    /// @dev Not marked nonReentrant itself because the two internal calls each
    ///      hold the guard; calling them sequentially here is safe and avoids a
    ///      self-reentrancy false-positive on the shared lock.
    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    // ----------------------------------------------------------------------
    //                     Rewards distribution (role-gated)
    // ----------------------------------------------------------------------

    /// @notice Start/extend a finite reward period of `rewardsDuration` seconds
    ///         emitting `reward` reward-tokens in total over that period.
    /// @dev ONLY callable by `rewardsDistribution`. Rewards MUST already be held
    ///      by this contract (pre-funded). The solvency check below — identical
    ///      in spirit to Synthetix — guarantees the contract holds enough reward
    ///      tokens to pay out the entire period, so emissions can never exceed
    ///      what was actually funded. There is NO mint anywhere in this path.
    function notifyRewardAmount(uint256 reward)
        external
        onlyRewardsDistribution
        updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Solvency: the contract must already hold enough reward tokens to cover
        // the full period at the new rate. Rewards are pre-funded, never minted.
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(
            rewardRate <= balance / rewardsDuration,
            "RnxStaking: provided reward too high (not pre-funded)"
        );

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward, periodFinish);
    }

    // ----------------------------------------------------------------------
    //                       Owner admin (no principal access)
    // ----------------------------------------------------------------------

    /// @notice Set the reward period duration. Only allowed when no period is
    ///         currently active, so an in-flight schedule cannot be mutated.
    function setRewardsDuration(uint256 newDuration) external onlyOwner {
        require(block.timestamp > periodFinish, "RnxStaking: period still active");
        require(newDuration > 0, "RnxStaking: duration is zero");
        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(newDuration);
    }

    /// @notice Recover stray tokens accidentally sent to this contract.
    /// @dev EXPLICITLY forbids recovering the staking token, so staked principal
    ///      is untouchable by any role. (This mirrors Synthetix's
    ///      recoverERC20 guard.)
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(stakingToken), "RnxStaking: cannot recover staking token");
        require(IERC20Min(token).transfer(owner, amount), "RnxStaking: recover transfer failed");
        emit Recovered(token, amount);
    }
}

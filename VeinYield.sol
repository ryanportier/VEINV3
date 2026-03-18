// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IVeinStake {
    function stakers(address) external view returns (uint256 amount, uint256 stakedAt, uint256 unstakeRequestedAt, uint256 pendingUnstake);
    function totalStaked() external view returns (uint256);
    function yieldMultiplierBps(address wallet) external view returns (uint256);
}

/// @title VeinYield — Passive yield pool for $VEIN stakers
/// @notice Operator deposits trading fees. Stakers claim proportional yield
///         weighted by their stake amount × time multiplier.
///         Uses a snapshot-per-distribution model (like MasterChef).
contract VeinYield is ReentrancyGuard, Ownable {

    IERC20     public immutable vein;
    IVeinStake public immutable stake;

    // ── Reward tracking (MasterChef-style) ───────────────────────
    uint256 public accRewardPerShare; // scaled by 1e18
    uint256 public totalDistributed;

    mapping(address => uint256) public rewardDebt;   // per wallet
    mapping(address => uint256) public pendingReward; // unclaimed

    // ── Events ───────────────────────────────────────────────────
    event YieldDistributed(uint256 amount, uint256 newAccPerShare);
    event YieldClaimed(address indexed wallet, uint256 amount);
    event RewardDebtUpdated(address indexed wallet, uint256 debt);

    constructor(address _vein, address _stake, address _owner)
        Ownable(_owner)
    {
        vein  = IERC20(_vein);
        stake = IVeinStake(_stake);
    }

    // ── Operator deposits fees ────────────────────────────────────
    /// @notice Called by operator with trading fees accumulated from BANKR swaps.
    function distributeYield(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        uint256 total = stake.totalStaked();
        require(total > 0, "No stakers");

        vein.transferFrom(msg.sender, address(this), amount);

        // Increase accRewardPerShare
        accRewardPerShare += (amount * 1e18) / total;
        totalDistributed  += amount;

        emit YieldDistributed(amount, accRewardPerShare);
    }

    // ── Sync pending rewards for a wallet ─────────────────────────
    /// @notice Must be called before stake changes (stake/unstake).
    ///         In production this would be called by VeinStake via interface.
    function sync(address wallet) external {
        _sync(wallet);
    }

    function _sync(address wallet) internal {
        (uint256 stakedAmt,,,) = stake.stakers(wallet);
        if (stakedAmt == 0) return;

        uint256 multBps = stake.yieldMultiplierBps(wallet);
        // effective stake = actual stake × time multiplier
        uint256 effective = (stakedAmt * multBps) / 10000;

        uint256 accumulated = (effective * accRewardPerShare) / 1e18;
        uint256 debt        = rewardDebt[wallet];

        if (accumulated > debt) {
            pendingReward[wallet] += accumulated - debt;
        }

        rewardDebt[wallet] = accumulated;
        emit RewardDebtUpdated(wallet, accumulated);
    }

    // ── Claim yield ───────────────────────────────────────────────
    function claimYield() external nonReentrant {
        _sync(msg.sender);
        uint256 amount = pendingReward[msg.sender];
        require(amount > 0, "Nothing to claim");
        pendingReward[msg.sender] = 0;
        vein.transfer(msg.sender, amount);
        emit YieldClaimed(msg.sender, amount);
    }

    // ── Views ─────────────────────────────────────────────────────
    function getPending(address wallet) external view returns (uint256) {
        (uint256 stakedAmt,,,) = stake.stakers(wallet);
        if (stakedAmt == 0) return pendingReward[wallet];

        uint256 multBps   = stake.yieldMultiplierBps(wallet);
        uint256 effective = (stakedAmt * multBps) / 10000;
        uint256 accumulated = (effective * accRewardPerShare) / 1e18;
        uint256 debt = rewardDebt[wallet];

        uint256 extra = accumulated > debt ? accumulated - debt : 0;
        return pendingReward[wallet] + extra;
    }
}

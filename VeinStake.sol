// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VeinStake — Rig tier staking for $VEIN
/// @notice Stake $VEIN to access mine shafts. Unstake with 48h window or pay 2% penalty.
contract VeinStake is ReentrancyGuard, Ownable {

    IERC20 public immutable vein;

    // ── Tier thresholds ──────────────────────────────────────────
    uint256 public constant PROSPECTOR_MIN  =  25_000_000 * 1e18;
    uint256 public constant SHAFT_MIN       =  50_000_000 * 1e18;
    uint256 public constant DEEP_MIN        = 100_000_000 * 1e18;

    uint8 public constant TIER_NONE        = 0;
    uint8 public constant TIER_PROSPECTOR  = 1;
    uint8 public constant TIER_SHAFT       = 2;
    uint8 public constant TIER_DEEP        = 3;

    // Depths: 0 = shallow, 1 = medium, 2 = deep
    uint8 public constant DEPTH_SHALLOW = 0;
    uint8 public constant DEPTH_MEDIUM  = 1;
    uint8 public constant DEPTH_DEEP    = 2;

    // Penalty pool (2% on instant unstake) — goes to yield pool
    address public yieldPool;
    uint256 public constant PENALTY_BPS = 200; // 2%
    uint256 public constant UNSTAKE_WINDOW = 48 hours;

    // ── Staker state ─────────────────────────────────────────────
    struct StakerInfo {
        uint256 amount;
        uint256 stakedAt;        // timestamp of first stake
        uint256 unstakeRequestedAt; // 0 if no pending request
        uint256 pendingUnstake;
    }

    mapping(address => StakerInfo) public stakers;
    uint256 public totalStaked;

    // ── Events ───────────────────────────────────────────────────
    event Staked(address indexed wallet, uint256 amount, uint8 tier);
    event UnstakeRequested(address indexed wallet, uint256 amount, uint256 availableAt);
    event Unstaked(address indexed wallet, uint256 amount, uint256 penalty);
    event InstantUnstaked(address indexed wallet, uint256 amount, uint256 penalty);

    constructor(address _vein, address _yieldPool, address _owner)
        Ownable(_owner)
    {
        vein = IERC20(_vein);
        yieldPool = _yieldPool;
    }

    // ── Stake ─────────────────────────────────────────────────────
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        vein.transferFrom(msg.sender, address(this), amount);

        StakerInfo storage s = stakers[msg.sender];
        if (s.amount == 0) s.stakedAt = block.timestamp;
        s.amount += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount, getTier(msg.sender));
    }

    // ── Request unstake (48h window, no penalty) ──────────────────
    function requestUnstake(uint256 amount) external {
        StakerInfo storage s = stakers[msg.sender];
        require(s.amount >= amount, "Insufficient stake");
        require(s.pendingUnstake == 0, "Unstake already pending");
        s.pendingUnstake = amount;
        s.unstakeRequestedAt = block.timestamp;
        emit UnstakeRequested(msg.sender, amount, block.timestamp + UNSTAKE_WINDOW);
    }

    // ── Complete unstake after 48h ─────────────────────────────────
    function completeUnstake() external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        require(s.pendingUnstake > 0, "No pending unstake");
        require(block.timestamp >= s.unstakeRequestedAt + UNSTAKE_WINDOW, "Window not elapsed");

        uint256 amount = s.pendingUnstake;
        s.pendingUnstake = 0;
        s.unstakeRequestedAt = 0;
        s.amount -= amount;
        totalStaked -= amount;

        vein.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, 0);
    }

    // ── Instant unstake (2% penalty) ──────────────────────────────
    function instantUnstake(uint256 amount) external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        require(s.amount >= amount, "Insufficient stake");

        uint256 penalty = (amount * PENALTY_BPS) / 10000;
        uint256 payout  = amount - penalty;

        s.amount -= amount;
        totalStaked -= amount;

        if (penalty > 0 && yieldPool != address(0)) {
            vein.transfer(yieldPool, penalty);
        }
        vein.transfer(msg.sender, payout);
        emit InstantUnstaked(msg.sender, payout, penalty);
    }

    // ── View: tier ────────────────────────────────────────────────
    function getTier(address wallet) public view returns (uint8) {
        uint256 amt = stakers[wallet].amount;
        if (amt >= DEEP_MIN)       return TIER_DEEP;
        if (amt >= SHAFT_MIN)      return TIER_SHAFT;
        if (amt >= PROSPECTOR_MIN) return TIER_PROSPECTOR;
        return TIER_NONE;
    }

    // ── View: depth access ────────────────────────────────────────
    function canAccess(address wallet, uint8 depth) external view returns (bool) {
        uint8 tier = getTier(wallet);
        if (depth == DEPTH_SHALLOW) return tier >= TIER_PROSPECTOR;
        if (depth == DEPTH_MEDIUM)  return tier >= TIER_SHAFT;
        if (depth == DEPTH_DEEP)    return tier >= TIER_DEEP;
        return false;
    }

    // ── View: stake duration in days ──────────────────────────────
    function stakeDays(address wallet) external view returns (uint256) {
        uint256 at = stakers[wallet].stakedAt;
        if (at == 0) return 0;
        return (block.timestamp - at) / 1 days;
    }

    // ── View: yield multiplier (basis points) ─────────────────────
    // Returns 10000 = 1.0x | 11500 = 1.15x | 13500 = 1.35x
    function yieldMultiplierBps(address wallet) external view returns (uint256) {
        uint256 days_ = (block.timestamp - stakers[wallet].stakedAt) / 1 days;
        if (stakers[wallet].amount == 0) return 10000;
        if (days_ >= 30) return 13500;
        if (days_ >= 7)  return 11500;
        return 10000;
    }

    // ── Admin ─────────────────────────────────────────────────────
    function setYieldPool(address _yieldPool) external onlyOwner {
        yieldPool = _yieldPool;
    }
}

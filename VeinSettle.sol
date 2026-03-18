// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VeinSettle — EIP-712 receipt settlement + epoch rewards
/// @notice Drillers submit signed receipts from the coordinator.
///         Credits are recorded per epoch. Operator funds epochs with $VEIN.
///         Rewards are proportional to refined credits × XAU multiplier.
contract VeinSettle is EIP712, ReentrancyGuard, Ownable {
    using ECDSA for bytes32;

    IERC20 public immutable vein;
    address public coordinator; // signs receipts off-chain

    // ── EIP-712 type hash ─────────────────────────────────────────
    bytes32 public constant RECEIPT_TYPEHASH = keccak256(
        "DrillReceipt(address wallet,uint256 epochId,uint256 siteId,uint256 credits,uint256 solveIndex)"
    );

    // ── Epoch state ───────────────────────────────────────────────
    struct Epoch {
        uint256 totalCredits;   // sum of all refined credits
        uint256 rewardPool;     // $VEIN funded by operator
        uint256 xauMultBps;     // e.g. 12500 = 1.25x
        bool    funded;         // operator has funded
        uint256 startTime;
        uint256 endTime;
    }

    uint256 public currentEpochId;
    uint256 public constant EPOCH_DURATION = 24 hours;

    mapping(uint256 => Epoch) public epochs;

    // wallet => epochId => credits
    mapping(address => mapping(uint256 => uint256)) public credits;

    // wallet => solveIndex (replay protection)
    mapping(address => uint256) public solveIndex;

    // wallet => epochId => claimed
    mapping(address => mapping(uint256 => bool)) public claimed;

    // ── Events ────────────────────────────────────────────────────
    event ReceiptSubmitted(address indexed wallet, uint256 epochId, uint256 siteId, uint256 credits, uint256 solveIndex);
    event EpochFunded(uint256 epochId, uint256 rewardPool, uint256 xauMultBps);
    event EpochAdvanced(uint256 oldEpoch, uint256 newEpoch);
    event RewardClaimed(address indexed wallet, uint256 epochId, uint256 amount);

    constructor(address _vein, address _coordinator, address _owner)
        EIP712("VeinSettle", "1")
        Ownable(_owner)
    {
        vein = IERC20(_vein);
        coordinator = _coordinator;
        // Genesis epoch
        epochs[0].startTime = block.timestamp;
        epochs[0].endTime   = block.timestamp + EPOCH_DURATION;
    }

    // ── Submit drill receipt ──────────────────────────────────────
    /// @param wallet     The driller wallet
    /// @param epochId    Must match currentEpochId
    /// @param siteId     Which mine shaft
    /// @param newCredits Credits earned by this solve
    /// @param idx        Must equal solveIndex[wallet] (anti-replay)
    /// @param sig        Coordinator's EIP-712 signature
    function submitReceipt(
        address wallet,
        uint256 epochId,
        uint256 siteId,
        uint256 newCredits,
        uint256 idx,
        bytes calldata sig
    ) external nonReentrant {
        require(epochId == currentEpochId, "Wrong epoch");
        require(block.timestamp <= epochs[epochId].endTime, "Epoch closed");
        require(idx == solveIndex[wallet], "Bad solve index");
        require(newCredits > 0 && newCredits <= 3, "Invalid credits");

        // Verify coordinator signature
        bytes32 structHash = keccak256(abi.encode(
            RECEIPT_TYPEHASH,
            wallet,
            epochId,
            siteId,
            newCredits,
            idx
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, sig);
        require(signer == coordinator, "Bad signature");

        // Record
        solveIndex[wallet]++;
        credits[wallet][epochId] += newCredits;
        epochs[epochId].totalCredits += newCredits;

        emit ReceiptSubmitted(wallet, epochId, siteId, newCredits, idx);
    }

    // ── Fund epoch (operator) ──────────────────────────────────────
    /// @notice Called by operator after epoch ends. Sends $VEIN to this contract.
    ///         xauMultBps: e.g. 12500 = 1.25x (Chainlink snapshot off-chain)
    function fundEpoch(uint256 epochId, uint256 amount, uint256 xauMultBps) external onlyOwner {
        require(!epochs[epochId].funded, "Already funded");
        require(block.timestamp > epochs[epochId].endTime, "Epoch not ended");
        require(xauMultBps >= 5000 && xauMultBps <= 20000, "Bad multiplier");

        vein.transferFrom(msg.sender, address(this), amount);

        epochs[epochId].rewardPool  = amount;
        epochs[epochId].xauMultBps  = xauMultBps;
        epochs[epochId].funded      = true;

        emit EpochFunded(epochId, amount, xauMultBps);
    }

    // ── Advance epoch ─────────────────────────────────────────────
    function advanceEpoch() external {
        require(block.timestamp > epochs[currentEpochId].endTime, "Too early");
        uint256 old = currentEpochId;
        currentEpochId++;
        epochs[currentEpochId].startTime = block.timestamp;
        epochs[currentEpochId].endTime   = block.timestamp + EPOCH_DURATION;
        emit EpochAdvanced(old, currentEpochId);
    }

    // ── Claim reward ──────────────────────────────────────────────
    function claimReward(uint256 epochId) external nonReentrant {
        require(epochs[epochId].funded, "Not funded yet");
        require(!claimed[msg.sender][epochId], "Already claimed");

        uint256 myCredits    = credits[msg.sender][epochId];
        require(myCredits > 0, "No credits");

        uint256 totalCredits = epochs[epochId].totalCredits;
        uint256 pool         = epochs[epochId].rewardPool;
        uint256 mult         = epochs[epochId].xauMultBps;

        // reward = pool × (myCredits / totalCredits) × xauMult
        uint256 base   = (pool * myCredits) / totalCredits;
        uint256 reward = (base * mult) / 10000;

        // Cap to pool size (safety)
        if (reward > pool) reward = pool;

        claimed[msg.sender][epochId] = true;
        vein.transfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, epochId, reward);
    }

    // ── Views ─────────────────────────────────────────────────────
    function getMyCredits(address wallet, uint256 epochId) external view returns (uint256) {
        return credits[wallet][epochId];
    }

    function estimateReward(address wallet, uint256 epochId) external view returns (uint256) {
        Epoch memory e = epochs[epochId];
        if (!e.funded || e.totalCredits == 0) return 0;
        uint256 myC = credits[wallet][epochId];
        uint256 base = (e.rewardPool * myC) / e.totalCredits;
        return (base * e.xauMultBps) / 10000;
    }

    function epochInfo(uint256 epochId) external view returns (
        uint256 totalCredits,
        uint256 rewardPool,
        uint256 xauMultBps,
        bool funded,
        uint256 startTime,
        uint256 endTime
    ) {
        Epoch memory e = epochs[epochId];
        return (e.totalCredits, e.rewardPool, e.xauMultBps, e.funded, e.startTime, e.endTime);
    }

    // ── Admin ─────────────────────────────────────────────────────
    function setCoordinator(address _coordinator) external onlyOwner {
        coordinator = _coordinator;
    }
}

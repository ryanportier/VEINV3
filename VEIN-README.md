# $VEIN — Gold Extraction Protocol
## Proof-of-Inference Mining on Base L2

---

## Architecture

```
vein/
├── contracts/
│   ├── VeinToken.sol   — ERC-20 $VEIN, 100B fixed supply
│   ├── VeinStake.sol   — Rig tiers, stake/unstake, 48h window, 2% penalty
│   ├── VeinSettle.sol  — EIP-712 receipt verification, epoch credits, rewards
│   └── VeinYield.sol   — Passive yield pool from trading fees
│
├── coordinator/
│   ├── server.js       — Node.js API (auth, sites, drill, submit, refine)
│   ├── package.json
│   └── .env.example
│
├── frontend/
│   └── index.html      — Industrial brutal UI, connects to coordinator + contracts
│
└── hardhat.config.ts   — Deploy config for Base Sepolia / Base Mainnet
```

---

## How to run (local / testnet)

### 1. Coordinator API

```bash
cd coordinator
cp .env.example .env
# Fill in:
#   COORDINATOR_PRIVATE_KEY — fresh wallet, NOT your main wallet
#   ANTHROPIC_API_KEY       — for generating challenges
#   SETTLE_CONTRACT_ADDRESS — after step 3

npm install
npm run dev   # starts on :3001
```

### 2. Contracts (Base Sepolia testnet)

```bash
# Install Hardhat
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox @openzeppelin/contracts dotenv

# Add to .env:
#   DEPLOY_PRIVATE_KEY — wallet with Base Sepolia ETH (get free from faucet)
#   BASE_SEPOLIA_RPC   — https://sepolia.base.org (or Alchemy/Infura)
#   COORDINATOR_ADDRESS — public address of coordinator wallet

npx hardhat run scripts/deploy.js --network base-sepolia
```

Get Base Sepolia ETH: https://www.alchemy.com/faucets/base-sepolia

### 3. Frontend

Open `frontend/index.html` in browser directly, or serve with:
```bash
npx serve frontend/
```

Change `const API = 'http://localhost:3001'` to your deployed coordinator URL.
Add `window.SETTLE_CONTRACT_ADDRESS = '0x...'` with the deployed VeinSettle address.

---

## Contract flow

```
User stakes $VEIN in VeinStake → gets tier (Prospector/Shaft/Deep)
  ↓
User (or agent) authenticates with coordinator (BANKR wallet sig)
  ↓
Coordinator returns drill challenge (Claude Haiku)
  ↓
User submits artifact → coordinator verifies deterministically
  ↓
Smelting queue (1h/2h/4h depending on depth)
  ↓
Coordinator signs EIP-712 receipt
  ↓
User submits receipt to VeinSettle.sol on-chain
  ↓
Every 24h: operator calls fundEpoch() with XAU multiplier
  ↓
Users call claimReward() — proportional to credits × XAU mult
```

---

## XAU Oracle

In production, the operator reads the Chainlink XAU/USD price feed on Base:
- Mainnet: `0x...` (check Chainlink docs for Base)
- The coordinator currently uses a hardcoded demo price
- Real integration: call Chainlink in fundEpoch() or pass the price via off-chain snapshot

---

## Token distribution (suggested)

| Allocation          | Amount        | Notes                           |
|---------------------|---------------|---------------------------------|
| Fair launch (BANKR) | 70B (70%)     | Public sale                     |
| Epoch rewards pool  | 15B (15%)     | Locked in VeinSettle, released slowly |
| Team + dev          | 10B (10%)     | 1yr cliff, 2yr vest             |
| Liquidity           | 5B (5%)       | Initial DEX liquidity on Base   |

---

## Security checklist before mainnet

- [ ] Audit VeinSettle.sol (handles real money)
- [ ] Audit VeinStake.sol (handles user stakes)  
- [ ] Test replay protection (solveIndex)
- [ ] Test unstaking edge cases
- [ ] Add emergency pause to VeinSettle
- [ ] Verify Chainlink oracle integration
- [ ] Test with Base Sepolia for at least 1 week

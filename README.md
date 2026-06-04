# 🪙 Barney Stable Coin (BSC)

A decentralized, overcollateralized stablecoin protocol built with Solidity and Foundry.

Barney Stable Coin (BSC) is designed to maintain a soft peg to the US Dollar by allowing users to deposit approved collateral assets and mint stablecoins against their deposited value.

The protocol follows a similar design philosophy to MakerDAO's DAI system:

- 💰 Exogenous Collateral (WETH & WBTC)
- 🔒 Overcollateralized Positions
- 📈 Chainlink Price Feed Oracles
- ⚡ Algorithmic Stability Mechanisms
- 🛡️ Health Factor Enforcement

---

# 📚 Table of Contents

- [Overview](#-overview)
- [How It Works](#-how-it-works)
- [Architecture](#-architecture)
- [Core Features](#-core-features)
- [Health Factor](#-health-factor)
- [Collateral System](#-collateral-system)
- [Price Feeds](#-price-feeds)
- [Project Structure](#-project-structure)
- [Testing](#-testing)
- [Deployment](#-deployment)
- [Foundry Commands](#-foundry-commands)
- [Future Improvements](#-future-improvements)

---

# 🎯 Overview

The protocol consists of two primary smart contracts:

### 1. BarneyStableCoin.sol

The ERC20 stablecoin contract.

Responsibilities:

- Minting BSC
- Burning BSC
- Ownership control
- Restricted minting access

Only the `CoinEngine` contract is allowed to mint and burn stablecoins.

---

### 2. CoinEngine.sol

The protocol's brain.

Responsibilities:

- Accept collateral deposits
- Track user collateral balances
- Mint BSC
- Burn BSC
- Calculate health factors
- Determine collateral value
- Prevent undercollateralization

---

# ⚙️ How It Works

### Deposit Collateral

Users deposit approved collateral:

- WETH
- WBTC

Example:

```text
Deposit 10 WETH
```

At:

```text
ETH = $2,000
```

Collateral Value:

```text
10 × $2,000 = $20,000
```

---

### Mint Stablecoins

The protocol enforces a 200% collateralization ratio.

If collateral value is:

```text
$20,000
```

Maximum mintable BSC:

```text
$10,000
```

This ensures the protocol remains overcollateralized.

---

### Health Factor Protection

Every mint operation checks the user's health factor.

If minting would push the account below the minimum safety threshold:

```solidity
revert CoinEngine__Health_Factor_Below_Minimum();
```

The transaction fails.

---

# 🏗️ Architecture

```text
                    +------------------+
                    |   Chainlink      |
                    |   Price Feeds    |
                    +---------+--------+
                              |
                              v
+------------+      +------------------+
|   WETH     |----->|                  |
+------------+      |                  |
                    |                  |
+------------+----->|   CoinEngine     |
|   WBTC     |      |                  |
+------------+      |                  |
                    +---------+--------+
                              |
                              v
                    +------------------+
                    | BarneyStableCoin |
                    |       BSC        |
                    +------------------+
```

---

# 🚀 Core Features

## Collateral Deposits

Users can deposit supported collateral assets.

```solidity
depositCollateral(token, amount);
```

Features:

- Token whitelist enforcement
- Event emission
- Balance tracking
- Safe transfers

---

## Stablecoin Minting

```solidity
mintBSC(amount);
```

Features:

- Health factor checks
- Collateral ratio enforcement
- Overcollateralization guarantees

---

## USD Value Calculations

The protocol converts collateral into USD value using Chainlink price feeds.

```solidity
getUsdValue(token, amount);
```

Example:

```text
15 ETH × $2,000 = $30,000
```

---

## Reverse Collateral Calculations

Convert USD value back into collateral amount.

```solidity
getCollateralAmountFromUsd(token, usdAmount);
```

Example:

```text
$100 → 0.05 ETH
```

at:

```text
ETH = $2,000
```

---

# ❤️ Health Factor

The health factor determines whether a user is safely collateralized.

Conceptually:

```text
Health Factor =
Adjusted Collateral Value
--------------------------
Stablecoin Minted
```

Where:

```text
Adjusted Collateral Value
=
Collateral Value × Liquidation Threshold
```

The protocol requires:

```text
Health Factor >= 1
```

If:

```text
Health Factor < 1
```

the position becomes unsafe.

---

# 🏦 Collateral System

Currently supported collateral:

| Asset | Purpose |
|---------|---------|
| WETH | Ethereum collateral |
| WBTC | Bitcoin collateral |

Each collateral token has an associated Chainlink price feed.

Mappings maintained by the protocol:

```solidity
Collateral Token
        ↓
Price Feed
```

and

```solidity
User
    ↓
Collateral Deposited
```

---

# 📈 Price Feeds

The protocol uses Chainlink AggregatorV3 price feeds.

Supported feeds:

| Asset | Feed |
|---------|---------|
| ETH/USD | Chainlink |
| BTC/USD | Chainlink |

Benefits:

- Decentralized pricing
- Tamper-resistant data
- Real-time valuation

---

# 🧪 Testing

The project contains extensive unit testing using Foundry.

Current test coverage includes:

## Constructor Tests

- Length mismatch validation
- Token/feed configuration checks

---

## Oracle Tests

- USD valuation calculations
- Collateral conversion calculations

---

## Deposit Tests

- Zero amount reverts
- Unsupported collateral reverts
- Balance updates
- Event emission verification
- Account information tracking

---

## Minting Tests

- Zero mint amount reverts
- Health factor enforcement
- Overcollateralization checks

---

Example test:

```solidity
function testRevertsIfMintBreaksHealthFactor() public
```

Verifies users cannot mint beyond protocol safety limits.

---

# 📂 Project Structure

```text
src/
├── BarneyStableCoin.sol
├── CoinEngine.sol

script/
├── DeployBSC.s.sol
├── HelperConfig.s.sol

test/
├── unit/
│   └── CoinEngine.t.sol
│
├── mocks/
│   └── MockV3Aggregator.sol
```

---

# 🚀 Deployment

Deployment is handled through:

```solidity
DeployBSC.s.sol
```

Deployment flow:

1. Load active network configuration
2. Deploy BarneyStableCoin
3. Deploy CoinEngine
4. Transfer ownership of BSC to CoinEngine
5. Return deployed contract references

Ownership transfer:

```solidity
bsc.transferOwnership(address(engine));
```

This ensures only the engine can mint and burn stablecoins.

---

# 🔧 Network Configuration

The protocol supports:

### Sepolia

Uses live Chainlink price feeds.

Configured assets:

- WETH
- WBTC

---

### Anvil Local Development

Automatically deploys:

- Mock ETH/USD Feed
- Mock BTC/USD Feed
- Mock WETH
- Mock WBTC

This enables deterministic local testing.

---

# 🛠️ Foundry Commands

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Verbose Testing

```bash
forge test -vvvv
```

### Coverage

```bash
forge coverage
```

### Format

```bash
forge fmt
```

### Deploy Locally

```bash
forge script script/DeployBSC.s.sol --broadcast
```

### Deploy To Sepolia

```bash
forge script script/DeployBSC.s.sol \
--rpc-url $SEPOLIA_RPC_URL \
--private-key $PRIVATE_KEY \
--broadcast
```

---

# 🔮 Future Improvements

- Liquidation System
- Collateral Redemption
- Burn Mechanism Enhancements
- Multi-Collateral Support
- Governance
- Stability Fee Model
- Additional Oracle Integrations
- Cross-Chain Deployment
- Formal Verification

---

# 🙏 Acknowledgements

This project was built while studying advanced Solidity development, smart contract architecture, protocol design, oracle integrations, and DeFi risk management using the Foundry framework.

Inspired by:

- MakerDAO
- DAI Stablecoin
- Chainlink Price Feeds
- Foundry Development Framework

---

## 👨‍💻 Author

**Barney**

Blockchain Engineer | Solidity Developer | Smart Contract Security Enthusiast

Building decentralized systems one block at a time. 🚀

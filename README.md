# Barney StableCoin (BSC)

An overcollateralized, USD-pegged stablecoin engine built on Solidity and Foundry.

BSC is a decentralized stablecoin backed by exogenous collateral (WETH and WBTC). Users
deposit collateral and mint BSC against it, subject to a 200% collateralization ratio and
a continuous health-factor check. Undercollateralized positions can be liquidated by
anyone, and a fee-funded reserve acts as a first-loss buffer against bad debt before
losses are recorded on-chain.

The design follows the MakerDAO DAI pattern, with three deliberate additions that are not
present in most reference implementations:

1. A mathematically justified health-factor floor for liquidations (HF = 0.55)
2. A fee-funded reserve that absorbs bad debt as a first-loss layer
3. A full invariant test suite that verifies the accounting cannot silently break

---

## Table of Contents

- [What This Is](#what-this-is)
- [Architecture](#architecture)
- [Key Design Decisions](#key-design-decisions)
- [Health Factor and the 0.55 Threshold](#health-factor-and-the-055-threshold)
- [Bad Debt and the First-Loss Reserve](#bad-debt-and-the-first-loss-reserve)
- [Testing](#testing)
- [Security Invariants](#security-invariants)
- [Project Structure](#project-structure)
- [Deployment](#deployment)
- [Running Fork Tests](#running-fork-tests)
- [Known Limitations](#known-limitations)
- [Roadmap](#roadmap)
- [Origin and Acknowledgements](#origin-and-acknowledgements)

---

## What This Is

Two primary contracts:

**`BarneyStableCoin.sol`** — an ERC20 stablecoin (`BSC`), `Ownable`, `ERC20Burnable`.
Mint and burn are restricted to the owner. Ownership is transferred to `CoinEngine`
during deployment, so the engine — and only the engine — controls supply.

**`CoinEngine.sol`** — the protocol core. Holds collateral, tracks per-user debt,
calculates health factors against live Chainlink price feeds, and enforces
overcollateralization on every mint, redeem, and liquidation. It also manages a
per-token fee-funded reserve that absorbs bad debt.

Users interact through four entry points:

| Function | Purpose |
|---|---|
| `depositCollateral(token, amount)` | Deposit WETH or WBTC as collateral |
| `mintBSC(amount)` | Mint BSC against deposited collateral |
| `burnBSC(amount)` | Burn BSC to reduce debt |
| `redeemCollateral(token, amount)` | Withdraw collateral (0.10% fee accrues to reserve) |
| `liquidate(collateral, user, debtToCover)` | Liquidate an undercollateralized position |

Convenience wrappers `depositCollateralAndMintBSC` and `redeemBSCForCollateral` are
provided for single-transaction flows.

---

## Architecture
┌─────────────────────┐
│ Chainlink Feeds │
│ ETH/USD BTC/USD │
└──────────┬──────────┘
│
┌─────────────┐ │ ┌─────────────┐
│ WETH │────┐ │ ┌────│ WBTC │
└─────────────┘ │ │ │ └─────────────┘
▼ ▼ ▼
┌─────────────────────┐
│ CoinEngine │
│ │
│ • collateral │
│ • debt ledger │
│ • health factor │
│ • reserve │
│ • bad-debt ledger │
└──────────┬──────────┘
│ mint / burn
▼
┌─────────────────────┐
│ BarneyStableCoin │
│ BSC │
└─────────────────────┘
│
▼ (on bad debt absorption)
┌─────────────────────┐
│ Treasury │
│ (configurable) │
└─────────────────────┘

text

### Three layers of solvency protection

| Layer | Mechanism | Status |
|---|---|---|
| **1** | 200% overcollateralization + 10% liquidation bonus | Implemented |
| **2** | 0.10% redeem fee → per-token reserve absorbs bad debt | Implemented |
| **3** | External backstop (`BarneyGuardian`) for catastrophic bad debt | Roadmap |

Layer 1 is the primary defense. Layer 2 is a first-loss buffer that absorbs small
losses without touching the system's collateralization ratio. Layer 3 is the subject
of a companion repository and is not part of this codebase.

---

## Key Design Decisions

Every choice below is deliberate and reflected in the code and tests.

### 200% collateralization, 10% liquidation bonus

Standard parameters from the MakerDAO/DAI lineage. High enough to absorb typical
market volatility before positions become liquidatable, low enough that capital is
not wasted. The 10% bonus is the industry-standard incentive; see the derivation
below for why it is the linchpin of the health-factor floor.

### Fee on redeem only (0.10%), not on deposit or mint

Fees on extraction, not on entry. Deposits and mints are the actions the protocol
wants to encourage; redeems are where the reserve is funded. Denominator is
`BPS_DENOMINATOR = 10_000`, so `REDEEM_FEE_BPS = 10` is exactly 0.10%.

### Per-token reserves, no cross-token absorption

`s_reserve[token]` tracks each collateral token separately. A WETH reserve cannot
cover a WBTC bad debt. This is intentional: cross-token absorption would introduce
an oracle dependency at exactly the moment the system is under stress. Keeping
reserves local keeps the accounting simple and the failure modes bounded.

### Bad-debt sink is a treasury address, not `address(0xdead)`

When the reserve absorbs bad debt, the corresponding collateral is transferred to
the address passed as `i_badDebtSink` in the constructor. For a portfolio
deployment this is a fresh address; for production it would be a protocol
multisig. Absorbing collateral by burning to `0xdead` is also valid, but a
treasury preserves the option to recover value later (Compound's model).

### Reserve absorption moves physical collateral out of the engine

Decrementing `s_reserve[token]` without a matching physical transfer would break
the accounting invariant. The absorption path decrements the reserve **and**
transfers the same amount of collateral to `i_badDebtSink`, keeping
`physical == user_claims + reserve` intact. This is verified by
`invariant_engineBalanceMatchesAccounting`.

### Bad debt is deduplicated per user via `s_recognizedBadDebt`

Without deduplication, a user who is liquidated to zero, re-deposits, and is
liquidated again would have their residual debt recorded twice in
`s_totalBadDebt`. `s_recognizedBadDebt[user]` tracks how much has already been
recognized; new bad debt is `max(0, remainingDebt - recognized)`. This is a
small but important correctness fix beyond the base implementation.

### Constructor validates zero addresses, empty arrays, and duplicates

The engine constructor rejects:
- Array length mismatches
- Empty collateral array
- Zero address for any of: collateral token, price feed, BSC token, bad-debt sink
- Duplicate collateral tokens (O(n²) — fine, n is tiny)

Feeds are **not** validated at construction. A broken feed is caught on first use
via the `OracleLib` staleness, positivity, and round-completeness checks. This
avoids expensive constructor calls and matches how Uniswap V3 pools defer oracle
setup to first observation.

### Decimal-safe oracle math

`getUsdValue` and `getCollateralAmountFromUsd` read `IERC20Metadata(token).decimals()`
and normalize accordingly, so 18-decimal WETH and 8-decimal WBTC both produce correct
18-decimal USD values. Most reference implementations assume 18 decimals and silently
misprice 8-decimal tokens by 10^10.

---

## Health Factor and the 0.55 Threshold

The health factor is defined as:
HF = (collateralValueInUsd × LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION) / debt
= (collateralValueInUsd × 0.5) / debt

text

A position is liquidatable when `HF < 1.0`. **However**, liquidation with a 10%
bonus does not always improve the position's HF. The math:

When a liquidator covers `x` of debt, they receive `1.1x` of collateral. The
position's HF changes by:
new_HF > old_HF ⟺ collateral / debt > 1.1 ⟺ 2 × HF > 1.1 ⟺ HF > 0.55

text

**Below HF = 0.55, every liquidation worsens the position's HF.** A check that
demands `endingHF > startingHF` after liquidation — the standard safety check in
reference implementations — therefore makes positions below 0.55 **permanently
unliquidatable**. Funds are frozen, and the position slowly becomes bad debt.

The engine resolves this by only enforcing HF improvement when
`startingHF >= 0.55`. Below that threshold, the liquidation is allowed to proceed
even though it mathematically worsens HF. Resolution at a loss is better than
permanent freeze.

This threshold is not a magic constant — it is `(1 + liquidationBonus) / 2`. If
the bonus is ever changed to, say, 20%, the threshold becomes 0.60.

---

## Bad Debt and the First-Loss Reserve

**Bad debt** is debt with zero collateral backing. It cannot be liquidated further
because there is nothing to seize.

The engine handles bad debt in two stages:

**Stage 1 — reserve absorption.** When a liquidation leaves residual debt, the
engine attempts to cover it from `s_reserve[collateral]`. The absorbed amount is
transferred to `i_badDebtSink`, decrementing both the reserve and the engine's
physical balance so that the accounting invariant stays intact. Partial absorption
is possible: if the reserve is smaller than the bad debt, it is drained to zero
and the remainder moves to Stage 2.

**Stage 2 — `s_totalBadDebt`.** Any portion the reserve could not cover is
recorded in `s_totalBadDebt`. This value is visible on-chain via
`getTotalBadDebt()` and is the input to Layer 3 (`BarneyGuardian`).

**What the reserve is not.** The reserve is a first-loss buffer, not a guarantee.
It refills from future redemption fees, but it does not retroactively pay down
already-recognized bad debt — that is a governance/backstop decision, not an
automatic engine action. See [Known Limitations](#known-limitations).

---

## Testing

**110+ tests** across four categories, all green locally and in CI.

| Suite | File | Count | Purpose |
|---|---|---|---|
| Unit | `test/unit/CoinEngine.t.sol` | 76 | Every engine function, every error path, every event |
| Unit | `test/unit/BarneyStableCoin.t.sol` | 14 | Token behavior, access control, ERC20 compliance |
| Unit | `test/unit/OracleLib.t.sol` | 7 | Staleness, zero/negative prices, future timestamps |
| Fuzz | `test/fuzz/BarneyFuzz.t.sol` | 8 | Stateless invariants on the token: supply conservation, transfer behavior |
| Invariant | `test/invariant/Invariants.t.sol` | 4 | Stateful invariants over 32,768 randomized calls |
| Fork | `test/fork/ForkIntegration.t.sol` | 5 | Full system against real Sepolia feeds and real WETH |

Run the full suite:

```bash
forge test
Run only the fast unit tests:

bash
forge test --match-path "test/unit/*"
Run the invariant tests with detailed traces:

bash
forge test --match-contract InvariantsTest -vvv
Fork tests
The fork suite exercises the full system against live Chainlink feeds on Sepolia,
using real WETH. WBTC on Sepolia is not deployed as a contract at the expected
address, so the suite uses an 8-decimal mock for the token — but keeps the real
BTC/USD Chainlink feed, so decimal normalization is tested against live data.

The five fork tests:

Full lifecycle — deposit → mint → burn → redeem against real feeds and WETH

WBTC decimal handling — 8-decimal math with live BTC/USD feed

Liquidation + reserve + treasury — full Layer-2 path with a mocked price crash

Oracle staleness — time-warped feed triggers OracleLib__PriceFeed_Is_Stale

Accounting invariant — the same invariant from fuzzing, verified on real state

Security Invariants
Four stateful invariants are enforced across 32,768 randomized calls per run
(256 runs × 128 depth):

invariant_protocolMustHaveMoreValueThanTotalSupply
Total collateral value in USD ≥ total BSC supply. If this ever fails, the protocol
is insolvent.

invariant_engineBalanceMatchesAccounting
For every collateral token:
IERC20(token).balanceOf(engine) == s_totalCollateralDeposited[token] + s_reserve[token]
No wei of collateral is unaccounted for. This is the invariant that proves the
fee and absorption paths do not leak value.

invariant_getterFunctionsShouldNotRevert
All public view functions are callable. Guards against accidentally introducing
a getter that reverts on valid inputs.

invariant_reserveNeverDecreases
The reserve is monotone non-decreasing except when explicitly consumed by
absorption (which is separately verified by the accounting invariant).

Notable fixes caught during development
Decimal normalization — 8-decimal WBTC was mispriced by 10^10 in a naive implementation. Fixed with IERC20Metadata.decimals() normalization and a dedicated regression test.

Bad-debt double-counting — a user who was liquidated to zero, re-deposited, and was liquidated again had their residual debt recorded twice. Fixed with s_recognizedBadDebt[user].

HF-improvement check locking positions below 0.55 — fixed by conditionally applying the check only above the mathematical crossover.

msg.sender == address(engine) self-transfer edge case in the fuzz handler — surfaced by an invariant failure on CI, fixed by using makeAddr actors in the handler.

Project Structure
text
src/
├── BarneyStableCoin.sol           # ERC20 stablecoin
├── CoinEngine.sol                 # Core protocol
└── libraries/
    └── OracleLib.sol              # Chainlink staleness + positivity checks

script/
├── DeployBSC.s.sol                # Deploy BSC + engine, transfer ownership
└── HelperConfig.s.sol             # Sepolia and Anvil configurations

test/
├── unit/
│   ├── CoinEngine.t.sol           # 76 tests
│   ├── BarneyStableCoin.t.sol     # 14 tests
│   └── OracleLib.t.sol            # 7 tests
├── fuzz/
│   └── BarneyFuzz.t.sol           # 8 fuzz tests
├── invariant/
│   ├── Handler.t.sol              # Fuzz handler using makeAddr actors
│   └── Invariants.t.sol           # 4 invariants
├── fork/
│   └── ForkIntegration.t.sol      # 5 fork tests
└── mocks/
    └── ERC20MockEightDec.sol      # 8-decimal ERC20 mock
Deployment
Local (Anvil)
bash
anvil                              # in one terminal
forge script script/DeployBSC.s.sol --broadcast
Anvil configuration deploys mock ETH/USD and BTC/USD feeds, a mock 18-decimal
WETH, and a mock 8-decimal WBTC. No external dependencies required.

Sepolia
bash
forge script script/DeployBSC.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
HelperConfig reads block.chainid and selects the Sepolia configuration, which
uses the real Chainlink ETH/USD and BTC/USD feeds and the real Sepolia WETH
address. The treasury address is passed as the fourth constructor argument to
CoinEngine.

Environment variables required:

bash
# .env
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=0x...
Do not commit .env. Add it to .gitignore. See .env.example for the
expected shape.

Running Fork Tests
Fork tests require a Sepolia RPC URL. The setUp function reads
SEPOLIA_RPC_URL from the environment; if it is missing, fork tests will fail
with vm.envString: environment variable "SEPOLIA_RPC_URL" not found.

Before running fork tests, either:

Option A — Export for the current shell session:

bash
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
forge test --match-path "test/fork/*" -vvv
Option B — Use a .env file and source it:

bash
echo "SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY" > .env
source .env
forge test --match-path "test/fork/*" -vvv
Any Sepolia RPC provider works: Alchemy, Infura, QuickNode, or the public
https://rpc.sepolia.org (rate-limited but sufficient for this test suite).

CI note. The GitHub Actions workflow passes SEPOLIA_RPC_URL via a
repository secret of the same name. Fork PRs from external forks will not have
access to the secret and will see the fork tests fail — this is a GitHub platform
restriction, not a project issue. To run fork tests locally without a key, either
skip the fork suite (--no-match-path "test/fork/*") or use
https://rpc.sepolia.org.

Known Limitations
These are documented by design, not oversights.

Uncovered bad debt above the reserve is tracked but not resolved. Visible
via getTotalBadDebt(). Resolution is the subject of Layer 3
(BarneyGuardian). The engine does not attempt to write off or socialize
losses on its own.

Partial-coverage positions are not bad debt. A position with $1 of
collateral and $1000 of debt has $999 of effectively-unrecoverable value, but
it is not flagged as bad debt until the $1 is also liquidated. This is
intentional — the position remains liquidatable until the collateral is
exhausted.

No cross-token absorption. A WETH reserve cannot cover a WBTC bad debt.
Keeping reserves local to their token avoids cross-oracle dependencies during
stress.

Single Chainlink feed per collateral. No TWAP, no aggregation, no fallback
oracle. A misbehaving feed halts mint/burn/liquidate for that token until the
feed recovers.

Immutable by design. No governance, no upgradeability, no pause. A bug that
escapes review is not fixable in place.

Only WETH and WBTC. The collateral allowlist is set in the constructor and
cannot be modified. This is a deliberate scope restriction.

s_totalBadDebt does not decrement. If a subsequent action partially
covers an already-recognized bad debt, the ledger is not adjusted. Full
coverage is out of scope for this iteration; see MakerDAO's vice variable for
the reference implementation.

No reentrancy guard on the combined wrappers. depositCollateralAndMintBSC
and redeemBSCForCollateral do not declare nonReentrant because their
inner calls each guard individually and run sequentially. This is correct but
easy to "helpfully" break — do not add the modifier to the wrappers.

Roadmap
☑ Layer 1 — Overcollateralization, liquidation, health-factor math, HF < 0.55 resolution
☑ Layer 2 — Fee-funded reserve, bad-debt absorption, treasury sink, accounting invariant
☑ Testing — 110+ tests across unit, fuzz, invariant, and fork suites
☑ CI — GitHub Actions with secret-managed Sepolia RPC
□ Layer 3 — BarneyGuardian: Aave-style Safety Module (separate repository)
□ Formal verification of core invariants (Certora or Halmos)
□ Multiple independent Chainlink feeds per collateral
□ Governance module for adding collateral and tuning parameters
Origin and Acknowledgements
Built while studying the Cyfrin DSC pattern, then extended with a materially
different design in three areas:

The 0.55 HF threshold — a mathematically derived floor below which
liquidations cannot improve HF, requiring a conditional skip of the improvement
check

The fee-funded reserve and its absorption path — first-loss buffer with
accounting-safe treasury transfer

The invariant test suite — including invariant_engineBalanceMatchesAccounting,
which proves the engine cannot silently lose collateral

The base architecture (exogenous collateral, overcollateralization, liquidation
bonus, health factor) is the standard DeFi lending pattern. The additions above
are the parts that required original reasoning.

Inspired by:

MakerDAO DSS (DAI) — the closest architectural ancestor

Compound III — the reserve absorption pattern

Aave V3 — the future direction of Layer 3

Chainlink Price Feeds

Foundry

Author
Barnabas Munuhe

Solidity Developer | Smart Contract Security Enthusiast

GitHub

text

---
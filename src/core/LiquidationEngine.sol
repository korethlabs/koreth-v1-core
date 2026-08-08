// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {FeeCollector} from "./FeeCollector.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";
import {RiskManager} from "../security/RiskManager.sol";

/// @title LiquidationEngine
/// @notice Atomic liquidation: seize LP → unwind → send underlying tokens to liquidator
/// @dev The protocol does NOT swap tokens during liquidation. The liquidator receives
///      the raw underlying tokens (e.g., ETH + USDC) from the LP unwind. This eliminates
///      swap slippage, MEV sandwich attacks, and SwapRouter dependency.
///
///      Protocol fee (Aave pattern): taken as a % of the liquidation bonus from the
///      underlying tokens before sending to the liquidator. Fee goes to FeeCollector
///      for distribution to treasury + insurance.
///
///      For single-asset liquidation UX, use the FlashloanLiquidator periphery contract.
contract LiquidationEngine is ILiquidationEngine, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    ProtocolCore public core;
    IPositionManager public positionManager;
    ILendingEngine public lendingEngine;

    /// @dev Deprecated — swap removed from liquidation flow. Kept for UUPS storage layout.
    address private __deprecated_swapRouter;
    FeeCollector public feeCollector;

    // --- Configurable Parameters ---
    uint256 public maxLiquidationPortion = 5000; // 50%
    /// @dev Deprecated — no swap in liquidation flow. Kept for UUPS storage layout.
    uint256 private __deprecated_maxSwapSlippageBps;

    // --- Absolute Bounds ---
    uint256 public constant MIN_LIQUIDATION_PORTION = 1000;
    uint256 public constant MAX_LIQUIDATION_PORTION_CAP = 10_000;
    uint256 public constant LIQUIDATION_THRESHOLD = 1e18;
    /// @dev Minimum remaining collateral value (in USD, 18 decimals) to keep position alive.
    ///      Below this threshold, remaining value is treated as 0 and bad debt is written off.
    uint256 public constant DUST_THRESHOLD_USD = 1e18; // $1

    // --- Events ---
    event MaxLiquidationPortionUpdated(uint256 oldValue, uint256 newValue);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Emitted when a capped partial liquidation leaves a position still in debt with
    ///         collateral above the dust threshold — latent under-collateralization to monitor.
    event ResidualInsolvency(uint256 indexed positionId, uint256 remainingDebt, uint256 remainingValue);
    /// @notice Emitted when unwind realized more value (at spot) than the Chainlink-sized seize
    ///         target, and the excess underlying was refunded to the borrower (Liquidation M-1).
    event LiquidationOverSeizeRefunded(uint256 indexed positionId, uint256 refund0, uint256 refund1);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    modifier onlyRiskAdmin() {
        ACLManager acl = _acl();
        require(acl.isRiskAdmin(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_RISK_ADMIN");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core, address _positionManager, address _lendingEngine) external initializer {
        require(_core != address(0) && _positionManager != address(0) && _lendingEngine != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        positionManager = IPositionManager(_positionManager);
        lendingEngine = ILendingEngine(_lendingEngine);

        // Set defaults (state variable initializers don't run in proxy context)
        maxLiquidationPortion = 5000;
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    // --- Admin Setters ---

    function setMaxLiquidationPortion(uint256 _maxLiquidationPortion) external onlyRiskAdmin {
        require(_maxLiquidationPortion >= MIN_LIQUIDATION_PORTION, "BELOW_MIN");
        require(_maxLiquidationPortion <= MAX_LIQUIDATION_PORTION_CAP, "ABOVE_MAX");
        emit MaxLiquidationPortionUpdated(maxLiquidationPortion, _maxLiquidationPortion);
        maxLiquidationPortion = _maxLiquidationPortion;
    }

    function setFeeCollector(address _feeCollector) external onlyPoolAdmin {
        require(_feeCollector != address(0), "ZERO_ADDRESS");
        require(_feeCollector.code.length > 0, "NOT_CONTRACT");
        emit FeeCollectorUpdated(address(feeCollector), _feeCollector);
        feeCollector = FeeCollector(_feeCollector);
    }

    /// @notice Resolve the fee collector (reverts if it was never configured).
    /// @dev Mirrors ProtocolCore.getPriceFeedRegistry(). It used to be treated as optional here,
    ///      while LendingPool hard-required the same dependency — and the deploy script only wired
    ///      the pool, so on a live protocol this was unset: the protocol's share of every
    ///      liquidation bonus was skipped, and a bad-debt writeoff paid the swept fees to the
    ///      defaulting borrower while lenders absorbed the loss. Refusing to liquidate until it is
    ///      wired is the safe direction; paying the wrong party silently is not.
    function getFeeCollector() public view returns (FeeCollector) {
        FeeCollector collector = feeCollector;
        require(address(collector) != address(0), "FEE_COLLECTOR_UNSET");
        return collector;
    }

    // --- Core Logic ---

    /// @inheritdoc ILiquidationEngine
    /// @dev Flow:
    ///   1. Accrue interest, verify the position is liquidatable, cap repay at maxRepay.
    ///   2. Pull repayAmount from the liquidator and repay the debt (no fee taken from repayment).
    ///   3. Compute collateralToSeize = repay + liquidationBonus (in USD).
    ///   4. FEE SWEEP: for a V3 position, collect all uncollected fees into the engine FIRST.
    ///      Fees are the borrower's yield, not collateral, so the subsequent unwind seizes
    ///      PRINCIPAL ONLY — a partial liquidation can never over-collect fees.
    ///   5. Unwind liquidity proportional to collateralToSeize; take the protocol fee (% of the
    ///      bonus) to the FeeCollector; send the remaining principal to the liquidator.
    ///      Degenerate case: if the position has NO principal liquidity (totalLiquidity == 0),
    ///      the swept fees ARE the seizure and are paid to the liquidator (and zeroed), so the
    ///      step-7 routing below is skipped for that path.
    ///   6. If debt is fully cleared: return the residual LP/NFT to the borrower. If underwater
    ///      with no collateral left: write the remaining debt off as bad debt.
    ///   7. Route any REMAINING swept fees: to the borrower on a normal liquidation, to the
    ///      FeeCollector on a bad-debt writeoff (a defaulting borrower shouldn't keep fees while
    ///      lenders lose). Skipped entirely for the degenerate path in step 5 (fees already paid).
    /// @param positionId The position to liquidate
    /// @param repayAmount Borrow-asset amount the liquidator repays (<= maxRepay)
    /// @param deadline Unix timestamp after which the call reverts (EXPIRED)
    /// @param minAmount0 Min token0 the liquidator accepts from the seized principal (slippage)
    /// @param minAmount1 Min token1 the liquidator accepts from the seized principal (slippage)
    /// @return profit Always 0 here (liquidator receives two tokens; see LiquidationExecuted event)
    function liquidate(
        uint256 positionId,
        uint256 repayAmount,
        uint256 deadline,
        uint256 minAmount0,
        uint256 minAmount1
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 profit)
    {
        require(repayAmount > 0, "ZERO_AMOUNT");
        require(block.timestamp <= deadline, "EXPIRED");

        // Step 1: Accrue interest BEFORE health factor check
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        require(
            pos.status == IPositionManager.PositionStatus.Active
                || pos.status == IPositionManager.PositionStatus.Borrowed,
            "POSITION_NOT_ACTIVE"
        );
        lendingEngine.accrueInterest(pos.borrowAsset);

        // Step 2: Verify position is liquidatable (with fresh interest)
        (bool canLiquidate, uint256 maxRepay) = isLiquidatable(positionId);
        require(canLiquidate, "NOT_LIQUIDATABLE");
        require(repayAmount <= maxRepay, "EXCEEDS_MAX_REPAY");

        // Step 3: Resolve the shared lending market + collateral risk config (bonus from RiskManager)
        address poolAddr = core.lendingPool(pos.borrowAsset);
        require(poolAddr != address(0), "LENDING_POOL_NOT_FOUND");
        address borrowAsset = pos.borrowAsset;

        // Step 4: Calculate collateral to seize in USD (18 decimals)
        uint256 bonus = _liquidationBonus(pos.lpType);
        uint8 borrowDecimals = TokenUtils.safeDecimals(borrowAsset);
        uint256 collateralToSeizeNormalized;
        {
            uint256 repayUsd = _getRepayValueUsd(borrowAsset, repayAmount, borrowDecimals);
            collateralToSeizeNormalized = repayUsd + ((repayUsd * bonus) / 10_000);
        }

        // Step 5: Pull repayment from liquidator and repay full debt
        // Full repayAmount goes to debt — no fee deduction from repayment.
        {
            uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
            OZIERC20(borrowAsset).safeTransferFrom(msg.sender, address(this), repayAmount);
            uint256 balAfter = IERC20(borrowAsset).balanceOf(address(this));
            require(balAfter >= balBefore && balAfter - balBefore == repayAmount, "FEE_ON_TRANSFER_UNSUPPORTED");
        }
        OZIERC20(borrowAsset).forceApprove(poolAddr, repayAmount);
        lendingEngine.repayOnBehalf(positionId, repayAmount);

        // Step 6: Calculate liquidity to remove proportional to collateral seized
        // Use adapter.getLiquidity() to read actual liquidity (V3 reads from NFT, V2 uses pos.amount)
        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_SET");
        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Step 6a: Sweep uncollected V3 fees out BEFORE seizing principal. Uncollected fees are
        // the borrower's yield, NOT collateral (the oracle values principal only). Sweeping them
        // here means unwind() seizes principal only and cannot over-collect fees on a partial
        // liquidation. The swept fees are routed at the end: to the borrower on a normal
        // liquidation, to the protocol on a bad-debt writeoff (policy b).
        // Gated to UniswapV3 (the only V3-NFT adapter with an implemented collectFees). When
        // PancakeSwapV3/Aerodrome NFT adapters ship, extend this condition to sweep their fees
        // too — otherwise a partial liquidation would over-collect their uncollected fees.
        uint256 sweptFee0;
        uint256 sweptFee1;
        if (pos.lpType == ILPAdapter.LPType.UniswapV3) {
            (sweptFee0, sweptFee1) = adapter.collectFees(pos.lpToken, pos.tokenId);
        }

        // Deliberately the raw oracle value, NOT the haircut value used by getMaxBorrow /
        // getHealthFactor. The haircut is a risk discount on borrowing capacity, not a price: the
        // liquidator is handed real tokens, so the seize ratio must be taken against market value.
        // Discounting here would hand out more liquidity than repayUsd + bonus is worth.
        uint256 positionValue = positionManager.getPositionValue(positionId);
        uint256 totalLiquidity = uint256(adapter.getLiquidity(pos.lpToken, pos.tokenId, pos.amount));

        uint256 amount0;
        uint256 amount1;

        if (totalLiquidity == 0) {
            // No principal liquidity to seize. The swept fees are the only value available, so
            // hand them to the liquidator (who repaid the debt) instead of the borrower.
            // Degenerate/defensive path: unreachable while a position holds debt under
            // principal-only valuation (liquidity can't be drawn to zero below HF 1).
            require(pos.tokenId > 0, "ZERO_LIQUIDITY");
            amount0 = sweptFee0;
            amount1 = sweptFee1;
            sweptFee0 = 0; // consumed by the liquidator — do not double-route below
            sweptFee1 = 0;
        } else {
            // Proportional principal removal (fees already swept, so unwind seizes principal only)
            uint256 liquidityToRemove256;
            if (positionValue == 0 || collateralToSeizeNormalized >= positionValue) {
                liquidityToRemove256 = totalLiquidity;
            } else {
                liquidityToRemove256 = Math.mulDiv(totalLiquidity, collateralToSeizeNormalized, positionValue);
            }
            require(liquidityToRemove256 > 0, "ZERO_LIQUIDITY");
            require(liquidityToRemove256 <= type(uint128).max, "LIQUIDITY_OVERFLOW");
            uint128 liquidityToRemove = uint128(liquidityToRemove256);

            // Step 7: Reduce position amount BEFORE external call (CEI)
            // ERC-20 LP types track liquidity via pos.amount — reduce it.
            // NFT LP types (V3) track liquidity in the NFT — skip.
            bool isErc20LP = pos.lpType == ILPAdapter.LPType.UniswapV2 || pos.lpType == ILPAdapter.LPType.PancakeSwapV2
                || pos.lpType == ILPAdapter.LPType.Curve;
            if (isErc20LP && pos.amount > 0) {
                uint256 amountToReduce = liquidityToRemove256 > pos.amount ? pos.amount : liquidityToRemove256;
                positionManager.reducePositionAmount(positionId, amountToReduce);
            }
            (amount0, amount1) = adapter.unwind(pos.lpToken, pos.tokenId, liquidityToRemove);

            // Step 7b: Clamp an over-seize (Liquidation M-1). liquidityToRemove was sized against the
            // Chainlink fair value (positionValue), but unwind realizes tokens at the pool's actual
            // spot composition. When spot diverges from Chainlink, the realized tokens can be worth
            // more than collateralToSeizeNormalized (repay + bonus) — the liquidator would pocket the
            // difference at the borrower's expense. Re-value what came out at Chainlink and, if it
            // exceeds the target, refund the proportional excess of each token to the borrower.
            //
            // Only on a partial seize. The full-seize branch above is reached exactly when
            // collateralToSeizeNormalized >= positionValue, and on a full unwind realizedUsd equals the
            // whole position's Chainlink value == positionValue <= target — so the clamp would be a
            // mathematical no-op there anyway. Gating it out keeps the full-close residual path (which
            // already returns any leftover to the borrower) as the single owner of full-seize surplus.
            // This never reverts and never reads the pool — realizedUsd comes from the same registry as
            // the seize target, so the two are measured on one ruler and their ratio is manipulation-neutral.
            if (liquidityToRemove256 < totalLiquidity) {
                uint256 realizedUsd = _valueUsd(pos.token0, amount0) + _valueUsd(pos.token1, amount1);
                if (realizedUsd > collateralToSeizeNormalized) {
                    uint256 keep0 = Math.mulDiv(amount0, collateralToSeizeNormalized, realizedUsd);
                    uint256 keep1 = Math.mulDiv(amount1, collateralToSeizeNormalized, realizedUsd);
                    uint256 refund0 = amount0 - keep0;
                    uint256 refund1 = amount1 - keep1;
                    amount0 = keep0;
                    amount1 = keep1;
                    if (refund0 > 0) OZIERC20(pos.token0).safeTransfer(pos.owner, refund0);
                    if (refund1 > 0) OZIERC20(pos.token1).safeTransfer(pos.owner, refund1);
                    emit LiquidationOverSeizeRefunded(positionId, refund0, refund1);
                }
            }
        }

        // Step 8: Protocol fee — taken from underlying tokens.
        // Fee = liquidationFeeBps % of the bonus portion of the seized collateral.
        // This is proportionally deducted from both token0 and token1.
        // Always applied when there are tokens to seize — if the liquidator profits,
        // the protocol should too. For truly worthless positions (amount0=amount1=0),
        // the fee is naturally 0.
        if (bonus > 0) {
            FeeCollector collector = getFeeCollector();
            uint256 feeBps = collector.liquidationFeeBps();
            // fee% of the bonus portion: (bonus / (10000 + bonus)) * feeBps / 10000
            // Simplified: feeBps * bonus / (10000 * (10000 + bonus))
            // Applied proportionally to each token amount.
            uint256 denominator = 10_000 * (10_000 + bonus);
            uint256 feeNumerator = feeBps * bonus;

            if (amount0 > 0 && feeNumerator > 0) {
                uint256 fee0 = Math.mulDiv(amount0, feeNumerator, denominator);
                if (fee0 > 0) {
                    amount0 -= fee0;
                    OZIERC20(pos.token0).forceApprove(address(collector), fee0);
                    collector.collectFee(pos.token0, fee0, address(this), "liquidation");
                }
            }
            if (amount1 > 0 && feeNumerator > 0) {
                uint256 fee1 = Math.mulDiv(amount1, feeNumerator, denominator);
                if (fee1 > 0) {
                    amount1 -= fee1;
                    OZIERC20(pos.token1).forceApprove(address(collector), fee1);
                    collector.collectFee(pos.token1, fee1, address(this), "liquidation");
                }
            }
        }

        // Step 9: Send remaining underlying tokens to liquidator — NO SWAP
        if (amount0 > 0) {
            OZIERC20(pos.token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            OZIERC20(pos.token1).safeTransfer(msg.sender, amount1);
        }

        // Slippage protection — checked AFTER fees so liquidator gets accurate net amounts
        require(amount0 >= minAmount0, "SLIPPAGE_AMOUNT0");
        require(amount1 >= minAmount1, "SLIPPAGE_AMOUNT1");

        // Step 10: Handle full debt repayment — return remaining LP to borrower
        // Track how much collateral value leaves the market for RiskManager supply-cap accounting:
        // a full close removes the whole position value; a partial removes only the seized value.
        // Note: in the degenerate totalLiquidity==0 path positionValue==0, and BOTH terminal
        // branches below (full-close and bad-debt writeoff) overwrite supplyRemovedUsd to
        // positionValue (==0). The residual branch is unreachable there (remainingValue==0<=DUST),
        // so the initial collateralToSeizeNormalized is never recorded — no supply-tracking drift.
        uint256 supplyRemovedUsd = collateralToSeizeNormalized;
        bool badDebt = false;
        uint256 remainingDebt = lendingEngine.getDebt(positionId);
        if (remainingDebt == 0) {
            IPositionManager.Position memory freshPos = positionManager.getPosition(positionId);

            // Return remaining LP to borrower (V2: LP tokens, V3: NFT even if empty)
            uint128 remainingLiquidity = adapter.getLiquidity(freshPos.lpToken, freshPos.tokenId, freshPos.amount);
            bool isNFT = freshPos.lpType == ILPAdapter.LPType.UniswapV3
                || freshPos.lpType == ILPAdapter.LPType.PancakeSwapV3 || freshPos.lpType == ILPAdapter.LPType.Aerodrome;
            if (remainingLiquidity > 0 || isNFT) {
                // NFT positions: always return NFT (even empty — borrower owns it)
                // ERC-20 positions: return remaining LP tokens
                adapter.unlock(freshPos.lpToken, freshPos.tokenId, freshPos.amount, freshPos.owner);
                if (!isNFT && freshPos.amount > 0) {
                    positionManager.reducePositionAmount(positionId, freshPos.amount);
                }
            }

            supplyRemovedUsd = positionValue; // full pre-seizure position value leaves the market
            positionManager.markLiquidated(positionId, msg.sender, repayAmount);
        } else {
            // Step 11: Bad debt writeoff — position underwater, no collateral left to seize
            // Check if position has remaining collateral value (works for both V2 and V3)
            uint256 remainingValue = positionManager.getPositionValue(positionId);
            if (remainingValue <= DUST_THRESHOLD_USD) {
                // No meaningful collateral left — write off remaining debt as bad debt.
                // Dust threshold prevents tiny residual values from blocking writeoff.
                lendingEngine.writeOffDebt(positionId);
                supplyRemovedUsd = positionValue; // full position value leaves the market
                positionManager.markLiquidated(positionId, msg.sender, repayAmount);
                badDebt = true; // route swept fees to the protocol, not the defaulting borrower
            } else {
                // Position still has debt AND collateral above dust after a capped partial
                // liquidation. Surface it so monitoring can catch latent under-collateralization
                // rather than letting it accrue silently until the next liquidation.
                emit ResidualInsolvency(positionId, remainingDebt, remainingValue);
            }
        }

        // Route the swept V3 fees: to the borrower on a normal liquidation, to the protocol on a
        // bad-debt writeoff (policy b — a defaulting borrower shouldn't keep fees while lenders
        // take a loss). The routing no longer degrades when the FeeCollector is missing: falling
        // back to the borrower there inverted the policy exactly when it mattered, paying the
        // defaulter out of a loss the lenders were absorbing.
        if (sweptFee0 > 0 || sweptFee1 > 0) {
            if (badDebt) {
                FeeCollector collector = getFeeCollector();
                if (sweptFee0 > 0) {
                    OZIERC20(pos.token0).forceApprove(address(collector), sweptFee0);
                    collector.collectFee(pos.token0, sweptFee0, address(this), "liquidation_baddebt");
                }
                if (sweptFee1 > 0) {
                    OZIERC20(pos.token1).forceApprove(address(collector), sweptFee1);
                    collector.collectFee(pos.token1, sweptFee1, address(this), "liquidation_baddebt");
                }
            } else {
                if (sweptFee0 > 0) OZIERC20(pos.token0).safeTransfer(pos.owner, sweptFee0);
                if (sweptFee1 > 0) OZIERC20(pos.token1).safeTransfer(pos.owner, sweptFee1);
            }
        }

        // Credit the market's supply-cap tracker for the collateral value that left the protocol.
        positionManager.recordCollateralSeized(positionId, supplyRemovedUsd);

        // profit is not directly calculable here since liquidator receives two tokens.
        // The event emits collateralSeized in USD for off-chain profit tracking.
        profit = 0;

        emit LiquidationExecuted(positionId, msg.sender, repayAmount, collateralToSeizeNormalized, profit);
    }

    /// @notice Health factor below which 100% liquidation is allowed (prevents bad debt)
    uint256 public constant CRITICAL_HF_THRESHOLD = 0.95e18; // 0.95

    /// @inheritdoc ILiquidationEngine
    /// @dev WARNING: This is a view function and does NOT call accrueInterest().
    ///      Health factor may be stale. For accurate results, call
    ///      lendingEngine.accrueInterest(borrowAsset) first, or rely on liquidate()
    ///      which accrues automatically before checking.
    function isLiquidatable(uint256 positionId) public view returns (bool liquidatable, uint256 maxRepay) {
        uint256 healthFactor = positionManager.getHealthFactor(positionId);

        if (healthFactor >= LIQUIDATION_THRESHOLD) {
            return (false, 0);
        }

        uint256 totalDebt = lendingEngine.getDebt(positionId);
        if (totalDebt == 0) return (false, 0);

        if (healthFactor < CRITICAL_HF_THRESHOLD) {
            maxRepay = totalDebt;
        } else {
            maxRepay = (totalDebt * maxLiquidationPortion) / 10_000;
        }

        if (maxRepay == 0) maxRepay = 1;

        return (true, maxRepay);
    }

    /// @inheritdoc ILiquidationEngine
    function getLiquidationBonus(uint256 positionId) public view returns (uint256) {
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        return _liquidationBonus(pos.lpType);
    }

    /// @dev Read the liquidation bonus for an LP collateral type from RiskManager (source of truth).
    function _liquidationBonus(ILPAdapter.LPType lpType) internal view returns (uint256) {
        address rmAddr = core.riskManagerAddr();
        require(rmAddr != address(0), "RISK_MANAGER_NOT_SET");
        return RiskManager(rmAddr).getCollateralConfig(lpType).liquidationBonus;
    }

    // --- Rescue ---

    /// @notice Rescue tokens stuck in this contract (e.g., unexpected transfer)
    /// @dev Only callable by PoolAdmin. Cannot rescue during active liquidation (nonReentrant).
    function rescueTokens(address token, address to, uint256 amount) external onlyPoolAdmin nonReentrant {
        require(token != address(0) && to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "ZERO_AMOUNT");
        OZIERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // --- Internal ---

    /// @notice Convert borrow asset amount to 18-dec USD value
    /// @dev Always through the registry — see LendingEngine._toUsd. Mispricing the repay leg is
    ///      what decides how much collateral gets seized, so guessing here is the last place the
    ///      protocol can afford it.
    function _getRepayValueUsd(address borrowAsset, uint256 amount, uint8 decimals) internal view returns (uint256) {
        require(decimals <= 36, "INVALID_DECIMALS");
        return PriceFeedRegistry(core.getPriceFeedRegistry()).getUsdValue(borrowAsset, amount, decimals);
    }

    /// @notice Value a token amount in 18-dec USD through the Chainlink registry.
    /// @dev Same source and reverts-on-missing-feed discipline as _getRepayValueUsd; used to measure
    ///      what a partial unwind actually realized so an over-seize can be clamped (Liquidation M-1).
    function _valueUsd(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return PriceFeedRegistry(core.getPriceFeedRegistry()).getUsdValue(token, amount, TokenUtils.safeDecimals(token));
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    // Reduced from 50 to 49 after adding feeCollector.
    uint256[49] private __gap;
}

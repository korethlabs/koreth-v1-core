// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {TestPools} from "../helpers/TestPools.sol";
import {TestSecurity} from "../helpers/TestSecurity.sol";

/// @title LiquidationInvariantTest
/// @notice Fuzz-driven invariant tests for liquidation logic.
contract LiquidationInvariantTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LendingPool public market;
    RiskManager public riskManager;
    LPOracleHub public oracleHub;
    FeeCollector public fc;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public lpToken = makeAddr("lpToken");
    address public borrowAsset;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        oracleHub = LPOracleHub(
            address(
                new ERC1967Proxy(address(new LPOracleHub()), abi.encodeCall(LPOracleHub.initialize, (address(core))))
            )
        );

        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(new LendingEngine()), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(new LiquidationEngine()),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        ILendingPool.PoolConfig memory mConfig = ILendingPool.PoolConfig({borrowAsset: address(usdc)});
        market = LendingPool(
            address(
                new ERC1967Proxy(
                    address(new LendingPool()),
                    abi.encodeCall(LendingPool.initialize, (mConfig, address(irm), address(core)))
                )
            )
        );

        fc = new FeeCollector(address(core), makeAddr("treasury"), makeAddr("insurance"));

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        adapter.setTokenReturns(address(usdc), address(usdc));
        adapter.setUnwindAmounts(50e18, 50e18);
        oracle = new MockLPOracle();
        riskManager = new RiskManager(address(core));

        // Fund adapter so unwind can transfer tokens
        usdc.mint(address(adapter), 10_000_000e18);

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV3);
        borrowAsset = address(usdc);
        TestPricing.wireStable(core, address(usdc));
        core.registerLendingPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        aclManager.addRiskAdmin(owner);
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        TestSecurity.wireBreaker(core, pm);
        pm.setLendingEngine(address(le));
        liq.setFeeCollector(address(fc));
        vm.stopPrank();

        // Supply liquidity
        address lender = makeAddr("lender");
        usdc.mint(lender, 10_000_000e18);
        vm.prank(lender);
        usdc.approve(address(market), 10_000_000e18);
        vm.prank(lender);
        market.supply(10_000_000e18);
    }

    // ================================================================
    // INVARIANT 1: Healthy positions must not be liquidatable
    // ================================================================

    function testFuzz_healthyPositionNotLiquidatable(uint256 borrowAmt) public {
        oracle.setPrice(100_000e18);
        uint256 maxBorrow = 65_000e18; // 65% LTV
        borrowAmt = bound(borrowAmt, 1e18, maxBorrow);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, borrowAmt);

        // At current price HF should be > 1.0 (borrowed within LTV, threshold is 75%)
        uint256 hf = pm.getHealthFactor(posId);
        if (hf >= 1e18) {
            (bool liquidatable,) = liq.isLiquidatable(posId);
            assertFalse(liquidatable, "Healthy position must not be liquidatable");
        }
    }

    // ================================================================
    // INVARIANT 2: Position becomes liquidatable when HF < 1.0
    // ================================================================

    function testFuzz_undercollateralizedIsLiquidatable(uint256 priceDrop) public {
        oracle.setPrice(100_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Borrow close to max LTV
        vm.prank(user);
        le.borrow(posId, 60_000e18);

        // Drop price enough to make HF < 1.0
        // liquidationThreshold = 75%, debt = 60k, need value < 60k/0.75 = 80k
        priceDrop = bound(priceDrop, 25_000e18, 50_000e18);
        oracle.setPrice(100_000e18 - priceDrop);

        uint256 hf = pm.getHealthFactor(posId);
        if (hf < 1e18) {
            (bool liquidatable,) = liq.isLiquidatable(posId);
            assertTrue(liquidatable, "Undercollateralized position must be liquidatable");
        }
    }

    // ================================================================
    // INVARIANT 3: Liquidation must reduce debt
    // ================================================================

    function testFuzz_liquidationReducesDebt(uint256 repayAmt) public {
        oracle.setPrice(100_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, 60_000e18);

        // Crash price to make liquidatable
        oracle.setPrice(70_000e18);

        // Asserted rather than returned on: the setup is deterministic in everything that decides
        // liquidatability — the borrow is a fixed 60_000e18 and the crash a fixed 70_000e18, with
        // the fuzzed input only sizing the repay afterwards — so an early return here would be a
        // silent pass, not a skipped edge case.
        (bool liquidatable, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(liquidatable, "Crashed position must be liquidatable");
        assertGt(maxRepay, 0, "Liquidatable position must allow a non-zero repay");

        repayAmt = bound(repayAmt, 1e18, maxRepay);
        uint256 debtBefore = le.getDebt(posId);

        address liquidator = makeAddr("liquidator");
        usdc.mint(liquidator, repayAmt);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmt);
        vm.prank(liquidator);
        liq.liquidate(posId, repayAmt, block.timestamp + 300, 0, 0);

        uint256 debtAfter = le.getDebt(posId);
        assertLt(debtAfter, debtBefore, "Liquidation must reduce debt");
    }

    // ================================================================
    // INVARIANT 4: Liquidation bonus must not exceed position value
    // ================================================================

    function testFuzz_liquidationBonusBounded(uint256 borrowAmt) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 30_000e18, 65_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, borrowAmt);

        // Must equal the configured market bonus (500 bps = 5%) — catches misconfiguration/regressions
        uint256 bonus = liq.getLiquidationBonus(posId);
        assertEq(bonus, 500, "Liquidation bonus must match configured market bonus");
    }

    // ================================================================
    // INVARIANT 5: Non-owner cannot borrow against someone else's position
    // ================================================================

    function testFuzz_borrowIsolation(uint256 borrowAmt) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 1e18, 65_000e18);

        address alice = makeAddr("alice");
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert();
        le.borrow(posId, borrowAmt);
    }

    // ================================================================
    // INVARIANT 6: Below the critical health threshold the whole debt is
    //              repayable, and a position left with no debt is closed
    // ================================================================

    function testFuzz_fullLiquidationClosesPosition(uint256 borrowRatio) public {
        oracle.setPrice(100_000e18);
        borrowRatio = bound(borrowRatio, 8000, 9500); // 80-95% of max LTV
        uint256 borrowAmt = (65_000e18 * borrowRatio) / 10_000;

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, borrowAmt);

        // Crash price severely
        oracle.setPrice(50_000e18);

        // Asserted rather than returned on: every input in the fuzzed range crashes the position
        // past the liquidation threshold, so an early return here would be a silent pass rather
        // than a skipped edge case.
        (bool liquidatable, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(liquidatable, "Crashed position must be liquidatable");
        assertGt(maxRepay, 0, "Liquidatable position must allow a non-zero repay");

        uint256 debtBefore = le.getDebt(posId);

        address liquidator = makeAddr("liquidator");
        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);
        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 300, 0, 0);

        IPositionManager.Position memory pos = pm.getPosition(posId);

        // Keyed on the debt rather than on `pos.amount`. The collateral here is an NFT LP type,
        // for which `amount` is 0 by construction and the engine leaves it untouched — it only
        // reduces `amount` for ERC-20 LP. So `amount` says nothing about how much collateral is
        // left, and a check guarded on it never runs on the NFT path in either polarity.
        //
        // The full repay below is a property of these inputs, not of liquidation in general. The
        // engine only lets a liquidator take the whole debt once health is under
        // CRITICAL_HF_THRESHOLD; above it, and still under 1.0, maxRepay is capped by the close
        // factor and residual debt survives on purpose. This setup deliberately crashes past that
        // threshold — halving the price against a borrow of 80-95% of max LTV puts health in
        // [0.607, 0.721] across the whole bound, far below 0.95 — so maxRepay is the entire debt
        // and clearing it is the only correct outcome. Widen the bound or soften the crash and
        // that stops holding: the assertion is then failing accurately, not spuriously.
        assertGt(debtBefore, 0, "Setup must leave debt for the liquidation to clear");
        assertEq(le.getDebt(posId), 0, "A full repay below the critical health threshold must clear the debt");
        assertEq(
            uint8(pos.status),
            uint8(IPositionManager.PositionStatus.Liquidated),
            "A position with no debt left must be marked Liquidated"
        );
    }
}

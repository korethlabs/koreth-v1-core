// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockAccruingLendingPool} from "../mocks/MockAccruingLendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {TestPools} from "../helpers/TestPools.sol";
import {TestSecurity} from "../helpers/TestSecurity.sol";

/// @notice Transformer that does nothing, so transform() runs to its post-transform health check.
contract NoopTransformer {
    function noop() external {}
}

/// @title AccrueBeforeHealthCheck (M1 regression)
/// @notice removeCollateral() and transform() must accrue interest before reading the health factor.
/// @dev getHealthFactor -> getDebt reads the pool's borrow index as of the last accrual. If a caller
///      gates a collateral-reducing action on that figure without first poking accrual, a pool that
///      has interest pending (index not yet advanced this block) reports understated debt and an
///      overstated health factor — letting an owner pull collateral (or transform) out of a position
///      that is actually underwater. borrow() and liquidate() already accrue first; these two paths
///      did not. Each test drives a real borrow through the LendingEngine so debt is index-sensitive,
///      then schedules pending interest that only materialises on accrueInterest(): at the stale index
///      the position reads healthy (asserted), so a non-accruing check would pass — the fix makes the
///      call accrue first, see the true sub-1 health factor, and revert.
contract AccrueBeforeHealthCheckTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockAccruingLendingPool public market;
    RiskManager public riskManager;
    MockERC20 public usdc;
    address public borrowAsset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public lpToken = makeAddr("lpToken");

    // $50K collateral at 65% LTV / 75% liquidation threshold: a maxed borrow of $32,500 has a health
    // factor of 37,500 / 32,500 = 1.1538. A pending index of 1.2x lifts debt to $39,000, dropping the
    // true health factor to 0.9615 — underwater, but only once the interest is accrued.
    uint256 internal constant COLLATERAL = 50_000e18;
    uint256 internal constant MAX_BORROW = 32_500e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant PENDING_INDEX = 1.2e27;

    function setUp() public {
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

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(COLLATERAL);
        usdc = new MockERC20("USDC", "USDC", 18);
        borrowAsset = address(usdc);
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);
        market = new MockAccruingLendingPool(address(usdc), address(irm));
        riskManager = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV3);
        TestPricing.wireStable(core, address(usdc));
        core.registerLendingPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        TestSecurity.wireBreaker(core, pm);
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Fund the pool so borrow()'s transferOut succeeds.
        usdc.mint(address(market), 1_000_000e18);
    }

    /// @dev Deposit, clear the borrow cooldown, and borrow the full LTV so the position sits at a
    ///      health factor just above 1 while the pool's index is fresh.
    function _openMaxedBorrow() internal returns (uint256 posId) {
        vm.prank(alice);
        posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, MAX_BORROW);
    }

    function test_removeCollateral_accruesBeforeHealthCheck() public {
        uint256 posId = _openMaxedBorrow();

        // Schedule interest that has NOT yet been folded into the live index.
        market.setPendingIndex(PENDING_INDEX);

        // At the stale index the position still reads healthy, so a health check that skipped accrual
        // would let the removal through.
        assertEq(market.borrowIndex(), RAY, "index still stale before accrual");
        assertGe(pm.getHealthFactor(posId), 1e18, "stale health factor looks solvent");

        // No token movement on unwind — isolate the health-check path.
        adapter.setUnwindAmounts(0, 0);

        vm.prank(alice);
        vm.expectRevert("UNHEALTHY_AFTER_REMOVAL");
        pm.removeCollateral(posId, 1e18, 0, 0);
    }

    function test_transform_accruesBeforeHealthCheck() public {
        uint256 posId = _openMaxedBorrow();

        NoopTransformer transformer = new NoopTransformer();
        vm.prank(owner);
        aclManager.addTransformer(address(transformer));

        market.setPendingIndex(PENDING_INDEX);

        assertEq(market.borrowIndex(), RAY, "index still stale before accrual");
        assertGe(pm.getHealthFactor(posId), 1e18, "stale health factor looks solvent");

        vm.prank(alice);
        vm.expectRevert("UNHEALTHY_AFTER_TRANSFORM");
        pm.transform(posId, address(transformer), abi.encodeCall(NoopTransformer.noop, ()));
    }

    /// @dev Positive control: with no pending interest, the same maxed position stays solvent and the
    ///      removal succeeds — proving the reverts above are the accrual biting, not an unrelated gate.
    function test_removeCollateral_succeedsWhenFullyAccrued() public {
        uint256 posId = _openMaxedBorrow();

        adapter.setUnwindAmounts(0, 0);

        vm.prank(alice);
        pm.removeCollateral(posId, 1e18, 0, 0);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Borrowed), "still borrowed");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockLendingPool} from "../mocks/MockLendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {TestPools} from "../helpers/TestPools.sol";

contract CircuitBreakerIntegrationTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    CircuitBreaker public cb;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockLendingPool public market;
    MockERC20 public usdc;
    InterestRateModel public irm;
    RiskManager public riskManager;

    address public owner = makeAddr("owner");
    address public keeper = makeAddr("keeper");
    address public alice = makeAddr("alice");
    address public lpToken = makeAddr("lpToken");

    address public borrowAsset;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        cb = new CircuitBreaker(address(core));

        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);
        market = new MockLendingPool(address(usdc), address(irm));
        borrowAsset = address(usdc);
        riskManager = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        aclManager.addKeeper(keeper);
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV3);
        TestPricing.wireStable(core, address(usdc));
        core.registerLendingPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        pm.setLendingEngine(address(le));
        pm.setCircuitBreaker(address(cb));
        vm.stopPrank();

        usdc.mint(address(market), 10_000_000e18);
    }

    // ========== Deposit ==========

    function test_deposit_revertsWhenPoolPaused() public {
        // Keeper pauses the pool
        vm.prank(keeper);
        cb.pausePool(lpToken, "TVL_DROP");

        vm.prank(alice);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        pm.deposit(lpToken, 1, 100e18, borrowAsset);
    }

    function test_deposit_worksWhenPoolNotPaused() public {
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, borrowAsset);
    }

    // ========== Borrow ==========

    function test_borrow_revertsWhenPoolPaused() public {
        // Deposit first (pool not paused yet)
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Keeper pauses the pool
        vm.prank(keeper);
        cb.pausePool(lpToken, "VOLATILITY");

        // Borrow should fail
        vm.prank(alice);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        le.borrow(posId, 30_000e18);
    }

    // ========== Withdraw ==========

    function test_withdraw_worksWhenPoolPaused() public {
        // Deposit
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);

        // Keeper pauses the pool
        vm.prank(keeper);
        cb.pausePool(lpToken, "TVL_DROP");

        // User can still withdraw (exit should always work)
        vm.prank(alice);
        pm.withdraw(posId);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Closed));
    }

    // ========== Pricing During Pause ==========

    function test_getPositionValue_worksWhenPoolPaused() public {
        // Deposit and borrow
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        // Keeper pauses the pool
        vm.prank(keeper);
        cb.pausePool(lpToken, "RESERVE_DRIFT");

        // Health factor should still be computable (getPositionValue works)
        uint256 value = pm.getPositionValue(posId);
        assertGt(value, 0, "Position value must work during pause");
    }

    // ========== Unpause ==========

    function test_deposit_worksAfterUnpause() public {
        vm.prank(keeper);
        cb.pausePool(lpToken, "TVL_DROP");

        // Blocked
        vm.prank(alice);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        pm.deposit(lpToken, 1, 100e18, borrowAsset);

        // Unpause
        vm.prank(owner);
        cb.unpausePool(lpToken);

        // Works again
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, borrowAsset);
    }

    // ========== Admin ==========

    function test_setCircuitBreaker_onlyPoolAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        pm.setCircuitBreaker(address(cb));
    }

    /// @dev The breaker used to be detachable, and every freeze check sat behind a null test — so
    ///      clearing it did not disable one lever, it disabled the entire circuit breaker across
    ///      deposits, borrows and collateral changes, with only an event to say so.
    /// @dev Mirrors ProtocolCore.getPriceFeedRegistry(): a mandatory dependency that is not yet
    ///      wired says so, instead of reverting as a call into an empty address.
    function test_getCircuitBreaker_revertsWhenUnset() public {
        PositionManager bare = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        vm.expectRevert("CIRCUIT_BREAKER_UNSET");
        bare.getCircuitBreaker();
    }

    function test_circuitBreakerCannotBeDetached() public {
        address attached = address(pm.circuitBreaker());

        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        pm.setCircuitBreaker(address(0));

        assertEq(address(pm.circuitBreaker()), attached, "breaker must survive the attempt");
    }
}

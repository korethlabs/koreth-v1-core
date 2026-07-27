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
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract CircuitBreakerIntegrationTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    CircuitBreaker public cb;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public keeper = makeAddr("keeper");
    address public alice = makeAddr("alice");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;

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
        market = new MockMarket(address(usdc), address(irm));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        aclManager.addKeeper(keeper);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
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
        pm.deposit(lpToken, 1, 100e18, marketId);
    }

    function test_deposit_worksWhenPoolNotPaused() public {
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId);
    }

    // ========== Borrow ==========

    function test_borrow_revertsWhenPoolPaused() public {
        // Deposit first (pool not paused yet)
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
        pm.deposit(lpToken, 1, 100e18, marketId);

        // Unpause
        vm.prank(owner);
        cb.unpausePool(lpToken);

        // Works again
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId);
    }

    // ========== Admin ==========

    function test_setCircuitBreaker_onlyPoolAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        pm.setCircuitBreaker(address(cb));
    }

    function test_worksWithoutCircuitBreaker() public {
        // Remove circuit breaker
        vm.prank(owner);
        pm.setCircuitBreaker(address(0));

        // Deposit works
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId);
    }
}

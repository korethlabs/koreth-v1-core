// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title DepositValidationTest
/// @notice Tests for deposit-time validations: circuit breaker warning, oracle health check
contract DepositValidationTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LPOracleHub public oracleHub;
    CircuitBreaker public circuitBreaker;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public lpToken = makeAddr("lpToken");
    uint256 public marketId;

    event CircuitBreakerNotConfigured(uint256 indexed marketId, address pool);

    function setUp() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 18);
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

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
        LendingEngine le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        market = new MockMarket(address(usdc), address(irm));
        market.setLpType(ILPAdapter.LPType.UniswapV2);
        circuitBreaker = new CircuitBreaker(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();
    }

    // ========== LP Type Mismatch ==========

    /// @notice Depositing an LP whose detected type differs from the market's configured type reverts.
    function test_deposit_revertsLpTypeMismatch() public {
        // lpToken is detected as UniswapV2 (adapter). Register a market configured for UniswapV3.
        MockMarket v3Market = new MockMarket(makeAddr("borrowAsset"), makeAddr("irm2"));
        v3Market.setLpType(ILPAdapter.LPType.UniswapV3);
        vm.prank(owner);
        uint256 v3MarketId = core.registerMarket(address(v3Market));

        vm.prank(alice);
        vm.expectRevert("LP_TYPE_MISMATCH");
        pm.deposit(lpToken, 0, 100e18, v3MarketId);
    }

    // ========== Zero-value deposit rejection ==========

    /// @notice A position the oracle prices at 0 is rejected by the generic ZERO_VALUE guard.
    ///         (Under principal-only valuation this is exactly what a fee-only / liquidity-less V3
    ///         position prices to — no separate NO_PRINCIPAL guard needed.) Here we model that
    ///         generically by forcing the mock oracle's totalValue to 0.
    function test_deposit_revertsZeroValue() public {
        oracle.setPrice(0); // mock oracle → totalValue == 0

        vm.prank(alice);
        vm.expectRevert("ZERO_VALUE");
        pm.deposit(lpToken, 0, 100e18, marketId);
    }

    /// @notice A normal position (principal > 0) deposits fine.
    function test_deposit_succeedsWithPrincipal() public {
        oracle.setPrice(100e18);

        vm.prank(alice);
        pm.deposit(lpToken, 0, 100e18, marketId);
    }

    // ========== CircuitBreaker Warning ==========

    function test_deposit_emitsCircuitBreakerNotConfigured() public {
        vm.expectEmit(true, false, false, true);
        emit CircuitBreakerNotConfigured(marketId, lpToken);

        vm.prank(alice);
        pm.deposit(lpToken, 0, 100e18, marketId);
    }

    function test_deposit_noEventWhenCircuitBreakerSet() public {
        vm.prank(owner);
        pm.setCircuitBreaker(address(circuitBreaker));

        vm.recordLogs();
        vm.prank(alice);
        pm.deposit(lpToken, 0, 100e18, marketId);

        // Verify CircuitBreakerNotConfigured was NOT emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 cbEventSig = keccak256("CircuitBreakerNotConfigured(uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertFalse(logs[i].topics[0] == cbEventSig, "Should not emit CircuitBreakerNotConfigured");
            }
        }
    }

    // ========== Oracle Health Check ==========

    function test_deposit_blockedWhenOracleUnhealthy() public {
        vm.prank(owner);
        pm.setCircuitBreaker(address(circuitBreaker));

        oracle.setHealthy(false);

        vm.prank(alice);
        vm.expectRevert("ORACLE_UNHEALTHY");
        pm.deposit(lpToken, 0, 100e18, marketId);
    }

    function test_deposit_worksWhenOracleHealthy() public {
        vm.prank(owner);
        pm.setCircuitBreaker(address(circuitBreaker));

        oracle.setHealthy(true);

        vm.prank(alice);
        pm.deposit(lpToken, 0, 100e18, marketId);
    }
}

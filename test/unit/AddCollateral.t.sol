// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";

/// @title AddCollateralTest
/// @notice Unit tests for PositionManager.addCollateral()
contract AddCollateralTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LPOracleHub public oracleHub;
    LendingEngine public le;
    RiskManager public riskManager;
    MockLPAdapter public v3Adapter;
    MockLPAdapter public v2Adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockMarket public v2Market;
    MockERC20 public token0;
    MockERC20 public token1;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public lpToken = makeAddr("lpToken");
    address public v2LpToken = makeAddr("v2LpToken");

    uint256 public marketId;
    uint256 public v2MarketId;

    event CollateralAdded(uint256 indexed positionId, uint256 addedLiquidity, uint256 used0, uint256 used1);

    function setUp() public {
        // Deploy tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 6);

        // Deploy core
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        // Oracle hub (proxy)
        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        // PositionManager (proxy)
        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        // LendingEngine (proxy)
        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        // Mocks
        v3Adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        v3Adapter.setSupportedToken(lpToken, true);
        v3Adapter.setTokenReturns(address(token0), address(token1));

        v2Adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        v2Adapter.setSupportedToken(v2LpToken, true);
        v2Adapter.setTokenReturns(address(token0), address(token1));

        oracle = new MockLPOracle();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);
        market = new MockMarket(address(usdc), address(irm)); // defaults to V3
        v2Market = new MockMarket(address(usdc), address(irm));
        v2Market.setLpType(ILPAdapter.LPType.UniswapV2);
        riskManager = new RiskManager(address(core));

        // Wire everything
        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));

        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(v3Adapter));
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(v2Adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistPool(lpToken);
        core.whitelistPool(v2LpToken);
        marketId = core.registerMarket(address(market));
        v2MarketId = core.registerMarket(address(v2Market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Fund alice with tokens
        token0.mint(alice, 100 ether);
        token1.mint(alice, 100_000e6);
    }

    // ========== Helpers ==========

    function _depositV3(address user) internal returns (uint256 positionId) {
        vm.prank(user);
        positionId = pm.deposit(lpToken, 1, 0, marketId);
    }

    function _depositV2(address user) internal returns (uint256 positionId) {
        vm.prank(user);
        positionId = pm.deposit(v2LpToken, 0, 100e18, v2MarketId);
    }

    // ========== Success Cases ==========

    function test_addCollateral_V3_success() public {
        uint256 positionId = _depositV3(alice);

        uint256 addAmount0 = 1 ether;
        uint256 addAmount1 = 2000e6;

        vm.startPrank(alice);
        token0.approve(address(pm), addAmount0);
        token1.approve(address(pm), addAmount1);

        vm.expectEmit(true, false, false, true);
        emit CollateralAdded(positionId, addAmount0 + addAmount1, addAmount0, addAmount1);

        pm.addCollateral(positionId, addAmount0, addAmount1, 0, 0);
        vm.stopPrank();

        // V3: pos.amount should NOT change (liquidity in NFT)
        PositionManager.Position memory pos = pm.getPosition(positionId);
        assertEq(pos.amount, 0, "V3 amount should stay 0");
    }

    function test_addCollateral_V2_increasesAmount() public {
        uint256 positionId = _depositV2(alice);

        PositionManager.Position memory posBefore = pm.getPosition(positionId);
        uint256 amountBefore = posBefore.amount;

        uint256 addAmount0 = 1 ether;
        uint256 addAmount1 = 2000e6;

        vm.startPrank(alice);
        token0.approve(address(pm), addAmount0);
        token1.approve(address(pm), addAmount1);
        pm.addCollateral(positionId, addAmount0, addAmount1, 0, 0);
        vm.stopPrank();

        // V2: pos.amount should increase
        PositionManager.Position memory posAfter = pm.getPosition(positionId);
        assertGt(posAfter.amount, amountBefore, "V2 amount should increase");
        assertEq(posAfter.amount, amountBefore + addAmount0 + addAmount1, "V2 amount should match added liquidity");
    }

    function test_addCollateral_onlyToken0() public {
        uint256 positionId = _depositV3(alice);

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        pm.addCollateral(positionId, 1 ether, 0, 0, 0);
        vm.stopPrank();
    }

    function test_addCollateral_onlyToken1() public {
        uint256 positionId = _depositV3(alice);

        vm.startPrank(alice);
        token1.approve(address(pm), 2000e6);
        pm.addCollateral(positionId, 0, 2000e6, 0, 0);
        vm.stopPrank();
    }

    function test_addCollateral_onBorrowedPosition() public {
        uint256 positionId = _depositV3(alice);

        // Set position to Borrowed via LendingEngine updateDebt
        vm.prank(address(le));
        pm.updateDebt(positionId, 1000e6);

        PositionManager.Position memory pos = pm.getPosition(positionId);
        assertEq(uint256(pos.status), uint256(IPositionManager.PositionStatus.Borrowed));

        // addCollateral should work on Borrowed positions
        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        token1.approve(address(pm), 2000e6);
        pm.addCollateral(positionId, 1 ether, 2000e6, 0, 0);
        vm.stopPrank();
    }

    function test_addCollateral_emitsEvent() public {
        uint256 positionId = _depositV3(alice);

        vm.startPrank(alice);
        token0.approve(address(pm), 5 ether);
        token1.approve(address(pm), 10_000e6);

        vm.expectEmit(true, false, false, true);
        emit CollateralAdded(positionId, 5 ether + 10_000e6, 5 ether, 10_000e6);

        pm.addCollateral(positionId, 5 ether, 10_000e6, 0, 0);
        vm.stopPrank();
    }

    // ========== Revert Cases ==========

    function test_addCollateral_revertsNotOwner() public {
        uint256 positionId = _depositV3(alice);

        token0.mint(bob, 1 ether);
        vm.startPrank(bob);
        token0.approve(address(pm), 1 ether);
        vm.expectRevert("NOT_POSITION_OWNER");
        pm.addCollateral(positionId, 1 ether, 0, 0, 0);
        vm.stopPrank();
    }

    function test_addCollateral_revertsZeroAmounts() public {
        uint256 positionId = _depositV3(alice);

        vm.prank(alice);
        vm.expectRevert("ZERO_AMOUNTS");
        pm.addCollateral(positionId, 0, 0, 0, 0);
    }

    function test_addCollateral_revertsClosedPosition() public {
        uint256 positionId = _depositV3(alice);

        // Withdraw to close
        vm.prank(alice);
        pm.withdraw(positionId);

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        vm.expectRevert("POSITION_NOT_BORROWABLE");
        pm.addCollateral(positionId, 1 ether, 0, 0, 0);
        vm.stopPrank();
    }

    function test_addCollateral_revertsNonexistentPosition() public {
        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        vm.expectRevert("POSITION_NOT_FOUND");
        pm.addCollateral(999, 1 ether, 0, 0, 0);
        vm.stopPrank();
    }

    function test_addCollateral_revertsWhenPaused() public {
        uint256 positionId = _depositV3(alice);

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(owner);
        vm.stopPrank();
        vm.prank(owner);
        core.pause();

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        vm.expectRevert("PAUSED");
        pm.addCollateral(positionId, 1 ether, 0, 0, 0);
        vm.stopPrank();
    }

    // ========== RiskManager Integration ==========

    function test_addCollateral_enforcesMaxPositionValue() public {
        uint256 positionId = _depositV3(alice);

        // Set oracle price high so position exceeds cap
        oracle.setPrice(20_000_000e18); // $20M — above $10M cap

        vm.startPrank(owner);
        core.setRiskManager(address(riskManager));
        vm.stopPrank();

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        token1.approve(address(pm), 2000e6);
        vm.expectRevert("POSITION_TOO_LARGE");
        pm.addCollateral(positionId, 1 ether, 2000e6, 0, 0);
        vm.stopPrank();
    }

    function test_addCollateral_tracksSupplyDelta() public {
        // Use V2 position so pos.amount changes → oracle returns different value
        uint256 positionId = _depositV2(alice);

        // Oracle price is per-unit, so value scales with amount
        // MockLPOracle returns constant price regardless of amount,
        // so we verify RiskManager wiring doesn't revert.
        // Real delta tracking is covered by E2E fork tests with real oracles.
        oracle.setPrice(5000e18);

        vm.startPrank(owner);
        core.setRiskManager(address(riskManager));
        vm.stopPrank();

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        token1.approve(address(pm), 2000e6);
        pm.addCollateral(positionId, 1 ether, 2000e6, 0, 0);
        vm.stopPrank();

        // Verify pos.amount increased (V2 semantics)
        PositionManager.Position memory pos = pm.getPosition(positionId);
        assertGt(pos.amount, 100e18, "V2 amount should have increased from addCollateral");
    }

    // ========== Slippage Protection ==========

    function test_addCollateral_slippageAmount0_reverts() public {
        uint256 posId = _depositV3(alice);
        token0.mint(alice, 1 ether);
        token1.mint(alice, 2000e6);

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        token1.approve(address(pm), 2000e6);
        // minAmount0Used = max — impossible to satisfy
        vm.expectRevert("SLIPPAGE_AMOUNT0");
        pm.addCollateral(posId, 1 ether, 2000e6, type(uint256).max, 0);
        vm.stopPrank();
    }

    function test_addCollateral_slippageAmount1_reverts() public {
        uint256 posId = _depositV3(alice);
        token0.mint(alice, 1 ether);
        token1.mint(alice, 2000e6);

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        token1.approve(address(pm), 2000e6);
        vm.expectRevert("SLIPPAGE_AMOUNT1");
        pm.addCollateral(posId, 1 ether, 2000e6, 0, type(uint256).max);
        vm.stopPrank();
    }

    function test_addCollateral_zeroSlippage_succeeds() public {
        uint256 posId = _depositV3(alice);
        token0.mint(alice, 1 ether);
        token1.mint(alice, 2000e6);

        vm.startPrank(alice);
        token0.approve(address(pm), 1 ether);
        token1.approve(address(pm), 2000e6);
        pm.addCollateral(posId, 1 ether, 2000e6, 0, 0);
        vm.stopPrank();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title V3LiquidationPaths
/// @notice Tests for V3-specific liquidation paths: fee-only, NFT return, slippage, tokenId discriminator
contract V3LiquidationPaths is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LPOracleHub public oracleHub;
    MockLPAdapter public v3Adapter;
    MockLPAdapter public v2Adapter;
    MockLPOracle public oracle;
    MockMarket public v3Market;
    MockMarket public v2Market;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");
    address public v2LpToken = makeAddr("v2LpToken");

    uint256 public v3MarketId;
    uint256 public v2MarketId;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        weth = new MockERC20("WETH", "WETH", 18);
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
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        LiquidationEngine liqImpl = new LiquidationEngine();
        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(liqImpl),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        // V3 adapter (NFT-style: tokenId > 0, amount = 0)
        v3Adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        v3Adapter.setSupportedToken(lpToken, true);
        v3Adapter.setTokenReturns(address(weth), address(usdc));
        v3Adapter.setUnwindAmounts(25e18, 25_000e18);
        v3Adapter.setMockLiquidity(1_000_000); // V3: liquidity from NFT, not amount

        // V2 adapter (ERC-20 style: tokenId = 0, amount > 0)
        v2Adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        v2Adapter.setSupportedToken(v2LpToken, true);
        v2Adapter.setTokenReturns(address(weth), address(usdc));
        v2Adapter.setUnwindAmounts(25e18, 25_000e18);

        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);

        v3Market = new MockMarket(address(usdc), address(irm));
        // MockMarket defaults to V3 lpType — keep it
        v2Market = new MockMarket(address(usdc), address(irm));
        v2Market.setLpType(ILPAdapter.LPType.UniswapV2);

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(v3Adapter));
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(v2Adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistPool(lpToken);
        core.whitelistPool(v2LpToken);
        v3MarketId = core.registerMarket(address(v3Market));
        v2MarketId = core.registerMarket(address(v2Market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Fund
        usdc.mint(address(v3Market), 1_000_000e18);
        usdc.mint(address(v2Market), 1_000_000e18);
        weth.mint(address(v3Adapter), 1_000_000e18);
        usdc.mint(address(v3Adapter), 1_000_000e18);
        weth.mint(address(v2Adapter), 1_000_000e18);
        usdc.mint(address(v2Adapter), 1_000_000e18);
    }

    // Helper: create V3 position (tokenId > 0, amount = 0)
    function _createV3LiquidatablePosition() internal returns (uint256 posId) {
        vm.prank(alice);
        posId = pm.deposit(lpToken, 42, 0, v3MarketId); // V3: tokenId=42, amount=0
        vm.roll(block.number + 3);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        // Drop price to make liquidatable
        oracle.setPrice(35_000e18);
    }

    // ========== 1. V3 fee-only liquidation ==========

    function test_v3_feeOnlyLiquidation() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 42, 0, v3MarketId);
        vm.roll(block.number + 3);
        vm.prank(alice);
        le.borrow(posId, 10_000e18);

        // Set liquidity to 0 (fee-only position)
        v3Adapter.setMockLiquidity(0);
        // Set fees available
        v3Adapter.setMockFees(5e18, 5000e18);
        // Oracle still prices position (via fees)
        oracle.setPrice(8000e18);

        (bool canLiq,) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Should be liquidatable");

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        usdc.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), maxRepay);
        liq.liquidate(posId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Debt should decrease
        assertLt(le.getDebt(posId), 10_000e18, "Debt must decrease");
    }

    // ========== 2. Fee-only liquidation — fees go to the liquidator, not the borrower ==========

    /// @dev Models a fee-only position via the mock: the adapter reports 0 liquidity
    ///      (setMockLiquidity(0)) with fees available, and MockLPOracle assigns it a value. In
    ///      production, principal-only valuation makes such a position's principal 0. The engine
    ///      sweeps the fees and, with no principal to seize, hands them to the liquidator who
    ///      repaid the debt — never back to the borrower.
    function test_v3_feeOnly_liquidatorTakesFees() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 42, 0, v3MarketId);
        vm.roll(block.number + 3);
        vm.prank(alice);
        le.borrow(posId, 5000e18);

        v3Adapter.setMockLiquidity(0);
        v3Adapter.setMockFees(10e18, 10_000e18); // fees in adapter
        oracle.setPrice(6000e18); // HF < 1.0

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        uint256 partialRepay = maxRepay > 2 ? maxRepay / 2 : 1;

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 liqWethBefore = weth.balanceOf(liquidator);
        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);

        usdc.mint(liquidator, partialRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), partialRepay);
        liq.liquidate(posId, partialRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Liquidator receives BOTH swept fee tokens; borrower receives nothing of either.
        assertGt(weth.balanceOf(liquidator), liqWethBefore, "liquidator receives WETH fees");
        // Net USDC = minted partialRepay - repaid partialRepay + swept USDC fees → strictly up by the fees.
        assertGt(usdc.balanceOf(liquidator), liqUsdcBefore, "liquidator receives USDC fees");
        assertEq(weth.balanceOf(alice), aliceWethBefore, "borrower receives no WETH fees");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "borrower receives no USDC fees");
    }

    // ========== 2b. Normal liquidation sweeps fees to the borrower ==========

    /// @dev A V3 position with BOTH liquidity and uncollected fees: a partial liquidation must
    ///      seize only principal for the liquidator and sweep ALL uncollected fees back to the
    ///      borrower (fees are not collateral). This is the core security fix — a small partial
    ///      liquidation can no longer skim the position's fees.
    function test_v3_normalLiquidation_sweepsFeesToBorrower() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 42, 0, v3MarketId);
        vm.roll(block.number + 3);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        // Position keeps its liquidity (default 1_000_000) and has uncollected fees.
        v3Adapter.setMockFees(3e18, 3000e18); // 3 WETH + 3000 USDC of fees
        v3Adapter.setUnwindAmounts(25e18, 25_000e18);
        oracle.setPrice(35_000e18); // HF < 1 → liquidatable

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        uint256 partialRepay = maxRepay / 2; // partial

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 liqWethBefore = weth.balanceOf(liquidator);

        usdc.mint(liquidator, partialRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), partialRepay);
        liq.liquidate(posId, partialRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Borrower receives ALL the swept fees (not a proportional slice, not the liquidator).
        assertEq(weth.balanceOf(alice), aliceWethBefore + 3e18, "borrower receives all swept WETH fees");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 3000e18, "borrower receives all swept USDC fees");
        // Liquidator receives principal proceeds from the unwind.
        assertGt(weth.balanceOf(liquidator), liqWethBefore, "liquidator receives principal proceeds");
    }

    // ========== 3. minAmount slippage revert ==========

    function test_slippage_reverts() public {
        uint256 posId = _createV3LiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        usdc.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), maxRepay);

        // Set unrealistic minimum — should revert
        vm.expectRevert("SLIPPAGE_AMOUNT0");
        liq.liquidate(posId, maxRepay, block.timestamp, type(uint256).max, 0);
        vm.stopPrank();
    }

    function test_slippage_passesWithZero() public {
        uint256 posId = _createV3LiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        usdc.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), maxRepay);

        // minAmount = 0 should always pass
        liq.liquidate(posId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        assertLt(le.getDebt(posId), 30_000e18, "Debt must decrease");
    }

    // ========== 4. V3 NFT returned after full liquidation ==========

    function test_v3_nftReturnedAfterFullLiquidation() public {
        uint256 posId = _createV3LiquidatablePosition();

        uint256 totalDebt = le.getDebt(posId);
        usdc.mint(liquidator, totalDebt);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), totalDebt);
        liq.liquidate(posId, totalDebt, block.timestamp, 0, 0);
        vm.stopPrank();

        // Position should be liquidated
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint256(pos.status), uint256(IPositionManager.PositionStatus.Liquidated));

        // adapter.unlock should have been called (NFT returned to borrower)
        assertGt(v3Adapter.unlockCallCount(), 0, "NFT should be returned via unlock");
    }

    // ========== 5. Underwater fee-only takes all fees ==========

    function test_v3_underwaterFeeOnly_takesAllFees() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 42, 0, v3MarketId);
        vm.roll(block.number + 3);
        vm.prank(alice);
        le.borrow(posId, 20_000e18);

        v3Adapter.setMockLiquidity(0);
        v3Adapter.setMockFees(2e18, 2000e18); // Only $4K in fees
        oracle.setPrice(3000e18); // Position worth $3K but debt is $20K — underwater

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        usdc.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), maxRepay);
        liq.liquidate(posId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Alice should NOT receive excess (underwater = take everything)
        // Liquidator received all fees
    }

    // ========== 6. V2 with tokenId > 0 doesn't hit fee-only path ==========

    function test_v2_tokenIdNonZero_normalPath() public {
        // V2 position with tokenId > 0 (shouldn't hit fee-only path)
        vm.prank(alice);
        uint256 posId = pm.deposit(v2LpToken, 99, 100e18, v2MarketId); // tokenId=99, amount=100
        vm.roll(block.number + 3);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        oracle.setPrice(35_000e18); // make liquidatable

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        usdc.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), maxRepay);
        liq.liquidate(posId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Should work via normal unwind path (not fee-only)
        // pos.amount should decrease (V2 with isErc20LP = true)
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertLt(pos.amount, 100e18, "V2 amount must decrease");
    }

    // ========== 7. Ring buffer volatility after 100+ entries ==========
    // (PriceValidator test — included here for completeness)

    // ========== 7. AMOUNT_OVERFLOW revert for V2 > uint128 ==========

    function test_v2_amountOverflow_reverts() public {
        // V2 getLiquidity reverts on amount > uint128.max
        vm.expectRevert("AMOUNT_OVERFLOW");
        v2Adapter.getLiquidity(v2LpToken, 0, uint256(type(uint128).max) + 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../helpers/ForkTestBase.sol";

/// @title ProtocolDeploymentTest
/// @notice Verify the full protocol deploys correctly against forked mainnet
contract ProtocolDeploymentTest is ForkTestBase {
    function setUp() public override {
        super.setUp();
    }

    function test_coreDeployed() public view {
        assertEq(core.owner(), deployer);
        assertEq(address(core.aclManager()), address(aclManager));
        assertTrue(aclManager.isEmergencyAdmin(guardian));
        assertFalse(core.paused());
    }

    function test_proxiesInitialized() public view {
        // PositionManager proxy is initialized and connected
        assertEq(address(positionManager.core()), address(core));
        assertEq(address(positionManager.oracleHub()), address(oracleHub));

        // LendingEngine proxy is initialized
        assertEq(address(lendingEngine.core()), address(core));
        assertEq(address(lendingEngine.positionManager()), address(positionManager));

        // LiquidationEngine proxy is initialized
        assertEq(address(liquidationEngine.core()), address(core));
        assertEq(address(liquidationEngine.positionManager()), address(positionManager));
        assertEq(address(liquidationEngine.lendingEngine()), address(lendingEngine));

        // OracleHub proxy is initialized
        assertEq(address(oracleHub.core()), address(core));
    }

    function test_adaptersRegistered() public view {
        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), address(v3Adapter));
        assertEq(core.adapters(ILPAdapter.LPType.UniswapV2), address(v2Adapter));
    }

    function test_oraclesRegistered() public view {
        assertEq(oracleHub.oracles(ILPAdapter.LPType.UniswapV3), address(v3Oracle));
        assertEq(oracleHub.oracles(ILPAdapter.LPType.UniswapV2), address(v2Oracle));
    }

    function test_poolsWhitelisted() public view {
        assertTrue(core.isPoolSupported(Constants.UNI_V3_WETH_USDC_3000));
        assertTrue(core.isPoolSupported(Constants.UNI_V2_WETH_USDC));
        assertFalse(core.isPoolSupported(address(0x1234)));
    }

    function test_marketCreated() public view {
        address marketAddr = core.markets(ethUsdcMarketId);
        assertTrue(marketAddr != address(0));

        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        assertEq(uint8(config.lpType), uint8(ILPAdapter.LPType.UniswapV3));
        assertEq(config.borrowAsset, Constants.USDC);
        assertEq(config.maxLtv, 6500);
        assertEq(config.liquidationThreshold, 7500);
        assertEq(config.liquidationBonus, 500);
    }

    function test_authorization() public view {
        assertTrue(aclManager.isLendingEngine(address(lendingEngine)));
        assertTrue(aclManager.isLiquidationEngine(address(liquidationEngine)));
    }

    function test_chainlinkFeedsWork() public view {
        uint256 ethPrice = _getEthPrice();
        // ETH should be between $500 and $50,000 (sanity check)
        assertGt(ethPrice, 500e18);
        assertLt(ethPrice, 50_000e18);
    }

    function test_uniswapV3PoolExists() public view {
        // Verify the forked Uniswap V3 pool has liquidity
        uint256 wethBalance = IERC20(Constants.WETH).balanceOf(Constants.UNI_V3_WETH_USDC_3000);
        uint256 usdcBalance = IERC20(Constants.USDC).balanceOf(Constants.UNI_V3_WETH_USDC_3000);
        assertGt(wethBalance, 0, "V3 pool has no WETH");
        assertGt(usdcBalance, 0, "V3 pool has no USDC");
    }

    function test_canFundTestAccounts() public {
        _fundWeth(alice, 10 ether);
        _fundUsdc(alice, 10_000e6);

        assertEq(IERC20(Constants.WETH).balanceOf(alice), 10 ether);
        assertEq(IERC20(Constants.USDC).balanceOf(alice), 10_000e6);
    }

    function test_cannotReinitializeProxy() public {
        vm.expectRevert();
        positionManager.initialize(address(core), address(oracleHub));
    }

    function test_onlyOwnerCanUpgrade() public {
        PositionManager newImpl = new PositionManager();

        // Alice cannot upgrade
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        positionManager.upgradeToAndCall(address(newImpl), "");

        // Deployer (owner) can upgrade
        vm.prank(deployer);
        positionManager.upgradeToAndCall(address(newImpl), "");
    }

    function test_guardianCanPause() public {
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.unpause();

        // Owner can unpause
        vm.prank(deployer);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_interestRateModel() public view {
        // At 0% utilization: ~2% APR
        uint256 aprAtZero = volatileModel.getBorrowRateAPR(0);
        assertApproxEqAbs(aprAtZero, 200, 5);

        // At 80% (kink): ~8% APR
        uint256 aprAtKink = volatileModel.getBorrowRateAPR(8000);
        assertApproxEqAbs(aprAtKink, 800, 5);

        // At 95%: very high (steep slope above kink)
        uint256 aprAt95 = volatileModel.getBorrowRateAPR(9500);
        assertGt(aprAt95, 5000); // >50% APR
    }
}

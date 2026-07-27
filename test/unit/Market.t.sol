// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {Market} from "../../src/markets/Market.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MarketTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    Market public market;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public le = makeAddr("lendingEngine"); // LendingEngine address
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    uint256 constant DEAD_SHARES = 1_000_000;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        irm = new InterestRateModel(200, 600, 10_000, 8000);
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        IMarket.MarketConfig memory config = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(usdc),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 10_000_000e6,
            minPoolTvl: 5_000_000e18,
            minPoolAge: 0
        });

        Market impl = new Market();
        market = Market(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(Market.initialize, (config, address(irm), address(core)))
                )
            )
        );

        // Grant le the LENDING_ENGINE role so it can call transferOut/transferIn
        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(le);
        vm.stopPrank();
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(market), amount);
    }

    // ========== Initialization ==========

    function test_initialize_setsState() public view {
        assertEq(address(market.core()), address(core));
        assertEq(market.borrowIndex(), 1e27);
    }

    // ========== First Deposit (dead shares) ==========

    function test_supply_firstDeposit_mintsDeadShares() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        uint256 shares = market.supply(10_000e6);

        assertEq(shares, 10_000e6 - DEAD_SHARES);
        assertEq(market.shares(address(0xdead)), DEAD_SHARES);
        assertEq(market.totalShares(), 10_000e6);
    }

    function test_supply_firstDeposit_revertsBelowMinimum() public {
        _fundAndApprove(alice, 500);
        vm.prank(alice);
        vm.expectRevert("BELOW_MINIMUM_DEPOSIT");
        market.supply(500);
    }

    // ========== MKT-1: Inflation Attack ==========

    function test_inflationAttack_blocked() public {
        _fundAndApprove(attacker, DEAD_SHARES + 1);
        vm.prank(attacker);
        market.supply(DEAD_SHARES + 1);

        usdc.mint(address(market), 10_000e6); // Donation

        _fundAndApprove(bob, 5000e6);
        vm.prank(bob);
        uint256 victimShares = market.supply(5000e6);

        assertGt(victimShares, 0, "Victim must receive shares");
        assertEq(victimShares, 5000e6);
    }

    // ========== Normal Supply/Withdraw ==========

    function test_supply_secondDeposit_normalShares() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        _fundAndApprove(bob, 5000e6);
        vm.prank(bob);
        uint256 bobShares = market.supply(5000e6);
        assertEq(bobShares, 5000e6);
    }

    function test_supply_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("ZERO_AMOUNT");
        market.supply(0);
    }

    function test_withdraw_success() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        uint256 aliceShares = market.supply(10_000e6);

        vm.prank(alice);
        uint256 received = market.withdraw(aliceShares);
        assertEq(received, 10_000e6 - DEAD_SHARES);
        assertEq(market.shares(alice), 0);
    }

    function test_withdraw_revertsInsufficientShares() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_SHARES");
        market.withdraw(10_000e6);
    }

    function test_withdraw_revertsInsufficientLiquidity() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        uint256 aliceShares = market.supply(10_000e6);

        vm.prank(le);
        market.transferOut(makeAddr("borrower"), 8000e6);

        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        market.withdraw(aliceShares);
    }

    // ========== Interest Accrual ==========

    function test_accrueInterest_initialState() public view {
        assertEq(market.borrowIndex(), 1e27);
    }

    function test_accrueInterest_noOpWhenNoBorrows() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        uint256 indexBefore = market.borrowIndex();
        vm.warp(block.timestamp + 365 days);
        market.accrueInterest();
        assertEq(market.borrowIndex(), indexBefore);
    }

    function test_accrueInterest_indexGrowsWithBorrows() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        market.supply(100_000e6);

        vm.prank(le);
        market.transferOut(makeAddr("b"), 50_000e6);

        uint256 indexBefore = market.borrowIndex();
        vm.warp(block.timestamp + 365 days);
        market.accrueInterest();
        assertGt(market.borrowIndex(), indexBefore);
    }

    function test_accrueInterest_idempotentSameBlock() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        market.supply(100_000e6);

        vm.prank(le);
        market.transferOut(makeAddr("b"), 50_000e6);

        vm.warp(block.timestamp + 100);
        market.accrueInterest();
        uint256 index1 = market.borrowIndex();
        market.accrueInterest();
        assertEq(market.borrowIndex(), index1);
    }

    // ========== TransferOut / TransferIn ==========

    function test_transferOut_success() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        address borrower = makeAddr("borrower");
        vm.prank(le);
        market.transferOut(borrower, 5000e6);
        assertEq(usdc.balanceOf(borrower), 5000e6);
    }

    function test_transferOut_revertsNotLendingEngine() public {
        vm.prank(alice);
        vm.expectRevert("NOT_LENDING_ENGINE");
        market.transferOut(alice, 1000e6);
    }

    function test_transferOut_revertsInsufficientLiquidity() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        vm.prank(le);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        market.transferOut(makeAddr("b"), 11_000e6);
    }

    function test_transferIn_success() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        vm.prank(le);
        market.transferOut(makeAddr("b"), 5000e6);

        address repayer = makeAddr("repayer");
        usdc.mint(repayer, 5000e6);
        vm.prank(repayer);
        usdc.approve(address(market), 5000e6);

        vm.prank(le);
        market.transferIn(repayer, 5000e6);
        assertEq(usdc.balanceOf(repayer), 0);
    }

    function test_transferIn_revertsNotLendingEngine() public {
        vm.prank(alice);
        vm.expectRevert("NOT_LENDING_ENGINE");
        market.transferIn(alice, 1000e6);
    }

    // ========== ACLManager: LendingEngine Role ==========

    function test_lendingEngineRole_changeRole() public {
        address newLE = makeAddr("newLE");

        vm.startPrank(owner);
        aclManager.removeLendingEngine(le);
        aclManager.addLendingEngine(newLE);
        vm.stopPrank();

        // Old LE can no longer call
        vm.prank(le);
        vm.expectRevert("NOT_LENDING_ENGINE");
        market.transferOut(makeAddr("x"), 100);

        // New LE can call
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        vm.prank(newLE);
        market.transferOut(makeAddr("x"), 100);
    }

    function test_lendingEngineRole_revertsNotAdmin() public {
        bytes32 leRole = aclManager.LENDING_ENGINE();
        bytes32 adminRole = aclManager.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, adminRole));
        aclManager.grantRole(leRole, makeAddr("x"));
    }

    // ========== Admin (owner via ProtocolCore) ==========

    function test_updateConfig_success() public {
        vm.prank(owner);
        market.updateConfig(7000, 8000, 600, 20_000_000e6);

        IMarket.MarketConfig memory config = market.getConfig();
        assertEq(config.maxLtv, 7000);
    }

    function test_updateConfig_revertsNotRiskAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_RISK_ADMIN");
        market.updateConfig(7000, 8000, 600, 20_000_000e6);
    }

    function test_updateConfig_revertsLtvTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("LTV_TOO_HIGH");
        market.updateConfig(9600, 8000, 600, 20_000_000e6);
    }

    function test_initialize_revertsBonusTooHigh() public {
        IMarket.MarketConfig memory badConfig = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(usdc),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: market.MAX_LIQUIDATION_BONUS() + 1,
            borrowCap: 10_000_000e6,
            minPoolTvl: 5_000_000e18,
            minPoolAge: 0
        });

        Market impl = new Market();
        vm.expectRevert("BONUS_TOO_HIGH");
        new ERC1967Proxy(address(impl), abi.encodeCall(Market.initialize, (badConfig, address(irm), address(core))));
    }

    function test_updateConfig_revertsBonusTooHigh() public {
        uint256 maxBonus = market.MAX_LIQUIDATION_BONUS();
        vm.prank(owner);
        vm.expectRevert("BONUS_TOO_HIGH");
        market.updateConfig(7000, 8000, maxBonus + 1, 20_000_000e6);
    }

    function test_updateConfig_bonusAtMax() public {
        uint256 maxBonus = market.MAX_LIQUIDATION_BONUS();
        vm.prank(owner);
        market.updateConfig(7000, 8000, maxBonus, 20_000_000e6);

        IMarket.MarketConfig memory cfg = market.getConfig();
        assertEq(cfg.liquidationBonus, maxBonus);
    }

    function test_upgrade_onlyPoolAdmin() public {
        Market newImpl = new Market();
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        market.upgradeToAndCall(address(newImpl), "");

        vm.prank(owner);
        market.upgradeToAndCall(address(newImpl), "");
    }

    // ========== Fuzz ==========

    function testFuzz_supply_alwaysGetsShares(uint256 amount) public {
        amount = bound(amount, DEAD_SHARES + 1, 1_000_000_000e6);
        _fundAndApprove(alice, amount);
        vm.prank(alice);
        uint256 shares = market.supply(amount);
        assertGt(shares, 0);
    }

    function testFuzz_supplyWithdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, DEAD_SHARES + 1, 1_000_000_000e6);
        _fundAndApprove(alice, amount);
        vm.prank(alice);
        uint256 aliceShares = market.supply(amount);

        vm.prank(alice);
        uint256 received = market.withdraw(aliceShares);
        assertLe(amount - received, DEAD_SHARES);
    }

    // ========== Interest Accrual — borrows always accrue ==========

    function test_accrueInterest_withBorrows_alwaysAccrues() public {
        // Verify interest accrues whenever totalBorrow > 0.
        // The code fix changed `if (totalBorrow == 0 || totalSupply == 0)` to
        // `if (totalBorrow == 0)` — only skipping when there are no borrows.

        // 1. Set reserve factor so protocol gets a share of interest
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);
        vm.prank(owner);
        market.setReserveFactor(2000); // 20%

        // 2. Supply and borrow to set up state
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        vm.prank(le);
        market.transferOut(makeAddr("borrower"), 5000e6);

        // 3. Verify state: totalBorrow > 0 (the condition that must trigger accrual)
        IMarket.MarketState memory s = market.getMarketState();
        assertGt(s.totalSupply, 0, "Must have supply");
        assertGt(s.totalBorrow, 0, "Must have borrows");

        uint256 totalBorrowBefore = s.totalBorrow;
        uint256 reservesBefore = market.protocolReserves();

        // 3. Advance time
        vm.warp(block.timestamp + 30 days);
        market.accrueInterest();

        IMarket.MarketState memory sAfter = market.getMarketState();
        uint256 reservesAfter = market.protocolReserves();

        // Interest MUST have accrued (not skipped)
        assertGt(sAfter.totalBorrow, totalBorrowBefore, "Interest must accrue with outstanding borrows");
        assertGt(market.borrowIndex(), 1e27, "BorrowIndex must grow");
        assertGt(reservesAfter, reservesBefore, "Reserves must grow from protocol share of interest");
        assertLe(sAfter.utilization, 10_000, "Utilization must be capped at 100%");
    }

    function test_accrueInterest_zeroBorrow_skips() public {
        // No borrows — accrual should skip harmlessly
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        market.supply(10_000e6);

        uint256 indexBefore = market.borrowIndex();
        vm.warp(block.timestamp + 30 days);
        market.accrueInterest();

        // BorrowIndex should not change (no borrows to accrue on)
        assertEq(market.borrowIndex(), indexBefore, "BorrowIndex must not change with zero borrows");
    }
}

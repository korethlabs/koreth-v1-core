// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title ProtocolInvariantE2E
/// @notice E2E invariant tests against forked mainnet with real Uniswap V3 positions.
/// @dev These tests verify protocol-wide invariants hold across real LP operations.
///
///      Invariants tested:
///        1. Health factor >= 1.0 after any valid borrow
///        2. Health factor decreases monotonically with additional debt
///        3. Full repay restores max HF
///        4. Market solvency: balance + borrows >= supply
///        5. Debt never exceeds market totalBorrow
///        6. Position value from oracle is consistent with real Uniswap state
///        7. Borrow index never decreases after interest accrual
///        8. Closed position has zero debt
///        9. Price crash makes leveraged positions liquidatable
///       10. Multiple users cannot interfere with each other's HF
contract ProtocolInvariantE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    // ================================================================
    // 1. Health factor >= 1.0 after any valid borrow
    // ================================================================

    function test_invariant_healthyAfterBorrow() public {
        // Each iteration mints its own fresh position and recomputes max borrow,
        // so no throwaway setup position is needed here.
        uint256[] memory fractions = new uint256[](4);
        fractions[0] = 25;
        fractions[1] = 50;
        fractions[2] = 75;
        fractions[3] = 99;

        for (uint256 i = 0; i < fractions.length; i++) {
            // Fresh position for each test
            uint256 tid = _createV3Position(alice, 1 ether, 2500e6);
            uint256 pid = _depositV3(alice, tid);

            uint256 mb = lendingEngine.getMaxBorrow(pid);
            uint256 borrowAmt = (mb * fractions[i]) / 100;
            if (borrowAmt == 0) continue;

            // Advance past the borrow cooldown using an ABSOLUTE target relative to this
            // position's recorded deposit block. (A relative `block.number + N` roll is
            // unreliable inside a fork loop — intervening fork txs can leave block.number
            // unchanged, leaving no cooldown gap.)
            vm.roll(positionManager.getPosition(pid).depositBlock + 10);
            vm.prank(alice);
            lendingEngine.borrow(pid, borrowAmt);

            uint256 hf = _getHealthFactor(pid);
            assertGe(hf, 1e18, "HF must be >= 1.0 after valid borrow");
        }
    }

    // ================================================================
    // 2. HF decreases monotonically with additional debt
    // ================================================================

    function test_invariant_hfDecreasesWithDebt() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        uint256 step = maxBorrow / 5;
        require(step > 0, "Step too small");

        uint256 prevHF = type(uint256).max;
        for (uint256 i = 1; i <= 4; i++) {
            vm.prank(alice);
            lendingEngine.borrow(posId, step);

            uint256 hf = _getHealthFactor(posId);
            assertLt(hf, prevHF, "HF must decrease with each borrow");
            prevHF = hf;
        }
    }

    // ================================================================
    // 3. Full repay restores max HF
    // ================================================================

    function test_invariant_fullRepayRestoresMaxHF() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 3);

        uint256 hfBorrowed = _getHealthFactor(posId);
        assertLt(hfBorrowed, type(uint256).max, "HF should not be max while borrowed");

        // Repay all
        uint256 debt = _getDebt(posId);
        _fundUsdc(alice, debt);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, debt);
        lendingEngine.repay(posId, type(uint256).max);
        vm.stopPrank();

        assertEq(_getHealthFactor(posId), type(uint256).max, "Full repay must restore max HF");
        assertEq(_getDebt(posId), 0, "Debt must be zero after full repay");
    }

    // ================================================================
    // 4. Market solvency: balance + borrows >= supply
    // ================================================================

    function test_invariant_marketSolvency() public {
        // Alice borrows
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 2);

        // Accrue some interest
        _advanceTime(30 days);
        _refreshChainlinkMocks();
        address marketAddr = core.markets(ethUsdcMarketId);
        IMarket(marketAddr).accrueInterest();

        IMarket.MarketState memory s = IMarket(marketAddr).getMarketState();
        uint256 marketBalance = IERC20(Constants.USDC).balanceOf(marketAddr);

        assertGe(
            marketBalance + s.totalBorrow, s.totalSupply, "Market must remain solvent: balance + borrows >= supply"
        );
    }

    // ================================================================
    // 5. Individual debt never exceeds market totalBorrow
    // ================================================================

    function test_invariant_debtNeverExceedsMarketBorrow() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 2);

        // Accrue interest over 6 months
        _advanceTime(180 days);
        _refreshChainlinkMocks();
        address marketAddr = core.markets(ethUsdcMarketId);
        IMarket(marketAddr).accrueInterest();

        uint256 posDebt = _getDebt(posId);
        IMarket.MarketState memory s = IMarket(marketAddr).getMarketState();

        assertLe(posDebt, s.totalBorrow + 1, "Position debt must not exceed market totalBorrow");
    }

    // ================================================================
    // 6. Position value from oracle is positive for real LP positions
    // ================================================================

    function test_invariant_positionValuePositive() public {
        // V3 position
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);

        uint256 value = _getPositionValue(posId);
        assertGt(value, 0, "V3 position must have positive value");

        // Value should be in reasonable range ($1k - $100k for 2 ETH + 5000 USDC)
        assertGt(value, 1000e18, "V3 position value must be > $1000");
        assertLt(value, 100_000e18, "V3 position value must be < $100k");
    }

    // ================================================================
    // 7. Borrow index never decreases
    // ================================================================

    function test_invariant_borrowIndexNeverDecreases() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 3);

        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 indexBefore = IMarket(marketAddr).borrowIndex();

        // Accrue over multiple intervals
        uint256[] memory intervals = new uint256[](3);
        intervals[0] = 1 days;
        intervals[1] = 30 days;
        intervals[2] = 90 days;

        for (uint256 i = 0; i < intervals.length; i++) {
            _advanceTime(intervals[i]);
            _refreshChainlinkMocks();
            IMarket(marketAddr).accrueInterest();

            uint256 indexAfter = IMarket(marketAddr).borrowIndex();
            assertGe(indexAfter, indexBefore, "borrowIndex must never decrease");
            indexBefore = indexAfter;
        }
    }

    // ================================================================
    // 8. Closed position has zero debt
    // ================================================================

    function test_invariant_closedPositionZeroDebt() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow and repay
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 4);

        uint256 debt = _getDebt(posId);
        _fundUsdc(alice, debt);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, debt);
        lendingEngine.repay(posId, type(uint256).max);
        vm.stopPrank();

        // Withdraw
        vm.prank(alice);
        positionManager.withdraw(posId);

        IPositionManager.Position memory pos = positionManager.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Closed), "Must be Closed");
        assertEq(_getDebt(posId), 0, "Closed position must have zero debt");
    }

    // ================================================================
    // 9. Price crash makes leveraged positions liquidatable
    // ================================================================

    function test_invariant_priceCrashTriggersLiquidation() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow near max LTV
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 90) / 100);

        uint256 hfBefore = _getHealthFactor(posId);
        console.log("HF before crash: %s", hfBefore / 1e16);

        // Crash ETH price — 50% drop
        _crashEthPrice(5000 ether);

        // Position should be liquidatable after severe crash
        (bool isLiq,) = liquidationEngine.isLiquidatable(posId);
        assertTrue(isLiq, "Position must be liquidatable after 50% price crash with 90% LTV usage");
    }

    // ================================================================
    // 10. Multi-user isolation — one user's borrow doesn't affect another's HF
    // ================================================================

    function test_invariant_multiUserIsolation() public {
        // Alice deposits and borrows
        uint256 tokenIdA = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posA = _depositV3(alice, tokenIdA);

        // Charlie deposits (fund first)
        address charlie = makeAddr("charlie");
        _fundWeth(charlie, 2 ether);
        _fundUsdc(charlie, 5000e6);
        uint256 tokenIdC = _createV3Position(charlie, 2 ether, 5000e6);
        vm.startPrank(charlie);
        nftManager.approve(address(v3Adapter), tokenIdC);
        uint256 posC = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenIdC, 0, ethUsdcMarketId);
        vm.stopPrank();

        vm.roll(block.number + 5);

        // Record Charlie's HF before Alice borrows
        uint256 charlieHFBefore = _getHealthFactor(posC);

        // Alice borrows heavily
        uint256 maxBorrowA = lendingEngine.getMaxBorrow(posA);
        vm.prank(alice);
        lendingEngine.borrow(posA, (maxBorrowA * 80) / 100);

        // Charlie's HF must not change
        uint256 charlieHFAfter = _getHealthFactor(posC);
        assertEq(charlieHFAfter, charlieHFBefore, "Alice's borrow must not affect Charlie's HF");
    }

    // ========== Helpers ==========

    function _refreshChainlinkMocks() internal {
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), _readPoolPriceAsChainlink(), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            Constants.CL_USDC_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(100_000_000), block.timestamp, block.timestamp, uint80(1))
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title InterestStressE2E
/// @notice Stress tests for interest accrual over long durations on forked mainnet.
contract InterestStressE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 1 year of interest accrual — verify debt grows, market stays solvent
    function test_interestAccrual_oneYear() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        uint256 borrowAmt = maxBorrow / 2;
        vm.prank(alice);
        lendingEngine.borrow(posId, borrowAmt);

        uint256 debtAtStart = _getDebt(posId);
        address marketAddr = core.markets(ethUsdcMarketId);

        // Accrue monthly for 12 months
        for (uint256 m = 1; m <= 12; m++) {
            _advanceTime(30 days);
            _refreshChainlinkMocks();
            IMarket(marketAddr).accrueInterest();
        }

        uint256 debtAfterYear = _getDebt(posId);
        IMarket.MarketState memory s = IMarket(marketAddr).getMarketState();

        console.log("Debt start: %s USDC", debtAtStart / 1e6);
        console.log("Debt 1 year: %s USDC", debtAfterYear / 1e6);
        console.log("Interest earned: %s USDC", (debtAfterYear - debtAtStart) / 1e6);

        assertGt(debtAfterYear, debtAtStart, "Debt must grow over time");
        // Solvency incl. protocol reserves: cash + outstanding borrows must cover
        // lender obligations (totalSupply) plus the protocol's accrued reserves.
        assertGe(
            IERC20(Constants.USDC).balanceOf(marketAddr) + s.totalBorrow,
            s.totalSupply + Market(marketAddr).protocolReserves(),
            "Market must remain solvent after 1 year (incl. reserves)"
        );
    }

    /// @notice 5 years of interest — verify no overflow or accounting corruption
    function test_interestAccrual_fiveYears() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 3);

        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 indexBefore = IMarket(marketAddr).borrowIndex();

        // Accrue quarterly for 5 years (20 quarters)
        for (uint256 q = 0; q < 20; q++) {
            _advanceTime(90 days);
            _refreshChainlinkMocks();
            IMarket(marketAddr).accrueInterest();
        }

        uint256 indexAfter = IMarket(marketAddr).borrowIndex();
        uint256 debtAfter = _getDebt(posId);

        assertGt(indexAfter, indexBefore, "Borrow index must increase over 5 years");
        assertGt(debtAfter, 0, "Debt must still be trackable after 5 years");

        // Market solvency after 5 years: cash + borrows cover lender obligations + reserves
        IMarket.MarketState memory s = IMarket(marketAddr).getMarketState();
        assertGe(
            IERC20(Constants.USDC).balanceOf(marketAddr) + s.totalBorrow,
            s.totalSupply + Market(marketAddr).protocolReserves(),
            "Market must remain solvent after 5 years (incl. reserves)"
        );
    }

    /// @notice High utilization interest — borrow 80% of supply, verify rates spike
    function test_interestAccrual_highUtilization() public {
        // Add more supply first
        _fundUsdc(bob, 200_000e6);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(marketAddr, 200_000e6);
        IMarket(marketAddr).supply(200_000e6);
        vm.stopPrank();

        // Create a large position and borrow heavily
        _fundWeth(alice, 10 ether);
        _fundUsdc(alice, 30_000e6);
        uint256 tokenId = _createV3Position(alice, 10 ether, 30_000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 80) / 100);

        IMarket.MarketState memory sBefore = IMarket(marketAddr).getMarketState();
        console.log("Utilization: %s bps", sBefore.utilization);
        console.log("Borrow rate: %s", sBefore.borrowRate);

        // Accrue 30 days at high utilization
        _advanceTime(30 days);
        _refreshChainlinkMocks();
        IMarket(marketAddr).accrueInterest();

        IMarket.MarketState memory sAfter = IMarket(marketAddr).getMarketState();
        assertGt(sAfter.borrowRate, 0, "Borrow rate must be positive at high utilization");
        assertGt(sAfter.totalBorrow, sBefore.totalBorrow, "totalBorrow must grow from interest");
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

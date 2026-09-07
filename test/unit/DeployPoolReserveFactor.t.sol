// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DeployBase} from "../../script/DeployBase.s.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {MockConstantFeed} from "../mocks/MockConstantFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice A chain profile with every external dependency stubbed out, so the deploy can run
///         against no fork at all.
/// @dev Both DEX factories are left at address(0). That is a supported profile — DeployBase skips
///      the oracle and adapter deployments for a DEX a chain does not list — and it reduces the
///      deploy to the part under test: roles, the pool factory, and the single market the script
///      creates for the borrow asset.
contract StubProfile is DeployBase {
    address internal immutable STABLECOIN;
    address internal immutable WETH;
    address internal immutable STABLE_FEED;
    address internal immutable NATIVE_FEED;
    address internal immutable DEPLOYER;

    /// @notice Fee destinations this profile hands the script, readable from a test.
    /// @dev Fixed and distinct from each other and from the deployer, so a test can tell whether
    ///      FeeCollector was wired from the config or from whatever address the script had nearest
    ///      to hand. Every profile used to pass the deployer for both, which no assertion could
    ///      distinguish from reading the config correctly.
    address public constant TREASURY = address(0x7EA5);
    address public constant INSURANCE_FUND = address(0x1435);

    constructor(address stablecoin, address weth, address stableFeed, address nativeFeed, address deployer) {
        STABLECOIN = stablecoin;
        WETH = weth;
        STABLE_FEED = stableFeed;
        NATIVE_FEED = nativeFeed;
        DEPLOYER = deployer;
    }

    /// @notice The deploy script's reserve factor, readable from a test.
    /// @dev The constant is internal to DeployBase, and exposing it here rather than repeating the
    ///      literal is the point: a test that hardcoded 2000 would keep passing if the script's
    ///      value were edited, which is the drift this file exists to catch.
    function defaultReserveFactorBps() external pure returns (uint256) {
        return DEFAULT_RESERVE_FACTOR_BPS;
    }

    /// @dev virtual so a test can take this config and change one field. The alternative — a second
    ///      profile repeating all twenty of them — drifts from this one the moment either is edited.
    function _config() internal view virtual override returns (ChainConfig memory) {
        return ChainConfig({
            deployer: DEPLOYER,
            guardian: DEPLOYER,
            riskAdmin: DEPLOYER,
            treasury: TREASURY,
            insuranceFund: INSURANCE_FUND,
            v2Factory: address(0),
            v2Router: address(0),
            v3Factory: address(0),
            v3NftManager: address(0),
            weth: WETH,
            stablecoin: STABLECOIN,
            clNativeUsd: NATIVE_FEED,
            clStablecoinUsd: STABLE_FEED,
            clSequencerUptime: address(0),
            v2Pools: new address[](0),
            v3Pools: new address[](0),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            haircut: 0,
            borrowCap: 1_000_000e18,
            // Nonzero on purpose. A stub profile states what this file treats as a normal
            // deployment, and 0 here would mean "both risk checks off" — the exact state the
            // required fields exist to make impossible to reach by omission.
            minBorrowUsd: 100e18,
            dailyBorrowIncreaseLimit: 10_000_000e18
        });
    }
}

/// @title DeployPoolReserveFactorTest
/// @notice That a lending pool created by the deploy script keeps a share of borrower interest.
/// @dev PoolFactory.createPool applies the reserve factor only `if (reserveFactorBps > 0)`, so a
///      zero arriving from the script is not an error anywhere: the pool deploys, registers and
///      lends normally, and simply pays 100% of borrower interest to suppliers with the protocol
///      accruing nothing. There is no revert and no event to notice, which is why the deploy path
///      needs its own assertion rather than relying on the pool's own reserve-factor tests — those
///      set the factor by hand and so cannot see it failing to arrive.
contract DeployPoolReserveFactorTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;

    StubProfile internal profile;
    MockERC20 internal usdc;
    address internal deployer;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_KEY);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockConstantFeed stableFeed = new MockConstantFeed(1e18);
        MockConstantFeed nativeFeed = new MockConstantFeed(3000e18);

        profile = new StubProfile(address(usdc), address(weth), address(stableFeed), address(nativeFeed), deployer);

        // run() reads the key from the environment and checks it against the profile's declared
        // deployer, so the test has to supply a matching pair rather than prank its way in.
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));

        profile.run();
    }

    /// @dev Two assertions because they fail on different mistakes. The equality catches the
    ///      reserve factor being dropped from the createPool call or overwritten afterwards; it
    ///      would still hold if the script's constant were edited to zero. The nonzero check is
    ///      what catches that.
    function test_deployedPool_carriesTheScriptsReserveFactor() public view {
        address pool = profile.core().lendingPool(address(usdc));
        assertTrue(pool != address(0), "deploy registered no pool for the borrow asset");

        uint256 expected = profile.defaultReserveFactorBps();
        assertGt(expected, 0, "the deploy script's reserve factor is zero");
        assertEq(LendingPool(pool).reserveFactorBps(), expected, "deployed pool did not take the script's factor");
    }
}

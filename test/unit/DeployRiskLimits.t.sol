// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DeployBase} from "../../script/DeployBase.s.sol";
import {DeployBSCTestnet} from "../../script/deploy/BSCTestnet.s.sol";
import {DeployEthMainnet} from "../../script/deploy/EthMainnet.s.sol";
import {DeployLocal} from "../../script/deploy/Local.s.sol";
import {DeploySepolia} from "../../script/deploy/Sepolia.s.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {StubProfile} from "./DeployPoolReserveFactor.t.sol";
import {MockConstantFeed} from "../mocks/MockConstantFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

// The shipped profiles declare _config() internal, so each probe only widens the visibility of the
// real thing. Reading the config rather than running the deploy is deliberate: these profiles point
// at live mainnet and testnet addresses, and what is under test is the numbers the profile states.
contract EthMainnetProbe is DeployEthMainnet {
    function config() external returns (ChainConfig memory) {
        return _config();
    }
}

contract SepoliaProbe is DeploySepolia {
    function config() external returns (ChainConfig memory) {
        return _config();
    }
}

contract BSCTestnetProbe is DeployBSCTestnet {
    function config() external returns (ChainConfig memory) {
        return _config();
    }
}

contract LocalProbe is DeployLocal {
    function config() external returns (ChainConfig memory) {
        return _config();
    }
}

/// @title DeployRiskLimitsTest
/// @notice That every chain profile states a debt floor and a daily borrow throttle, and that a
///         deploy actually installs them on RiskManager.
/// @dev Both limits default to 0 in RiskManager and 0 means the check does not run, so a deployment
///      that never set them looks completely healthy: the protocol deploys, lends, liquidates and
///      hands over with no revert, no event and nothing for a test of RiskManager itself to catch —
///      those tests set the limits by hand and so cannot see them failing to arrive. Hence assertions
///      on the post-deploy state and on the shipped profiles, rather than on the calls.
contract DeployRiskLimitsTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;
    /// @dev Anvil's documented default mnemonic; account #0 is the deployer DeployLocal insists on.
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
    uint256 internal constant LOCAL_CHAIN_ID = 1337;
    uint256 internal constant BPS = 10_000;

    StubProfile internal profile;
    RiskManager internal riskDefaults;
    address internal deployer;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_KEY);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockConstantFeed stableFeed = new MockConstantFeed(1e18);
        MockConstantFeed nativeFeed = new MockConstantFeed(3000e18);

        profile = new StubProfile(address(usdc), address(weth), address(stableFeed), address(nativeFeed), deployer);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        profile.run();

        // A RiskManager wired to nothing, purely to read maxPositionValue at its deployed default.
        // The profile assertions below compare against that rather than against a literal, so the
        // check follows the contract if the default is ever retuned instead of quietly going stale.
        ACLManager acl = new ACLManager(address(this));
        riskDefaults = new RiskManager(address(new ProtocolCore(address(this), address(acl))));
    }

    // --- Post-deploy state ---

    function test_deployedRiskManager_carriesBothLimits() public view {
        RiskManager rm = profile.riskManager();
        assertGt(rm.minBorrowUsd(), 0, "deploy left the debt floor disabled");
        assertGt(rm.dailyBorrowIncreaseLimit(), 0, "deploy left the daily borrow throttle disabled");
    }

    /// @dev Separate from the nonzero checks above, which would still hold if the script installed
    ///      some value of its own rather than the one the profile states.
    function test_deployedRiskManager_takesTheProfilesValues() public view {
        RiskManager rm = profile.riskManager();
        assertEq(rm.minBorrowUsd(), 100e18, "debt floor did not come from the config");
        assertEq(rm.dailyBorrowIncreaseLimit(), 10_000_000e18, "daily limit did not come from the config");
    }

    /// @dev The limits have to be in force before any market exists, or the window between market
    ///      creation and the risk step is a window in which borrowing is unthrottled.
    function test_limitsAreSetBeforeAnyMarketExists() public {
        uint256 riskStep = type(uint256).max;
        uint256 poolStep = type(uint256).max;

        // A second deploy, run under log recording, so the two events can be ordered within one run.
        vm.recordLogs();
        StubProfile fresh = _freshProfile();
        fresh.run();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 minBorrowTopic = keccak256("MinBorrowUsdUpdated(uint256,uint256)");
        bytes32 poolTopic = keccak256("LendingPoolRegistered(address,address)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == minBorrowTopic && riskStep == type(uint256).max) riskStep = i;
            if (entries[i].topics[0] == poolTopic && poolStep == type(uint256).max) poolStep = i;
        }

        assertTrue(riskStep != type(uint256).max, "deploy emitted no debt-floor update");
        assertTrue(poolStep != type(uint256).max, "deploy registered no lending pool");
        assertLt(riskStep, poolStep, "a market was created before the risk limits were in force");
    }

    // --- The shipped profiles ---

    function test_ethMainnetProfile_statesBothLimits() public {
        _withFeeRecipients();
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(address(0x6A4D)));
        _assertLimits(new EthMainnetProbe().config(), "EthMainnet");
    }

    function test_sepoliaProfile_statesBothLimits() public {
        _withFeeRecipients();
        _assertLimits(new SepoliaProbe().config(), "Sepolia");
    }

    function test_bscTestnetProfile_statesBothLimits() public {
        _withFeeRecipients();
        _assertLimits(new BSCTestnetProbe().config(), "BSCTestnet");
    }

    function test_localProfile_statesBothLimits() public {
        uint256 anvilKey = vm.deriveKey(ANVIL_MNEMONIC, 0);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(anvilKey));
        vm.chainId(LOCAL_CHAIN_ID);
        _assertLimits(new LocalProbe().config(), "Local");
    }

    /// @dev The floor has to stay under the smallest borrow script/SeedBorrow.s.sol makes, because
    ///      it binds repayment too: a seeded position below the floor could not be part-repaid, so
    ///      the local fork would serve a protocol nobody can exercise.
    function test_localProfile_floorStaysUnderTheSeededBorrows() public {
        uint256 anvilKey = vm.deriveKey(ANVIL_MNEMONIC, 0);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(anvilKey));
        vm.chainId(LOCAL_CHAIN_ID);
        DeployBase.ChainConfig memory cfg = new LocalProbe().config();

        // SeedBorrow borrows in the stablecoin's 6 decimals; the floor is 18-dec USD.
        uint256 smallestSeededBorrowUsd = 2000e18;
        assertLe(cfg.minBorrowUsd, smallestSeededBorrowUsd, "debt floor would strand the seeded positions");
    }

    // --- Helpers ---

    function _assertLimits(DeployBase.ChainConfig memory cfg, string memory name) internal view {
        assertGt(cfg.minBorrowUsd, 0, string.concat(name, ": no debt floor stated"));
        assertGt(cfg.dailyBorrowIncreaseLimit, 0, string.concat(name, ": no daily borrow throttle stated"));

        // A throttle below what one maximum position may legitimately draw would spend its whole
        // window on a single honest borrower instead of on an attack.
        uint256 largestSingleBorrow = (riskDefaults.maxPositionValue() * cfg.maxLtv) / BPS;
        assertGe(
            cfg.dailyBorrowIncreaseLimit,
            largestSingleBorrow,
            string.concat(name, ": daily limit is below one maximum position's borrow")
        );
    }

    function _withFeeRecipients() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(address(0x7EA5)));
        vm.setEnv("INSURANCE_FUND_ADDRESS", vm.toString(address(0x1435)));
    }

    function _freshProfile() internal returns (StubProfile) {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockConstantFeed stableFeed = new MockConstantFeed(1e18);
        MockConstantFeed nativeFeed = new MockConstantFeed(3000e18);
        return new StubProfile(address(usdc), address(weth), address(stableFeed), address(nativeFeed), deployer);
    }
}

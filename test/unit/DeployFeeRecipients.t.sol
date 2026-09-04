// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {StubProfile} from "./DeployPoolReserveFactor.t.sol";
import {MockConstantFeed} from "../mocks/MockConstantFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title DeployFeeRecipientsTest
/// @notice That a deploy sends protocol revenue somewhere the chain profile actually named.
/// @dev FeeCollector's constructor rejects address(0) and nothing else, so passing the deployer for
///      both arguments satisfies it — which is what every profile did. The result deploys, registers
///      and collects normally, with all revenue landing on the deploying EOA and the insurance fund
///      not segregated from it. No revert, no event, and no assertion anywhere could tell that state
///      apart from a correctly wired one, because the address the script passed and the address it
///      would have been compared against were the same.
///
///      Hence the fixed, distinct constants on StubProfile: this test can only pass if the two
///      addresses travelled from the config into the contract.
contract DeployFeeRecipientsTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;

    StubProfile internal profile;
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
    }

    function test_deployedFeeCollector_takesTheProfilesRecipients() public view {
        assertEq(profile.feeCollector().treasury(), profile.TREASURY(), "treasury did not come from the config");
        assertEq(
            profile.feeCollector().insuranceFund(),
            profile.INSURANCE_FUND(),
            "insurance fund did not come from the config"
        );
    }

    /// @dev The specific failure this replaces. Asserted separately from the equalities above
    ///      because those would still hold if a profile were edited to name the deployer twice.
    function test_deployedFeeCollector_doesNotPointAtTheDeployer() public view {
        assertTrue(profile.feeCollector().treasury() != deployer, "revenue routed to the deploying key");
        assertTrue(profile.feeCollector().insuranceFund() != deployer, "insurance fund is the deploying key");
        assertTrue(
            profile.feeCollector().treasury() != profile.feeCollector().insuranceFund(),
            "collapsed recipients make FeeCollector's split a no-op"
        );
    }
}

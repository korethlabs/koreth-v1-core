// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";

/// @notice Minimal configurable Chainlink AggregatorV3 mock
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function setStartedAt(uint256 _startedAt) external {
        startedAt = _startedAt;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setRound(uint80 _roundId, uint80 _answeredInRound) external {
        roundId = _roundId;
        answeredInRound = _answeredInRound;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @title PriceFeedRegistryTest
/// @notice Unit tests for staleness, L2 sequencer uptime (A3), and price bounds (B1)
contract PriceFeedRegistryTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    PriceFeedRegistry public registry;
    MockAggregator public feed;

    address public owner = makeAddr("owner");
    address public stranger = makeAddr("stranger");
    address public token = makeAddr("token");

    function setUp() public {
        vm.warp(1_000_000); // large timestamp so grace/staleness math is well-defined

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        registry = new PriceFeedRegistry(address(core));

        feed = new MockAggregator(8, 2000e8); // $2000, 8 decimals

        vm.prank(owner);
        registry.setPriceFeed(token, address(feed));
    }

    // ========== Baseline ==========

    function test_getPrice_normalizesTo18Decimals() public view {
        assertEq(registry.getPrice(token), 2000e18);
    }

    // ========== A3: L2 sequencer uptime ==========

    function _deploySequencer(int256 status, uint256 startedAt) internal returns (MockAggregator seq) {
        seq = new MockAggregator(0, status); // status: 0 = up, 1 = down
        seq.setStartedAt(startedAt);
    }

    function test_getPrice_revertsWhenSequencerDown() public {
        MockAggregator seq = _deploySequencer(1, block.timestamp - 10_000); // down
        vm.prank(owner);
        registry.setSequencerUptimeFeed(address(seq));

        vm.expectRevert("SEQUENCER_DOWN");
        registry.getPrice(token);
    }

    function test_getPrice_revertsWithinGracePeriod() public {
        // up, but only 100s since restart (< 3600 grace)
        MockAggregator seq = _deploySequencer(0, block.timestamp - 100);
        vm.prank(owner);
        registry.setSequencerUptimeFeed(address(seq));

        vm.expectRevert("SEQUENCER_GRACE_PERIOD");
        registry.getPrice(token);
    }

    function test_getPrice_succeedsAfterGracePeriod() public {
        // up, 4000s since restart (> 3600 grace)
        MockAggregator seq = _deploySequencer(0, block.timestamp - 4000);
        vm.prank(owner);
        registry.setSequencerUptimeFeed(address(seq));

        assertEq(registry.getPrice(token), 2000e18);
    }

    function test_getPrice_sequencerDisabledByDefault() public view {
        // No sequencer feed set → check skipped entirely
        assertEq(registry.getPrice(token), 2000e18);
    }

    // ========== B1: price bounds ==========

    function test_getPrice_revertsBelowFloor() public {
        vm.prank(owner);
        registry.setPriceBounds(token, 1000e18, 3000e18);

        feed.setAnswer(500e8); // $500 < $1000 floor
        vm.expectRevert("PRICE_BELOW_FLOOR");
        registry.getPrice(token);
    }

    function test_getPrice_revertsAboveCeiling() public {
        vm.prank(owner);
        registry.setPriceBounds(token, 1000e18, 3000e18);

        feed.setAnswer(5000e8); // $5000 > $3000 ceil
        vm.expectRevert("PRICE_ABOVE_CEIL");
        registry.getPrice(token);
    }

    function test_getPrice_succeedsWithinBounds() public {
        vm.prank(owner);
        registry.setPriceBounds(token, 1000e18, 3000e18);

        feed.setAnswer(2000e8); // $2000 within [1000, 3000]
        assertEq(registry.getPrice(token), 2000e18);
    }

    function test_getPrice_boundsDisabledByDefault() public {
        feed.setAnswer(1); // 1 wei price, no bounds set
        assertEq(registry.getPrice(token), 1e10); // 1 * 10^(18-8)
    }

    // ========== Access control & validation ==========

    function test_setSequencerUptimeFeed_onlyPoolAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_POOL_ADMIN");
        registry.setSequencerUptimeFeed(address(feed));
    }

    function test_setSequencerGracePeriod_onlyPoolAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_POOL_ADMIN");
        registry.setSequencerGracePeriod(1800);
    }

    function test_setSequencerGracePeriod_revertsOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        registry.setSequencerGracePeriod(100); // < 300
    }

    function test_setPriceBounds_onlyPoolAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_POOL_ADMIN");
        registry.setPriceBounds(token, 1, 2);
    }

    function test_setPriceBounds_revertsInvalidBounds() public {
        vm.prank(owner);
        vm.expectRevert("INVALID_BOUNDS");
        registry.setPriceBounds(token, 3000e18, 1000e18); // min >= max
    }

    function test_setPriceBounds_revertsZeroToken() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        registry.setPriceBounds(address(0), 1000e18, 3000e18);
    }

    function test_setSequencerUptimeFeed_allowsZeroToDisable() public {
        vm.prank(owner);
        registry.setSequencerUptimeFeed(address(0)); // no revert — disables the check
        assertEq(registry.sequencerUptimeFeed(), address(0));
    }
}

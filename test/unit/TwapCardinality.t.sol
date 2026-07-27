// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {UniswapV3Oracle} from "../../src/oracle/UniswapV3Oracle.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3.sol";

/// @notice Mock V3 pool with configurable cardinality and observe behavior
contract MockV3Pool {
    uint16 public cardinalityReturn;
    bool public observeShouldRevert;
    string public revertReason;
    int56[] public tickCumulativesReturn;

    int24 public currentTick;
    uint160 public sqrtPrice;

    constructor() {
        cardinalityReturn = 200;
        sqrtPrice = 79_228_162_514_264_337_593_543_950_336; // ~1:1 price
        currentTick = 0;

        // Default: valid tick cumulatives (delta = 0 over 1800s)
        tickCumulativesReturn.push(int56(0));
        tickCumulativesReturn.push(int56(0));
    }

    function setCardinality(uint16 _cardinality) external {
        cardinalityReturn = _cardinality;
    }

    function setObserveShouldRevert(bool _shouldRevert, string memory _reason) external {
        observeShouldRevert = _shouldRevert;
        revertReason = _reason;
    }

    function setTickCumulatives(int56 cumulative0, int56 cumulative1) external {
        tickCumulativesReturn[0] = cumulative0;
        tickCumulativesReturn[1] = cumulative1;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPrice, currentTick, 0, cardinalityReturn, cardinalityReturn, 0, true);
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeShouldRevert) {
            // Simulate Uniswap's "OLD" error
            revert(revertReason);
        }
        tickCumulatives = tickCumulativesReturn;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }

    function token0() external pure returns (address) {
        return address(0x1111);
    }

    function token1() external pure returns (address) {
        return address(0x2222);
    }

    function fee() external pure returns (uint24) {
        return 3000;
    }

    function liquidity() external pure returns (uint128) {
        return 1_000_000;
    }
}

/// @notice Minimal mock for NFT manager — only needs factory() for constructor
contract MockNFTManager {
    address public immutable factoryAddr;

    constructor() {
        factoryAddr = address(new MockV3Factory());
    }

    function factory() external view returns (address) {
        return factoryAddr;
    }
}

/// @notice Minimal mock for V3 factory
contract MockV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

/// @title TwapCardinalityTest
/// @notice Tests for UniswapV3Oracle TWAP cardinality validation and try/catch on observe
contract TwapCardinalityTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PriceFeedRegistry public priceFeedRegistry;
    UniswapV3OracleHarness public oracle;
    MockV3Pool public mockPool;

    address public owner = makeAddr("owner");

    function setUp() public {
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        vm.prank(owner);
        priceFeedRegistry = new PriceFeedRegistry(address(core));

        // Mock NFT manager — constructor calls positionManager.factory()
        MockNFTManager nftMgr = new MockNFTManager();
        oracle = new UniswapV3OracleHarness(address(core), address(nftMgr), address(priceFeedRegistry));
        mockPool = new MockV3Pool();
    }

    // ========== TWAP — observe() succeeds with valid mock ==========

    function test_twap_succeeds_anyCardinality() public {
        // Cardinality pre-check removed (L2-compatible).
        // observe() handles it — mock returns valid data so any cardinality works.
        mockPool.setCardinality(1);
        oracle.exposed_getTwapTick(address(mockPool));

        mockPool.setCardinality(151);
        oracle.exposed_getTwapTick(address(mockPool));

        mockPool.setCardinality(200);
        oracle.exposed_getTwapTick(address(mockPool));
    }

    function test_twap_customPeriod5min() public {
        vm.prank(owner);
        oracle.setTwapPeriod(300);

        mockPool.setCardinality(1);
        oracle.exposed_getTwapTick(address(mockPool)); // succeeds — observe() handles it
    }

    // ========== Try/Catch on observe() ==========

    function test_observe_revertsOLD_givesTwapUnavailable() public {
        // Cardinality passes but observe reverts with "OLD"
        mockPool.setCardinality(200);
        mockPool.setObserveShouldRevert(true, "OLD");

        vm.expectRevert("TWAP_UNAVAILABLE");
        oracle.exposed_getTwapTick(address(mockPool));
    }

    function test_observe_revertsAny_givesTwapUnavailable() public {
        // Any revert from observe() should be caught
        mockPool.setCardinality(200);
        mockPool.setObserveShouldRevert(true, "SOMETHING_ELSE");

        vm.expectRevert("TWAP_UNAVAILABLE");
        oracle.exposed_getTwapTick(address(mockPool));
    }

    function test_observe_success_returnsTick() public {
        mockPool.setCardinality(200);
        // Set tick cumulatives: delta = 1800 * 100 = 180000 over 1800s = tick 100
        mockPool.setTickCumulatives(0, 180_000);

        int24 tick = oracle.exposed_getTwapTick(address(mockPool));
        assertEq(tick, 100, "TWAP tick should be 100");
    }

    function test_observe_negativeTick_roundsDown() public {
        mockPool.setCardinality(200);
        // delta = -1801 over 1800s = -1.0005... should round to -2
        mockPool.setTickCumulatives(0, -1801);

        int24 tick = oracle.exposed_getTwapTick(address(mockPool));
        assertEq(tick, -2, "Negative tick should round towards negative infinity");
    }

    function test_observe_negativeTick_exact() public {
        mockPool.setCardinality(200);
        // delta = -1800 over 1800s = exactly -1
        mockPool.setTickCumulatives(0, -1800);

        int24 tick = oracle.exposed_getTwapTick(address(mockPool));
        assertEq(tick, -1, "Exact negative tick should not round further");
    }
}

/// @notice Harness to expose internal _getTwapTick for testing
contract UniswapV3OracleHarness is UniswapV3Oracle {
    constructor(
        address _core,
        address _nftManager,
        address _priceFeedRegistry
    )
        UniswapV3Oracle(_core, _nftManager, _priceFeedRegistry)
    {}

    function exposed_getTwapTick(address pool) external view returns (int24) {
        return _getTwapTick(pool);
    }
}

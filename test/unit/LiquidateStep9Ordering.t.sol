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
import {MockLendingPool} from "../mocks/MockLendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {TestPools} from "../helpers/TestPools.sol";
import {TestSecurity} from "../helpers/TestSecurity.sol";

/// @notice token0 with a transfer hook that snapshots the position's status the moment the engine
///         pays the liquidator. Modelling a callback-capable collateral token (ERC-777 / hook), it
///         lets the test observe the checks-effects-interactions ordering: whether the payout (an
///         interaction) lands before or after the position state is finalized.
contract HookToken {
    string public name = "HOOK";
    string public symbol = "HOOK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public watchTo;
    address public pm;
    uint256 public watchPosId;
    bool public captured;
    uint8 public statusAtPayout;

    /// @notice Arm the hook: on the next transfer whose recipient is `_to`, snapshot posId's status.
    function setWatch(address _to, address _pm, uint256 _posId) external {
        watchTo = _to;
        pm = _pm;
        watchPosId = _posId;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "INSUFFICIENT_BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _hook(to);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "INSUFFICIENT_BALANCE");
        require(allowance[from][msg.sender] >= amount, "INSUFFICIENT_ALLOWANCE");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _hook(to);
        return true;
    }

    function _hook(address to) internal {
        if (to == watchTo && !captured) {
            statusAtPayout = uint8(IPositionManager(pm).getPosition(watchPosId).status);
            captured = true;
        }
    }
}

/// @title LiquidateStep9Ordering (L1 regression)
/// @notice The liquidator's NO-SWAP token payout must be the LAST interaction in liquidate(): a
///         callback-capable collateral token must only hand the liquidator control after the position
///         state is fully finalized (marked liquidated, LP returned, supply-cap credited). Before the
///         reorder the payout ran before markLiquidated, so a hook would observe a still-Borrowed
///         position with the debt already repaid — a checks-effects-interactions violation.
contract LiquidateStep9OrderingTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockLendingPool public market;
    PriceFeedRegistry public priceRegistry;
    MockERC20 public usdc;
    HookToken public hookWeth;
    InterestRateModel public irm;
    RiskManager public riskManager;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");
    address public borrowAsset;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        hookWeth = new HookToken();
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        oracleHub = LPOracleHub(
            address(
                new ERC1967Proxy(address(new LPOracleHub()), abi.encodeCall(LPOracleHub.initialize, (address(core))))
            )
        );
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(new LendingEngine()), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );
        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(new LiquidationEngine()),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);
        market = new MockLendingPool(address(usdc), address(irm));
        borrowAsset = address(usdc);
        riskManager = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV2);
        priceRegistry = TestPricing.wireStable(core, address(usdc));
        TestPricing.priceAsset(priceRegistry, address(hookWeth), 200e18);
        core.registerLendingPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV2, RiskConfig.defaultConfig());
        TestSecurity.wireBreaker(core, pm);
        TestSecurity.wireFeeCollector(core, liq, makeAddr("treasury"));
        pm.setLendingEngine(address(le));
        // Full liquidation allowed so a single call repays the whole debt and closes the position.
        liq.setMaxLiquidationPortion(10_000);
        vm.stopPrank();

        // 25 hookWeth + 25,000 USDC per 100 units — token0 is the hook token.
        adapter.setTokenReturns(address(hookWeth), address(usdc));
        adapter.setUnwindAmounts(25e18, 25_000e18);
        adapter.setTotalLiquidity(100e18);

        usdc.mint(address(market), 1_000_000e18);
        hookWeth.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(adapter), 1_000_000e18);
    }

    function _createLiquidatablePosition() internal returns (uint256 posId) {
        vm.prank(alice);
        posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        oracle.setPrice(30_000e18); // HF drops below 1
    }

    function test_liquidatorPayoutIsLastInteraction() public {
        uint256 posId = _createLiquidatablePosition();
        uint256 totalDebt = le.getDebt(posId);

        // Arm the hook: capture the position status when hookWeth lands on the liquidator.
        hookWeth.setWatch(liquidator, address(pm), posId);

        usdc.mint(liquidator, totalDebt);
        vm.prank(liquidator);
        usdc.approve(address(liq), totalDebt);

        vm.prank(liquidator);
        liq.liquidate(posId, totalDebt, block.timestamp + 1 hours, 0, 0);

        // The hook must have fired (payout actually reached the liquidator)...
        assertTrue(hookWeth.captured(), "liquidator payout hook did not fire");
        // ...and at that moment the position must already be finalized as Liquidated, proving the
        // token transfer is the last interaction (post markLiquidated), not before it.
        assertEq(
            hookWeth.statusAtPayout(),
            uint8(IPositionManager.PositionStatus.Liquidated),
            "position not finalized before liquidator payout"
        );
    }
}

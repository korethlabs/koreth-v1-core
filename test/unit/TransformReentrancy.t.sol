// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {Market} from "../../src/markets/Market.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Transformer that re-enters PositionManager.transform() while a transform is in progress.
///         It owns its OWN position so the nested call passes the owner check and reaches the
///         TRANSFORM_IN_PROGRESS reentrancy guard.
contract ReentrantTransformer {
    PositionManager public pm;
    uint256 public ownPositionId;

    constructor(address _pm) {
        pm = PositionManager(_pm);
    }

    function setOwnPosition(uint256 posId) external {
        ownPositionId = posId;
    }

    /// @dev Entry point invoked by the outer transform(). Re-enters transform().
    function reenter() external {
        pm.transform(ownPositionId, address(this), abi.encodeCall(this.noop, ()));
    }

    function noop() external {}
}

/// @notice Transformer that tries to touch a DIFFERENT position than the one authorized.
contract CrossPositionTransformer {
    PositionManager public pm;
    uint256 public victimPositionId;

    constructor(address _pm) {
        pm = PositionManager(_pm);
    }

    function setVictim(uint256 posId) external {
        victimPositionId = posId;
    }

    /// @dev Attempts addCollateral on a position that is NOT the transformedPositionId.
    function attackOtherPosition() external {
        pm.addCollateral(victimPositionId, 1e18, 1e18, 0, 0);
    }
}

/// @notice Transformer that reverts with no reason string (tests TRANSFORM_FAILED bubble-up).
contract SilentRevertTransformer {
    function boom() external pure {
        // solhint-disable-next-line reason-string
        revert();
    }
}

contract TransformReentrancyTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    Market public market;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockERC20 public usdc;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public lpToken = makeAddr("lpToken");
    uint256 public marketId;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);
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

        IMarket.MarketConfig memory mConfig = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(usdc),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 100_000_000e18,
            minPoolTvl: 0,
            minPoolAge: 0
        });
        market = Market(
            address(
                new ERC1967Proxy(
                    address(new Market()), abi.encodeCall(Market.initialize, (mConfig, address(irm), address(core)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        adapter.setTokenReturns(address(usdc), address(usdc));
        oracle = new MockLPOracle();
        oracle.setPrice(100_000e18);

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();
    }

    // ========== Reentrancy guard ==========

    /// @notice A whitelisted transformer that re-enters transform() must hit TRANSFORM_IN_PROGRESS.
    function test_transform_reentrancy_blocked() public {
        ReentrantTransformer attacker = new ReentrantTransformer(address(pm));

        vm.prank(owner);
        aclManager.addTransformer(address(attacker));

        // The attacker owns its own position (so the nested owner check passes and we reach the guard)
        vm.prank(address(attacker));
        uint256 attackerPos = pm.deposit(lpToken, 1, 100e18, marketId);
        attacker.setOwnPosition(attackerPos);

        // Alice owns a position and transforms it via the attacker
        vm.prank(alice);
        uint256 alicePos = pm.deposit(lpToken, 2, 100e18, marketId);

        bytes memory data = abi.encodeCall(ReentrantTransformer.reenter, ());

        vm.prank(alice);
        vm.expectRevert("TRANSFORM_IN_PROGRESS");
        pm.transform(alicePos, address(attacker), data);
    }

    // ========== Cross-position authorization ==========

    /// @notice A transformer may only touch the position being transformed, not another one.
    function test_transform_cannotTouchOtherPosition() public {
        CrossPositionTransformer attacker = new CrossPositionTransformer(address(pm));

        vm.prank(owner);
        aclManager.addTransformer(address(attacker));

        // Victim position owned by alice
        vm.prank(alice);
        uint256 victimPos = pm.deposit(lpToken, 1, 100e18, marketId);
        attacker.setVictim(victimPos);

        // Attacker owns the position it will legitimately transform
        vm.prank(address(attacker));
        uint256 attackerPos = pm.deposit(lpToken, 2, 100e18, marketId);

        bytes memory data = abi.encodeCall(CrossPositionTransformer.attackOtherPosition, ());

        // During transform of attackerPos, it tries addCollateral on victimPos → not authorized
        vm.prank(address(attacker));
        vm.expectRevert("NOT_POSITION_OWNER");
        pm.transform(attackerPos, address(attacker), data);
    }

    // ========== TRANSFORM_FAILED bubble-up ==========

    /// @notice A transformer that reverts with no reason bubbles up TRANSFORM_FAILED.
    function test_transform_silentRevert_bubblesTransformFailed() public {
        SilentRevertTransformer attacker = new SilentRevertTransformer();

        vm.prank(owner);
        aclManager.addTransformer(address(attacker));

        vm.prank(alice);
        uint256 alicePos = pm.deposit(lpToken, 1, 100e18, marketId);

        bytes memory data = abi.encodeCall(SilentRevertTransformer.boom, ());

        vm.prank(alice);
        vm.expectRevert("TRANSFORM_FAILED");
        pm.transform(alicePos, address(attacker), data);
    }

    // ========== Non-owner cannot transform ==========

    /// @notice Only the position owner can initiate a transform.
    function test_transform_revertsNonOwner() public {
        SilentRevertTransformer t = new SilentRevertTransformer();
        vm.prank(owner);
        aclManager.addTransformer(address(t));

        vm.prank(alice);
        uint256 alicePos = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert("NOT_POSITION_OWNER");
        pm.transform(alicePos, address(t), abi.encodeCall(SilentRevertTransformer.boom, ()));
    }

    // ========== Non-whitelisted transformer rejected ==========

    /// @notice A transformer that is not whitelisted cannot be used.
    function test_transform_revertsNonWhitelistedTransformer() public {
        SilentRevertTransformer t = new SilentRevertTransformer(); // NOT added as transformer

        vm.prank(alice);
        uint256 alicePos = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(alice);
        vm.expectRevert("NOT_TRANSFORMER");
        pm.transform(alicePos, address(t), abi.encodeCall(SilentRevertTransformer.boom, ()));
    }
}

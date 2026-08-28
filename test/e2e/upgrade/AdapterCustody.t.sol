// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UniswapV2Adapter} from "../../../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../../src/adapters/UniswapV3Adapter.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {TestAdapters} from "../../helpers/TestAdapters.sol";

/// @dev A later adapter implementation: same behaviour, plus a state variable appended after the
///      storage gap — the shape a real upgrade grows into.
contract UniswapV2AdapterNext is UniswapV2Adapter {
    uint256 public newStateVar;

    function setNewStateVar(uint256 value) external {
        newStateVar = value;
    }
}

/// @dev The V3 counterpart.
contract UniswapV3AdapterNext is UniswapV3Adapter {
    uint256 public newStateVar;
}

/// @title AdapterCustodyE2E
/// @notice The adapters custody the collateral deposited through them, so their addresses are part
///         of the custody relationship. These tests cover the two halves of keeping that intact:
///         an LP type cannot be repointed at a different adapter, and the adapter behind a live
///         type can still be fixed by upgrading its implementation.
contract AdapterCustodyE2E is E2EBase {
    // ================================================================
    // 1. An adapter holding live collateral cannot be swapped out
    // ================================================================

    function test_replacingAnAdapterHoldingCollateralIsRejected() public {
        uint256 lpAmount = _createV2Position(alice, 1 ether, 2000e6);
        _depositV2(alice, lpAmount);

        assertGt(
            IERC20(Constants.UNI_V2_WETH_USDC).balanceOf(address(v2Adapter)),
            0,
            "adapter should custody the deposited LP"
        );

        vm.startPrank(deployer);
        address replacement =
            address(TestAdapters.uniswapV2(Constants.UNI_V2_FACTORY, Constants.UNI_V2_ROUTER, address(core)));
        vm.expectRevert("ADAPTER_ALREADY_SET");
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, replacement);
        vm.stopPrank();

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV2), address(v2Adapter), "registry unchanged");
    }

    /// @dev The same applies before anything is deposited: the check is on the registry slot, not on
    ///      whether assets happen to be sitting in the adapter at that moment. A type registered on
    ///      an empty protocol is the one that will hold collateral tomorrow.
    function test_replacingAnEmptyAdapterIsRejectedToo() public {
        vm.startPrank(deployer);
        address replacement =
            address(TestAdapters.uniswapV3(Constants.UNI_V3_NFT_MANAGER, Constants.UNI_V3_FACTORY, address(core)));
        vm.expectRevert("ADAPTER_ALREADY_SET");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, replacement);
        vm.stopPrank();
    }

    // ================================================================
    // 2. Fixing an adapter: upgrade the implementation, keep the custody
    // ================================================================

    /// @notice The point of the whole arrangement. A pool admin ships a new adapter implementation
    ///         while positions are open, and every exit still works: the debt-free borrower
    ///         withdraws their LP, and the underwater one is liquidated. The collateral never moves,
    ///         because the address holding it never changed.
    function test_upgradingTheAdapterImplementationLeavesLivePositionsWorking() public {
        uint256 lpAmount = _createV2Position(alice, 1 ether, 2000e6);
        uint256 freePos = _depositV2(alice, lpAmount / 2);
        uint256 borrowedPos = _depositV2(alice, lpAmount / 2);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(borrowedPos);
        vm.prank(alice);
        lendingEngine.borrow(borrowedPos, (maxBorrow * 90) / 100);

        uint256 custodied = IERC20(Constants.UNI_V2_WETH_USDC).balanceOf(address(v2Adapter));
        assertGt(custodied, 0, "adapter should custody the deposited LP");

        // The fix ships as an implementation swap behind the registered proxy address.
        vm.startPrank(deployer);
        UniswapV2AdapterNext newImpl = new UniswapV2AdapterNext();
        v2Adapter.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        // Wiring set by initialize() survives the upgrade — nothing had to be re-supplied.
        assertEq(address(v2Adapter.v2Factory()), Constants.UNI_V2_FACTORY, "factory preserved");
        assertEq(address(v2Adapter.v2Router()), Constants.UNI_V2_ROUTER, "router preserved");
        assertEq(address(v2Adapter.core()), address(core), "core preserved");
        assertEq(IERC20(Constants.UNI_V2_WETH_USDC).balanceOf(address(v2Adapter)), custodied, "collateral did not move");

        // The appended state variable lands past the gap and does not disturb what is already there.
        UniswapV2AdapterNext(address(v2Adapter)).setNewStateVar(42);
        assertEq(UniswapV2AdapterNext(address(v2Adapter)).newStateVar(), 42, "appended var usable");
        assertEq(address(v2Adapter.core()), address(core), "core still intact after new var written");

        // Exit 1: the debt-free position withdraws its LP back to the owner.
        uint256 aliceLpBefore = IERC20(Constants.UNI_V2_WETH_USDC).balanceOf(alice);
        IPositionManager.Position memory freeInfo = positionManager.getPosition(freePos);
        vm.prank(alice);
        positionManager.withdraw(freePos);
        assertEq(
            IERC20(Constants.UNI_V2_WETH_USDC).balanceOf(alice),
            aliceLpBefore + freeInfo.amount,
            "withdraw returned the LP after the upgrade"
        );

        // Exit 2: the borrowed position is liquidatable and can actually be liquidated.
        IPositionManager.Position memory pos = positionManager.getPosition(borrowedPos);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (_getPositionValue(borrowedPos) * 40) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(borrowedPos);
        assertTrue(canLiq, "position should be liquidatable");

        uint256 debtBefore = lendingEngine.getDebt(borrowedPos);
        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(borrowedPos, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        assertLt(lendingEngine.getDebt(borrowedPos), debtBefore, "liquidation reduced the debt after the upgrade");
    }

    /// @dev The V3 side, where the adapter holds the position NFT and gates every operation on
    ///      still owning it.
    function test_upgradingTheV3AdapterImplementationLeavesLivePositionsWorking() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        assertEq(nftManager.ownerOf(tokenId), address(v3Adapter), "adapter should custody the deposited NFT");

        vm.startPrank(deployer);
        UniswapV3AdapterNext newImpl = new UniswapV3AdapterNext();
        v3Adapter.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        assertEq(address(v3Adapter.nftManager()), Constants.UNI_V3_NFT_MANAGER, "nft manager preserved");
        assertEq(address(v3Adapter.v3Factory()), Constants.UNI_V3_FACTORY, "factory preserved");
        assertEq(nftManager.ownerOf(tokenId), address(v3Adapter), "NFT did not move");

        vm.prank(alice);
        positionManager.withdraw(positionId);
        assertEq(nftManager.ownerOf(tokenId), alice, "withdraw returned the NFT after the upgrade");
    }

    // ================================================================
    // 3. Who may upgrade
    // ================================================================

    /// @dev Gated the same way PositionManager and LiquidationEngine gate theirs — a pool admin on
    ///      the shared ACLManager, and nobody else.
    function test_upgradeIsPoolAdminOnly() public {
        UniswapV2AdapterNext newImpl = new UniswapV2AdapterNext();

        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        v2Adapter.upgradeToAndCall(address(newImpl), "");

        vm.prank(guardian); // emergency admin, not a pool admin
        vm.expectRevert("NOT_POOL_ADMIN");
        v2Adapter.upgradeToAndCall(address(newImpl), "");

        vm.prank(deployer);
        v2Adapter.upgradeToAndCall(address(newImpl), "");
    }

    /// @dev The implementation behind the proxy must not be usable on its own — an uninitialized
    ///      copy anyone could claim by calling initialize() first.
    function test_implementationCannotBeInitialized() public {
        UniswapV2Adapter impl = new UniswapV2Adapter();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(Constants.UNI_V2_FACTORY, Constants.UNI_V2_ROUTER, address(core));
    }
}

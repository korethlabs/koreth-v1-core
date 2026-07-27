// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IUniswapV2Pair} from "../../src/interfaces/external/IUniswapV2.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @title UniswapV2AdapterForkTest
/// @notice Fork tests against REAL Uniswap V2 on Ethereum mainnet
contract UniswapV2AdapterForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNI_V2_WETH_USDC = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    UniswapV2Adapter public adapter;
    ProtocolCore public core;
    ACLManager public aclManager;
    address public owner = makeAddr("owner");
    address public protocol = makeAddr("protocol");

    function setUp() public {
        vm.activeFork();

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        adapter = new UniswapV2Adapter(UNI_V2_FACTORY, UNI_V2_ROUTER, address(core));

        // Grant protocol address the POSITION_MANAGER role so it can call adapter
        bytes32 pmRole = aclManager.POSITION_MANAGER();
        vm.prank(owner);
        aclManager.grantRole(pmRole, protocol);
    }

    function _lockPosition() internal returns (address holder, uint256 lockAmount) {
        holder = makeAddr("v2LpHolder");
        lockAmount = 1e15;
        deal(UNI_V2_WETH_USDC, holder, lockAmount);

        vm.prank(holder);
        IUniswapV2Pair(UNI_V2_WETH_USDC).approve(address(adapter), lockAmount);

        vm.prank(protocol);
        adapter.validateAndLock(UNI_V2_WETH_USDC, 0, lockAmount, holder);
    }

    // ========== Basic ==========

    function test_isSupported() public view {
        assertTrue(adapter.isSupported(UNI_V2_WETH_USDC));
        assertFalse(adapter.isSupported(address(0x1234)));
        assertFalse(adapter.isSupported(WETH));
    }

    function test_lpType() public view {
        assertEq(uint8(adapter.lpType()), uint8(ILPAdapter.LPType.UniswapV2));
    }

    // ========== Access Control ==========

    function test_onlyProtocol_validateAndLock() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_AUTHORIZED");
        adapter.validateAndLock(UNI_V2_WETH_USDC, 0, 1e18, makeAddr("x"));
    }

    function test_onlyProtocol_unlock() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_AUTHORIZED");
        adapter.unlock(UNI_V2_WETH_USDC, 0, 1e18, makeAddr("x"));
    }

    function test_onlyProtocol_unwind() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_AUTHORIZED");
        adapter.unwind(UNI_V2_WETH_USDC, 0, 100);
    }

    function test_collectFees_alwaysZero() public {
        (uint256 f0, uint256 f1) = adapter.collectFees(UNI_V2_WETH_USDC, 0);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    // ========== Validation ==========

    function test_validateAndLock_revertsZeroAmount() public {
        vm.prank(protocol);
        vm.expectRevert("ZERO_AMOUNT");
        adapter.validateAndLock(UNI_V2_WETH_USDC, 0, 0, makeAddr("x"));
    }

    // ========== Real LP Tests ==========

    function test_validateAndLock_realLPToken() public {
        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        require(pair.totalSupply() > 0, "V2 pair has no supply");

        address holder = makeAddr("lpHolder");
        uint256 lockAmount = 1e15;
        deal(UNI_V2_WETH_USDC, holder, lockAmount);

        vm.prank(holder);
        pair.approve(address(adapter), lockAmount);

        vm.prank(protocol);
        ILPAdapter.LPInfo memory info = adapter.validateAndLock(UNI_V2_WETH_USDC, 0, lockAmount, holder);

        assertEq(pair.balanceOf(address(adapter)), lockAmount);
        assertEq(info.token0, pair.token0());
        assertEq(info.token1, pair.token1());
        assertEq(info.feeTier, 3000);
        assertEq(info.pool, UNI_V2_WETH_USDC);
        assertEq(uint8(info.lpType), uint8(ILPAdapter.LPType.UniswapV2));
    }

    function test_unlock_returnsLPTokens() public {
        (address holder, uint256 lockAmount) = _lockPosition();

        uint256 balBefore = IUniswapV2Pair(UNI_V2_WETH_USDC).balanceOf(holder);

        vm.prank(protocol);
        adapter.unlock(UNI_V2_WETH_USDC, 0, lockAmount, holder);

        assertEq(IUniswapV2Pair(UNI_V2_WETH_USDC).balanceOf(holder) - balBefore, lockAmount);
    }

    function test_unwind_removesLiquidity() public {
        (, uint256 lockAmount) = _lockPosition();

        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        address token0 = pair.token0();
        address token1 = pair.token1();

        uint256 t0Before = IERC20(token0).balanceOf(protocol);
        uint256 t1Before = IERC20(token1).balanceOf(protocol);

        uint128 removeAmount = uint128(lockAmount / 2);
        vm.prank(protocol);
        (uint256 amount0, uint256 amount1) = adapter.unwind(UNI_V2_WETH_USDC, 0, removeAmount);

        assertTrue(amount0 > 0 && amount1 > 0, "Must receive both tokens");
        assertEq(IERC20(token0).balanceOf(protocol) - t0Before, amount0);
        assertEq(IERC20(token1).balanceOf(protocol) - t1Before, amount1);

        uint256 remaining = pair.balanceOf(address(adapter));
        assertApproxEqAbs(remaining, lockAmount - uint256(removeAmount), 1);

        emit log_named_uint("Token0 received", amount0);
        emit log_named_uint("Token1 received", amount1);
    }

    function test_fullLifecycle() public {
        (address holder, uint256 lockAmount) = _lockPosition();

        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);

        // Partial unwind 25%
        uint128 removeAmount = uint128(lockAmount / 4);
        vm.prank(protocol);
        (uint256 a0, uint256 a1) = adapter.unwind(UNI_V2_WETH_USDC, 0, removeAmount);
        assertTrue(a0 > 0 && a1 > 0);

        // collectFees = (0,0) for V2
        (uint256 f0, uint256 f1) = adapter.collectFees(UNI_V2_WETH_USDC, 0);
        assertEq(f0, 0);
        assertEq(f1, 0);

        // Remaining LP
        uint256 remaining = pair.balanceOf(address(adapter));
        assertApproxEqAbs(remaining, lockAmount - uint256(removeAmount), 1);

        // Unlock remaining
        vm.prank(protocol);
        adapter.unlock(UNI_V2_WETH_USDC, 0, remaining, holder);
        assertEq(pair.balanceOf(address(adapter)), 0);
    }
}

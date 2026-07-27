// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/IUniswapV3.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @title UniswapV3AdapterForkTest
/// @notice Fork tests against REAL Uniswap V3 on Ethereum mainnet
/// @dev Run with: ETH_RPC_URL=<rpc> forge test --match-contract UniswapV3AdapterForkTest -vvv
contract UniswapV3AdapterForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI_V3_NFT_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNI_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    UniswapV3Adapter public adapter;
    INonfungiblePositionManager public nftManager;
    ProtocolCore public core;
    ACLManager public aclManager;
    address public owner = makeAddr("owner");
    address public protocol = makeAddr("protocol");

    function setUp() public {
        vm.activeFork();

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        adapter = new UniswapV3Adapter(UNI_V3_NFT_MANAGER, UNI_V3_FACTORY, address(core));
        nftManager = INonfungiblePositionManager(UNI_V3_NFT_MANAGER);

        // Grant protocol address the POSITION_MANAGER role so it can call adapter
        bytes32 pmRole = aclManager.POSITION_MANAGER();
        vm.prank(owner);
        aclManager.grantRole(pmRole, protocol);
    }

    function _findPosition(
        address t0,
        address t1,
        uint24 fee
    )
        internal
        view
        returns (uint256 tokenId, address posOwner)
    {
        uint256 startId = 800_000;
        for (uint256 i = startId; i > startId - 5000; i--) {
            try nftManager.positions(i) returns (
                uint96,
                address,
                address _t0,
                address _t1,
                uint24 _f,
                int24,
                int24,
                uint128 liq,
                uint256,
                uint256,
                uint128,
                uint128
            ) {
                if (liq > 0 && _t0 == t0 && _t1 == t1 && _f == fee) {
                    return (i, nftManager.ownerOf(i));
                }
            } catch {
                continue;
            }
        }
        revert("NO_POSITION_FOUND");
    }

    // ========== Basic ==========

    function test_isSupported() public view {
        assertTrue(adapter.isSupported(UNI_V3_NFT_MANAGER));
        assertFalse(adapter.isSupported(address(0x1234)));
    }

    function test_lpType() public view {
        assertEq(uint8(adapter.lpType()), uint8(ILPAdapter.LPType.UniswapV3));
    }

    function test_validateAndLock_revertsWrongLPToken() public {
        vm.prank(protocol);
        vm.expectRevert("NOT_UNISWAP_V3");
        adapter.validateAndLock(address(0x1234), 1, 0, makeAddr("x"));
    }

    // ========== Access Control ==========

    function test_onlyProtocol_validateAndLock() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_AUTHORIZED");
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, 1, 0, makeAddr("x"));
    }

    function test_onlyProtocol_unlock() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_AUTHORIZED");
        adapter.unlock(UNI_V3_NFT_MANAGER, 1, 0, makeAddr("x"));
    }

    function test_onlyProtocol_unwind() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_AUTHORIZED");
        adapter.unwind(UNI_V3_NFT_MANAGER, 1, 100);
    }

    function test_onlyProtocol_collectFees() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_AUTHORIZED");
        adapter.collectFees(UNI_V3_NFT_MANAGER, 1);
    }

    // ========== Real Position Tests ==========

    function test_validateAndLock_realPosition() public {
        (uint256 tokenId, address posOwner) = _findPosition(USDC, WETH, 500);

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = nftManager.positions(tokenId);

        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);

        vm.prank(protocol);
        ILPAdapter.LPInfo memory info = adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        assertEq(nftManager.ownerOf(tokenId), address(adapter));
        assertEq(info.token0, USDC);
        assertEq(info.token1, WETH);
        assertEq(info.feeTier, 500);
        assertEq(info.tickLower, tickLower);
        assertEq(info.tickUpper, tickUpper);
        assertEq(info.liquidity, liquidity);
        assertTrue(info.pool != address(0));
    }

    function test_unlock_returnsNFT() public {
        (uint256 tokenId, address posOwner) = _findPosition(USDC, WETH, 500);

        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        vm.prank(protocol);
        adapter.unlock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        assertEq(nftManager.ownerOf(tokenId), posOwner);
    }

    function test_unwind_partialLiquidity() public {
        (uint256 tokenId, address posOwner) = _findPosition(USDC, WETH, 500);

        (,,,,,,, uint128 initialLiq,,,,) = nftManager.positions(tokenId);

        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        uint256 usdcBefore = IERC20(USDC).balanceOf(protocol);
        uint256 wethBefore = IERC20(WETH).balanceOf(protocol);

        uint128 removeAmount = initialLiq / 2;
        vm.prank(protocol);
        (uint256 amount0, uint256 amount1) = adapter.unwind(UNI_V3_NFT_MANAGER, tokenId, removeAmount);

        uint256 usdcReceived = IERC20(USDC).balanceOf(protocol) - usdcBefore;
        uint256 wethReceived = IERC20(WETH).balanceOf(protocol) - wethBefore;

        assertTrue(usdcReceived > 0 || wethReceived > 0, "Must receive tokens");
        assertEq(usdcReceived, amount0);
        assertEq(wethReceived, amount1);

        (,,,,,,, uint128 remaining,,,,) = nftManager.positions(tokenId);
        assertApproxEqAbs(remaining, initialLiq - removeAmount, 1);
    }

    function test_unwind_fullLiquidity() public {
        (uint256 tokenId, address posOwner) = _findPosition(USDC, WETH, 500);

        (,,,,,,, uint128 initialLiq,,,,) = nftManager.positions(tokenId);

        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        vm.prank(protocol);
        (uint256 amount0, uint256 amount1) = adapter.unwind(UNI_V3_NFT_MANAGER, tokenId, initialLiq);

        (,,,,,,, uint128 remaining,,,,) = nftManager.positions(tokenId);
        assertEq(remaining, 0);
        assertTrue(amount0 > 0 || amount1 > 0);
    }

    function test_collectFees() public {
        (uint256 tokenId, address posOwner) = _findPosition(USDC, WETH, 500);

        (,,,,,,, uint128 initialLiq,,,,) = nftManager.positions(tokenId);

        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        vm.prank(protocol);
        (uint256 fees0, uint256 fees1) = adapter.collectFees(UNI_V3_NFT_MANAGER, tokenId);

        // Liquidity decreases by at most 1 wei (fee sync)
        (,,,,,,, uint128 liquidityAfter,,,,) = nftManager.positions(tokenId);
        assertApproxEqAbs(liquidityAfter, initialLiq, 1);

        emit log_named_uint("Fees0 (USDC)", fees0);
        emit log_named_uint("Fees1 (WETH)", fees1);
    }

    function test_fullLifecycle() public {
        (uint256 tokenId, address posOwner) = _findPosition(USDC, WETH, 500);

        (,,,,,,, uint128 initialLiq,,,,) = nftManager.positions(tokenId);
        require(initialLiq > 100, "Need meaningful liquidity");

        // 1. Lock
        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);
        assertEq(nftManager.ownerOf(tokenId), address(adapter));

        // 2. Partial unwind (25%)
        vm.prank(protocol);
        adapter.unwind(UNI_V3_NFT_MANAGER, tokenId, initialLiq / 4);

        // 3. Collect fees
        vm.prank(protocol);
        adapter.collectFees(UNI_V3_NFT_MANAGER, tokenId);

        // 4. Verify ~75% remaining
        (,,,,,,, uint128 remaining,,,,) = nftManager.positions(tokenId);
        assertApproxEqAbs(remaining, initialLiq - initialLiq / 4, 2); // -1 from fee sync

        // 5. Unlock
        vm.prank(protocol);
        adapter.unlock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);
        assertEq(nftManager.ownerOf(tokenId), posOwner);
    }
}

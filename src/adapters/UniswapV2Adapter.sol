// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IUniswapV2Pair, IUniswapV2Factory, IUniswapV2Router} from "../interfaces/external/IUniswapV2.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title UniswapV2Adapter
/// @notice Handles Uniswap V2 ERC-20 LP token deposits, withdrawals, and unwinding
/// @dev V2 LP tokens are fungible ERC-20s. Key differences from V3:
///      - No tick ranges — full price range
///      - Fees auto-compound into reserves (no separate collectFees)
///      - LP token amount IS the liquidity
///      - removeLiquidity via V2 Router
///
///      UUPS upgradeable, like every other contract the protocol routes through. This one holds the
///      deposited LP tokens, so its *address* is part of the custody relationship: repointing
///      ProtocolCore at a different adapter would leave each live position resolving to a contract
///      that never received its collateral. Upgrading the implementation behind a fixed proxy
///      address ships a fix without moving the assets.
contract UniswapV2Adapter is ILPAdapter, Initializable, UUPSUpgradeable {
    using SafeERC20 for OZIERC20;

    // Storage, not immutables. Immutables do work behind a proxy — they live in the implementation
    // bytecode — but they would make every replacement implementation re-supply these addresses by
    // hand, and one wrong argument silently repoints the custodian of live collateral at something
    // else. Set once by initialize(), an upgrade cannot get them wrong because it never restates them.
    IUniswapV2Factory public v2Factory;
    IUniswapV2Router public v2Router;
    ProtocolCore public core;

    // --- Events ---
    event PositionLocked(address indexed pair, address indexed from, uint256 amount);
    event PositionUnlocked(address indexed pair, address indexed to, uint256 amount);
    event LiquidityUnwound(address indexed pair, uint256 liquidityRemoved, uint256 amount0, uint256 amount1);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _factory, address _router, address _core) external initializer {
        require(_factory != address(0) && _router != address(0) && _core != address(0), "ZERO_ADDRESS");
        v2Factory = IUniswapV2Factory(_factory);
        v2Router = IUniswapV2Router(_router);
        core = ProtocolCore(_core);
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    // --- ILPAdapter ---

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256, /* tokenId */
        uint256 amount,
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= type(uint128).max, "AMOUNT_OVERFLOW");
        require(from != address(0), "ZERO_FROM");

        // Verify this is a valid V2 pair from our factory (validate before interacting)
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        IUniswapV2Pair pair = IUniswapV2Pair(lpToken);
        require(pair.factory() == address(v2Factory), "NOT_OUR_FACTORY");
        address token0 = pair.token0();
        address token1 = pair.token1();
        require(v2Factory.getPair(token0, token1) == lpToken, "INVALID_PAIR");

        // Transfer LP tokens from user to adapter
        OZIERC20(address(pair)).safeTransferFrom(from, address(this), amount);

        info = LPInfo({
            lpType: LPType.UniswapV2,
            token0: token0,
            token1: token1,
            feeTier: 3000, // V2 always 0.3%
            tickLower: 0,
            tickUpper: 0,
            liquidity: uint128(amount),
            pool: lpToken
        });

        emit PositionLocked(lpToken, from, amount);
    }

    /// @inheritdoc ILPAdapter
    function unlock(
        address lpToken,
        uint256, /* tokenId */
        uint256 amount,
        address to
    )
        external
        onlyProtocol
    {
        require(to != address(0), "ZERO_RECIPIENT");
        require(to != address(this), "CANNOT_UNLOCK_TO_SELF");
        require(amount > 0, "ZERO_AMOUNT");

        // Re-validate the pair's authenticity before moving tokens, matching the sibling
        // liquidity functions: transfer only what a genuine pair from our factory can back.
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        require(IUniswapV2Pair(lpToken).factory() == address(v2Factory), "NOT_OUR_FACTORY");

        OZIERC20(lpToken).safeTransfer(to, amount);

        emit PositionUnlocked(lpToken, to, amount);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Approves router, calls removeLiquidity. Tokens sent to msg.sender.
    ///      Slippage is 0 — handled at LiquidationEngine level.
    function unwind(
        address lpToken,
        uint256, /* tokenId */
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        require(liquidityToRemove > 0, "ZERO_LIQUIDITY");

        // Validate pair before interacting
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        IUniswapV2Pair pair = IUniswapV2Pair(lpToken);
        require(pair.factory() == address(v2Factory), "NOT_OUR_FACTORY");
        address token0 = pair.token0();
        address token1 = pair.token1();

        OZIERC20(address(pair)).forceApprove(address(v2Router), uint256(liquidityToRemove));

        // Remove liquidity — tokens to caller
        (amount0, amount1) = v2Router.removeLiquidity(
            token0,
            token1,
            uint256(liquidityToRemove),
            0,
            0, // slippage handled by LiquidationEngine
            msg.sender,
            block.timestamp
        );

        emit LiquidityUnwound(lpToken, uint256(liquidityToRemove), amount0, amount1);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Calls v2Router.addLiquidity. New LP tokens minted to this adapter.
    ///      Unused tokens refunded to refundTo.
    function addLiquidity(
        address lpToken,
        uint256, /* tokenId */
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address refundTo
    )
        external
        onlyProtocol
        returns (uint256 addedLiquidity, uint256 used0, uint256 used1)
    {
        require(amount0 > 0 || amount1 > 0, "ZERO_AMOUNTS");
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        IUniswapV2Pair pair = IUniswapV2Pair(lpToken);
        require(pair.factory() == address(v2Factory), "NOT_OUR_FACTORY");

        // Validate token0/token1 match the pair (exact order required)
        require(token0 == pair.token0() && token1 == pair.token1(), "TOKEN_MISMATCH");

        OZIERC20(token0).forceApprove(address(v2Router), amount0);
        OZIERC20(token1).forceApprove(address(v2Router), amount1);

        (used0, used1, addedLiquidity) =
            v2Router.addLiquidity(token0, token1, amount0, amount1, 0, 0, address(this), block.timestamp);

        // Refund unused tokens to user
        if (refundTo != address(0)) {
            if (amount0 > used0) OZIERC20(token0).safeTransfer(refundTo, amount0 - used0);
            if (amount1 > used1) OZIERC20(token1).safeTransfer(refundTo, amount1 - used1);
        }
    }

    /// @inheritdoc ILPAdapter
    /// @dev Burns LP tokens via V2 Router, sends underlying tokens to recipient.
    function removeLiquidity(
        address lpToken,
        uint256,
        uint128 liquidity,
        address recipient
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        require(liquidity > 0, "ZERO_LIQUIDITY");
        require(recipient != address(0), "ZERO_RECIPIENT");
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        IUniswapV2Pair pair = IUniswapV2Pair(lpToken);
        require(pair.factory() == address(v2Factory), "NOT_OUR_FACTORY");

        address token0 = pair.token0();
        address token1 = pair.token1();

        OZIERC20(lpToken).forceApprove(address(v2Router), uint256(liquidity));

        (amount0, amount1) =
            v2Router.removeLiquidity(token0, token1, uint256(liquidity), 0, 0, recipient, block.timestamp);
    }

    /// @inheritdoc ILPAdapter
    /// @dev V2 fees auto-compound into reserves. No separate collection needed.
    function collectFees(address, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    /// @dev V2 LP tokens — pos.amount IS the liquidity
    function getLiquidity(address, uint256, uint256 amount) external pure override returns (uint128) {
        require(amount <= type(uint128).max, "AMOUNT_OVERFLOW");
        return uint128(amount);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.UniswapV2;
    }

    /// @inheritdoc ILPAdapter
    /// @dev Checks if address is a contract AND is a V2 pair from our factory
    function isSupported(address lpToken) external view returns (bool) {
        if (lpToken == address(0)) return false;
        if (lpToken.code.length == 0) return false;

        try IUniswapV2Pair(lpToken).factory() returns (address f) {
            return f == address(v2Factory);
        } catch {
            return false;
        }
    }

    /// @inheritdoc ILPAdapter
    /// @dev V2 fees compound into the pair reserves; there are no separately held fees to sweep
    ///      (collectFees is a no-op returning zero).
    function supportsFeeCollection() external pure returns (bool) {
        return false;
    }

    /// @inheritdoc ILPAdapter
    /// @dev The lesser of what the pair holds and what it counts as reserves, per token.
    ///
    ///      A V2 pair tracks reserves separately from its ERC-20 balances, and skim() pays out the
    ///      excess to whoever asks. So a balance above reserves is someone else's tokens sitting in
    ///      the pair until they take them back, and counting it would let a donation made just
    ///      before a measurement be reclaimed just after it — no capital committed, only ordering.
    ///
    ///      Reserves alone are not the answer either: they are only refreshed by mint, burn, swap
    ///      and sync, so a pair drained by a direct transfer still reports the old figures until
    ///      someone pokes it, and would measure as full while holding nothing. The two agree on an
    ///      untouched pair and diverge only in these cases, and the minimum takes the pessimistic
    ///      side of each — which is the safe side for a floor meant to catch a pool running dry.
    ///
    ///      Applied per token rather than to a total, so an inflated side cannot make up for a side
    ///      that has actually drained.
    function poolHoldings(address pool)
        external
        view
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(pool);
        token0 = pair.token0();
        token1 = pair.token1();

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        amount0 = _min(OZIERC20(token0).balanceOf(pool), reserve0);
        amount1 = _min(OZIERC20(token1).balanceOf(pool), reserve1);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // --- Storage Gap ---
    // 3 declared slots (0-2) + 47 gap slots = 50 total. When appending a state var, decrement __gap
    // by the slots it consumes so the total stays 50 (UUPS storage-collision safety). Verified via
    // `forge inspect ... storage-layout`.
    uint256[47] private __gap;
}

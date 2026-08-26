// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "../interfaces/external/IUniswapV3.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title UniswapV3Adapter
/// @notice Handles Uniswap V3 NFT position deposits, withdrawals, and unwinding
/// @dev Real implementation — interacts with Uniswap V3 NonfungiblePositionManager.
///      Uses ProtocolCore for ownership. Protocol address updatable if PositionManager migrates.
///
///      Design notes:
///      - unwind() decreases liquidity and collects whatever is owed. In the liquidation flow the
///        LiquidationEngine sweeps uncollected fees FIRST (fees are not collateral — they are the
///        borrower's yield), so by the time unwind() runs there are no fees left and it collects
///        only the freshly-decreased principal.
///      - collectFees() calls decreaseLiquidity(1 wei) to trigger fee accounting update,
///        then collects all owed tokens. The 1 wei of liquidity loss is negligible.
///      - amount0Min/amount1Min are 0 in decreaseLiquidity because slippage protection is
///        handled at the LiquidationEngine level via oracle-based post-swap validation.
contract UniswapV3Adapter is ILPAdapter {
    using SafeERC20 for OZIERC20;

    INonfungiblePositionManager public immutable nftManager;
    IUniswapV3Factory public immutable v3Factory;
    ProtocolCore public immutable core;

    // --- Events ---
    event PositionLocked(uint256 indexed tokenId, address indexed from, address pool, uint128 liquidity);
    event PositionUnlocked(uint256 indexed tokenId, address indexed to);
    event LiquidityUnwound(uint256 indexed tokenId, uint128 liquidityRemoved, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 indexed tokenId, uint256 fees0, uint256 fees1);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    /// @dev Authorized = PositionManager or LiquidationEngine
    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(address _nftManager, address _factory, address _core) {
        require(_nftManager != address(0) && _factory != address(0) && _core != address(0), "ZERO_ADDRESS");
        nftManager = INonfungiblePositionManager(_nftManager);
        v3Factory = IUniswapV3Factory(_factory);
        core = ProtocolCore(_core);
    }

    // --- ILPAdapter Implementation ---

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256 tokenId,
        uint256, /* amount */
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(from != address(0), "ZERO_FROM");

        // Read position data
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            nftManager.positions(tokenId);

        require(liquidity > 0, "NO_LIQUIDITY");

        // Transfer NFT from user to adapter
        nftManager.transferFrom(from, address(this), tokenId);
        require(nftManager.ownerOf(tokenId) == address(this), "TRANSFER_FAILED");

        // Get pool address
        address pool = v3Factory.getPool(token0, token1, fee);
        require(pool != address(0), "POOL_NOT_FOUND");

        info = LPInfo({
            lpType: LPType.UniswapV3,
            token0: token0,
            token1: token1,
            feeTier: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            pool: pool
        });

        emit PositionLocked(tokenId, from, pool, liquidity);
    }

    /// @inheritdoc ILPAdapter
    function unlock(
        address lpToken,
        uint256 tokenId,
        uint256, /* amount */
        address to
    )
        external
        onlyProtocol
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(to != address(0), "ZERO_RECIPIENT");
        require(to != address(this), "CANNOT_UNLOCK_TO_SELF");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");

        nftManager.transferFrom(address(this), to, tokenId);

        emit PositionUnlocked(tokenId, to);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Decreases liquidity, then collects all owed tokens. In the liquidation flow the
    ///      LiquidationEngine sweeps uncollected fees beforehand, so this collects only the
    ///      freshly-decreased principal (there are no fees left to collect).
    ///      Slippage on decreaseLiquidity is 0 because protection is at the LiquidationEngine
    ///      level via oracle-based post-swap validation (SWAP_SLIPPAGE_EXCEEDED check).
    function unwind(
        address lpToken,
        uint256 tokenId,
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(liquidityToRemove > 0, "ZERO_LIQUIDITY");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");

        // Decrease liquidity — adapter passes amount0Min/amount1Min = 0 to Uniswap.
        // Slippage is checked post-unwind by LiquidationEngine (require amount0 >= minAmount0).
        nftManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidityToRemove, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );

        // Collect the tokens owed. During liquidation, fees were already swept by the engine,
        // so this returns only the freshly-decreased principal. The type(uint128).max caps are
        // safe: nothing beyond what decreaseLiquidity just credited is owed.
        (amount0, amount1) = nftManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: msg.sender, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );

        emit LiquidityUnwound(tokenId, liquidityToRemove, amount0, amount1);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Collects accumulated trading fees without meaningfully removing liquidity.
    ///      Calls decreaseLiquidity(1) to trigger fee accounting update in the pool
    ///      (Uniswap V3 requires a burn to sync tokensOwed with feeGrowthInside).
    ///      The 1 wei of liquidity removed is negligible.
    function collectFees(address lpToken, uint256 tokenId)
        external
        onlyProtocol
        returns (uint256 fees0, uint256 fees1)
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");

        // Check if position has liquidity (can't decrease if already 0)
        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);

        if (currentLiquidity > 1) {
            // Burn 1 wei of liquidity to trigger fee accounting sync.
            // Skipped when liquidity <= 1 to avoid underflow — uncollected fees from the
            // latest swap will be synced on the next pool interaction. Negligible amounts.
            nftManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: 1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
        }

        // Collect all owed tokens (fees + the 1 wei of liquidity)
        (fees0, fees1) = nftManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: msg.sender, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );

        emit FeesCollected(tokenId, fees0, fees1);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Calls nftManager.increaseLiquidity to add tokens to existing V3 NFT position.
    ///      Tokens must already be in this adapter. Unused tokens refunded to refundTo.
    function addLiquidity(
        address lpToken,
        uint256 tokenId,
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
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");
        require(amount0 > 0 || amount1 > 0, "ZERO_AMOUNTS");

        // Validate token order matches NFT (separate frame to avoid stack-too-deep)
        _validateTokenOrder(tokenId, token0, token1);

        // Increase liquidity + refund in separate frame
        (addedLiquidity, used0, used1) = _increaseLiquidity(tokenId, token0, token1, amount0, amount1, refundTo);
    }

    function _validateTokenOrder(uint256 tokenId, address token0, address token1) internal view {
        (,, address t0, address t1,,,,,,,,) = nftManager.positions(tokenId);
        require(token0 == t0 && token1 == t1, "TOKEN_MISMATCH");
    }

    function _increaseLiquidity(
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address refundTo
    )
        internal
        returns (uint256 addedLiquidity, uint256 used0, uint256 used1)
    {
        OZIERC20(token0).forceApprove(address(nftManager), amount0);
        OZIERC20(token1).forceApprove(address(nftManager), amount1);

        (uint128 liquidity, uint256 a0, uint256 a1) = nftManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        addedLiquidity = uint256(liquidity);
        used0 = a0;
        used1 = a1;

        // Refund unused tokens to user
        if (refundTo != address(0)) {
            if (amount0 > used0) OZIERC20(token0).safeTransfer(refundTo, amount0 - used0);
            if (amount1 > used1) OZIERC20(token1).safeTransfer(refundTo, amount1 - used1);
        }
    }

    /// @inheritdoc ILPAdapter
    /// @dev Decreases liquidity and sends underlying tokens to recipient.
    ///      Unlike unwind(), this does NOT collect accumulated fees — only the decreased liquidity.
    ///      Used by PositionManager.removeCollateral() for deleverage flows.
    function removeLiquidity(
        address lpToken,
        uint256 tokenId,
        uint128 liquidity,
        address recipient
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(liquidity > 0, "ZERO_LIQUIDITY");
        require(recipient != address(0), "ZERO_RECIPIENT");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");

        // Decrease liquidity — returns the exact token amounts freed
        (uint256 decreased0, uint256 decreased1) = nftManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );

        // Uniswap tracks owed amounts as uint128, so these already fit — assert it explicitly
        // rather than silently truncating the collect() caps below.
        require(decreased0 <= type(uint128).max && decreased1 <= type(uint128).max, "COLLECT_OVERFLOW");

        // Collect ONLY the decreased amounts — leave accumulated fees in the position.
        // tokensOwed includes both decreased liquidity + accumulated fees, but we cap
        // amount0Max/amount1Max to only collect what was decreased. Remaining fees stay
        // in the NFT for later collectFees/compoundFees calls.
        (amount0, amount1) = nftManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: recipient, amount0Max: uint128(decreased0), amount1Max: uint128(decreased1)
            })
        );
    }

    /// @inheritdoc ILPAdapter
    /// @dev Reads live liquidity directly from V3 NFT — the source of truth for V3 positions
    function getLiquidity(address lpToken, uint256 tokenId, uint256) external view override returns (uint128) {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        (,,,,,,, uint128 liquidity,,,,) = nftManager.positions(tokenId);
        return liquidity;
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.UniswapV3;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        return lpToken == address(nftManager);
    }

    /// @inheritdoc ILPAdapter
    /// @dev V3 positions hold uncollected fees in the NFT, separate from principal liquidity.
    function supportsFeeCollection() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc ILPAdapter
    /// @dev Plain token balances. A V3 pool keeps no reserve accounting to cap them against: its
    ///      liquidity lives in the balances themselves, spread across ticks, and there is no skim()
    ///      to hand back an excess. A donation therefore stays in the pool and counts as depth,
    ///      which is what it is.
    function poolHoldings(address pool)
        external
        view
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        token0 = IUniswapV3Pool(pool).token0();
        token1 = IUniswapV3Pool(pool).token1();
        amount0 = OZIERC20(token0).balanceOf(pool);
        amount1 = OZIERC20(token1).balanceOf(pool);
    }

    /// @notice ERC721 receiver hook — restricts safeTransferFrom to prevent stuck NFTs
    /// @dev validateAndLock uses transferFrom (not safeTransferFrom) so this hook only fires
    ///      if someone calls safeTransferFrom directly. Restricted to V3 NFT manager only,
    ///      initiated by this adapter or the protocol contract.
    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(nftManager), "ONLY_V3_NFT");
        require(
            operator == address(this) || _acl().isPositionManager(operator) || _acl().isLiquidationEngine(operator),
            "UNEXPECTED_OPERATOR"
        );
        return this.onERC721Received.selector;
    }
}

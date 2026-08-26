// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Mock adapter for testing PositionManager
contract MockLPAdapter is ILPAdapter {
    ILPAdapter.LPType public immutable _lpType;
    mapping(address => bool) public supportedTokens;
    bool public shouldRevert;

    // Configurable return values
    address public token0Return = address(0x1111);
    address public token1Return = address(0x2222);
    uint256 public unwindAmount0 = 1 ether;
    uint256 public unwindAmount1 = 2000e6;

    // Track calls for verification
    uint256 public lockCallCount;
    uint256 public unlockCallCount;

    constructor(ILPAdapter.LPType lpType_) {
        _lpType = lpType_;
    }

    function setTokenReturns(address _token0, address _token1) external {
        token0Return = _token0;
        token1Return = _token1;
    }

    function setUnwindAmounts(uint256 _amount0, uint256 _amount1) external {
        unwindAmount0 = _amount0;
        unwindAmount1 = _amount1;
    }

    function setSupportedToken(address token, bool supported) external {
        supportedTokens[token] = supported;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function validateAndLock(address lpToken, uint256, uint256, address)
        external
        override
        returns (LPInfo memory info)
    {
        require(!shouldRevert, "MOCK_REVERT");
        lockCallCount++;
        info = LPInfo({
            lpType: _lpType,
            token0: token0Return,
            token1: token1Return,
            feeTier: 3000,
            tickLower: -887_220,
            tickUpper: 887_220,
            liquidity: 1_000_000,
            pool: lpToken
        });
    }

    function unlock(address, uint256, uint256, address) external override {
        require(!shouldRevert, "MOCK_REVERT");
        unlockCallCount++;
    }

    /// @notice Total liquidity the position has (set to match deposit amount for scaling)
    uint256 public totalLiquidity = 100e18;

    function setTotalLiquidity(uint256 _total) external {
        totalLiquidity = _total;
    }

    function unwind(address, uint256, uint128 liquidityToRemove)
        external
        override
        returns (uint256 out0, uint256 out1)
    {
        // Scale output proportionally to liquidity removed (realistic behavior)
        if (totalLiquidity > 0) {
            out0 = (unwindAmount0 * uint256(liquidityToRemove)) / totalLiquidity;
            out1 = (unwindAmount1 * uint256(liquidityToRemove)) / totalLiquidity;
        } else {
            out0 = unwindAmount0;
            out1 = unwindAmount1;
        }

        // Transfer tokens to caller
        if (out0 > 0 && token0Return != address(0)) {
            IERC20(token0Return).transfer(msg.sender, out0);
        }
        if (out1 > 0 && token1Return != address(0)) {
            IERC20(token1Return).transfer(msg.sender, out1);
        }
    }

    // Configurable fee returns for fee-only liquidation tests
    uint256 public mockFee0;
    uint256 public mockFee1;

    function setMockFees(uint256 _fee0, uint256 _fee1) external {
        mockFee0 = _fee0;
        mockFee1 = _fee1;
    }

    function collectFees(address, uint256) external override returns (uint256, uint256) {
        // Transfer fees to caller (like real adapter would)
        if (mockFee0 > 0 && token0Return != address(0)) {
            require(IERC20(token0Return).transfer(msg.sender, mockFee0), "TRANSFER_FAILED");
        }
        if (mockFee1 > 0 && token1Return != address(0)) {
            require(IERC20(token1Return).transfer(msg.sender, mockFee1), "TRANSFER_FAILED");
        }
        return (mockFee0, mockFee1);
    }

    function removeLiquidity(
        address,
        uint256,
        uint128 liquidity,
        address recipient
    )
        external
        override
        returns (uint256 out0, uint256 out1)
    {
        if (totalLiquidity > 0) {
            out0 = (unwindAmount0 * uint256(liquidity)) / totalLiquidity;
            out1 = (unwindAmount1 * uint256(liquidity)) / totalLiquidity;
        } else {
            out0 = unwindAmount0;
            out1 = unwindAmount1;
        }
        if (out0 > 0 && token0Return != address(0)) {
            require(IERC20(token0Return).transfer(recipient, out0), "TRANSFER_FAILED");
        }
        if (out1 > 0 && token1Return != address(0)) {
            require(IERC20(token1Return).transfer(recipient, out1), "TRANSFER_FAILED");
        }
    }

    function addLiquidity(
        address,
        uint256,
        address,
        address,
        uint256 amount0,
        uint256 amount1,
        address
    )
        external
        pure
        override
        returns (uint256, uint256, uint256)
    {
        return (amount0 + amount1, amount0, amount1);
    }

    // Override liquidity for V3-style tests (amount=0, liquidity from NFT)
    uint128 public mockLiquidity;
    bool public useMockLiquidity;

    function setMockLiquidity(uint128 _liq) external {
        mockLiquidity = _liq;
        useMockLiquidity = true;
    }

    function getLiquidity(address, uint256, uint256 amount) external view override returns (uint128) {
        if (useMockLiquidity) return mockLiquidity;
        require(amount <= type(uint128).max, "AMOUNT_OVERFLOW");
        return uint128(amount);
    }

    function lpType() external view override returns (LPType) {
        return _lpType;
    }

    function isSupported(address lpToken) external view override returns (bool) {
        return supportedTokens[lpToken];
    }

    // Fee-collection capability. The default reports true only for LPType.UniswapV3 — matching the
    // existing V3 fee-sweep tests so they keep passing untouched. Any other LP type (including the
    // other concentrated-liquidity NFT types) reports false unless a test opts in via
    // setSupportsFeeCollection(true); tests exercising a non-V3 fee-bearing adapter must set it
    // explicitly, which also proves the liquidation path consults the flag rather than the type.
    bool private _overrideFeeCollection;
    bool private _feeCollectionSet;

    function setSupportsFeeCollection(bool v) external {
        _overrideFeeCollection = v;
        _feeCollectionSet = true;
    }

    function supportsFeeCollection() external view override returns (bool) {
        return _feeCollectionSet ? _overrideFeeCollection : _lpType == LPType.UniswapV3;
    }

    // Holdings measure. Reports the pool's plain token balances against the configured pair, which
    // is what a real V3 adapter does; the V2 cap at reserves is a property of UniswapV2Adapter and
    // is tested there against a pair that actually keeps reserves, not against this mock.
    function poolHoldings(address pool)
        external
        view
        override
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        token0 = token0Return;
        token1 = token1Return;
        amount0 = IERC20(token0Return).balanceOf(pool);
        amount1 = IERC20(token1Return).balanceOf(pool);
    }
}

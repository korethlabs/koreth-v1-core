// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title MarketRegistry
/// @notice Track and query all active lending markets
contract MarketRegistry {
    ProtocolCore public immutable core;

    // All market IDs
    uint256[] public allMarketIds;

    // Indexes for fast lookup
    mapping(ILPAdapter.LPType => uint256[]) public marketsByLPType;
    mapping(address => uint256[]) public marketsByBorrowAsset;

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
    }

    /// @notice Register a market in the registry (called after MarketFactory creates one)
    function registerMarket(uint256 marketId, ILPAdapter.LPType lpType, address borrowAsset) external onlyPoolAdmin {
        allMarketIds.push(marketId);
        marketsByLPType[lpType].push(marketId);
        marketsByBorrowAsset[borrowAsset].push(marketId);
    }

    /// @notice Get all market IDs
    function getAllMarkets() external view returns (uint256[] memory) {
        return allMarketIds;
    }

    /// @notice Get markets for a specific LP type
    function getMarketsByLPType(ILPAdapter.LPType lpType) external view returns (uint256[] memory) {
        return marketsByLPType[lpType];
    }

    /// @notice Get markets for a specific borrow asset
    function getMarketsByBorrowAsset(address borrowAsset) external view returns (uint256[] memory) {
        return marketsByBorrowAsset[borrowAsset];
    }

    /// @notice Get total TVL across all markets
    function getTotalTVL() external view returns (uint256 totalSupply, uint256 totalBorrow) {
        for (uint256 i = 0; i < allMarketIds.length; i++) {
            address marketAddr = core.markets(allMarketIds[i]);
            IMarket.MarketState memory state = IMarket(marketAddr).getMarketState();
            totalSupply += state.totalSupply;
            totalBorrow += state.totalBorrow;
        }
    }
}

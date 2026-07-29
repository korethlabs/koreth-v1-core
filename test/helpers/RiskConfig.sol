// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskManager} from "../../src/security/RiskManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

/// @notice Shared helper for wiring RiskManager collateral configs in tests.
/// @dev Mirrors the legacy per-market defaults (65% LTV / 75% liq threshold / 5% bonus / no haircut)
///      so existing test math holds under the shared-pool model.
library RiskConfig {
    function defaultConfig() internal pure returns (RiskManager.CollateralConfig memory) {
        return RiskManager.CollateralConfig({
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            haircut: 0,
            borrowCap: type(uint256).max, // == RiskManager.NO_BORROW_CAP; 0 would block all borrowing
            enabled: true
        });
    }

    function config(
        uint256 maxLtv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 haircut,
        uint256 borrowCap,
        bool enabled
    )
        internal
        pure
        returns (RiskManager.CollateralConfig memory)
    {
        return RiskManager.CollateralConfig({
            maxLtv: maxLtv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            haircut: haircut,
            borrowCap: borrowCap,
            enabled: enabled
        });
    }
}

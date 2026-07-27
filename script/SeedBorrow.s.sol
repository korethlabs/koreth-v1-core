// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {ILendingEngine} from "../src/interfaces/ILendingEngine.sol";

/// @title SeedBorrow
/// @notice Second seeding step: each user borrows against the position it created earlier. Kept
///         separate because the borrow cooldown requires blocks to be mined after the deposit, and
///         forge simulates an entire script at a single block height.
/// @dev    Run a few blocks after SeedLocal + SeedUsers:
///           forge script script/SeedBorrow.s.sol --rpc-url http://localhost:8545 --broadcast
contract SeedBorrow is Script {
    using stdJson for string;

    function run() external {
        string memory json = vm.readFile("./deployments/local.json");
        IPositionManager positionManager = IPositionManager(json.readAddress(".positionManager"));
        ILendingEngine lendingEngine = ILendingEngine(json.readAddress(".lendingEngine"));

        // Anvil accounts #0..#3, keys derived from SEED_MNEMONIC (env, loaded from local .env —
        // never hardcode keys in tracked files). Per-user borrow (USDC 6-dec); 0 = leave as collateral.
        string memory mnemonic = vm.envString("SEED_MNEMONIC");
        uint256[4] memory keys = [
            vm.deriveKey(mnemonic, 0), vm.deriveKey(mnemonic, 1), vm.deriveKey(mnemonic, 2), vm.deriveKey(mnemonic, 3)
        ];
        uint256[4] memory amounts = [uint256(3000e6), 2000e6, 8000e6, 0];

        for (uint256 i = 0; i < keys.length; i++) {
            if (amounts[i] == 0) continue;
            address user = vm.addr(keys[i]);
            uint256[] memory ids = positionManager.getPositionsByOwner(user);
            if (ids.length == 0) continue;
            uint256 positionId = ids[ids.length - 1];

            vm.startBroadcast(keys[i]);
            lendingEngine.borrow(positionId, amounts[i]);
            vm.stopBroadcast();

            console.log("user", user);
            console.log("  borrowed", amounts[i]);
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {LendingPool} from "./LendingPool.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {RiskManager} from "../security/RiskManager.sol";

/// @title PoolFactory
/// @notice Deploys shared lending pools (one per borrow asset) as UUPS proxies, and whitelists
///         collateral types by forwarding their risk config to RiskManager.
/// @dev Formerly MarketFactory. In the unified-pool model there is one pool per borrow asset;
///      collateral risk params live in RiskManager per LPType.
contract PoolFactory {
    ProtocolCore public immutable core;

    /// @notice The LendingPool implementation contract that all proxies point to
    address public poolImplementation;

    // Pre-deployed interest rate models
    mapping(string => address) public interestRateModels;

    event PoolCreated(address indexed borrowAsset, address proxy, address implementation);
    event PoolImplementationUpdated(address oldImpl, address newImpl);
    event CollateralWhitelisted(ILPAdapter.LPType indexed lpType);

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core, address _poolImplementation) {
        core = ProtocolCore(_core);
        poolImplementation = _poolImplementation;
    }

    /// @notice Deploy a new shared lending pool as a UUPS proxy (one per borrow asset)
    /// @dev borrowAsset MUST be a standard ERC20 (USDC, USDT, DAI, WETH).
    ///      Fee-on-transfer, rebasing, and ERC-777 tokens are NOT supported.
    /// @param borrowAsset The pool's borrow asset (also the pool key in ProtocolCore.pools)
    /// @param rateModelType Key of a pre-registered interest rate model
    /// @param reserveFactorBps Reserve factor for the pool (% of interest kept by protocol)
    function createPool(
        address borrowAsset,
        string calldata rateModelType,
        uint256 reserveFactorBps
    )
        external
        onlyPoolAdmin
        returns (address poolAddr)
    {
        address rateModel = interestRateModels[rateModelType];
        require(rateModel != address(0), "INVALID_RATE_MODEL");
        require(poolImplementation != address(0), "NO_IMPLEMENTATION");
        require(borrowAsset != address(0), "ZERO_BORROW_ASSET");
        require(borrowAsset.code.length > 0, "NOT_CONTRACT");

        ILendingPool.PoolConfig memory config = ILendingPool.PoolConfig({borrowAsset: borrowAsset});

        // Deploy ERC1967 proxy pointing to the LendingPool implementation
        bytes memory initData = abi.encodeCall(LendingPool.initialize, (config, rateModel, address(core)));
        ERC1967Proxy proxy = new ERC1967Proxy(poolImplementation, initData);
        poolAddr = address(proxy);

        // Register in core keyed by borrow asset
        core.registerPool(borrowAsset, poolAddr);

        if (reserveFactorBps > 0) {
            LendingPool(poolAddr).setReserveFactor(reserveFactorBps);
        }

        emit PoolCreated(borrowAsset, poolAddr, poolImplementation);
    }

    /// @notice Whitelist a collateral (LP) type by forwarding its risk config to RiskManager.
    /// @dev Requires PoolFactory (or its caller) to have RISK_ADMIN on ACLManager, since it calls
    ///      RiskManager.setCollateralConfig. The config is the single source of truth for the
    ///      collateral's LTV/liqThreshold/liqBonus/haircut/borrowCap/enabled.
    function whitelistCollateral(
        ILPAdapter.LPType lpType,
        RiskManager.CollateralConfig calldata cfg
    )
        external
        onlyPoolAdmin
    {
        address rmAddr = core.riskManagerAddr();
        require(rmAddr != address(0), "RISK_MANAGER_NOT_SET");
        RiskManager(rmAddr).setCollateralConfig(lpType, cfg);
        emit CollateralWhitelisted(lpType);
    }

    /// @notice Update the implementation for future pool deployments
    /// @dev Does NOT upgrade existing pools — they keep their current impl
    function setPoolImplementation(address _impl) external onlyPoolAdmin {
        require(_impl != address(0), "ZERO_ADDRESS");
        // A non-contract impl would not fail here but in createPool, where the ERC1967 proxy
        // delegatecalls initialize() into empty code — every pool deployment reverts until an
        // admin notices. Screen it at the setter, like every other address setter here.
        require(_impl.code.length > 0, "NOT_CONTRACT");
        emit PoolImplementationUpdated(poolImplementation, _impl);
        poolImplementation = _impl;
    }

    function setInterestRateModel(string calldata modelType, address model) external onlyPoolAdmin {
        require(model != address(0), "ZERO_ADDRESS");
        require(model.code.length > 0, "NOT_CONTRACT");
        interestRateModels[modelType] = model;
    }
}

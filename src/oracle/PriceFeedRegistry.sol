// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @notice Chainlink AggregatorV3 minimal interface
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title PriceFeedRegistry
/// @notice Chainlink price feed registry for any token → USD price
/// @dev Used by PositionManager and LendingEngine to convert debt amounts to USD.
///      Returns prices normalized to 18 decimals.
///      Same pattern as Aave's AaveOracle: token → Chainlink feed → USD price.
///
///      Registry address consistency:
///        LP oracles (V2/V3) hold this registry as `immutable` — set once at deployment.
///        PositionManager/LiquidationEngine read from `core.priceFeedRegistryAddr()` — mutable.
///        If governance rotates the registry address on ProtocolCore, oracles still use the old one.
///        This is intentional: rotating the registry requires redeploying oracles (not upgradeable),
///        registering them via `core.registerOracle()`, and updating `core.priceFeedRegistryAddr()`
///        as a coordinated multi-step governance action.
///
///      Fail-closed design:
///        getPrice() reverts on stale/invalid feeds. This blocks deposits, borrows, and liquidations
///        for affected assets. This is intentional — pricing on bad data is worse than pausing.
///        If Chainlink is down beyond maxStaleness, emergency admin pauses the protocol.
///        Same approach as Aave V3.
contract PriceFeedRegistry {
    ProtocolCore public immutable core;

    mapping(address => address) public priceFeeds; // token → Chainlink feed
    mapping(address => uint8) public feedDecimals; // feed → cached decimals
    uint256 public maxStaleness = 3600; // 1 hour

    // --- L2 sequencer uptime (address(0) = disabled, e.g. on L1 / in tests) ---
    address public sequencerUptimeFeed;
    uint256 public sequencerGracePeriod = 3600; // 1h buffer after a sequencer restart

    // --- Optional per-token sanity bounds (0 = disabled) ---
    // Guards against a Chainlink feed pinned at its minAnswer/maxAnswer during an extreme move.
    mapping(address => uint256) public minPrice; // 18-dec USD lower bound (exclusive)
    mapping(address => uint256) public maxPrice; // 18-dec USD upper bound (exclusive)

    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MaxStalenessUpdated(uint256 oldValue, uint256 newValue);
    event SequencerUptimeFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event SequencerGracePeriodUpdated(uint256 oldValue, uint256 newValue);
    event PriceBoundsUpdated(address indexed token, uint256 minPrice, uint256 maxPrice);

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core) {
        require(_core != address(0), "ZERO_CORE");
        require(_core.code.length > 0, "NOT_CONTRACT");
        core = ProtocolCore(_core);
    }

    /// @notice Set Chainlink price feed for a token
    /// @dev Validates the feed is callable and returns sane data before registering
    function setPriceFeed(address token, address feed) external onlyPoolAdmin {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        require(feed.code.length > 0, "NOT_CONTRACT");

        // Validate feed works and has valid decimals
        uint8 dec = IAggregatorV3(feed).decimals();
        require(dec <= 36, "INVALID_FEED_DECIMALS");

        // Validate feed returns a positive price (catch misconfigured feeds early)
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "INVALID_FEED_PRICE");

        priceFeeds[token] = feed;
        feedDecimals[feed] = dec;
        emit PriceFeedUpdated(token, feed);
    }

    /// @notice Set max staleness for price feeds
    function setMaxStaleness(uint256 _maxStaleness) external onlyPoolAdmin {
        require(_maxStaleness >= 300 && _maxStaleness <= 86_400, "OUT_OF_BOUNDS");
        emit MaxStalenessUpdated(maxStaleness, _maxStaleness);
        maxStaleness = _maxStaleness;
    }

    /// @notice Set the Chainlink L2 Sequencer Uptime Feed (address(0) disables the check)
    /// @dev Required on L2s (Base/Arbitrum/Optimism). Leave unset on L1 Ethereum.
    function setSequencerUptimeFeed(address feed) external onlyPoolAdmin {
        require(feed == address(0) || feed.code.length > 0, "NOT_CONTRACT");
        emit SequencerUptimeFeedUpdated(sequencerUptimeFeed, feed);
        sequencerUptimeFeed = feed;
    }

    /// @notice Set the grace period after a sequencer restart before prices are trusted again
    function setSequencerGracePeriod(uint256 _gracePeriod) external onlyPoolAdmin {
        require(_gracePeriod >= 300 && _gracePeriod <= 86_400, "OUT_OF_BOUNDS");
        emit SequencerGracePeriodUpdated(sequencerGracePeriod, _gracePeriod);
        sequencerGracePeriod = _gracePeriod;
    }

    /// @notice Set optional 18-dec USD sanity bounds for a token (0 = disabled)
    /// @dev Set just inside the underlying aggregator's minAnswer/maxAnswer to reject a feed
    ///      pinned at its floor/ceiling during an extreme price move.
    function setPriceBounds(address token, uint256 _minPrice, uint256 _maxPrice) external onlyPoolAdmin {
        require(token != address(0), "ZERO_ADDRESS");
        require(_maxPrice == 0 || _minPrice < _maxPrice, "INVALID_BOUNDS");
        minPrice[token] = _minPrice;
        maxPrice[token] = _maxPrice;
        emit PriceBoundsUpdated(token, _minPrice, _maxPrice);
    }

    /// @notice Revert if the L2 sequencer is down or within the grace period after a restart
    function _checkSequencer() internal view {
        address seq = sequencerUptimeFeed;
        if (seq == address(0)) return; // disabled (L1 / tests)
        (, int256 up, uint256 startedAt,,) = IAggregatorV3(seq).latestRoundData();
        // up == 0 → sequencer is up; up == 1 → down
        require(up == 0, "SEQUENCER_DOWN");
        // startedAt must be a valid, non-future round (avoids underflow → panic on a bad feed)
        require(startedAt != 0 && startedAt <= block.timestamp, "SEQUENCER_INVALID_ROUND");
        require(block.timestamp - startedAt > sequencerGracePeriod, "SEQUENCER_GRACE_PERIOD");
    }

    /// @notice Get token price in USD (18 decimals)
    /// @param token Token address
    /// @return price USD price normalized to 18 decimals
    function getPrice(address token) public view returns (uint256 price) {
        _checkSequencer();

        address feed = priceFeeds[token];
        require(feed != address(0), "NO_PRICE_FEED");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "INVALID_PRICE");
        require(updatedAt > 0 && answeredInRound >= roundId, "STALE_ROUND");
        require(block.timestamp >= updatedAt && block.timestamp - updatedAt <= maxStaleness, "STALE_PRICE");

        uint8 dec = feedDecimals[feed];
        if (dec < 18) {
            price = Math.mulDiv(uint256(answer), 10 ** (18 - dec), 1);
        } else if (dec > 18) {
            price = Math.mulDiv(uint256(answer), 1, 10 ** (dec - 18));
        } else {
            price = uint256(answer);
        }

        // Optional sanity bounds: reject a feed pinned at its floor/ceiling (0 = disabled).
        uint256 lower = minPrice[token];
        uint256 upper = maxPrice[token];
        require(lower == 0 || price > lower, "PRICE_BELOW_FLOOR");
        require(upper == 0 || price < upper, "PRICE_ABOVE_CEIL");
    }

    /// @notice Convert a token amount to USD value (18 decimals)
    /// @param token Token address
    /// @param amount Token amount in native decimals
    /// @param tokenDecimals Token's decimal count (must be <= 36)
    /// @return usdValue USD value in 18 decimals
    function getUsdValue(address token, uint256 amount, uint8 tokenDecimals) external view returns (uint256 usdValue) {
        require(tokenDecimals <= 36, "INVALID_DECIMALS");
        uint256 price = getPrice(token);
        usdValue = Math.mulDiv(amount, price, 10 ** tokenDecimals);
    }
}

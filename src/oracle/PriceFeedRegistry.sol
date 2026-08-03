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
///        The borrow-side consumers (PositionManager/LendingEngine/LiquidationEngine) resolve it
///        per call through `core.getPriceFeedRegistry()` — mutable.
///        If governance rotates the registry on ProtocolCore, oracles still use the old one.
///        This is intentional: rotating the registry requires redeploying oracles (not upgradeable),
///        registering them via `core.registerOracle()`, and calling `core.setPriceFeedRegistry()`
///        as a coordinated multi-step governance action. Note the new registry must already price
///        every listed borrow asset, since the borrow side fails closed rather than assuming.
///
///      Fail-closed design:
///        getPrice() reverts on stale/invalid feeds, and on tokens with no price source at all.
///        This blocks deposits, borrows, and liquidations for affected assets. This is intentional
///        — pricing on bad data is worse than pausing. If Chainlink is down beyond maxStaleness,
///        emergency admin pauses the protocol. Same approach as Aave V3.
///
///        An asset with no feed can still be priced, but only by an explicit per-token declaration
///        (setPeggedPrice). That is the one sanctioned way to assert a price, and it is deliberately
///        narrow: the protocol must never derive a price for an asset nobody vouched for.
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

    /// @notice Declared 18-dec USD price for assets priced by assertion rather than by feed (0 = none).
    /// @dev Only consulted when a token has no feed. This exists so that "USDC is worth $1" is a
    ///      statement governance made on-chain, with an event and a revocation, instead of the
    ///      silent consequence of a pointer nobody set. Prefer a feed wherever one exists: a peg
    ///      cannot observe a depeg, which is precisely when the assumption stops holding.
    mapping(address => uint256) public peggedPrice;

    event PriceFeedUpdated(address indexed token, address indexed feed);
    event PeggedPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
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

    /// @notice Declare a fixed 18-dec USD price for a token that has no Chainlink feed (0 = clear).
    /// @dev For assets the protocol prices by assertion — a stablecoin on a chain with no feed, or
    ///      a test deployment. It is deliberately a per-token, evented, revocable declaration and
    ///      not a global fallback: the protocol should never be able to invent a price for an asset
    ///      nobody vouched for. A feed always wins over a peg, so declaring one cannot mask a feed.
    function setPeggedPrice(address token, uint256 priceE18) external onlyPoolAdmin {
        require(token != address(0), "ZERO_ADDRESS");
        emit PeggedPriceUpdated(token, peggedPrice[token], priceE18);
        peggedPrice[token] = priceE18;
    }

    /// @notice Whether the protocol can price this token at all.
    /// @dev Existence, not health — a feed that is currently stale still counts. Callers that gate
    ///      configuration (ProtocolCore.registerPool) need to know a price source was configured;
    ///      callers that gate money movement go through getPrice(), which additionally reverts on
    ///      stale or out-of-bounds data. Conflating the two would make listing a market fail
    ///      whenever a feed happened to be lagging.
    function isPriceable(address token) external view returns (bool) {
        return priceFeeds[token] != address(0) || peggedPrice[token] > 0;
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
        if (feed == address(0)) {
            // No feed: the only remaining source is a price governance declared for this specific
            // token. Absent that, refuse — an unpriceable asset must stop the caller, never fall
            // back to an assumed value. The sanity bounds below are deliberately not applied: they
            // exist to catch an aggregator pinned at its floor/ceiling, and a declared constant has
            // no aggregator to pin.
            price = peggedPrice[token];
            require(price > 0, "NO_PRICE_FEED");
            return price;
        }

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

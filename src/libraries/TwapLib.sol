// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TwapLib
/// @notice Uniswap's tick-accumulator oracle cut down to what Surety needs.
/// @dev The accumulator is exact: `cumAtLast` is updated on every swap with the tick that was held since the
///      previous swap. A ring buffer stores at most one observation per `MIN_INTERVAL` seconds, which is enough
///      for short-window TWAPs (setRange guardrail, settlement deviation guard, M5 breaker). Epoch-long TWAPs
///      never need the ring: the hook snapshots the cumulative at each epoch start.
library TwapLib {
    uint16 internal constant CARDINALITY = 128;
    uint32 internal constant MIN_INTERVAL = 12;

    error NotInitialized();
    error FutureTime();

    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    struct State {
        uint32 lastTs; // time the current `lastTick` started being held
        int24 lastTick; // tick after the most recent swap
        int56 cumAtLast; // tick cumulative at `lastTs`
        uint16 index; // slot of the newest stored observation
        uint16 count; // number of populated slots
        Observation[128] obs;
    }

    function initialize(State storage s, int24 tick) internal {
        uint32 t = uint32(block.timestamp);
        s.lastTs = t;
        s.lastTick = tick;
        s.cumAtLast = 0;
        s.obs[0] = Observation(t, 0);
        s.index = 0;
        s.count = 1;
    }

    /// @notice Record the tick that holds from now on. Call after every swap.
    function update(State storage s, int24 newTick) internal {
        uint32 t = uint32(block.timestamp);
        if (t != s.lastTs) {
            s.cumAtLast += int56(s.lastTick) * int56(uint56(t - s.lastTs));
            s.lastTs = t;
            Observation memory newest = s.obs[s.index];
            if (t - newest.timestamp >= MIN_INTERVAL) {
                uint16 next = uint16((uint256(s.index) + 1) % CARDINALITY);
                s.obs[next] = Observation(t, s.cumAtLast);
                s.index = next;
                if (s.count < CARDINALITY) s.count++;
            }
        }
        s.lastTick = newTick;
    }

    /// @notice Tick cumulative at time `t` (must be <= now). Exact for t >= lastTs, interpolated before that.
    function cumulativeAt(State storage s, uint32 t) internal view returns (int56) {
        if (s.count == 0) revert NotInitialized();
        if (t > block.timestamp) revert FutureTime();
        if (t >= s.lastTs) return s.cumAtLast + int56(s.lastTick) * int56(uint56(t - s.lastTs));

        // Bracket t between two observations (or the newest observation and the live point).
        uint16 oldestIdx = s.count < CARDINALITY ? 0 : uint16((uint256(s.index) + 1) % CARDINALITY);
        Observation memory oldest = s.obs[oldestIdx];
        if (t <= oldest.timestamp) return oldest.tickCumulative;

        Observation memory newest = s.obs[s.index];
        if (t >= newest.timestamp) {
            return _interpolate(newest.timestamp, newest.tickCumulative, s.lastTs, s.cumAtLast, t);
        }

        // Binary search in logical order [0, count-1], where logical i maps to (oldestIdx + i) % CARDINALITY.
        uint256 lo = 0;
        uint256 hi = uint256(s.count) - 1;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            Observation memory o = s.obs[(oldestIdx + mid) % CARDINALITY];
            if (o.timestamp <= t) lo = mid;
            else hi = mid;
        }
        Observation memory a = s.obs[(oldestIdx + lo) % CARDINALITY];
        Observation memory b = s.obs[(oldestIdx + hi) % CARDINALITY];
        return _interpolate(a.timestamp, a.tickCumulative, b.timestamp, b.tickCumulative, t);
    }

    /// @notice Arithmetic-mean tick over the last `window` seconds, clamped to the oldest stored observation.
    function meanTick(State storage s, uint32 window) internal view returns (int24) {
        uint32 end = uint32(block.timestamp);
        uint16 oldestIdx = s.count < CARDINALITY ? 0 : uint16((uint256(s.index) + 1) % CARDINALITY);
        uint32 oldestTs = s.obs[oldestIdx].timestamp;
        uint32 start = end > window ? end - window : 0;
        if (start < oldestTs) start = oldestTs;
        if (start >= end) return s.lastTick;
        return meanTickBetween(cumulativeAt(s, start), cumulativeAt(s, end), end - start);
    }

    /// @notice Mean tick from two cumulatives, rounded towards negative infinity like Uniswap v3.
    function meanTickBetween(int56 cumStart, int56 cumEnd, uint32 dt) internal pure returns (int24 tick) {
        if (dt == 0) revert FutureTime();
        int56 delta = cumEnd - cumStart;
        tick = int24(delta / int56(uint56(dt)));
        if (delta < 0 && (delta % int56(uint56(dt)) != 0)) tick--;
    }

    function _interpolate(uint32 ta, int56 ca, uint32 tb, int56 cb, uint32 t) private pure returns (int56) {
        if (tb == ta) return ca;
        return ca + ((cb - ca) * int56(uint56(t - ta))) / int56(uint56(tb - ta));
    }
}

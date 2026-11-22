// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {SuretyShares} from "./SuretyShares.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {TwapLib} from "./libraries/TwapLib.sol";
import {ScoreLib} from "./libraries/ScoreLib.sol";
import {SuretyMath} from "./libraries/SuretyMath.sol";

/// @title SuretyHook
/// @notice A Uniswap v4 hook that owns all of one pool's liquidity and lets bonded curators manage slices of it.
///         Each epoch, every curator is scored against a passive full-range position of the same starting value.
///         Underperformance is repaid to depositors from the curator's bond; outperformance earns a fee.
/// @dev Enforcement (scoring, slashing, fees) is pure bookkeeping and runs inside the first swap after an epoch
///      ends. Reallocation moves liquidity and runs from `settle()`. Settlement never swaps.
contract SuretyHook is BaseHook, IUnlockCallback, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using TwapLib for TwapLib.State;
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    struct Config {
        uint32 epochLength; // seconds
        uint16 perfFeeBps; // φ: share of positive excess paid to the curator, as vault shares
        uint16 reallocBps; // δ: share of the worst curator's capital moved to the best each epoch
        uint16 bondMultiple; // k: a slice's capital is capped at k × bond
        uint16 settleRewardBps; // share of each slash set aside to reward settle() callers
        int24 minWidth; // W_min: minimum range width in ticks
        int24 maxDistance; // D: max distance of a range's centre from the TWAP tick
        uint8 maxRebalances; // R: setRange calls per curator per epoch
        uint32 shortTwapWindow; // window for the setRange guardrail and the settlement deviation guard
        int24 maxSpotDeviation; // max |spot tick - short TWAP tick| allowed when the hook moves liquidity
        uint16 breakerBps; // X: freeze a slice once it is this far below its benchmark mid-epoch
        uint32 breakerInterval; // run the breaker check at most once per this many seconds
        uint16 anchorBps; // share of depositor capital always kept in the hook's own full-range position
        uint256 minBond; // in token1
        uint256 maxSettleReward; // in token1, per settle() call
    }

    struct Curator {
        address owner;
        bool active; // holds a slice
        bool exiting;
        bool frozen; // liquidity pulled by the breaker this epoch
        bool needsRearm; // was frozen; gets no capital until it calls setRange again
        int24 tickLower;
        int24 tickUpper;
        uint8 rebalances;
        uint64 rebalanceEpoch;
        uint64 exitEpoch;
        uint128 liquidity;
        uint256 bond; // token1, held as ERC-6909 claims
        uint256 idle0; // slice tokens not in the range, held as ERC-6909 claims
        uint256 idle1;
        uint256 v0; // slice value at the epoch's mark price, adjusted for capital moved in or out
        int256 lastExcess;
        uint256 fg0Freeze; // pool fee growth when frozen: the benchmark stops earning fees here
        uint256 fg1Freeze;
    }

    /// @dev Deposits and withdrawals queue into a batch that is closed at an epoch boundary and processed by settle().
    struct Batch {
        uint256 dep0;
        uint256 dep1;
        uint256 withdrawShares;
        uint160 sqrtPrice; // short-TWAP price the batch was processed at
        uint256 sharesMinted;
        uint256 out0;
        uint256 out1;
        bool processed;
    }

    struct Request {
        uint256 dep0;
        uint256 dep1;
        uint256 withdrawShares;
    }

    enum Op {
        Realloc,
        Bond,
        Unbond,
        SetRange
    }

    // ------------------------------------------------------------------
    // Constants and storage
    // ------------------------------------------------------------------

    uint8 public constant MAX_CURATORS = 3;
    uint8 internal constant NONE = type(uint8).max;
    uint256 internal constant BPS = 10_000;
    /// @dev Capital only shifts when the gap in excess return exceeds 1 part per million, so rounding dust can't move it.
    int256 internal constant SHIFT_THRESHOLD = 1e12;

    Config internal config;
    SuretyShares public immutable shares;

    PoolKey public poolKey;
    bool public poolBound;

    TwapLib.State internal twap;

    Curator[3] internal curators;

    // Epoch state
    uint64 public epochId;
    uint32 public epochStart;
    uint32 public epochEnd;
    int56 internal epochStartCum;
    uint160 public markSqrtPrice; // P0: the epoch-long TWAP of the previous epoch
    uint256 internal fg0Start;
    uint256 internal fg1Start;
    bool public reallocPending;
    uint8 internal shiftFrom = NONE;
    uint8 internal shiftTo = NONE;
    uint32 public lastBreakerCheck;

    // Vault balances (ERC-6909 claims held by the hook)
    uint256 public reserve0; // depositor capital not allocated to any slice, incl. slashed bonds
    uint256 public reserve1;
    uint256 public rewardPool; // token1 set aside for settle() callers
    /// @dev Depositor capital the hook holds full range itself (salt 3). It is never frozen, so the pool is never empty
    ///      and moving the price always costs real money, which makes a fake price impossible to hold for free.
    uint128 public anchorLiquidity;

    // Queues
    uint256 public openBatch = 1;
    uint256 public closedBatch; // 0 = none waiting
    mapping(uint256 => Batch) internal batches;
    mapping(uint256 => mapping(address => Request)) public requests;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    event EpochSettled(uint64 indexed epochId, uint160 markSqrtPrice, uint256 nav);
    event CuratorScored(uint64 indexed epochId, address indexed curator, uint256 v0, uint256 v1, uint256 benchmark);
    event CuratorSlashed(uint64 indexed epochId, address indexed curator, uint256 amount);
    event PerformanceFeePaid(uint64 indexed epochId, address indexed curator, uint256 value, uint256 shares);
    event CuratorFrozen(uint64 indexed epochId, address indexed curator);
    event Reallocated(uint64 indexed epochId, address indexed from, address indexed to, uint256 value);
    event RangeSet(address indexed curator, int24 tickLower, int24 tickUpper);
    event CuratorRegistered(address indexed curator, uint256 bond);
    event CuratorExited(address indexed curator, uint64 unlockEpoch);
    event BatchProcessed(uint256 indexed batchId, uint256 sharesMinted, uint256 sharesBurned, uint256 out0, uint256 out1);
    event Deposited(address indexed user, uint256 indexed batchId, uint256 amount0, uint256 amount1);
    event WithdrawRequested(address indexed user, uint256 indexed batchId, uint256 shares);
    event SettleRewardPaid(address indexed caller, uint256 amount);

    error PoolAlreadyBound();
    error PoolNotBound();
    error LiquidityOnlyThroughVault();
    error NothingToSettle();
    error ZeroAmount();
    error CuratorLimit();
    error AlreadyCurator();
    error NotCurator();
    error BondTooSmall();
    error InvalidRange();
    error RangeTooFar();
    error TooManyRebalances();
    error SpotDeviation();
    error BondLocked();
    error BatchNotProcessed();
    error CuratorFrozenErr();

    // ------------------------------------------------------------------
    // Construction and hook permissions
    // ------------------------------------------------------------------

    constructor(IPoolManager _poolManager, Config memory _config)
        BaseHook(_poolManager)

    {
        config = _config;
        shares = new SuretyShares();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        if (poolBound) revert PoolAlreadyBound();
        if (address(key.hooks) != address(this)) revert InvalidPool();
        poolBound = true;
        poolKey = key;

        twap.initialize(SuretyMath.tickAtSqrt(sqrtPriceX96));
        epochId = 1;
        epochStart = uint32(block.timestamp);
        epochEnd = uint32(block.timestamp) + config.epochLength;
        epochStartCum = 0;
        markSqrtPrice = sqrtPriceX96;
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev All liquidity goes through the vault. The hook's own modifyLiquidity calls skip this callback.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityOnlyThroughVault();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityOnlyThroughVault();
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _enforceIfDue();
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        (, int24 tick,,) = poolManager.getSlot0(_poolId());
        twap.update(tick);
        // Throttled: the short TWAP barely moves within a few seconds, so most swaps skip the check entirely.
        if (block.timestamp >= uint256(lastBreakerCheck) + config.breakerInterval) {
            lastBreakerCheck = uint32(block.timestamp);
            _checkBreaker();
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------
    // Drawdown breaker: freeze, never slash
    // ------------------------------------------------------------------

    /// @dev Mid-epoch check of each live slice against its benchmark, both marked at the short TWAP (never spot).
    ///      A slice more than X below is pulled out of the pool and parked idle until settlement. Nothing is slashed
    ///      here, because mid-epoch prices can be pushed around. The slash comes at settlement, at the epoch-long TWAP.
    ///      Runs inside afterSwap, where the PoolManager is already unlocked, so liquidity can be removed directly.
    function _checkBreaker() internal {
        uint160 sqrtNow = SuretyMath.sqrtAtTick(twap.meanTick(config.shortTwapWindow));
        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(_poolId());
        bool froze;
        for (uint8 i; i < MAX_CURATORS; i++) {
            Curator storage c = curators[i];
            if (!c.active || c.frozen || c.liquidity == 0 || c.v0 == 0) continue;
            (uint256 v, uint256 b) = _liveScore(i, sqrtNow, fg0, fg1);
            if (v * BPS >= b * (BPS - config.breakerBps)) continue;
            _withdrawToIdle(i, c.liquidity);
            c.frozen = true;
            c.fg0Freeze = fg0;
            c.fg1Freeze = fg1;
            froze = true;
            emit CuratorFrozen(epochId, c.owner);
        }
        if (froze) _settleDeltas();
    }

    /// @dev Slice value and benchmark so far this epoch, both at `sqrtNow`.
    function _liveScore(uint8 i, uint160 sqrtNow, uint256 fg0, uint256 fg1)
        internal
        view
        returns (uint256 v, uint256 b)
    {
        v = _sliceValue(i, sqrtNow);
        uint256 dg0;
        uint256 dg1;
        unchecked {
            dg0 = fg0 - fg0Start;
            dg1 = fg1 - fg1Start;
        }
        b = SuretyMath.benchmark(curators[i].v0, markSqrtPrice, sqrtNow, dg0, dg1);
    }

    // ------------------------------------------------------------------
    // Depositors
    // ------------------------------------------------------------------

    /// @notice Queue a deposit of both tokens. It is priced and turned into shares at the next epoch boundary.
    function deposit(uint256 amount0, uint256 amount1) external nonReentrant {
        if (!poolBound) revert PoolNotBound();
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        uint256 id = openBatch;
        Batch storage b = batches[id];
        Request storage r = requests[id][msg.sender];
        b.dep0 += amount0;
        b.dep1 += amount1;
        r.dep0 += amount0;
        r.dep1 += amount1;
        if (amount0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        emit Deposited(msg.sender, id, amount0, amount1);
    }

    /// @notice Queue a withdrawal. Paid out in kind, pro rata from every slice, at the next epoch boundary.
    function requestWithdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 id = openBatch;
        batches[id].withdrawShares += amount;
        requests[id][msg.sender].withdrawShares += amount;
        shares.move(msg.sender, address(this), amount);
        emit WithdrawRequested(msg.sender, id, amount);
    }

    /// @notice Claim the shares and tokens owed from a processed batch.
    function claim(uint256 batchId) external nonReentrant returns (uint256 sharesOut, uint256 out0, uint256 out1) {
        Batch storage b = batches[batchId];
        if (!b.processed) revert BatchNotProcessed();
        Request memory r = requests[batchId][msg.sender];
        delete requests[batchId][msg.sender];

        if (r.dep0 > 0 || r.dep1 > 0) {
            uint256 batchValue = ScoreLib.value(b.dep0, b.dep1, b.sqrtPrice);
            uint256 userValue = ScoreLib.value(r.dep0, r.dep1, b.sqrtPrice);
            if (batchValue > 0) sharesOut = FullMath.mulDiv(b.sharesMinted, userValue, batchValue);
            if (sharesOut > 0) shares.move(address(this), msg.sender, sharesOut);
        }
        if (r.withdrawShares > 0) {
            out0 = FullMath.mulDiv(b.out0, r.withdrawShares, b.withdrawShares);
            out1 = FullMath.mulDiv(b.out1, r.withdrawShares, b.withdrawShares);
            if (out0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(msg.sender, out0);
            if (out1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(msg.sender, out1);
        }
    }

    // ------------------------------------------------------------------
    // Curators
    // ------------------------------------------------------------------

    /// @notice Register as a curator by posting a bond in token1. The slice starts at the next reallocation.
    function registerCurator(uint256 bond) external nonReentrant {
        if (!poolBound) revert PoolNotBound();
        if (bond < config.minBond) revert BondTooSmall();
        if (_curatorIndex(msg.sender) != NONE) revert AlreadyCurator();
        uint8 slot = NONE;
        for (uint8 i; i < MAX_CURATORS; i++) {
            if (curators[i].owner == address(0)) {
                slot = i;
                break;
            }
        }
        if (slot == NONE) revert CuratorLimit();
        Curator storage c = curators[slot];
        c.owner = msg.sender;
        c.bond = bond;
        poolManager.unlock(abi.encode(Op.Bond, abi.encode(msg.sender, bond)));
        emit CuratorRegistered(msg.sender, bond);
    }

    function topUpBond(uint256 amount) external nonReentrant {
        uint8 i = _requireCurator(msg.sender);
        if (amount == 0) revert ZeroAmount();
        curators[i].bond += amount;
        poolManager.unlock(abi.encode(Op.Bond, abi.encode(msg.sender, amount)));
    }

    /// @notice Set the range for the caller's slice. Liquidity-only: the slice is pulled and re-added, never swapped.
    function setRange(int24 tickLower, int24 tickUpper) external nonReentrant {
        uint8 i = _requireCurator(msg.sender);
        Curator storage c = curators[i];
        if (c.frozen) revert CuratorFrozenErr();
        _checkRange(tickLower, tickUpper);
        // A curator frozen last epoch re-arms by choosing a fresh range. It rejoins at the next reallocation.
        c.needsRearm = false;

        if (c.rebalanceEpoch != epochId) {
            c.rebalanceEpoch = epochId;
            c.rebalances = 0;
        }
        if (c.rebalances >= config.maxRebalances) revert TooManyRebalances();
        c.rebalances++;

        if (c.liquidity > 0 || c.idle0 > 0 || c.idle1 > 0) {
            poolManager.unlock(abi.encode(Op.SetRange, abi.encode(i, tickLower, tickUpper)));
        } else {
            c.tickLower = tickLower;
            c.tickUpper = tickUpper;
        }
        emit RangeSet(msg.sender, tickLower, tickUpper);
    }

    /// @notice Leave. The slice is scored for the current epoch, returned at the next reallocation, and the bond
    ///         unlocks one full epoch after that.
    function exitCurator() external {
        uint8 i = _requireCurator(msg.sender);
        Curator storage c = curators[i];
        if (!c.exiting) {
            c.exiting = true;
            c.exitEpoch = epochId;
            emit CuratorExited(msg.sender, epochId + 2);
        }
    }

    function claimBond() external nonReentrant {
        uint8 i = _requireCurator(msg.sender);
        Curator storage c = curators[i];
        if (!c.exiting || c.active || epochId < c.exitEpoch + 2) revert BondLocked();
        uint256 amount = c.bond;
        delete curators[i];
        poolManager.unlock(abi.encode(Op.Unbond, abi.encode(msg.sender, amount)));
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    /// @notice Enforce the ended epoch if no swap has yet, then reallocate. Pays the caller from slashed bonds.
    function settle() external nonReentrant {
        if (!poolBound) revert PoolNotBound();
        bool did = _enforceIfDue();
        if (reallocPending) {
            poolManager.unlock(abi.encode(Op.Realloc, abi.encode(msg.sender)));
            did = true;
        }
        if (!did) revert NothingToSettle();
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Op op, bytes memory args) = abi.decode(data, (Op, bytes));
        Currency c1 = poolKey.currency1;
        if (op == Op.Realloc) {
            _reallocate(abi.decode(args, (address)));
        } else if (op == Op.Bond) {
            (address payer, uint256 amount) = abi.decode(args, (address, uint256));
            c1.settle(poolManager, payer, amount, false);
        } else if (op == Op.Unbond) {
            (address to, uint256 amount) = abi.decode(args, (address, uint256));
            c1.take(poolManager, to, amount, false);
        } else {
            (uint8 i, int24 tl, int24 tu) = abi.decode(args, (uint8, int24, int24));
            _checkSpot();
            Curator storage c = curators[i];
            if (c.liquidity > 0) _withdrawToIdle(i, c.liquidity);
            c.tickLower = tl;
            c.tickUpper = tu;
            if (c.active) _deploy(i);
        }
        _settleDeltas();
        return "";
    }

    /// @dev Scoring, slashing and fees. Bookkeeping only, so it is cheap enough to run inside a swap.
    function _enforceIfDue() internal returns (bool) {
        if (block.timestamp < epochEnd) return false;
        uint64 id = epochId;

        // P1: the epoch-long TWAP, from the accumulator snapshot at epoch start to the scheduled epoch end.
        uint160 sqrtP1;
        {
            int56 cumEnd = twap.cumulativeAt(epochEnd);
            int24 tick1 = TwapLib.meanTickBetween(epochStartCum, cumEnd, epochEnd - epochStart);
            sqrtP1 = SuretyMath.sqrtAtTick(tick1);
        }
        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(_poolId());
        uint256 dg0;
        uint256 dg1;
        unchecked {
            dg0 = fg0 - fg0Start;
            dg1 = fg1 - fg1Start;
        }

        int256[3] memory ratio;
        uint256[3] memory perfFee;
        uint256 totalPerfFee;
        for (uint8 i; i < MAX_CURATORS; i++) {
            Curator storage c = curators[i];
            if (!c.active || c.v0 == 0) {
                ratio[i] = type(int256).min;
                continue;
            }
            uint256 v1 = _sliceValue(i, sqrtP1);
            uint256 b;
            if (c.frozen) {
                // The benchmark stops earning fees at the freeze, so a wrongful freeze costs the curator only fees it
                // missed, never a slash. The price move is still marked over the whole epoch.
                uint256 g0;
                uint256 g1;
                unchecked {
                    g0 = c.fg0Freeze - fg0Start;
                    g1 = c.fg1Freeze - fg1Start;
                }
                b = SuretyMath.benchmark(c.v0, markSqrtPrice, sqrtP1, g0, g1);
            } else {
                b = SuretyMath.benchmark(c.v0, markSqrtPrice, sqrtP1, dg0, dg1);
            }
            int256 e = int256(v1) - int256(b);
            c.lastExcess = e;
            ratio[i] = (e * 1e18) / int256(c.v0);
            emit CuratorScored(id, c.owner, c.v0, v1, b);

            if (e < 0) {
                uint256 slash = uint256(-e);
                if (slash > c.bond) slash = c.bond;
                if (slash > 0) {
                    c.bond -= slash;
                    uint256 reward = (slash * config.settleRewardBps) / BPS;
                    rewardPool += reward;
                    reserve1 += slash - reward;
                    emit CuratorSlashed(id, c.owner, slash);
                }
            } else if (e > 0) {
                perfFee[i] = (uint256(e) * config.perfFeeBps) / BPS;
                totalPerfFee += perfFee[i];
            }
            c.v0 = v1; // next epoch's starting value, at the new mark price

            if (c.frozen) {
                // The frozen slice is already idle, so returning it to depositors is bookkeeping only. The curator gets
                // no capital until it re-arms with setRange.
                reserve0 += c.idle0;
                reserve1 += c.idle1;
                c.idle0 = 0;
                c.idle1 = 0;
                c.v0 = 0;
                c.active = false;
                c.frozen = false;
                c.needsRearm = true;
            }
        }

        uint256 nav = _nav(sqrtP1);
        _pickShift(ratio);

        // Close the queue so the next settle() prices it at the new mark, and open the next epoch.
        if (closedBatch == 0) {
            Batch storage ob = batches[openBatch];
            if (ob.dep0 > 0 || ob.dep1 > 0 || ob.withdrawShares > 0) {
                closedBatch = openBatch;
                openBatch++;
            }
        }
        epochStartCum = twap.cumulativeAt(uint32(block.timestamp));
        epochStart = uint32(block.timestamp);
        epochEnd = uint32(block.timestamp) + config.epochLength;
        markSqrtPrice = sqrtP1;
        fg0Start = fg0;
        fg1Start = fg1;
        epochId = id + 1;
        reallocPending = true;
        // Last: the only external call in enforcement (minting fee shares) comes after every state write.
        _payPerformanceFees(id, perfFee, totalPerfFee, nav);
        emit EpochSettled(id, sqrtP1, nav);
        return true;
    }

    function _payPerformanceFees(uint64 id, uint256[3] memory perfFee, uint256 totalPerfFee, uint256 nav) internal {
        uint256 supply = shares.totalSupply();
        if (totalPerfFee == 0 || supply == 0 || nav <= totalPerfFee) return;
        // Mint shares worth exactly the fees: T / (S + T) = fee / nav.
        uint256 totalShares = FullMath.mulDiv(totalPerfFee, supply, nav - totalPerfFee);
        for (uint8 i; i < MAX_CURATORS; i++) {
            if (perfFee[i] == 0) continue;
            uint256 s = FullMath.mulDiv(totalShares, perfFee[i], totalPerfFee);
            if (s > 0) shares.mint(curators[i].owner, s);
            emit PerformanceFeePaid(id, curators[i].owner, perfFee[i], s);
        }
    }

    function _pickShift(int256[3] memory ratio) internal {
        uint8 best = NONE;
        uint8 worst = NONE;
        for (uint8 i; i < MAX_CURATORS; i++) {
            if (ratio[i] == type(int256).min) continue;
            if (best == NONE || ratio[i] > ratio[best]) best = i;
            if (worst == NONE || ratio[i] < ratio[worst]) worst = i;
        }
        if (best != worst && worst != NONE && ratio[worst] < 0 && ratio[best] - ratio[worst] > SHIFT_THRESHOLD) {
            shiftFrom = worst;
            shiftTo = best;
        } else {
            shiftFrom = NONE;
            shiftTo = NONE;
        }
    }

    /// @dev Moves liquidity. Runs inside unlock. Never swaps; leftovers stay idle as ERC-6909 claims.
    function _reallocate(address caller) internal {
        _checkSpot();
        uint160 mark = markSqrtPrice;
        uint64 id = epochId;

        // 0. Pull the anchor into the reserve; everything below is then plain reserve bookkeeping.
        if (anchorLiquidity > 0) {
            (int128 a0, int128 a1) = _modifyAnchor(-int256(uint256(anchorLiquidity)));
            reserve0 += uint128(a0);
            reserve1 += uint128(a1);
        }

        // 1. Exits: slices of curators who asked to leave in an already-scored epoch return to the reserve.
        for (uint8 i; i < MAX_CURATORS; i++) {
            Curator storage c = curators[i];
            if (c.active && c.exiting && c.exitEpoch < id) {
                (uint256 o0, uint256 o1) = _removeFraction(i, 1, 1);
                reserve0 += o0;
                reserve1 += o1;
                c.v0 = 0;
                c.active = false;
            } else if (
                !c.active && c.owner != address(0) && !c.exiting && !c.needsRearm && c.tickUpper > c.tickLower
            ) {
                c.active = true; // newly registered curators join here
            }
        }

        // 2. Queued withdrawals, then deposits.
        if (closedBatch != 0) _processBatch(closedBatch);

        // 3. Performance shift: δ of the worst curator's capital goes to the best.
        if (shiftFrom != NONE && curators[shiftFrom].active && curators[shiftTo].active) {
            Curator storage from = curators[shiftFrom];
            Curator storage to = curators[shiftTo];
            (uint256 o0, uint256 o1) = _removeFraction(shiftFrom, config.reallocBps, BPS);
            from.v0 -= FullMath.mulDiv(from.v0, config.reallocBps, BPS);
            to.idle0 += o0;
            to.idle1 += o1;
            uint256 moved = ScoreLib.value(o0, o1, mark);
            to.v0 += moved;
            emit Reallocated(id - 1, from.owner, to.owner, moved);
        }
        shiftFrom = NONE;
        shiftTo = NONE;

        // 4. Cap every slice at k × bond.
        for (uint8 i; i < MAX_CURATORS; i++) {
            Curator storage c = curators[i];
            if (!c.active) continue;
            uint256 val = _sliceValue(i, mark);
            uint256 cap = c.bond * config.bondMultiple;
            if (val > cap) {
                (uint256 o0, uint256 o1) = _removeFraction(i, val - cap, val);
                c.v0 -= FullMath.mulDiv(c.v0, val - cap, val);
                reserve0 += o0;
                reserve1 += o1;
            }
        }

        // 5. Hand the reserve out equally to active curators, within each one's cap headroom.
        _distributeReserve(mark);

        // 6. Put idle tokens to work in each range, and everything left in the reserve back into full range.
        for (uint8 i; i < MAX_CURATORS; i++) {
            if (curators[i].active) _deploy(i);
        }
        _deployAnchor();

        // 7. Reward the caller from slashed bonds.
        uint256 reward = rewardPool < config.maxSettleReward ? rewardPool : config.maxSettleReward;
        if (reward > 0 && caller != address(0)) {
            rewardPool -= reward;
            poolKey.currency1.take(poolManager, caller, reward, false);
            emit SettleRewardPaid(caller, reward);
        }
        reallocPending = false;
    }

    function _processBatch(uint256 id) internal {
        Batch storage b = batches[id];

        // Withdrawals: in kind and pro rata from every slice and the reserve, so no price is needed.
        uint256 burned = b.withdrawShares;
        if (burned > 0) {
            uint256 supply = shares.totalSupply();
            uint256 out0 = FullMath.mulDiv(reserve0, burned, supply);
            uint256 out1 = FullMath.mulDiv(reserve1, burned, supply);
            reserve0 -= out0;
            reserve1 -= out1;
            for (uint8 i; i < MAX_CURATORS; i++) {
                Curator storage c = curators[i];
                if (!c.active) continue;
                (uint256 o0, uint256 o1) = _removeFraction(i, burned, supply);
                c.v0 -= FullMath.mulDiv(c.v0, burned, supply);
                out0 += o0;
                out1 += o1;
            }
            b.out0 = out0;
            b.out1 = out1;
            shares.burn(address(this), burned);
            poolKey.currency0.take(poolManager, address(this), out0, false);
            poolKey.currency1.take(poolManager, address(this), out1, false);
        }

        // Deposits: priced at the short TWAP now, not at the epoch mark. The mark is the average of an epoch that
        // has ended, so after a trend it can overvalue one token, and a one-sided deposit of that token would dilute
        // everyone else. settle() already requires spot to be near the short TWAP. Rounded down.
        uint256 minted;
        uint160 px = SuretyMath.sqrtAtTick(twap.meanTick(config.shortTwapWindow));
        if (b.dep0 > 0 || b.dep1 > 0) {
            uint256 depValue = ScoreLib.value(b.dep0, b.dep1, px);
            uint256 supply = shares.totalSupply();
            uint256 nav = _nav(px);
            minted = (supply == 0 || nav == 0) ? depValue : FullMath.mulDiv(depValue, supply, nav);
            poolKey.currency0.settle(poolManager, address(this), b.dep0, false);
            poolKey.currency1.settle(poolManager, address(this), b.dep1, false);
            reserve0 += b.dep0;
            reserve1 += b.dep1;
            if (minted > 0) shares.mint(address(this), minted);
        }
        b.sharesMinted = minted;
        b.sqrtPrice = px;
        b.processed = true;
        closedBatch = 0;
        emit BatchProcessed(id, minted, burned, b.out0, b.out1);
    }

    function _distributeReserve(uint160 mark) internal {
        uint256 n;
        for (uint8 i; i < MAX_CURATORS; i++) {
            if (curators[i].active) n++;
        }
        if (n == 0) return;
        // Only what's above the anchor's share of NAV goes to curators.
        uint256 rv = ScoreLib.value(reserve0, reserve1, mark);
        uint256 target = FullMath.mulDiv(_nav(mark), config.anchorBps, BPS);
        if (rv <= target) return;
        uint256 share0 = FullMath.mulDiv(reserve0, rv - target, rv * n);
        uint256 share1 = FullMath.mulDiv(reserve1, rv - target, rv * n);
        uint256 shareValue = ScoreLib.value(share0, share1, mark);
        if (shareValue == 0) return;
        for (uint8 i; i < MAX_CURATORS; i++) {
            Curator storage c = curators[i];
            if (!c.active) continue;
            uint256 cap = c.bond * config.bondMultiple;
            uint256 val = _sliceValue(i, mark);
            if (val >= cap) continue;
            uint256 a0 = share0;
            uint256 a1 = share1;
            if (shareValue > cap - val) {
                a0 = FullMath.mulDiv(share0, cap - val, shareValue);
                a1 = FullMath.mulDiv(share1, cap - val, shareValue);
            }
            reserve0 -= a0;
            reserve1 -= a1;
            c.idle0 += a0;
            c.idle1 += a1;
            c.v0 += ScoreLib.value(a0, a1, mark);
        }
    }

    // ------------------------------------------------------------------
    // Liquidity plumbing (inside unlock)
    // ------------------------------------------------------------------

    /// @dev Modify slice `i` by `liqDelta`. Fees accrued on the position go to the slice's idle balance.
    ///      Returns the principal delta (positive when tokens come out).
    function _modify(uint8 i, int256 liqDelta) internal returns (int128 p0, int128 p1) {
        Curator storage c = curators[i];
        uint256 f0;
        uint256 f1;
        (p0, p1, f0, f1) = _modifyPos(c.tickLower, c.tickUpper, i, liqDelta);
        c.idle0 += f0;
        c.idle1 += f1;
        c.liquidity = _applyDelta(c.liquidity, liqDelta);
    }

    /// @dev The one place the hook calls modifyLiquidity. Splits the result into principal and fees.
    function _modifyPos(int24 tl, int24 tu, uint8 salt, int256 liqDelta)
        internal
        returns (int128 p0, int128 p1, uint256 f0, uint256 f1)
    {
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: liqDelta, salt: bytes32(uint256(salt))}),
            ""
        );
        f0 = uint128(fees.amount0());
        f1 = uint128(fees.amount1());
        p0 = callerDelta.amount0() - fees.amount0();
        p1 = callerDelta.amount1() - fees.amount1();
    }

    function _applyDelta(uint128 liq, int256 liqDelta) internal pure returns (uint128) {
        return liqDelta < 0 ? liq - uint128(uint256(-liqDelta)) : liq + uint128(uint256(liqDelta));
    }

    function _withdrawToIdle(uint8 i, uint128 liq) internal {
        (int128 p0, int128 p1) = _modify(i, -int256(uint256(liq)));
        curators[i].idle0 += uint128(p0);
        curators[i].idle1 += uint128(p1);
    }

    /// @dev Take num/den of slice `i` (liquidity and idle) out of the slice, rounded down.
    function _removeFraction(uint8 i, uint256 num, uint256 den) internal returns (uint256 out0, uint256 out1) {
        Curator storage c = curators[i];
        uint128 liq = uint128(FullMath.mulDiv(c.liquidity, num, den));
        if (liq > 0) {
            (int128 p0, int128 p1) = _modify(i, -int256(uint256(liq)));
            out0 = uint128(p0);
            out1 = uint128(p1);
        }
        uint256 i0 = FullMath.mulDiv(c.idle0, num, den);
        uint256 i1 = FullMath.mulDiv(c.idle1, num, den);
        c.idle0 -= i0;
        c.idle1 -= i1;
        out0 += i0;
        out1 += i1;
    }

    /// @dev Add as much of the slice's idle balance to its range as fits at the current price.
    function _deploy(uint8 i) internal {
        Curator storage c = curators[i];
        if (c.tickUpper <= c.tickLower) return;
        // Keep 2 wei back per token so rounding up inside the pool never overdraws the slice.
        uint256 a0 = c.idle0 > 2 ? c.idle0 - 2 : 0;
        uint256 a1 = c.idle1 > 2 ? c.idle1 - 2 : 0;
        if (a0 == 0 && a1 == 0) return;
        (uint160 sqrtP,,,) = poolManager.getSlot0(_poolId());
        uint128 liq = SuretyMath.liquidityFor(sqrtP, c.tickLower, c.tickUpper, a0, a1);
        if (liq == 0) return;
        (int128 p0, int128 p1) = _modify(i, int256(uint256(liq)));
        c.idle0 -= uint128(-p0);
        c.idle1 -= uint128(-p1);
    }

    /// @dev Modify the anchor. Fees it accrued go to the reserve. Returns the principal delta.
    function _modifyAnchor(int256 liqDelta) internal returns (int128 p0, int128 p1) {
        (int24 lo, int24 hi) = _fullRange();
        uint256 f0;
        uint256 f1;
        (p0, p1, f0, f1) = _modifyPos(lo, hi, 3, liqDelta);
        reserve0 += f0;
        reserve1 += f1;
        anchorLiquidity = _applyDelta(anchorLiquidity, liqDelta);
    }

    /// @dev Put the whole reserve full range (2 wei per token held back for rounding, as in _deploy).
    function _deployAnchor() internal {
        uint256 a0 = reserve0 > 2 ? reserve0 - 2 : 0;
        uint256 a1 = reserve1 > 2 ? reserve1 - 2 : 0;
        if (a0 == 0 || a1 == 0) return;
        (uint160 sqrtP,,,) = poolManager.getSlot0(_poolId());
        (int24 lo, int24 hi) = _fullRange();
        uint128 liq = SuretyMath.liquidityFor(sqrtP, lo, hi, a0, a1);
        if (liq == 0) return;
        (int128 p0, int128 p1) = _modifyAnchor(int256(uint256(liq)));
        reserve0 -= uint128(-p0);
        reserve1 -= uint128(-p1);
    }

    function _fullRange() internal view returns (int24, int24) {
        int24 s = poolKey.tickSpacing;
        return (TickMath.minUsableTick(s), TickMath.maxUsableTick(s));
    }

    /// @dev Net the hook's deltas against its ERC-6909 claims at the end of every unlock.
    function _settleDeltas() internal {
        _settleDelta(poolKey.currency0);
        _settleDelta(poolKey.currency1);
    }

    function _settleDelta(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d > 0) poolManager.mint(address(this), currency.toId(), uint256(d));
        else if (d < 0) poolManager.burn(address(this), currency.toId(), uint256(-d));
    }

    // ------------------------------------------------------------------
    // Guardrails
    // ------------------------------------------------------------------

    function _checkRange(int24 tl, int24 tu) internal view {
        int24 spacing = poolKey.tickSpacing;
        if (
            tl >= tu || tl % spacing != 0 || tu % spacing != 0 || tl < TickMath.minUsableTick(spacing)
                || tu > TickMath.maxUsableTick(spacing) || tu - tl < config.minWidth
        ) revert InvalidRange();
        int24 centre = int24((int256(tl) + int256(tu)) / 2);
        int24 ref = twap.meanTick(config.shortTwapWindow);
        int24 dist = centre > ref ? centre - ref : ref - centre;
        if (dist > config.maxDistance) revert RangeTooFar();
    }

    /// @dev The hook only adds liquidity when spot is close to the short TWAP, so nobody can push the price first
    ///      and trade against the liquidity the hook is about to add.
    function _checkSpot() internal view {
        (, int24 spot,,) = poolManager.getSlot0(_poolId());
        int24 ref = twap.meanTick(config.shortTwapWindow);
        int24 dev = spot > ref ? spot - ref : ref - spot;
        if (dev > config.maxSpotDeviation) revert SpotDeviation();
    }

    // ------------------------------------------------------------------
    // Valuation
    // ------------------------------------------------------------------

    /// @notice Value of slice `i` in token1 at `sqrtP`: position principal + uncollected fees + idle tokens.
    function _sliceValue(uint8 i, uint160 sqrtP) internal view returns (uint256) {
        Curator storage c = curators[i];
        if (c.liquidity == 0) return ScoreLib.value(c.idle0, c.idle1, sqrtP);
        return _positionValue(c.tickLower, c.tickUpper, i, c.idle0, c.idle1, sqrtP);
    }

    /// @dev Value at `sqrtP` of the hook's position (salt), including uncollected fees, plus loose tokens.
    function _positionValue(int24 tl, int24 tu, uint8 salt, uint256 extra0, uint256 extra1, uint160 sqrtP)
        internal
        view
        returns (uint256)
    {
        return SuretyMath.livePositionValue(
            poolManager, _poolId(), address(this), tl, tu, bytes32(uint256(salt)), extra0, extra1, sqrtP
        );
    }

    /// @notice Depositor-owned value: every slice, the reserve and the anchor. Bonds, rewards and queued batches are
    ///         excluded.
    function _nav(uint160 sqrtP) internal view returns (uint256 nav) {
        nav = ScoreLib.value(reserve0, reserve1, sqrtP);
        if (anchorLiquidity > 0) {
            (int24 lo, int24 hi) = _fullRange();
            nav += _positionValue(lo, hi, 3, 0, 0, sqrtP);
        }
        for (uint8 i; i < MAX_CURATORS; i++) {
            if (curators[i].active) nav += _sliceValue(i, sqrtP);
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function curatorState(address who)
        external
        view
        returns (uint256 bond, uint256 capital, int256 lastExcess, bool frozen)
    {
        uint8 i = _curatorIndex(who);
        if (i == NONE) return (0, 0, 0, false);
        Curator storage c = curators[i];
        return (c.bond, c.active ? _sliceValue(i, markSqrtPrice) : 0, c.lastExcess, c.frozen);
    }

    function epochInfo() external view returns (uint64 id, uint64 endsAt, uint256 sharePrice) {
        uint256 supply = shares.totalSupply();
        sharePrice = supply == 0 ? 1e18 : FullMath.mulDiv(_nav(markSqrtPrice), 1e18, supply);
        return (epochId, epochEnd, sharePrice);
    }

    function totalValue() external view returns (uint256) {
        return _nav(markSqrtPrice);
    }

    function twapTick(uint32 window) external view returns (int24) {
        return twap.meanTick(window);
    }

    /// @notice Sum of everything the hook's ERC-6909 claims must cover, per token. Used by the invariant tests.
    function accountedClaims() external view returns (uint256 claims0, uint256 claims1) {
        claims0 = reserve0;
        claims1 = reserve1 + rewardPool;
        for (uint8 i; i < MAX_CURATORS; i++) {
            Curator storage c = curators[i];
            claims0 += c.idle0;
            claims1 += c.idle1 + c.bond;
        }
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _poolId() internal view returns (PoolId) {
        return poolKey.toId();
    }

    function _curatorIndex(address who) internal view returns (uint8) {
        if (who == address(0)) return NONE;
        for (uint8 i; i < MAX_CURATORS; i++) {
            if (curators[i].owner == who) return i;
        }
        return NONE;
    }

    function _requireCurator(address who) internal view returns (uint8 i) {
        i = _curatorIndex(who);
        if (i == NONE) revert NotCurator();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VoltTrace pedagogy surface (internal codename: explos_dos)
/// @notice Laboratory ledger for bounded gas griefing drills; not a token and not a bridge.
/// @dev Companion material ships under ms-dos_new (Python) and winRARAI (static UI). Keep cohort sizes small on mainnet.

interface IVoltTraceSink {
    function ping(uint256 lessonId, bytes32 cohortTag) external returns (bool);
}

library VoltDosMath {
    uint256 internal constant WAD = 1e18;

    function saturatingAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return type(uint256).max;
            return c;
        }
    }

    function boundedMul(uint256 a, uint256 b, uint256 cap) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        if (a > cap / b) return cap;
        return a * b;
    }

    function clamp(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }
}

abstract contract VoltReentryShell {
    uint256 private _voltGate;

    modifier voltNonReentrant() {
        if (_voltGate == 1) revert VoltGateBusy();
        _voltGate = 1;
        _;
        _voltGate = 0;
    }

    error VoltGateBusy();
}

contract ExplosDosVoltLedger is VoltReentryShell {
    using VoltDosMath for uint256;

    uint256 public constant LESSON_CAP = 941;
    uint256 public constant COHORT_CAP = 128;
    uint256 public constant BATCH_CEILING = 64;
    uint256 public constant GAS_HINT_FLOOR = 21_000;
    uint256 public constant GAS_HINT_CEILING = 30_000_000;
    uint256 public constant TRACE_VERSION = 0x7a3c91f0e4b2d816ULL;
    uint256 public constant DRILL_SEED = 0x4f2e9c1a7b5583d4ULL;
    uint256 public constant PACING_NUMER = 73;
    uint256 public constant PACING_DENOM = 100;
    uint256 public constant JITTER_MASK = 0x0f0f0f0f0f0f0f0f;

    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;
    address public immutable ADDRESS_GOVERNOR;

    error VDL_ArgumentRange(string scope, uint256 got, uint256 minAllowed, uint256 maxAllowed);
    error VDL_CohortUnknown(uint256 cohortId);
    error VDL_LessonUnknown(uint256 lessonId);
    error VDL_LessonLocked(uint256 lessonId);
    error VDL_CohortFull(uint256 cohortId);
    error VDL_NotGovernor(address caller);
    error VDL_NotOperator(address caller);
    error VDL_NotAuditor(address caller);
    error VDL_NotLearner(address caller);
    error VDL_SinkReverted(address sink);
    error VDL_SinkMissing();
    error VDL_PacingViolation(uint256 cohortId, uint256 nextAllowed);
    error VDL_BatchTooLarge(uint256 requested, uint256 maxAllowed);
    error VDL_HashCollision(bytes32 tag);
    error VDL_ZeroAddress(string which);
    error VDL_AlreadyEnrolled(uint256 cohortId, address learner);
    error VDL_NotEnrolled(uint256 cohortId, address learner);
    error VDL_ScoreOutOfBand(uint256 score, uint256 maxScore);
    error VDL_DrillInactive(uint256 drillId);
    error VDL_DrillExhausted(uint256 drillId);

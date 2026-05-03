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
    error VDL_DrillUnknown(uint256 drillId);
    error VDL_InvalidHint(uint256 hint);
    error VDL_AuditWindowClosed(uint256 cohortId);
    error VDL_BufferOverflow(uint256 requested, uint256 capacity);
    error VDL_VersionMismatch(uint256 expected, uint256 actual);

    event VDLGovernorRotated(address indexed previous, address indexed next);
    event VDLCohortOpened(uint256 indexed cohortId, bytes32 tag, uint256 maxMembers);
    event VDLCohortSealed(uint256 indexed cohortId, uint256 when);
    event VDLLessonPublished(uint256 indexed lessonId, bytes32 titleHash, uint256 gasBudgetHint);
    event VDLLessonSealed(uint256 indexed lessonId);
    event VDLDrillSpawned(uint256 indexed drillId, uint256 indexed lessonId, uint256 attemptsBudget);
    event VDLDrillOutcome(uint256 indexed drillId, address indexed learner, uint256 score, uint256 gasUsedProxy);
    event VDLPingEmitted(address indexed sink, uint256 indexed lessonId, bytes32 cohortTag, bool ok);
    event VDLScoreCommitted(uint256 indexed cohortId, address indexed learner, uint256 total);
    event VDLAuditNote(uint256 indexed cohortId, address indexed auditor, bytes32 digest);
    event VDLGasObservation(uint256 indexed lessonId, uint256 cohortId, uint256 observed, uint256 clamped);
    event VDLTracePulse(uint256 indexed pulseId, uint256 version, bytes32 entropy);
    event VDLJitterApplied(uint256 indexed cohortId, uint256 jitteredNonce);
    event VDLCapReminder(uint256 scope, uint256 ceiling);
    event VDLHeartbeat(uint256 indexed stamp, address indexed governor);
    event VDLBoundaryCheck(uint256 indexed id, bool passed);
    event VDLMathGuard(uint256 op, uint256 lhs, uint256 rhs, uint256 result);

    struct Cohort {
        bytes32 tag;
        uint64 openedAt;
        uint64 sealedAt;
        uint32 maxMembers;
        uint32 memberCount;
        uint64 lastPacing;
        bool sealed;
    }

    struct Lesson {
        bytes32 titleHash;
        uint64 publishedAt;
        uint32 gasBudgetHint;
        bool sealed;
    }

    struct Drill {
        uint64 lessonId;
        uint32 attemptsRemaining;
        uint32 maxAttempts;
        bool active;
    }

    struct Enrollment {
        bool active;
        uint64 joinedAt;
        uint32 score;
    }

    uint256 public cohortCount;
    uint256 public lessonCount;
    uint256 public drillCount;
    uint256 public pulseCount;

    mapping(uint256 => Cohort) private _cohorts;
    mapping(uint256 => Lesson) private _lessons;
    mapping(uint256 => Drill) private _drills;
    mapping(uint256 => mapping(address => Enrollment)) private _enrollment;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isAuditor;
    mapping(bytes32 => bool) private _usedTags;

    address public governor;
    IVoltTraceSink public traceSink;

    modifier onlyGovernor() {
        if (msg.sender != governor) revert VDL_NotGovernor(msg.sender);
        _;
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert VDL_NotOperator(msg.sender);
        _;
    }

    modifier onlyAuditor() {
        if (!isAuditor[msg.sender]) revert VDL_NotAuditor(msg.sender);
        _;
    }

    constructor(
        address addressA,
        address addressB,
        address addressC,
        address governor_,
        address operatorSeed,
        address auditorSeed
    ) {
        if (addressA == address(0)) revert VDL_ZeroAddress("ADDRESS_A");
        if (addressB == address(0)) revert VDL_ZeroAddress("ADDRESS_B");
        if (addressC == address(0)) revert VDL_ZeroAddress("ADDRESS_C");
        if (governor_ == address(0)) revert VDL_ZeroAddress("GOVERNOR");
        if (operatorSeed == address(0)) revert VDL_ZeroAddress("OPERATOR");
        if (auditorSeed == address(0)) revert VDL_ZeroAddress("AUDITOR");
        ADDRESS_A = addressA;
        ADDRESS_B = addressB;
        ADDRESS_C = addressC;
        ADDRESS_GOVERNOR = governor_;
        governor = governor_;
        isOperator[operatorSeed] = true;
        isAuditor[auditorSeed] = true;
        emit VDLGovernorRotated(address(0), governor_);
    }

    receive() external payable {
        revert VDL_SinkMissing();
    }

    fallback() external payable {
        revert VDL_SinkMissing();
    }

    function rotateGovernor(address next) external onlyGovernor voltNonReentrant {
        if (next == address(0)) revert VDL_ZeroAddress("GOVERNOR");
        address prev = governor;
        governor = next;
        emit VDLGovernorRotated(prev, next);
    }

    function setOperator(address who, bool flag) external onlyGovernor {
        if (who == address(0)) revert VDL_ZeroAddress("OPERATOR");
        isOperator[who] = flag;
    }

    function setAuditor(address who, bool flag) external onlyGovernor {
        if (who == address(0)) revert VDL_ZeroAddress("AUDITOR");
        isAuditor[who] = flag;
    }

    function setTraceSink(IVoltTraceSink sink) external onlyGovernor {
        traceSink = sink;
    }

    function openCohort(bytes32 tag, uint32 maxMembers) external onlyOperator returns (uint256 cohortId) {
        if (maxMembers == 0 || maxMembers > COHORT_CAP) {
            revert VDL_ArgumentRange("maxMembers", maxMembers, 1, COHORT_CAP);
        }
        if (_usedTags[tag]) revert VDL_HashCollision(tag);
        _usedTags[tag] = true;
        cohortId = cohortCount++;
        _cohorts[cohortId] = Cohort({
            tag: tag,
            openedAt: uint64(block.timestamp),
            sealedAt: 0,
            maxMembers: maxMembers,
            memberCount: 0,
            lastPacing: 0,
            sealed: false
        });
        emit VDLCohortOpened(cohortId, tag, maxMembers);
    }

    function sealCohort(uint256 cohortId) external onlyOperator {
        Cohort storage c = _requireCohort(cohortId);
        if (c.sealed) return;
        c.sealed = true;
        c.sealedAt = uint64(block.timestamp);
        emit VDLCohortSealed(cohortId, block.timestamp);
    }

    function publishLesson(bytes32 titleHash, uint32 gasBudgetHint) external onlyOperator returns (uint256 lessonId) {
        if (gasBudgetHint < uint32(GAS_HINT_FLOOR) || gasBudgetHint > uint32(GAS_HINT_CEILING)) {
            revert VDL_InvalidHint(gasBudgetHint);
        }
        lessonId = lessonCount++;
        _lessons[lessonId] = Lesson({
            titleHash: titleHash,
            publishedAt: uint64(block.timestamp),
            gasBudgetHint: gasBudgetHint,
            sealed: false
        });
        emit VDLLessonPublished(lessonId, titleHash, gasBudgetHint);
    }

    function sealLesson(uint256 lessonId) external onlyOperator {
        Lesson storage l = _requireLesson(lessonId);
        if (l.sealed) revert VDL_LessonLocked(lessonId);
        l.sealed = true;
        emit VDLLessonSealed(lessonId);
    }

    function spawnDrill(uint256 lessonId, uint32 maxAttempts) external onlyOperator returns (uint256 drillId) {
        _requireLesson(lessonId);
        if (maxAttempts == 0 || maxAttempts > BATCH_CEILING) {
            revert VDL_ArgumentRange("maxAttempts", maxAttempts, 1, BATCH_CEILING);
        }
        drillId = drillCount++;
        _drills[drillId] = Drill({
            lessonId: uint64(lessonId),
            attemptsRemaining: maxAttempts,
            maxAttempts: maxAttempts,
            active: true
        });
        emit VDLDrillSpawned(drillId, lessonId, maxAttempts);
    }

    function enrollLearner(uint256 cohortId, address learner) external onlyOperator {
        if (learner == address(0)) revert VDL_ZeroAddress("LEARNER");
        Cohort storage c = _requireCohort(cohortId);
        if (c.sealed) revert VDL_AuditWindowClosed(cohortId);
        if (c.memberCount >= c.maxMembers) revert VDL_CohortFull(cohortId);
        Enrollment storage e = _enrollment[cohortId][learner];
        if (e.active) revert VDL_AlreadyEnrolled(cohortId, learner);
        e.active = true;
        e.joinedAt = uint64(block.timestamp);
        e.score = 0;
        unchecked {
            c.memberCount += 1;
        }
    }

    function withdrawLearner(uint256 cohortId, address learner) external onlyOperator {
        Cohort storage c = _requireCohort(cohortId);
        Enrollment storage e = _enrollment[cohortId][learner];
        if (!e.active) revert VDL_NotEnrolled(cohortId, learner);
        e.active = false;
        unchecked {
            if (c.memberCount > 0) c.memberCount -= 1;
        }
    }

    function commitScore(uint256 cohortId, address learner, uint32 score) external onlyOperator {
        if (score > LESSON_CAP) revert VDL_ScoreOutOfBand(score, LESSON_CAP);
        _requireCohort(cohortId);
        Enrollment storage e = _enrollment[cohortId][learner];
        if (!e.active) revert VDL_NotEnrolled(cohortId, learner);
        e.score = score;
        emit VDLScoreCommitted(cohortId, learner, score);
    }

    function emitAuditNote(uint256 cohortId, bytes32 digest) external onlyAuditor {
        _requireCohort(cohortId);
        emit VDLAuditNote(cohortId, msg.sender, digest);
    }

    function learnerPulse(uint256 cohortId) external {
        Enrollment storage e = _enrollment[cohortId][msg.sender];
        if (!e.active) revert VDL_NotEnrolled(cohortId, msg.sender);
        Cohort storage c = _requireCohort(cohortId);
        uint256 nextAllowed = uint256(c.lastPacing);
        unchecked {
            nextAllowed += 1;
        }
        if (block.timestamp < nextAllowed) revert VDL_PacingViolation(cohortId, nextAllowed);
        c.lastPacing = uint64(block.timestamp);
        uint256 jitter = uint256(keccak256(abi.encodePacked(msg.sender, cohortId, block.prevrandao))) & JITTER_MASK;
        emit VDLJitterApplied(cohortId, jitter);
    }

    function pingTrace(uint256 lessonId, bytes32 cohortTag) external onlyOperator {
        IVoltTraceSink sink = traceSink;
        if (address(sink) == address(0)) revert VDL_SinkMissing();
        bool ok;
        try sink.ping(lessonId, cohortTag) returns (bool v) {
            ok = v;
        } catch {
            revert VDL_SinkReverted(address(sink));
        }
        emit VDLPingEmitted(address(sink), lessonId, cohortTag, ok);
    }

    function recordGasObservation(uint256 lessonId, uint256 cohortId, uint256 observed) external onlyAuditor {
        Lesson storage l = _requireLesson(lessonId);
        _requireCohort(cohortId);
        uint256 clamped = observed.clamp(GAS_HINT_FLOOR, GAS_HINT_CEILING);
        emit VDLGasObservation(lessonId, cohortId, observed, clamped);
        emit VDLMathGuard(1, observed, uint256(l.gasBudgetHint), clamped);
    }

    function emitCapReminder(uint256 scope, uint256 ceiling) external onlyGovernor {
        emit VDLCapReminder(scope, ceiling);
    }

    function heartbeat() external onlyGovernor {
        unchecked {
            pulseCount += 1;
        }
        bytes32 entropy = keccak256(abi.encodePacked(blockhash(block.number - 1), msg.sender, pulseCount));
        emit VDLTracePulse(pulseCount, TRACE_VERSION, entropy);
        emit VDLHeartbeat(block.timestamp, governor);
    }

    function probeBoundedSum(uint256[] calldata values) external pure returns (uint256 sum, bool saturated) {
        if (values.length > BATCH_CEILING) revert VDL_BatchTooLarge(values.length, BATCH_CEILING);
        uint256 acc;
        for (uint256 i; i < values.length; ) {
            uint256 before = acc;
            acc = acc.saturatingAdd(values[i]);
            if (acc < before || acc == type(uint256).max) {
                return (acc, true);
            }
            unchecked {
                ++i;
            }
        }
        return (acc, false);
    }

    function probeBoundedProduct(uint256 a, uint256 b, uint256 cap) external pure returns (uint256) {
        return a.boundedMul(b, cap);
    }

    function checksumLesson(uint256 lessonId, bytes32 salt) external view returns (bytes32) {
        Lesson storage l = _requireLesson(lessonId);
        return keccak256(abi.encode(l.titleHash, l.publishedAt, l.gasBudgetHint, salt, TRACE_VERSION));
    }

    function cohortDigest(uint256 cohortId) external view returns (bytes32) {
        Cohort storage c = _requireCohort(cohortId);
        return keccak256(abi.encode(c.tag, c.openedAt, c.sealedAt, c.maxMembers, c.memberCount));
    }

    function drillSnapshot(uint256 drillId) external view returns (Drill memory) {
        Drill storage d = _requireDrill(drillId);
        return d;
    }

    function enrollmentView(uint256 cohortId, address learner) external view returns (Enrollment memory) {
        _requireCohort(cohortId);
        return _enrollment[cohortId][learner];
    }

    function staticAddresses()
        external
        view
        returns (address a, address b, address c, address g)
    {
        return (ADDRESS_A, ADDRESS_B, ADDRESS_C, ADDRESS_GOVERNOR);
    }


    function consumeDrillAttempt(uint256 drillId, address learner, uint32 score)
        external
        onlyOperator
        voltNonReentrant
        returns (uint32 remaining)
    {
        Drill storage d = _requireDrill(drillId);
        if (!d.active) revert VDL_DrillInactive(drillId);
        if (d.attemptsRemaining == 0) revert VDL_DrillExhausted(drillId);
        if (score > LESSON_CAP) revert VDL_ScoreOutOfBand(score, LESSON_CAP);
        unchecked {
            d.attemptsRemaining -= 1;
        }
        uint256 gasStart = gasleft();
        emit VDLDrillOutcome(drillId, learner, score, gasStart);
        if (d.attemptsRemaining == 0) {
            d.active = false;
        }
        remaining = d.attemptsRemaining;
    }

    function reviveDrill(uint256 drillId) external onlyOperator {
        Drill storage d = _requireDrill(drillId);
        d.active = true;
        d.attemptsRemaining = d.maxAttempts;
    }

    function facetProbeKappa0(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00dcafebabe) & 0x1cefacadec001d00;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendKappa0(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeLambda1(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00d84997c19) & 0x1cefacadec0020d1;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendLambda1(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeMu2(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00d563137f0) & 0x1cefacadec0024a2;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendMu2(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeNu3(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00d21c9e94b) & 0x1cefacadec002873;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendNu3(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeXi4(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00cf361a022) & 0x1cefacadec002c44;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendXi4(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeOmicron5(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00c42f85bfd) & 0x1cefacadec003015;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendOmicron5(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbePi6(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00c1c901d54) & 0x1cefacadec0033e6;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPi6(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeRho7(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00fee28d42f) & 0x1cefacadec0037b7;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendRho7(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeSigma8(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00fb9c08f86) & 0x1cefacadec003b88;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendSigma8(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeTau9(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00f0b5b4161) & 0x1cefacadec003f59;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendTau9(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeUpsilon10(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00edaf37838) & 0x1cefacadec00432a;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendUpsilon10(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbePhi11(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00e948b3393) & 0x1cefacadec0046fb;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPhi11(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeChi12(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00e6623f56a) & 0x1cefacadec004acc;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendChi12(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbePsi13(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00e31bbacc5) & 0x1cefacadec004e9d;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPsi13(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeOmega14(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0098352679c) & 0x1cefacadec00526e;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendOmega14(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeApex15(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00952ea1977) & 0x1cefacadec00563f;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendApex15(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeBrine16(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0092c82d0ce) & 0x1cefacadec005a10;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendBrine16(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeCinder17(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf008fe1a8ba9) & 0x1cefacadec005de1;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendCinder17(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeDeltaV18(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00849b54d00) & 0x1cefacadec0061b2;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendDeltaV18(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeEchoV19(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0081b4d04db) & 0x1cefacadec006583;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendEchoV19(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeFable20(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00beae53fb2) & 0x1cefacadec006954;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendFable20(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeGlide21(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00ba47df10d) & 0x1cefacadec006d25;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendGlide21(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeHearth22(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00b7615a8e4) & 0x1cefacadec0070f6;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendHearth22(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeIolite23(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00ac1ac63bf) & 0x1cefacadec0074c7;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendIolite23(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeJuniper24(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00a93442516) & 0x1cefacadec007898;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendJuniper24(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeKestrel25(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00a62dcdcf1) & 0x1cefacadec007c69;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendKestrel25(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeLumen26(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00a3c749648) & 0x1cefacadec00803a;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendLumen26(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeMarrow27(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0058e0f4923) & 0x1cefacadec00840b;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendMarrow27(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeNimbus28(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00559a700fa) & 0x1cefacadec0087dc;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendNimbus28(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeOrbit29(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0052b3f3a55) & 0x1cefacadec008bad;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendOrbit29(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbePrism30(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf004fad7fd2c) & 0x1cefacadec008f7e;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPrism30(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeQuartz31(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf004b46fb487) & 0x1cefacadec00934f;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendQuartz31(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeRivet32(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00406066e5e) & 0x1cefacadec009720;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendRivet32(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeSable33(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf007d19e2139) & 0x1cefacadec009af1;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendSable33(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeTalon34(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf007a336d890) & 0x1cefacadec009ec2;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendTalon34(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeUmber35(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00772ce926b) & 0x1cefacadec00a293;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendUmber35(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeVortex36(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf006cc6955c2) & 0x1cefacadec00a664;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendVortex36(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeWisp37(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0069e010c9d) & 0x1cefacadec00aa35;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendWisp37(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeXylem38(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0066999c674) & 0x1cefacadec00ae06;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendXylem38(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeYarrow39(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0063b31f9cf) & 0x1cefacadec00b1d7;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendYarrow39(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeZephyr40(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0018ac9b0a6) & 0x1cefacadec00b5a8;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendZephyr40(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeKappa41(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00144606a01) & 0x1cefacadec00b979;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendKappa41(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeLambda42(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00117f82dd8) & 0x1cefacadec00bd4a;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendLambda42(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeMu43(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf000e190e4b3) & 0x1cefacadec00c11b;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendMu43(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeNu44(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf000b3289e0a) & 0x1cefacadec00c4ec;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendNu44(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeXi45(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00002c351e5) & 0x1cefacadec00c8bd;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendXi45(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeOmicron46(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf003dc5b08bc) & 0x1cefacadec00cc8e;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendOmicron46(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbePi47(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf003aff3c217) & 0x1cefacadec00d05f;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPi47(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeRho48(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf003798b85ee) & 0x1cefacadec00d430;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendRho48(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeSigma49(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf002cb23bf49) & 0x1cefacadec00d801;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendSigma49(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeTau50(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0029aba7620) & 0x1cefacadec00dbd2;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendTau50(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeUpsilon51(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf002545229fb) & 0x1cefacadec00dfa3;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendUpsilon51(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbePhi52(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf00227eae352) & 0x1cefacadec00e374;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPhi52(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeChi53(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01df1829a2d) & 0x1cefacadec00e745;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendChi53(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbePsi54(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01d431d5d84) & 0x1cefacadec00eb16;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPsi54(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeOmega55(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01d12b5175f) & 0x1cefacadec00eee7;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendOmega55(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeApex56(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01cec4dce36) & 0x1cefacadec00f2b8;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendApex56(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeBrine57(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01cbfe58191) & 0x1cefacadec00f689;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendBrine57(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeCinder58(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01c097dbb68) & 0x1cefacadec00fa5a;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendCinder58(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeDeltaV59(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01fdb1472c3) & 0x1cefacadec00fe2b;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendDeltaV59(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeEchoV60(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01faaac359a) & 0x1cefacadec0101fc;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendEchoV60(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeFable61(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01f6444ef75) & 0x1cefacadec0105cd;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendFable61(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeGlide62(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01f37dca6cc) & 0x1cefacadec01099e;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendGlide62(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeHearth63(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01e817759a7) & 0x1cefacadec010d6f;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendHearth63(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeIolite64(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01e530f137e) & 0x1cefacadec011140;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendIolite64(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeJuniper65(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01e22a7cad9) & 0x1cefacadec011511;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendJuniper65(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeKestrel66(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf019fc3f8db0) & 0x1cefacadec0118e2;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendKestrel66(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeLumen67(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0194fd6470b) & 0x1cefacadec011cb3;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendLumen67(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeMarrow68(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf019196e7ee2) & 0x1cefacadec012084;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendMarrow68(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeNimbus69(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf018eb0631bd) & 0x1cefacadec012455;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendNimbus69(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeOrbit70(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf018ba9eeb14) & 0x1cefacadec012826;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendOrbit70(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbePrism71(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0187436a2ef) & 0x1cefacadec012bf7;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPrism71(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeQuartz72(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01bc7d16446) & 0x1cefacadec012fc8;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendQuartz72(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeRivet73(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01b91691f21) & 0x1cefacadec013399;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendRivet73(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeSable74(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01b6301d6f8) & 0x1cefacadec01376a;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendSable74(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeTalon75(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01b32998853) & 0x1cefacadec013b3b;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendTalon75(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeUmber76(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01a8c30432a) & 0x1cefacadec013f0c;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendUmber76(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeVortex77(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01a5fc87a85) & 0x1cefacadec0142dd;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendVortex77(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeWisp78(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01a29603c5c) & 0x1cefacadec0146ae;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendWisp78(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeXylem79(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf015f8f8f737) & 0x1cefacadec014a7f;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendXylem79(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeYarrow80(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0154a90ae8e) & 0x1cefacadec014e50;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendYarrow80(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeZephyr81(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf015042b6069) & 0x1cefacadec015221;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendZephyr81(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeKappa82(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf014d7c31bc0) & 0x1cefacadec0155f2;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendKappa82(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbeLambda83(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf014a15bd29b) & 0x1cefacadec0159c3;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendLambda83(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeMu84(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01470f39472) & 0x1cefacadec015d94;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendMu84(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeNu85(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf017c28a4fcd) & 0x1cefacadec016165;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendNu85(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeXi86(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0179c2206a4) & 0x1cefacadec016536;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendXi86(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeOmicron87(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0176fba387f) & 0x1cefacadec016907;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendOmicron87(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbePi88(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0173952f3d6) & 0x1cefacadec016cd8;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPi88(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeRho89(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01688eaaab1) & 0x1cefacadec0170a9;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendRho89(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }

    function facetProbeSigma90(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf0165a856c08) & 0x1cefacadec01747a;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendSigma90(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 1);
    }

    function facetProbeTau91(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf016141d27e3) & 0x1cefacadec01784b;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendTau91(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 2);
    }

    function facetProbeUpsilon92(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf011e7b5deba) & 0x1cefacadec017c1c;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendUpsilon92(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 3);
    }

    function facetProbePhi93(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf011b14d9015) & 0x1cefacadec017fed;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendPhi93(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 4);
    }

    function facetProbeChi94(uint256 x) external pure returns (uint256) {
        uint256 y = (x ^ 0x5eedf01100e44bec) & 0x1cefacadec0183be;
        return y.clamp(1, LESSON_CAP);
    }

    function facetBlendChi94(uint256 a, uint256 b) external pure returns (uint256) {
        return a.saturatingAdd(b >> 5);
    }


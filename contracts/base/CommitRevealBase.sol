// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FundsBase} from "./FundsBase.sol";
import {HashLib} from "../libraries/HashLib.sol";

import {
    GameState,
    PlayerState,
    LastResult,
    CallbackIgnoreReason
} from "../shared/Types.sol";

import {
    InvalidGuess,
    ZeroCommitHash,
    IncorrectBetAmount,
    GameAlreadyActive,
    NoActiveGame,
    CommitPhaseNotOver,
    RevealPhaseOver,
    InvalidReveal,
    PrizePoolInsufficient,
    RevealNotExpired,
    VrfTimeoutNotReached,
    MaxRetriesReached,
    NotStuckYet,
    NotWaitingVrf
} from "../shared/Errors.sol";

import {
    Committed,
    RandomnessRequested,
    VrfRequestRetried,
    Settled,
    Cancelled,
    StuckGameCancelled,
    FeeCharged,
    CallbackIgnored
} from "../shared/Events.sol";

/**
 * @title CommitRevealBase
 * @notice Commit-Reveal 机制 + VRF 回调处理的核心实现
 * @dev 这是整个骰子游戏的核心状态机，管理游戏的完整生命周期
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              游戏状态机
 * ══════════════════════════════════════════════════════════════════════════════
 *
 *                              ┌─────────────┐
 *                              │    None     │◄────────────────────────────┐
 *                              │  (空闲状态)  │                             │
 *                              └──────┬──────┘                             │
 *                                     │                                    │
 *                                     │ commit()                           │
 *                                     │ 支付 0.001 ETH                     │
 *                                     ▼                                    │
 *                              ┌─────────────┐                             │
 *                              │  Committed  │                             │
 *                              │ (已提交承诺) │                             │
 *                              └──────┬──────┘                             │
 *                                     │                                    │
 *              ┌──────────────────────┼──────────────────────┐             │
 *              │                      │                      │             │
 *              │ 等待 60s             │ 60s~180s             │ > 180s      │
 *              │ (冷却期)             │ (Reveal 窗口)         │ (过期)      │
 *              ▼                      ▼                      ▼             │
 *     ┌────────────────┐    ┌────────────────┐    ┌────────────────┐       │
 *     │ CommitPhase    │    │ RevealPhase    │    │ cancelExpired  │       │
 *     │ NotOver        │    │ (可 Reveal)    │    │ 退款 50%        │───────┤
 *     └────────────────┘    └───────┬────────┘    └────────────────┘       │
 *                                   │                                      │
 *                                   │ reveal()                             │
 *                                   │ 验证 hash + 请求 VRF                  │
 *                                   ▼                                      │
 *                            ┌─────────────────┐                           │
 *                            │ RandomRequested │                           │
 *                            │ (等待 VRF 回调)  │                           │
 *                            └────────┬────────┘                           │
 *                                     │                                    │
 *         ┌───────────────────────────┼───────────────────────────┐        │
 *         │                           │                           │        │
 *         │ < 10min                   │ 10min~24h                 │ > 24h  │
 *         │ (等待回调)                 │ (可 Retry)                │ (卡住) │
 *         ▼                           ▼                           ▼        │
 *  ┌──────────────┐          ┌──────────────┐          ┌──────────────┐    │
 *  │ VRF 回调到达  │          │ retry()      │          │ cancelStuck  │    │
 *  │ 结算游戏      │──────────│ 重新请求 VRF │           │ 退款 100%    │────┘
 *  └──────┬───────┘          └──────────────┘          └──────────────┘
 *         │
 *         │ fulfillRandomWords()
 *         │ 计算结果 + 发放奖金
 *         ▼
 *  ┌──────────────────────────────────────┐
 *  │           游戏结算完成                │
 *  │  - 胜利: 奖金进入 pendingWithdrawals  │
 *  │  - 失败: 无奖金                       │
 *  │  - 结果存入 _lastResults              │
 *  └──────────────────────────────────────┘
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              时间窗口说明
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * commit 后的时间线：
 *
 * T=0          T=60s        T=180s                T=10min+        T=24h+
 *  │            │             │                      │              │
 *  │◄──冷却期──►│◄─Reveal窗口─►│                      │              │
 *  │  (60s)     │   (120s)    │                      │              │
 *  │            │             │                      │              │
 *  commit()     可以reveal    过期                   可retry         可强制取消
 *               开始          (只能cancel)           (VRF超时)       (VRF卡住)
 *
 * 为什么需要冷却期：
 * - 给矿工/验证者足够时间打包交易
 * - 防止玩家在同一区块内 commit+reveal（可能被矿工看到）
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              退款规则
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 1. 过期取消 (cancelExpiredCommitment)：
 *    - 条件：state == Committed && 已过 revealDeadline
 *    - 退款：(BET_AMOUNT - feePaid) / 2（约 50%）
 *    - 原因：玩家自己没有及时 reveal，惩罚性退款
 *
 * 2. 卡住取消 (cancelStuckGame)：
 *    - 条件：state == RandomRequested && VRF 超过 24 小时未响应
 *    - 退款：BET_AMOUNT - feePaid（100%）
 *    - 原因：VRF 故障不是玩家的错，全额退款
 */
abstract contract CommitRevealBase is FundsBase {
    //时间常量
    uint256 public constant COMMIT_DURATION = 60;               // commit 后等待多久才能 reveal
    uint256 public constant REVEAL_DURATION = 120;              // reveal 窗口时长
    uint8 public constant MAX_RETRIES = 3;                      // VRF 请求最大重试次数
    uint256 public constant VRF_STUCK_TIMEOUT = 24 hours;       // VRF 卡住超时时间（超过后可强制取消，获得全额退款）

    //状态存储
    mapping(address => PlayerState) internal _playerStates;     // 玩家当前游戏状态
    mapping(address => LastResult) internal _lastResults;       // 玩家上一局结果（仅保留最近一局）
    mapping(uint256 => address) public requestToPlayer;         // VRF requestId 到玩家地址的映射

    // ═══════════════════════════════════════════════════════════════════════════
    //                              抽象函数
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 将 256 位随机数转换为 1-6 的骰子点数
     * @dev 由子合约实现，通常是 (entropy % 6) + 1
     * @param entropy 混合后的随机数
     * @return 骰子点数（1-6）
     */
    function _toDice(uint256 entropy) internal pure virtual returns (uint8);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              核心游戏函数
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 提交游戏承诺（第一阶段）
     * @dev 必须从 payable 外部函数调用，msg.value == BET_AMOUNT
     *
     * 执行流程：
     * 1. 校验 commitHash 非空
     * 2. 校验下注金额
     * 3. 校验玩家没有进行中的游戏
     * 4. 扣除手续费
     * 5. 创建新的游戏状态
     * 6. 触发 Committed 事件
     *
     * @param commitHash 承诺哈希 = keccak256(player, guess, secret, contract, chainId, nonce)
     */
    function _commit(bytes32 commitHash) internal {
        if (commitHash == bytes32(0)) revert ZeroCommitHash();
        if (msg.value != BET_AMOUNT) revert IncorrectBetAmount();

        PlayerState storage ps = _playerStates[msg.sender];
        if (ps.state == GameState.Committed || ps.state == GameState.RandomRequested) {
            revert GameAlreadyActive();
        }

        uint64 nowTs = uint64(block.timestamp);
        uint32 newNonce = ps.nonce + 1;
        uint64 revealStart = nowTs + uint64(COMMIT_DURATION);
        uint64 revealDeadline = revealStart + uint64(REVEAL_DURATION);

        // 扣除手续费（在 commit 时立即扣除，不管最终输赢）
        uint256 fee = (BET_AMOUNT * feeBps) / 10000;
        if (fee > 0) {
            protocolFeesAccrued += fee;
            emit FeeCharged(msg.sender, feeRecipient, fee);
        }

        // 创建新的游戏状态
        _playerStates[msg.sender] = PlayerState({
            commitHash: commitHash,
            commitTime: nowTs,
            revealStart: revealStart,
            revealDeadline: revealDeadline,
            guess: 0,                    // reveal 时填入
            secret: bytes32(0),          // reveal 时填入
            requestId: 0,                // reveal 时填入
            vrfRequestTime: 0,           // reveal 时填入
            nonce: newNonce,
            retryCount: 0,
            feePaid: fee,
            state: GameState.Committed
        });

        emit Committed(msg.sender, commitHash, nowTs, revealStart, revealDeadline, newNonce);
    }

    /**
     * @notice 揭示猜测并请求 VRF 随机数（第二阶段）
     * @dev 只能在 Reveal 窗口内调用（commit 后 60s~180s）
     *
     * 执行流程：
     * 1. 校验 guess 在 1-6 范围内
     * 2. 校验游戏状态为 Committed
     * 3. 校验当前时间在 Reveal 窗口内
     * 4. 校验 commitHash 匹配
     * 5. 校验奖池余额充足
     * 6. 预留奖金（reservedForInFlightGames）
     * 7. 发起 VRF 请求
     *
     * @param guess 玩家猜测的点数（1-6）
     * @param secret 玩家的 secret（必须与 commit 时一致）
     * @return requestId VRF 请求 ID
     */
    function _revealAndRequestRandom(
        uint8 guess,
        bytes32 secret
    ) internal returns (uint256 requestId) {
        if (guess < 1 || guess > 6) revert InvalidGuess();

        PlayerState storage ps = _playerStates[msg.sender];
        if (ps.state != GameState.Committed) revert NoActiveGame();

        uint256 nowTs = block.timestamp;
        if (nowTs < ps.revealStart) revert CommitPhaseNotOver();
        if (nowTs >= ps.revealDeadline) revert RevealPhaseOver();

        // 重新计算 commitHash 并验证
        bytes32 computed = HashLib.computeCommitHash(
            msg.sender,
            guess,
            secret,
            address(this),
            block.chainid,
            ps.nonce
        );
        if (computed != ps.commitHash) revert InvalidReveal();

        // 检查奖池是否有足够余额
        if (_availablePrizeBalance() < PRIZE_AMOUNT) revert PrizePoolInsufficient();

        // 预留奖金（防止并发 reveal 导致奖池不足）
        reservedForInFlightGames += PRIZE_AMOUNT;

        // 保存 guess 和 secret（用于结算时的 Hybrid Mix）
        ps.guess = guess;
        ps.secret = secret;
        ps.state = GameState.RandomRequested;

        // 发起 VRF 请求
        requestId = _requestVrf();
        ps.requestId = requestId;
        ps.vrfRequestTime = uint64(nowTs);
        requestToPlayer[requestId] = msg.sender;

        emit RandomnessRequested(msg.sender, requestId);
    }

    /**
     * @notice 重试 VRF 请求
     * @dev 当 VRF 请求超过 10 分钟未响应时，玩家可以重新发起请求
     *
     * 重试机制说明：
     * - 最多重试 MAX_RETRIES 次（默认 3 次）
     * - 每次重试会生成新的 requestId
     * - 旧的 requestId 映射会被删除（防止旧回调干扰）
     *
     * @return newRequestId 新的 VRF 请求 ID
     */
    function _retryVrfRequest() internal returns (uint256 newRequestId) {
        PlayerState storage ps = _playerStates[msg.sender];
        if (ps.state != GameState.RandomRequested) revert NotWaitingVrf();

        uint256 deadline = uint256(ps.vrfRequestTime) + VRF_TIMEOUT;
        if (block.timestamp < deadline) revert VrfTimeoutNotReached();

        if (ps.retryCount >= MAX_RETRIES) revert MaxRetriesReached();

        // 清理旧的 requestId 映射
        uint256 oldRequestId = ps.requestId;
        delete requestToPlayer[oldRequestId];

        // 发起新的 VRF 请求
        newRequestId = _requestVrf();
        ps.requestId = newRequestId;
        ps.vrfRequestTime = uint64(block.timestamp);
        ps.retryCount++;
        requestToPlayer[newRequestId] = msg.sender;

        emit VrfRequestRetried(msg.sender, oldRequestId, newRequestId);
        emit RandomnessRequested(msg.sender, newRequestId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              取消/退出函数
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 取消过期的 Commit（玩家未及时 Reveal）
     * @dev 当玩家错过 Reveal 窗口后调用
     *
     * 退款规则：
     * - 退款 = (BET_AMOUNT - feePaid) / 2
     * - 约损失 50%（惩罚性退款，因为是玩家自己的失误）
     */
    function _cancelExpiredCommitment() internal {
        PlayerState storage ps = _playerStates[msg.sender];
        if (ps.state != GameState.Committed) revert NoActiveGame();
        if (block.timestamp < ps.revealDeadline) revert RevealNotExpired();

        uint256 netBet = BET_AMOUNT - ps.feePaid;
        uint256 refund = netBet / 2;  // 惩罚性退款：只退一半

        pendingWithdrawals[msg.sender] += refund;
        totalPendingWithdrawals += refund;

        _resetPlayerState(ps);

        emit Cancelled(msg.sender, refund);
    }

    /**
     * @notice 取消卡住的游戏（VRF 长时间未响应）
     * @dev 当 VRF 请求超过 24 小时未响应时调用
     *
     * 退款规则：
     * - 退款 = BET_AMOUNT - feePaid（全额退款）
     * - VRF 故障不是玩家的错，所以全额退款
     *
     * 为什么需要这个逃生口：
     * - VRF 节点可能故障
     * - Coordinator 可能升级/迁移
     * - 防止玩家资金永久锁死
     */
    function _cancelStuckGame() internal {
        PlayerState storage ps = _playerStates[msg.sender];
        if (ps.state != GameState.RandomRequested) revert NotWaitingVrf();

        uint256 stuckDeadline = uint256(ps.vrfRequestTime) + VRF_STUCK_TIMEOUT;
        if (block.timestamp < stuckDeadline) revert NotStuckYet();

        uint256 netBet = BET_AMOUNT - ps.feePaid;
        uint256 refund = netBet;  // 全额退款

        // 释放预留的奖金
        reservedForInFlightGames -= PRIZE_AMOUNT;

        pendingWithdrawals[msg.sender] += refund;
        totalPendingWithdrawals += refund;

        delete requestToPlayer[ps.requestId];
        _resetPlayerState(ps);

        emit StuckGameCancelled(msg.sender, refund);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              VRF 回调处理
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 处理 VRF 回调，结算游戏
     * @dev 由 Chainlink VRF Coordinator 调用（通过 fulfillRandomWords）
     *
     * 防御式编程：
     * - 检查 requestId 是否有效
     * - 检查玩家状态是否正确
     * - 检查 requestId 是否匹配（防止旧回调干扰）
     * - 检查 randomWords 是否非空
     *
     * 如果任何检查失败，不会 revert（避免浪费 Chainlink 节点的 gas），
     * 而是触发 CallbackIgnored 事件，记录原因。
     *
     * @param requestId VRF 请求 ID
     * @param randomWords Chainlink 返回的随机数数组
     */
    function _handleFulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal {
        // 查找对应的玩家
        address player = requestToPlayer[requestId];
        if (player == address(0)) {
            emit CallbackIgnored(requestId, address(0), CallbackIgnoreReason.UnknownRequestId);
            return;
        }

        PlayerState storage ps = _playerStates[player];

        // 检查玩家状态
        if (ps.state != GameState.RandomRequested) {
            emit CallbackIgnored(requestId, player, CallbackIgnoreReason.InvalidGameState);
            return;
        }

        // 检查 requestId 是否匹配（可能是 retry 后的旧回调）
        if (ps.requestId != requestId) {
            emit CallbackIgnored(requestId, player, CallbackIgnoreReason.RequestIdMismatch);
            return;
        }

        // 检查随机数数组非空
        if (randomWords.length == 0) {
            emit CallbackIgnored(requestId, player, CallbackIgnoreReason.EmptyRandomWords);
            return;
        }

        // ═══════════════════════════════════════════════════════════════════════
        //                          游戏结算逻辑
        // ═══════════════════════════════════════════════════════════════════════

        // 释放预留的奖金
        reservedForInFlightGames -= PRIZE_AMOUNT;

        // Hybrid Mix：将 VRF 随机数与玩家 secret 混合
        uint256 mixed = HashLib.mixRandomness(
            randomWords[0],
            ps.secret,
            player,
            requestId,
            address(this),
            block.chainid
        );

        // 转换为骰子点数（1-6）
        uint8 roll = _toDice(mixed);
        bool won = (roll == ps.guess);

        // 计算奖金
        uint256 payout = 0;
        if (won) {
            payout = PRIZE_AMOUNT;
            pendingWithdrawals[player] += payout;
            totalPendingWithdrawals += payout;
        }

        // 保存结果（仅保留最近一局）
        _lastResults[player] = LastResult({
            settledTime: uint64(block.timestamp),
            requestId: requestId,
            roll: roll,
            guess: ps.guess,
            won: won,
            payout: payout
        });

        // 清理状态
        delete requestToPlayer[requestId];
        _resetPlayerState(ps);

        emit Settled(player, requestId, roll, _lastResults[player].guess, won, payout);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              内部辅助函数
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 重置玩家状态
     * @dev 游戏结束（输/赢/取消）后调用，清空所有字段，保留 nonce
     * @param ps 玩家状态的 storage 引用
     */
    function _resetPlayerState(PlayerState storage ps) private {
        ps.commitHash = bytes32(0);
        ps.commitTime = 0;
        ps.revealStart = 0;
        ps.revealDeadline = 0;
        ps.guess = 0;
        ps.secret = bytes32(0);
        ps.requestId = 0;
        ps.vrfRequestTime = 0;
        ps.retryCount = 0;
        ps.feePaid = 0;
        ps.state = GameState.None;
        // 注意：nonce 不重置，每局递增
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              View 函数（供 GameLens 使用）
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 检查玩家是否可以开始新游戏（仅检查状态）
     * @dev 不检查 paused，由主合约的 canCommit() 组合判断
     * @param player 玩家地址
     * @return 是否可以 commit
     */
    function _canCommitByState(address player) internal view returns (bool) {
        return _playerStates[player].state == GameState.None;
    }

    /**
     * @notice 检查玩家是否可以 Reveal
     * @dev 必须在 Reveal 窗口内（commit 后 60s~180s）
     * @param player 玩家地址
     * @return 是否可以 reveal
     */
    function _canReveal(address player) internal view returns (bool) {
        PlayerState storage ps = _playerStates[player];
        if (ps.state != GameState.Committed) return false;
        uint256 nowTs = block.timestamp;
        return nowTs >= ps.revealStart && nowTs < ps.revealDeadline;
    }

    /**
     * @notice 检查玩家是否可以重试 VRF 请求
     * @dev 必须处于 RandomRequested 状态，且 VRF 已超时，且未达最大重试次数
     * @param player 玩家地址
     * @return 是否可以 retry
     */
    function _canRetry(address player) internal view returns (bool) {
        PlayerState storage ps = _playerStates[player];
        if (ps.state != GameState.RandomRequested) return false;
        if (ps.retryCount >= MAX_RETRIES) return false;
        return block.timestamp >= uint256(ps.vrfRequestTime) + VRF_TIMEOUT;
    }

    /**
     * @notice 检查玩家是否可以强制取消卡住的游戏
     * @dev 必须处于 RandomRequested 状态，且 VRF 已卡住超过 24 小时
     * @param player 玩家地址
     * @return 是否可以强制取消
     */
    function _canCancelStuck(address player) internal view returns (bool) {
        PlayerState storage ps = _playerStates[player];
        if (ps.state != GameState.RandomRequested) return false;
        return block.timestamp >= uint256(ps.vrfRequestTime) + VRF_STUCK_TIMEOUT;
    }

    /**
     * @notice 检查玩家是否可以取消过期的 Commit
     * @dev 必须处于 Committed 状态，且已过 Reveal 截止时间
     * @param player 玩家地址
     * @return 是否可以取消
     */
    function _canCancelExpired(address player) internal view returns (bool) {
        PlayerState storage ps = _playerStates[player];
        if (ps.state != GameState.Committed) return false;
        return block.timestamp >= ps.revealDeadline;
    }

    /**
     * @notice 获取玩家的时间信息（用于前端倒计时）
     * @dev 返回各个操作的剩余等待时间，0 表示已可执行
     * @param player 玩家地址
     * @return timeUntilRevealStart 距离 Reveal 窗口开启的剩余秒数
     * @return timeUntilRevealDeadline 距离 Reveal 截止的剩余秒数
     * @return timeUntilCanRetry 距离可重试 VRF 的剩余秒数
     * @return timeUntilCanCancelStuck 距离可强制取消的剩余秒数
     */
    function _getTimeInfo(address player)
        internal
        view
        returns (
            uint256 timeUntilRevealStart,
            uint256 timeUntilRevealDeadline,
            uint256 timeUntilCanRetry,
            uint256 timeUntilCanCancelStuck
        )
    {
        PlayerState storage ps = _playerStates[player];
        uint256 nowTs = block.timestamp;

        if (ps.state == GameState.Committed) {
            timeUntilRevealStart = nowTs >= ps.revealStart ? 0 : ps.revealStart - nowTs;
            timeUntilRevealDeadline = nowTs >= ps.revealDeadline ? 0 : ps.revealDeadline - nowTs;
        }

        if (ps.state == GameState.RandomRequested) {
            uint256 retryTime = uint256(ps.vrfRequestTime) + VRF_TIMEOUT;
            uint256 stuckTime = uint256(ps.vrfRequestTime) + VRF_STUCK_TIMEOUT;
            timeUntilCanRetry = nowTs >= retryTime ? 0 : retryTime - nowTs;
            timeUntilCanCancelStuck = nowTs >= stuckTime ? 0 : stuckTime - nowTs;
        }
    }
}

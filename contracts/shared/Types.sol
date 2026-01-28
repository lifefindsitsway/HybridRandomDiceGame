// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Types
 * @notice 混合随机骰子游戏的共享类型定义
 * @dev 包含所有枚举和结构体，供各模块引用
 */

// ═══════════════════════════════════════════════════════════════════════════
//                              枚举定义
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @notice 游戏状态枚举
 * @dev 每个玩家独立维护一份状态，状态转换流程：
 *      None → Committed（commit 成功）
 *      Committed → RandomRequested（reveal 成功）
 *      RandomRequested → None（VRF 回调结算）
 *      Committed → None（超时取消）
 *      RandomRequested → None（卡住取消）
 */
enum GameState {
    None,               // 空闲状态：可开始新局
    Committed,          // 已提交承诺：等待 reveal
    RandomRequested     // 已请求 VRF：等待回调结算
}

/**
 * @notice VRF 回调忽略原因枚举
 * @dev 用于 CallbackIgnored 事件，帮助定位回调异常原因
 */
enum CallbackIgnoreReason {
    UnknownRequestId,   // requestId 未映射到玩家（可能已 delete 或从未存在）
    InvalidGameState,   // 玩家状态不是 RandomRequested
    RequestIdMismatch,  // 玩家 requestId 已更新（retry 后旧回调到达）
    EmptyRandomWords    // randomWords 数组为空（防御式编程）
}

/**
 * @notice 推荐操作枚举
 * @dev 用于 PlayerDashboard，指示前端应显示的主要操作按钮
 */
enum NextAction {
    StartGame,          // 可开始新游戏 → 显示 "Start Game"
    WaitRevealWindow,   // 等待 reveal 窗口开启 → 显示倒计时
    Reveal,             // 可以 reveal → 显示 "Reveal"
    WaitVrf,            // 等待 VRF 回调 → 显示 "Waiting..."
    Retry,              // VRF 超时可重试 → 显示 "Retry"
    CancelExpired,      // reveal 过期可取消 → 显示 "Cancel & Refund"
    CancelStuck,        // VRF 卡住可强制取消 → 显示 "Emergency Cancel"
    Withdraw,           // 有余额可提现 → 显示 "Withdraw"
    Paused              // 合约已暂停 → 显示 "Game Paused"
}

// ═══════════════════════════════════════════════════════════════════════════
//                              核心数据结构
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @notice 玩家当前局的核心状态结构
 * @dev 每个玩家地址对应一个 PlayerState，存储在 _playerStates mapping 中
 *
 * @param commitHash 承诺哈希，由 keccak256(player, guess, secret, contract, chainid, nonce) 计算
 * @param commitTime commit 时间戳（秒），用于可观测性与调试
 * @param revealStart reveal 窗口起始时间 = commitTime + COMMIT_DURATION
 * @param revealDeadline reveal 截止时间 = revealStart + REVEAL_DURATION
 * @param guess 玩家猜测的点数（1~6），reveal 后写入
 * @param secret 玩家的秘密随机数，reveal 后写入，用于 Hybrid Mix
 * @param requestId VRF 请求 ID，用于匹配回调
 * @param vrfRequestTime VRF 请求发起时间，用于超时判断
 * @param nonce 防重放 nonce，每完成一局递增（无论输赢/取消）
 * @param retryCount VRF 重试次数，上限为 MAX_RETRIES
 * @param feePaid 当局已扣除的手续费，cancel 时用于计算退款
 * @param state 当前游戏状态
 */
struct PlayerState {
    bytes32 commitHash;
    uint64 commitTime;
    uint64 revealStart;
    uint64 revealDeadline;
    uint8 guess;
    bytes32 secret;
    uint256 requestId;
    uint64 vrfRequestTime;
    uint32 nonce;
    uint8 retryCount;
    uint256 feePaid;
    GameState state;
}

/**
 * @notice 玩家上一局结果结构
 * @dev 链上仅保留上一局结果，全量历史通过 Settled 事件追溯
 *
 * @param settledTime 结算时间戳（秒）
 * @param requestId 对应的 VRF 请求 ID
 * @param roll 掷骰结果（1~6）
 * @param guess 玩家猜测的点数（1~6）
 * @param won 是否中奖
 * @param payout 实际派奖金额（中奖为 PRIZE_AMOUNT，否则为 0）
 */
struct LastResult {
    uint64 settledTime;
    uint256 requestId;
    uint8 roll;
    uint8 guess;
    bool won;
    uint256 payout;
}

// ═══════════════════════════════════════════════════════════════════════════
//                           Lens 聚合结构（只读）
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @notice 玩家仪表盘结构（供 GameLens 使用）
 * @dev 聚合玩家一屏 UI 所需的全部数据，前端一次调用即可渲染完整界面
 *
 * @param playerState 玩家当前局状态
 * @param lastResult 玩家上一局结果
 * @param canCommit 是否可以开始新游戏（!paused && state == None）
 * @param canReveal 是否可以 reveal（state == Committed && 在 reveal 窗口内）
 * @param canRetry 是否可以重试 VRF（state == RandomRequested && VRF 超时 && retryCount < MAX）
 * @param canCancelExpired 是否可以取消过期游戏（state == Committed && 已过 deadline）
 * @param canCancelStuck 是否可以强制取消（state == RandomRequested && 卡住超过 24h）
 * @param canWithdraw 是否有余额可提现
 * @param timeUntilRevealStart 距离 reveal 窗口开启的剩余秒数（0 表示已可 reveal）
 * @param timeUntilRevealDeadline 距离 reveal 截止的剩余秒数（0 表示已过期）
 * @param timeUntilCanRetry 距离可重试 VRF 的剩余秒数（0 表示已可重试）
 * @param timeUntilCanCancelStuck 距离可强制取消的剩余秒数（0 表示已可取消）
 * @param pendingWithdrawal 玩家待提现余额
 * @param nextNonce 下一次 commit 应使用的 nonce
 * @param paused 合约是否已暂停
 * @param nextAction 推荐的下一步操作（用于前端按钮高亮）
 */
struct PlayerDashboard {
    PlayerState playerState;
    LastResult lastResult;
    bool canCommit;
    bool canReveal;
    bool canRetry;
    bool canCancelExpired;
    bool canCancelStuck;
    bool canWithdraw;
    uint256 timeUntilRevealStart;
    uint256 timeUntilRevealDeadline;
    uint256 timeUntilCanRetry;
    uint256 timeUntilCanCancelStuck;
    uint256 pendingWithdrawal;
    uint32 nextNonce;
    bool paused;
    NextAction nextAction;
}

/**
 * @notice 全局信息结构（供 GameLens 使用）
 * @dev 聚合合约级别的资金与配置信息，用于前端顶部面板展示
 *
 * @param paused 合约是否已暂停
 * @param balance 合约总余额
 * @param reserved 已保留总额（pending + fees + inFlight）
 * @param available 可用奖池余额
 * @param pendingWithdrawals 全体玩家待提现总额
 * @param protocolFees 协议累计手续费
 * @param inFlightReserve 在途游戏预留金额（每局 PRIZE_AMOUNT）
 * @param betAmount 单局下注金额（常量）
 * @param prizeAmount 胜利奖金（常量）
 */
struct GlobalInfo {
    bool paused;
    uint256 balance;
    uint256 reserved;
    uint256 available;
    uint256 pendingWithdrawals;
    uint256 protocolFees;
    uint256 inFlightReserve;
    uint256 betAmount;
    uint256 prizeAmount;
}

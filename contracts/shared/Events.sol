// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CallbackIgnoreReason} from "./Types.sol";

/**
 * @title Events
 * @notice 混合随机骰子游戏的事件定义
 * @dev 所有事件集中定义，方便链下索引和前端监听
 *      历史数据完全依赖事件追踪（链上仅保留最近一局结果）
 */

// ═══════════════════════════════════════════════════════════════════════════
//                           奖池事件
// ═══════════════════════════════════════════════════════════════════════════

/// @notice 奖池注资事件
/// @param funder 注资者地址
/// @param amount 注资金额（ETH）
event PrizePoolFunded(address indexed funder, uint256 amount);

// ═══════════════════════════════════════════════════════════════════════════
//                           游戏流程事件
// ═══════════════════════════════════════════════════════════════════════════

/// @notice 玩家提交承诺事件
/// @param player 玩家地址
/// @param commitHash 承诺哈希
/// @param commitTime commit 时间戳
/// @param revealStart reveal 窗口起始时间
/// @param revealDeadline reveal 截止时间
/// @param nonce 本局使用的 nonce
event Committed(
    address indexed player,
    bytes32 indexed commitHash,
    uint256 commitTime,
    uint256 revealStart,
    uint256 revealDeadline,
    uint32 nonce
);

/// @notice VRF 请求发起事件
/// @param player 玩家地址
/// @param requestId VRF 请求 ID
event RandomnessRequested(address indexed player, uint256 indexed requestId);

/// @notice VRF 请求重试事件
/// @param player 玩家地址
/// @param oldRequestId 旧的 VRF 请求 ID
/// @param newRequestId 新的 VRF 请求 ID
event VrfRequestRetried(
    address indexed player,
    uint256 indexed oldRequestId,
    uint256 indexed newRequestId
);

/// @notice 游戏结算事件
/// @param player 玩家地址
/// @param requestId VRF 请求 ID
/// @param roll 掷骰结果（1~6）
/// @param guess 玩家猜测（1~6）
/// @param won 是否中奖
/// @param payout 派奖金额
event Settled(
    address indexed player,
    uint256 indexed requestId,
    uint256 roll,
    uint256 guess,
    bool won,
    uint256 payout
);

/// @notice 玩家取消游戏事件
/// @param player 玩家地址
/// @param refund 退款金额
event Cancelled(address indexed player, uint256 refund);

/// @notice 卡住的游戏被强制取消事件
/// @param player 玩家地址
/// @param refund 退款金额
event StuckGameCancelled(address indexed player, uint256 refund);

// ═══════════════════════════════════════════════════════════════════════════
//                           提现事件
// ═══════════════════════════════════════════════════════════════════════════

/// @notice 玩家提现事件
/// @param player 玩家地址
/// @param amount 提现金额
event Withdrawn(address indexed player, uint256 amount);

/// @notice 协议手续费提取事件
/// @param feeRecipient 手续费接收地址
/// @param amount 提取金额
event ProtocolFeesWithdrawn(address indexed feeRecipient, uint256 amount);

// ═══════════════════════════════════════════════════════════════════════════
//                           手续费事件
// ═══════════════════════════════════════════════════════════════════════════

/// @notice 手续费配置更新事件
/// @param feeRecipient 新的手续费接收地址
/// @param feeBps 新的手续费率
event FeeConfigUpdated(address indexed feeRecipient, uint16 feeBps);

/// @notice 手续费扣除事件
/// @param player 被扣费的玩家
/// @param feeRecipient 手续费接收地址
/// @param fee 扣除的手续费金额（ETH）
event FeeCharged(address indexed player, address indexed feeRecipient, uint256 fee);

// ═══════════════════════════════════════════════════════════════════════════
//                           VRF 事件
// ═══════════════════════════════════════════════════════════════════════════

/// @notice VRF 配置更新事件
/// @param callbackGasLimit 新的回调 gas 上限
/// @param requestConfirmations 新的确认数
/// @param numWords 新的随机数数量
event VrfConfigUpdated(uint32 callbackGasLimit, uint16 requestConfirmations, uint32 numWords);

/// @notice VRF 回调被忽略事件
/// @dev 生产环境中用于监控和排查 VRF 回调异常
/// @param requestId VRF 请求 ID
/// @param player 玩家地址（可能为 address(0)）
/// @param reason 忽略原因
event CallbackIgnored(
    uint256 indexed requestId,
    address indexed player,
    CallbackIgnoreReason reason
);

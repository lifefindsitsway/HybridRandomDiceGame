// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Errors
 * @notice 混合随机骰子游戏的自定义错误定义
 * @dev 使用自定义错误替代 require 字符串，节省 gas 并提供更好的错误信息
 */

// ═══════════════════════════════════════════════════════════════════════════
//                           参数校验错误
// ═══════════════════════════════════════════════════════════════════════════

/// @notice guess 必须在 1~6 范围内
error InvalidGuess();

/// @notice commitHash 不能为 bytes32(0)
error ZeroCommitHash();

/// @notice 下注金额必须严格等于 BET_AMOUNT
error IncorrectBetAmount();

// ═══════════════════════════════════════════════════════════════════════════
//                           状态机错误
// ═══════════════════════════════════════════════════════════════════════════

/// @notice 玩家已有进行中的游戏（Committed/RandomRequested）
error GameAlreadyActive();

/// @notice 当前没有可操作的游戏（状态不符合预期）
error NoActiveGame();

/// @notice 当前不是等待 VRF 回调状态
error NotWaitingVrf();

// ═══════════════════════════════════════════════════════════════════════════
//                           时间窗口错误
// ═══════════════════════════════════════════════════════════════════════════

/// @notice commit 冷却期未结束，不能 reveal
error CommitPhaseNotOver();

/// @notice reveal 截止时间已过
error RevealPhaseOver();

/// @notice reveal 尚未过期，不能取消
error RevealNotExpired();

/// @notice VRF 未超时，不能 retry
error VrfTimeoutNotReached();

/// @notice VRF 重试次数已达上限
error MaxRetriesReached();

/// @notice 游戏未卡住足够长时间，不能强制取消
error NotStuckYet();

// ═══════════════════════════════════════════════════════════════════════════
//                           验证错误
// ═══════════════════════════════════════════════════════════════════════════

/// @notice reveal 信息不匹配 commitHash（guess/secret/nonce 不对）
error InvalidReveal();

// ═══════════════════════════════════════════════════════════════════════════
//                           资金相关错误
// ═══════════════════════════════════════════════════════════════════════════

/// @notice 奖池不足以覆盖 PRIZE_AMOUNT
error PrizePoolInsufficient();

/// @notice 没有可提现余额
error NothingToWithdraw();

/// @notice 转账失败
error WithdrawFailed();

// ═══════════════════════════════════════════════════════════════════════════
//                           手续费相关错误
// ═══════════════════════════════════════════════════════════════════════════

/// @notice feeRecipient 不能为零地址
error FeeRecipientZeroAddress();

/// @notice feeBps 超过上限 MAX_FEE_BPS
error FeeTooHigh();

/// @notice 非 feeRecipient 无权提取手续费
error NotFeeRecipient();

// ═══════════════════════════════════════════════════════════════════════════
//                           VRF 配置错误
// ═══════════════════════════════════════════════════════════════════════════

/// @notice VRF 配置参数非法
error InvalidVrfConfig();

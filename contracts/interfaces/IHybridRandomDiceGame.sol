// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PlayerState, LastResult} from "../shared/Types.sol";

/**
 * @title IHybridRandomDiceGame
 * @notice 混合随机骰子游戏的接口定义
 * @dev 定义所有外部可调用的函数，供前端和其他合约使用
 *
 * 接口设计说明：
 * 本接口不包含以下自动生成的 getter（避免 override 冲突）：
 * - 常量: BET_AMOUNT, PRIZE_AMOUNT, COMMIT_DURATION, REVEAL_DURATION, ...
 * - 不可变量: subscriptionId, keyHash
 * - 状态变量: feeRecipient, feeBps, protocolFeesAccrued, ...
 * - Mapping: pendingWithdrawals, requestToPlayer
 *
 * 这些可以直接通过合约地址调用，无需在接口中声明。
 */
interface IHybridRandomDiceGame {
    // ═══════════════════════════════════════════════════════════════════════════
    //                              玩家操作
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 提交游戏承诺
     * @dev 必须发送 BET_AMOUNT (0.001 ETH)
     * @param commitHash 承诺哈希 = keccak256(player, guess, secret, contract, chainId, nonce)
     */
    function commit(bytes32 commitHash) external payable;

    /**
     * @notice 揭示猜测并请求 VRF 随机数
     * @dev 只能在 Reveal 窗口内调用（commit 后 60s~180s）
     * @param guess 玩家猜测的点数（1-6）
     * @param secret 玩家的 secret（必须与 commit 时一致）
     * @return requestId VRF 请求 ID
     */
    function revealAndRequestRandom(uint8 guess, bytes32 secret) external returns (uint256 requestId);

    /**
     * @notice 重试 VRF 请求
     * @dev VRF 超过 10 分钟未响应时可调用，最多重试 3 次
     * @return newRequestId 新的 VRF 请求 ID
     */
    function retryVrfRequest() external returns (uint256 newRequestId);

    /**
     * @notice 取消过期的 Commit
     * @dev Reveal 窗口过期后可调用，退款约 50%
     */
    function cancelExpiredCommitment() external;

    /**
     * @notice 取消卡住的游戏
     * @dev VRF 超过 24 小时未响应时可调用，退款 100%
     */
    function cancelStuckGame() external;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              资金操作
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 提取玩家累积的奖金
     * @dev Pull Payment 模式，玩家主动提取
     */
    function withdraw() external;

    /**
     * @notice 提取协议手续费
     * @dev 仅手续费接收地址可调用
     * @param amount 提取金额
     */
    function withdrawProtocolFees(uint256 amount) external;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              管理员操作
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 更新手续费配置
     * @dev 仅 owner 可调用
     * @param _feeRecipient 新的手续费接收地址
     * @param _feeBps 新的手续费率（基点）
     */
    function setFeeConfig(address _feeRecipient, uint16 _feeBps) external;

    /**
     * @notice 更新 VRF 配置
     * @dev 仅 owner 可调用
     * @param _callbackGasLimit 回调 Gas 上限
     * @param _requestConfirmations 区块确认数
     * @param _numWords 请求的随机数个数
     */
    function setVrfConfig(uint32 _callbackGasLimit, uint16 _requestConfirmations, uint32 _numWords) external;

    /**
     * @notice 暂停游戏
     * @dev 仅阻止新的 commit，不影响已开始的游戏
     */
    function pause() external;

    /**
     * @notice 恢复游戏
     */
    function unpause() external;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              状态查询
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 获取玩家当前游戏状态
     * @param player 玩家地址
     * @return 玩家状态结构体
     */
    function getPlayerState(address player) external view returns (PlayerState memory);

    /**
     * @notice 获取玩家上一局结果
     * @param player 玩家地址
     * @return 上一局结果结构体
     */
    function getLastResult(address player) external view returns (LastResult memory);

    /**
     * @notice 获取玩家下一次 commit 应使用的 nonce
     * @param player 玩家地址
     * @return nonce 值
     */
    function getNextNonce(address player) external view returns (uint32);

    /**
     * @notice 获取可用奖池余额
     * @return 可用于支付奖金的余额
     */
    function availablePrizeBalance() external view returns (uint256);

    /**
     * @notice 获取资金分布详情
     * @return balance 合约总余额
     * @return reserved 已预留总额
     * @return available 可用奖池
     * @return pending 玩家待提现总额
     * @return feesAccrued 累计协议手续费
     * @return inFlight 在途游戏预留
     */
    function getReservedBalance()
        external
        view
        returns (
            uint256 balance,
            uint256 reserved,
            uint256 available,
            uint256 pending,
            uint256 feesAccrued,
            uint256 inFlight
        );

    // ═══════════════════════════════════════════════════════════════════════════
    //                              可操作性检查
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 检查玩家是否可以开始新游戏
     * @param player 玩家地址
     * @return 是否可以 commit
     */
    function canCommit(address player) external view returns (bool);

    /**
     * @notice 检查玩家是否可以 Reveal
     * @param player 玩家地址
     * @return 是否可以 reveal
     */
    function canReveal(address player) external view returns (bool);

    /**
     * @notice 检查玩家是否可以重试 VRF
     * @param player 玩家地址
     * @return 是否可以 retry
     */
    function canRetry(address player) external view returns (bool);

    /**
     * @notice 检查玩家是否可以强制取消
     * @param player 玩家地址
     * @return 是否可以强制取消
     */
    function canCancelStuck(address player) external view returns (bool);

    /**
     * @notice 检查玩家是否可以取消过期游戏
     * @param player 玩家地址
     * @return 是否可以取消
     */
    function canCancelExpired(address player) external view returns (bool);

    /**
     * @notice 获取时间信息（用于前端倒计时）
     * @param player 玩家地址
     * @return timeUntilRevealStart 距离 Reveal 窗口开启的剩余秒数
     * @return timeUntilRevealDeadline 距离 Reveal 截止的剩余秒数
     * @return timeUntilCanRetry 距离可重试的剩余秒数
     * @return timeUntilCanCancelStuck 距离可强制取消的剩余秒数
     */
    function getTimeInfo(address player)
        external
        view
        returns (
            uint256 timeUntilRevealStart,
            uint256 timeUntilRevealDeadline,
            uint256 timeUntilCanRetry,
            uint256 timeUntilCanCancelStuck
        );

    // ═══════════════════════════════════════════════════════════════════════════
    //                              工具函数
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 计算 commitHash
     * @dev 前端辅助函数，避免 abi.encode 编码不一致
     * @param player 玩家地址
     * @param guess 猜测的点数（1-6）
     * @param secret 玩家生成的 secret
     * @param nonce 游戏 nonce
     * @return commitHash
     */
    function computeCommitHash(
        address player,
        uint8 guess,
        bytes32 secret,
        uint32 nonce
    ) external view returns (bytes32);
}

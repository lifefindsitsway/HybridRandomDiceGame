// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VrfBase} from "./VrfBase.sol";

import {
    FeeRecipientZeroAddress,
    FeeTooHigh,
    NotFeeRecipient,
    NothingToWithdraw,
    WithdrawFailed
} from "../shared/Errors.sol";

import {
    FeeConfigUpdated,
    Withdrawn,
    ProtocolFeesWithdrawn
} from "../shared/Events.sol";

/**
 * @title FundsBase
 * @notice 资金管理基础合约
 * @dev 处理下注、奖金、手续费、提现等所有资金相关逻辑
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              资金流模型
 * ══════════════════════════════════════════════════════════════════════════════
 *
 *                    ┌─────────────────────────────────────────┐
 *                    │           合约总余额 (balance)           │
 *                    └─────────────────────────────────────────┘
 *                                       │
 *          ┌────────────────────────────┼────────────────────────────┐
 *          │                            │                            │
 *          ▼                            ▼                            ▼
 *  ┌───────────────┐          ┌─────────────────┐          ┌─────────────────┐
 *  │ 待提现余额     │          │ 协议手续费       │          │ 在途游戏预留     │
 *  │ (pending)     │          │ (feesAccrued)   │          │ (inFlight)      │
 *  └───────────────┘          └─────────────────┘          └─────────────────┘
 *          │                            │                            │
 *          └────────────────────────────┼────────────────────────────┘
 *                                       │
 *                                       ▼
 *                          ┌─────────────────────────┐
 *                          │ 已预留总额 (reserved)    │
 *                          │ = pending + fees +      │
 *                          │   inFlight              │
 *                          └─────────────────────────┘
 *                                       │
 *                                       ▼
 *                          ┌─────────────────────────┐
 *                          │ 可用奖池 (available)     │
 *                          │ = balance - reserved    │
 *                          └─────────────────────────┘
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                           为什么需要"在途游戏预留"
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 问题场景（如果不预留）：
 * 1. 奖池有 0.005 ETH
 * 2. 玩家 A reveal（检查通过：available >= PRIZE_AMOUNT）
 * 3. 玩家 B 同时 reveal（检查也通过）
 * 4. 两人都可能赢，但奖池只够付一个人
 *
 * 解决方案：
 * - reveal 时：reservedForInFlightGames += PRIZE_AMOUNT
 * - 结算时：reservedForInFlightGames -= PRIZE_AMOUNT
 * - 这样 available 会正确反映"还能支持几局游戏"
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              提现模式：Pull Payment
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 本合约采用 Pull Payment 模式而非直接转账：
 * - 玩家获胜后，奖金记入 pendingWithdrawals 而非立即转账
 * - 玩家需要主动调用 withdraw() 提取
 *
 * 为什么这样设计：
 * 1. 防止重入攻击
 * 2. 避免转账失败导致整个交易回滚
 * 3. 玩家可以累积多局奖金后一次提取（省 gas）
 */
abstract contract FundsBase is VrfBase {
    //手续费配置（协议收入模型）
    uint256 public constant BET_AMOUNT = 0.001 ether;           // 单局下注金额
    uint256 public constant PRIZE_AMOUNT = 0.005 ether;         // 获胜奖金

    uint16 public constant MAX_FEE_BPS = 500;                   // 手续费上限（基点，500 = 5%）
    uint16 public feeBps;                                       // 手续费率（基点，100 = 1%）
    address public feeRecipient;                                // 手续费接收地址
    uint256 public protocolFeesAccrued;                         // 累计待提取的协议手续费

    //玩家资金
    mapping(address => uint256) public pendingWithdrawals;      // 玩家待提现余额
    uint256 public totalPendingWithdrawals;                     // 所有玩家待提现余额总和
    uint256 public reservedForInFlightGames;    // 在途游戏预留金额（每局 reveal 时 +PRIZE_AMOUNT，结算时 -PRIZE_AMOUNT）

    // ═══════════════════════════════════════════════════════════════════════════
    //                              内部函数
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 初始化手续费模块
     * @dev 在构造函数中调用，设置初始手续费配置
     * @param _feeRecipient 手续费接收地址（不能为零地址）
     * @param _feeBps 手续费率（不能超过 MAX_FEE_BPS）
     */
    function _initFeeModule(address _feeRecipient, uint16 _feeBps) internal {
        if (_feeRecipient == address(0)) revert FeeRecipientZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        feeRecipient = _feeRecipient;
        feeBps = _feeBps;

        emit FeeConfigUpdated(_feeRecipient, _feeBps);
    }

    /**
     * @notice 计算可用奖池余额
     * @dev 扣除所有已预留金额后的可用余额
     * @return 可用于支付新游戏奖金的余额
     */
    function _availablePrizeBalance() internal view returns (uint256) {
        uint256 reserved = totalPendingWithdrawals + protocolFeesAccrued + reservedForInFlightGames;
        uint256 bal = address(this).balance;
        if (bal <= reserved) return 0;
        return bal - reserved;
    }

    /**
     * @notice 玩家提现
     * @dev Pull Payment 模式，玩家主动提取累积的奖金
     * @param player 玩家地址
     */
    function _withdraw(address player) internal {
        uint256 amount = pendingWithdrawals[player];
        if (amount == 0) revert NothingToWithdraw();

        // 先清零再转账（防重入）
        pendingWithdrawals[player] = 0;
        totalPendingWithdrawals -= amount;

        (bool ok, ) = player.call{value: amount}("");
        if (!ok) revert WithdrawFailed();

        emit Withdrawn(player, amount);
    }

    /**
     * @notice 提取协议手续费
     * @dev 仅手续费接收地址可调用
     * @param amount 提取金额（不能超过累计手续费）
     */
    function _withdrawProtocolFees(uint256 amount) internal {
        if (msg.sender != feeRecipient) revert NotFeeRecipient();
        if (amount == 0 || amount > protocolFeesAccrued) revert NothingToWithdraw();

        protocolFeesAccrued -= amount;

        (bool ok, ) = feeRecipient.call{value: amount}("");
        if (!ok) revert WithdrawFailed();

        emit ProtocolFeesWithdrawn(feeRecipient, amount);
    }

    /**
     * @notice 更新手续费配置
     * @dev 仅 owner 可调用（通过上层合约的权限控制）
     * @param _feeRecipient 新的手续费接收地址
     * @param _feeBps 新的手续费率
     */
    function _setFeeConfig(address _feeRecipient, uint16 _feeBps) internal {
        if (_feeRecipient == address(0)) revert FeeRecipientZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        feeRecipient = _feeRecipient;
        feeBps = _feeBps;

        emit FeeConfigUpdated(_feeRecipient, _feeBps);
    }

    /**
     * @notice 获取资金分布详情
     * @dev 用于前端展示和 GameLens 聚合
     * @return balance 合约总余额
     * @return reserved 已预留总额
     * @return available 可用奖池余额
     * @return pending 玩家待提现总额
     * @return feesAccrued 累计协议手续费
     * @return inFlight 在途游戏预留
     */
    function _getReservedBalance()
        internal
        view
        returns (
            uint256 balance,
            uint256 reserved,
            uint256 available,
            uint256 pending,
            uint256 feesAccrued,
            uint256 inFlight
        )
    {
        balance = address(this).balance;
        pending = totalPendingWithdrawals;
        feesAccrued = protocolFeesAccrued;
        inFlight = reservedForInFlightGames;
        reserved = pending + feesAccrued + inFlight;
        available = balance > reserved ? balance - reserved : 0;
    }
}

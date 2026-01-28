// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {CommitRevealBase} from "../base/CommitRevealBase.sol";
import {VrfBase} from "../base/VrfBase.sol";
import {HashLib} from "../libraries/HashLib.sol";
import {PlayerState, LastResult} from "../shared/Types.sol";
import {PrizePoolFunded} from "../shared/Events.sol";
import {IHybridRandomDiceGame} from "../interfaces/IHybridRandomDiceGame.sol";

/**
 * @title HybridRandomDiceGame
 * @author Lifefindsitsway
 * @notice 混合随机骰子游戏 - 主合约
 * @dev 组合所有模块，提供完整的游戏功能
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              合约架构
 * ══════════════════════════════════════════════════════════════════════════════
 *
 *   ┌──────────────────────────────────────────────────────────────────────────┐
 *   │                     HybridRandomDiceGame（主合约）                        │
 *   │                                                                          │
 *   │  ┌─────────────────────────────────────────────────────────────────────┐ │
 *   │  │                    CommitRevealBase（核心状态机）                    │ │
 *   │  │  - Commit/Reveal 机制                                               │ │
 *   │  │  - VRF 回调处理                                                      │ │
 *   │  │  - 游戏结算逻辑                                                      │ │
 *   │  │                                                                     │ │
 *   │  │  ┌─────────────────────────────────────────────────────────────────┐│ │
 *   │  │  │                   FundsBase（资金管理）                          ││ │
 *   │  │  │  - 下注/奖金/手续费                                              ││ │
 *   │  │  │  - 提现逻辑                                                      ││ │
 *   │  │  │  - 奖池预留机制                                                  ││ │
 *   │  │  │                                                                 ││ │
 *   │  │  │  ┌─────────────────────────────────────────────────────────────┐││ │
 *   │  │  │  │                VrfBase（VRF 集成）                           │││ │
 *   │  │  │  │  - Chainlink VRF V2 Plus                                    │││ │
 *   │  │  │  │  - 请求/回调管理                                             │││ │
 *   │  │  │  │                                                             │││ │
 *   │  │  │  │  ┌─────────────────────────────────────────────────────┐    │││ │
 *   │  │  │  │  │         VRFConsumerBaseV2Plus (Chainlink)           │    │││ │
 *   │  │  │  │  └─────────────────────────────────────────────────────┘    │││ │
 *   │  │  │  └─────────────────────────────────────────────────────────────┘││ │
 *   │  │  └─────────────────────────────────────────────────────────────────┘│ │
 *   │  └─────────────────────────────────────────────────────────────────────┘ │
 *   │                                                                          │
 *   │  + Pausable (OpenZeppelin)      - 紧急暂停功能                            │
 *   │  + ReentrancyGuard (OpenZeppelin) - 防重入保护                            │
 *   │  + IHybridRandomDiceGame        - 接口实现                                │
 *   └──────────────────────────────────────────────────────────────────────────┘
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              功能分类
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 【玩家操作】
 *   commit()                  - 提交游戏承诺（支付 0.001 ETH）
 *   revealAndRequestRandom()  - 揭示猜测，请求 VRF
 *   retryVrfRequest()         - 重试 VRF 请求（超时后）
 *   cancelExpiredCommitment() - 取消过期 commit（退款 50%）
 *   cancelStuckGame()         - 取消卡住的游戏（退款 100%）
 *   withdraw()                - 提取累积的奖金
 *
 * 【管理员操作】
 *   setFeeConfig()            - 更新手续费配置
 *   setVrfConfig()            - 更新 VRF 配置
 *   withdrawProtocolFees()    - 提取协议手续费
 *   pause() / unpause()       - 暂停/恢复游戏
 *
 * 【查询函数】
 *   getPlayerState()          - 获取玩家当前状态
 *   getLastResult()           - 获取玩家上局结果
 *   getNextNonce()            - 获取下一次 commit 的 nonce
 *   canCommit/canReveal/...   - 检查各操作是否可执行
 *   getTimeInfo()             - 获取倒计时信息
 *   computeCommitHash()       - 计算 commitHash（前端辅助）
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              暂停机制说明
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * pause() 只阻止新游戏开始（commit），不阻止：
 *   - reveal（已 commit 的玩家可以继续）
 *   - retry（等待 VRF 的玩家可以重试）
 *   - cancel（任何时候都可以取消）
 *   - withdraw（任何时候都可以提现）
 *
 * 这样设计是为了保护已经参与的玩家，不会因为紧急暂停而被迫损失资金。
 */
contract HybridRandomDiceGame is CommitRevealBase, Pausable, ReentrancyGuard, IHybridRandomDiceGame {

    // ═══════════════════════════════════════════════════════════════════════════
    //                              构造函数
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 部署游戏合约
     * @param coordinator Chainlink VRF Coordinator 地址
     * @param subId VRF 订阅 ID
     * @param gasLane Gas Lane 的 keyHash
     * @param _feeRecipient 手续费接收地址
     * @param _feeBps 手续费率（基点，100 = 1%）
     */
    constructor(
        address coordinator,
        uint256 subId,
        bytes32 gasLane,
        address _feeRecipient,
        uint16 _feeBps
    ) VrfBase(coordinator, subId, gasLane) {
        _initFeeModule(_feeRecipient, _feeBps);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              资金接收
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice 接收 ETH 注入奖池
     * @dev 任何人都可以向合约转账，增加奖池
     */
    receive() external payable {
        emit PrizePoolFunded(msg.sender, msg.value);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              玩家操作
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IHybridRandomDiceGame
    function commit(bytes32 commitHash) external payable nonReentrant whenNotPaused {
        _commit(commitHash);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function revealAndRequestRandom(
        uint8 guess,
        bytes32 secret
    ) external nonReentrant returns (uint256 requestId) {
        return _revealAndRequestRandom(guess, secret);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function retryVrfRequest() external nonReentrant returns (uint256 newRequestId) {
        return _retryVrfRequest();
    }

    /// @inheritdoc IHybridRandomDiceGame
    function cancelExpiredCommitment() external nonReentrant {
        _cancelExpiredCommitment();
    }

    /// @inheritdoc IHybridRandomDiceGame
    function cancelStuckGame() external nonReentrant {
        _cancelStuckGame();
    }

    /// @inheritdoc IHybridRandomDiceGame
    function withdraw() external nonReentrant {
        _withdraw(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              VRF 回调
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice VRF 回调函数
     * @dev 由 Chainlink VRF Coordinator 调用，不能直接调用
     * @param requestId VRF 请求 ID
     * @param randomWords 随机数数组
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        _handleFulfillRandomWords(requestId, randomWords);
    }

    /**
     * @notice 将随机数转换为骰子点数
     * @dev 实现 CommitRevealBase 的抽象函数
     * @param entropy 混合后的随机数
     * @return 骰子点数（1-6）
     */
    function _toDice(uint256 entropy) internal pure override returns (uint8) {
        return uint8((entropy % 6) + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              管理员操作
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IHybridRandomDiceGame
    function setFeeConfig(address _feeRecipient, uint16 _feeBps) external onlyOwner {
        _setFeeConfig(_feeRecipient, _feeBps);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function setVrfConfig(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        uint32 _numWords
    ) external onlyOwner {
        _setVrfConfig(_callbackGasLimit, _requestConfirmations, _numWords);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function withdrawProtocolFees(uint256 amount) external nonReentrant {
        _withdrawProtocolFees(amount);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IHybridRandomDiceGame
    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              查询函数
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IHybridRandomDiceGame
    function getPlayerState(address player) external view returns (PlayerState memory) {
        return _playerStates[player];
    }

    /// @inheritdoc IHybridRandomDiceGame
    function getLastResult(address player) external view returns (LastResult memory) {
        return _lastResults[player];
    }

    /// @inheritdoc IHybridRandomDiceGame
    function getNextNonce(address player) external view returns (uint32) {
        return _playerStates[player].nonce + 1;
    }

    /// @inheritdoc IHybridRandomDiceGame
    function availablePrizeBalance() external view returns (uint256) {
        return _availablePrizeBalance();
    }

    /// @inheritdoc IHybridRandomDiceGame
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
        )
    {
        return _getReservedBalance();
    }

    /// @inheritdoc IHybridRandomDiceGame
    function canCommit(address player) external view returns (bool) {
        return !paused() && _canCommitByState(player);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function canReveal(address player) external view returns (bool) {
        return _canReveal(player);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function canRetry(address player) external view returns (bool) {
        return _canRetry(player);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function canCancelStuck(address player) external view returns (bool) {
        return _canCancelStuck(player);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function canCancelExpired(address player) external view returns (bool) {
        return _canCancelExpired(player);
    }

    /// @inheritdoc IHybridRandomDiceGame
    function getTimeInfo(address player)
        external
        view
        returns (
            uint256 timeUntilRevealStart,
            uint256 timeUntilRevealDeadline,
            uint256 timeUntilCanRetry,
            uint256 timeUntilCanCancelStuck
        )
    {
        return _getTimeInfo(player);
    }

    /**
     * @notice 计算 commitHash（前端辅助函数）
     * @dev 前端可以直接调用此函数计算 hash，避免 abi.encode 编码不一致
     * @param player 玩家地址
     * @param guess 猜测的点数（1-6）
     * @param secret 玩家生成的 secret
     * @param nonce 游戏 nonce（使用 getNextNonce 获取）
     * @return commitHash 用于 commit 函数的哈希值
     */
    function computeCommitHash(
        address player,
        uint8 guess,
        bytes32 secret,
        uint32 nonce
    ) external view returns (bytes32) {
        return HashLib.computeCommitHash(player, guess, secret, address(this), block.chainid, nonce);
    }
}

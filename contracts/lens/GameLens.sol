// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    GameState,
    NextAction,
    PlayerState,
    LastResult,
    PlayerDashboard,
    GlobalInfo
} from "../shared/Types.sol";

/// @notice 游戏合约地址不能为零地址
error GameAddressZero();

/**
 * @title IGameCore
 * @notice GameLens 所需的核心合约接口
 * @dev 该接口是 HybridRandomDiceGame 合约的最小化子集，仅包含 Lens 聚合所需的 view 函数。
 *      独立定义而非直接使用 IHybridRandomDiceGame 的原因：
 *      - 部分函数（paused、pendingWithdrawals、BET_AMOUNT 等）是 Solidity 自动生成的 getter
 *      - 这些 getter 无法在接口中声明（会导致 override 冲突）
 *      - 保持 Lens 的编译时依赖最小化
 */
interface IGameCore {
    function getPlayerState(address player) external view returns (PlayerState memory);
    function getLastResult(address player) external view returns (LastResult memory);
    function getNextNonce(address player) external view returns (uint32);
    function getTimeInfo(address player)
        external
        view
        returns (
            uint256 timeUntilRevealStart,
            uint256 timeUntilRevealDeadline,
            uint256 timeUntilCanRetry,
            uint256 timeUntilCanCancelStuck
        );
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
    function canCommit(address player) external view returns (bool);
    function canReveal(address player) external view returns (bool);
    function canRetry(address player) external view returns (bool);
    function canCancelExpired(address player) external view returns (bool);
    function canCancelStuck(address player) external view returns (bool);
    function pendingWithdrawals(address player) external view returns (uint256);
    function paused() external view returns (bool);
    function BET_AMOUNT() external view returns (uint256);
    function PRIZE_AMOUNT() external view returns (uint256);
}

/**
 * @title GameLens
 * @notice 混合随机骰子游戏的只读聚合器合约
 * @dev 该合约的设计目标是：让前端通过一次 RPC 调用获取渲染完整 UI 所需的全部数据。
 *
 *
 * 设计原则：
 *
 * 1. 只读聚合（Read-Only Aggregator）
 *    - 不存储任何状态，不修改任何数据
 *    - 所有函数都是 view，可被任意调用而不消耗 gas（通过 eth_call）
 *    - 可随时替换/升级，不影响核心合约的资金与状态
 *
 * 2. 前端友好（Frontend-Friendly）
 *    - 返回"可直接渲染"的结构体，而非原始数据
 *    - 预计算按钮状态（canCommit、canReveal 等）
 *    - 预计算倒计时（timeUntilRevealStart 等）
 *    - 预计算推荐操作（nextAction）
 *
 * 3. 最小 RPC（Minimal RPC Calls）
 *    - getPlayerDashboard()：一次调用返回玩家完整状态
 *    - getGlobalInfo()：一次调用返回合约全局信息
 *
 *
 * NextAction 推导逻辑：
 *
 * 优先级从高到低（状态机关键操作优先于提现）：
 *
 * 1. state == Committed:
 *    - canCancelExpired → CancelExpired（过期取消，避免资金锁死）
 *    - canReveal → Reveal（核心流程）
 *    - else → WaitRevealWindow（等待窗口）
 *
 * 2. state == RandomRequested:
 *    - canCancelStuck → CancelStuck（卡住取消，紧急逃生）
 *    - canRetry → Retry（VRF 重试）
 *    - else → WaitVrf（等待回调）
 *
 * 3. canWithdraw → Withdraw（状态机空闲时才考虑提现）
 *
 * 4. state == None:
 *    - paused → Paused
 *    - else → StartGame
 *
 * 这样设计的原因：
 * - 进行中的游戏有时间限制（reveal deadline、VRF timeout）
 * - Withdraw 没有时间限制，随时可以提
 * - 避免用户被 Withdraw 按钮"带偏"而错过关键窗口
 *
 *
 * 使用示例
 *
 * ```javascript
 * // 部署时传入主合约地址
 * const lens = new ethers.Contract(lensAddress, GameLensABI, provider);
 *
 * // 获取玩家仪表盘
 * const d = await lens.getPlayerDashboard(playerAddress);
 * console.log("State:", d.playerState.state);
 * console.log("Next Action:", d.nextAction);
 * console.log("Can Reveal:", d.canReveal);
 *
 * // 获取全局信息
 * const g = await lens.getGlobalInfo();
 * console.log("Prize Pool:", g.available);
 * ```
 */
contract GameLens {
    /// @notice 核心游戏合约地址（不可变）
    IGameCore public immutable game;

    /**
     * @notice 构造函数
     * @param _game 核心游戏合约地址
     */
    constructor(address _game) {
        if (_game == address(0)) revert GameAddressZero();
        game = IGameCore(_game);
    }

    /**
     * @notice 获取玩家仪表盘数据
     * @dev 聚合玩家一屏 UI 所需的全部数据，前端一次调用即可渲染完整界面
     * @param player 玩家地址
     * @return d 玩家仪表盘结构体
     */
    function getPlayerDashboard(address player) external view returns (PlayerDashboard memory d) {
        // 核心状态
        d.playerState = game.getPlayerState(player);
        d.lastResult = game.getLastResult(player);

        // 可操作性布尔值
        d.canCommit = game.canCommit(player);
        d.canReveal = game.canReveal(player);
        d.canRetry = game.canRetry(player);
        d.canCancelExpired = game.canCancelExpired(player);
        d.canCancelStuck = game.canCancelStuck(player);

        // 提现相关
        d.pendingWithdrawal = game.pendingWithdrawals(player);
        d.canWithdraw = d.pendingWithdrawal > 0;

        // 倒计时信息
        (
            d.timeUntilRevealStart,
            d.timeUntilRevealDeadline,
            d.timeUntilCanRetry,
            d.timeUntilCanCancelStuck
        ) = game.getTimeInfo(player);

        // 辅助信息
        d.nextNonce = game.getNextNonce(player);
        d.paused = game.paused();

        // 推导推荐操作
        d.nextAction = _computeNextAction(d);
    }

    /**
     * @notice 获取全局信息
     * @dev 聚合合约级别的资金与配置信息，用于前端顶部面板展示
     * @return g 全局信息结构体
     */
    function getGlobalInfo() external view returns (GlobalInfo memory g) {
        g.paused = game.paused();

        (
            g.balance,
            g.reserved,
            g.available,
            g.pendingWithdrawals,
            g.protocolFees,
            g.inFlightReserve
        ) = game.getReservedBalance();

        g.betAmount = game.BET_AMOUNT();
        g.prizeAmount = game.PRIZE_AMOUNT();
    }

    /**
     * @notice 推导推荐的下一步操作
     * @dev 按优先级推导：状态机关键操作 > 提现 > 开始新游戏
     * @param d 玩家仪表盘数据
     * @return 推荐的 NextAction 枚举值
     */
    function _computeNextAction(PlayerDashboard memory d) internal pure returns (NextAction) {
        GameState state = d.playerState.state;

        // 优先级 1：Committed 状态的关键操作（有时间限制）
        if (state == GameState.Committed) {
            if (d.canCancelExpired) {
                return NextAction.CancelExpired;
            }
            if (d.canReveal) {
                return NextAction.Reveal;
            }
            return NextAction.WaitRevealWindow;
        }

        // 优先级 2：RandomRequested 状态的关键操作（有时间限制）
        if (state == GameState.RandomRequested) {
            if (d.canCancelStuck) {
                return NextAction.CancelStuck;
            }
            if (d.canRetry) {
                return NextAction.Retry;
            }
            return NextAction.WaitVrf;
        }

        // 优先级 3：状态机空闲时考虑提现（无时间限制）
        if (d.canWithdraw) {
            return NextAction.Withdraw;
        }

        // 优先级 4：开始新游戏或显示暂停
        if (d.paused) {
            return NextAction.Paused;
        }
        return NextAction.StartGame;
    }
}

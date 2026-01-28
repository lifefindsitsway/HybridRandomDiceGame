// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import {InvalidVrfConfig} from "../shared/Errors.sol";
import {VrfConfigUpdated} from "../shared/Events.sol";

/**
 * @title VrfBase
 * @notice Chainlink VRF V2 Plus 集成基础合约
 * @dev 封装 VRF 请求逻辑，为上层合约提供可验证随机数服务
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              继承关系
 * ══════════════════════════════════════════════════════════════════════════════
 *
 *   VRFConsumerBaseV2Plus (Chainlink)
 *           │
 *           ▼
 *       VrfBase ◄─── 本合约
 *           │
 *           ▼
 *      FundsBase
 *           │
 *           ▼
 *   CommitRevealBase
 *           │
 *           ▼
 *  HybridRandomDiceGame
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                           Chainlink VRF 工作原理
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 1. 请求阶段：
 *    - 合约调用 requestRandomWords() 向 VRF Coordinator 发起请求
 *    - 返回 requestId 用于后续匹配回调
 *
 * 2. 链下计算：
 *    - Chainlink 节点收到请求后，使用私钥生成随机数
 *    - 同时生成可验证证明（VRF Proof）
 *
 * 3. 回调阶段：
 *    - Coordinator 验证证明后调用 fulfillRandomWords()
 *    - 合约收到 requestId + randomWords 数组
 *
 * 安全保证：
 * - 节点无法预测或操控随机数（数学证明）
 * - 任何人都可以验证随机数的正确性
 * - 请求后节点必须响应，否则会被惩罚
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              配置参数说明
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * subscriptionId: VRF 订阅 ID（用于 LINK 付费）
 * keyHash: Gas Lane 标识符（决定 Gas 价格上限）
 * callbackGasLimit: 回调函数的 Gas 上限（太低会导致回调失败）
 * requestConfirmations: 等待的区块确认数（越多越安全，但越慢）
 * numWords: 请求的随机数个数（本游戏只需要 1 个）
 */
abstract contract VrfBase is VRFConsumerBaseV2Plus {
    uint256 public constant VRF_TIMEOUT = 10 minutes;       // VRF 请求超时时间（超时后可以 retry）
    uint256 public immutable subscriptionId;                // VRF 订阅 ID（不可变，部署时设置）
    bytes32 public immutable keyHash;                       // Gas Lane 的 keyHash（参考 Chainlink 文档）

    uint32 public callbackGasLimit = 200000;                // 回调函数的 Gas 上限（可通过 setVrfConfig 调整）
    uint16 public requestConfirmations = 3;                 // 等待的区块确认数
    uint32 public numWords = 1;                             // 请求的随机数个数（骰子游戏只需 1 个随机数）

    /**
     * @notice 构造函数
     * @param coordinator VRF Coordinator 合约地址
     * @param subId VRF 订阅 ID
     * @param gasLane Gas Lane 的 keyHash
     */
    constructor(
        address coordinator,
        uint256 subId,
        bytes32 gasLane
    ) VRFConsumerBaseV2Plus(coordinator) {
        subscriptionId = subId;
        keyHash = gasLane;
    }

    /**
     * @notice 发起 VRF 随机数请求
     * @dev 内部函数，由上层合约在 reveal 阶段调用
     * @return requestId VRF 请求 ID，用于匹配回调
     */
    function _requestVrf() internal returns (uint256 requestId) {
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                // nativePayment: false 表示用 LINK 代币支付
                // 如果设为 true，则用原生代币（ETH）支付
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );
    }

    /**
     * @notice 更新 VRF 配置参数
     * @dev 仅 owner 可调用（通过上层合约的权限控制）
     *
     * 参数校验规则：
     * - callbackGasLimit >= 100000（太低会导致回调失败）
     * - requestConfirmations 在 1-200 之间
     * - numWords 必须为 1（本游戏只需要 1 个随机数）
     *
     * @param _callbackGasLimit 新的回调 Gas 上限
     * @param _requestConfirmations 新的区块确认数
     * @param _numWords 请求的随机数个数（必须为 1）
     */
    function _setVrfConfig(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        uint32 _numWords
    ) internal {
        if (_callbackGasLimit < 100000) revert InvalidVrfConfig();
        if (_requestConfirmations < 1 || _requestConfirmations > 200) revert InvalidVrfConfig();
        if (_numWords != 1) revert InvalidVrfConfig();

        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        numWords = _numWords;

        emit VrfConfigUpdated(_callbackGasLimit, _requestConfirmations, _numWords);
    }
}

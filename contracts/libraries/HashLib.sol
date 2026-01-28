// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title HashLib
 * @notice 混合随机骰子游戏的哈希计算库
 * @dev 提供承诺哈希计算和随机数混合两个核心函数
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              安全设计说明
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 本库实现了 Commit-Reveal + VRF 混合随机方案的核心哈希逻辑：
 *
 * 1. 承诺哈希（Commit Hash）
 *    - 玩家在 commit 阶段提交 hash = keccak256(player, guess, secret, ...)
 *    - reveal 阶段验证 hash 是否匹配，防止玩家看到 VRF 结果后更改猜测
 *    - 包含 contractAddr + chainId + nonce 防止跨链/跨合约/重放攻击
 *
 * 2. 混合随机（Hybrid Randomness）
 *    - 将 Chainlink VRF 返回的随机数与玩家的 secret 混合
 *    - 即使 VRF 节点恶意（极低概率），也无法预测最终结果
 *    - 因为节点不知道玩家的 secret（commit 时只提交了 hash）
 *
 * ══════════════════════════════════════════════════════════════════════════════
 *                              为什么用 abi.encode 而非 abi.encodePacked
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 使用 abi.encode 而非 abi.encodePacked 的原因：
 * - abi.encode 对每个参数进行 32 字节对齐，避免哈希碰撞
 * - abi.encodePacked 紧凑编码可能导致不同参数组合产生相同哈希
 * - 例如：encodePacked("ab", "c") == encodePacked("a", "bc")
 *
 * 前端计算 commitHash 时必须使用相同的 abi.encode 方式，
 * 或直接调用合约的 computeCommitHash() helper 函数。
 */
library HashLib {
    /**
     * @notice 计算承诺哈希
     * @dev 用于 Commit-Reveal 机制的第一阶段
     *
     * 哈希包含 6 个参数，每个都有特定用途：
     * - player: 防止他人冒用你的 commit
     * - guess: 玩家的猜测（1-6）
     * - secret: 玩家生成的随机数，用于隐藏 guess 并参与最终随机混合
     * - contractAddr: 防止跨合约重放
     * - chainId: 防止跨链重放
     * - nonce: 防止同一玩家的历史 commit 被重放
     *
     * @param player 玩家地址
     * @param guess 玩家猜测的点数（1-6）
     * @param secret 玩家生成的 32 字节随机数
     * @param contractAddr 游戏合约地址
     * @param chainId 当前链 ID
     * @param nonce 玩家的游戏 nonce（每局递增）
     * @return 32 字节的承诺哈希
     */
    function computeCommitHash(
        address player,
        uint8 guess,
        bytes32 secret,
        address contractAddr,
        uint256 chainId,
        uint32 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(player, guess, secret, contractAddr, chainId, nonce)
        );
    }

    /**
     * @notice 混合 VRF 随机数和玩家 secret
     * @dev 实现"Hybrid Randomness"的核心逻辑
     *
     * 混合随机的安全性来自两个独立的熵源：
     * 1. vrfRandom: Chainlink VRF 提供的可验证随机数
     * 2. secret: 玩家在 commit 时生成的随机数
     *
     * 攻击分析：
     * - 矿工攻击：无法预测 VRF 结果，无法作弊
     * - VRF 节点攻击：不知道 secret（只看到 hash），无法预测最终结果
     * - 玩家攻击：VRF 结果不可预测，无法选择有利的 secret
     *
     * @param vrfRandom Chainlink VRF 返回的随机数
     * @param secret 玩家的 secret（reveal 时提交）
     * @param player 玩家地址
     * @param requestId VRF 请求 ID
     * @param contractAddr 游戏合约地址
     * @param chainId 当前链 ID
     * @return 混合后的 256 位随机数
     */
    function mixRandomness(
        uint256 vrfRandom,
        bytes32 secret,
        address player,
        uint256 requestId,
        address contractAddr,
        uint256 chainId
    ) internal pure returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(vrfRandom, secret, player, requestId, contractAddr, chainId)
            )
        );
    }
}

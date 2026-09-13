# H1 改进实验协议

## 目标

只使用固定快照 `gpt-5-nano-2025-08-07`，研究如何减少 H1 前置 LLM 建议因 `changed_text`、不完整覆盖或不稳定选择而整体失效。实验仍只处理长 `transcript segments[]` 到自然 `subtitles[]` 的文本切分，不涉及 word alignment、时间戳或 UI。

## 数据与隔离

- 沿用原实验 65 条、7 种语言数据。
- 13 条 `development` 用于选择 DP 奖励/惩罚参数。
- 52 条 `evaluation` 只用于最终报告。
- 模型固定为 `gpt-5-nano-2025-08-07`，新增在线组固定 `reasoning_effort=minimal`。
- 所有最终 cue 必须由原文切片产生，并通过完整覆盖与硬长度校验。
- 作者参考切法不是唯一正确答案；F1 只用于同一数据集内的相对比较。

## 实验组

| 组 | 模型任务 | 本地处理 | 预期失效方式 |
|---|---|---|---|
| `H1_text_minimal` | 重写完整原文并插入 cue 边界 | 全文精确匹配后，将全部边界奖励 1.5；失败则 R1 | 任一字符变化可导致全量降级 |
| `H1_guarded_projection_minimal` | 与旧 H1 相同 | 全文有效时保持旧 H1；无效时只投影能在原文中单调、原样定位的行末边界，弱奖励 0.25 | 只有完全无法恢复边界才全量降级 |
| `H1_projection_minimal` | 与旧 H1 相同 | 所有输出统一做无损投影，边界奖励 0.5 | 可能轻微改变原本有效建议的权重 |
| `H1_boundary_ratings` | 对少量边界逐项输出 `prefer/neutral/avoid` | 奖励/惩罚均为 0.5 后进入 DP | 可解析，但标签可能波动或全 neutral |
| `H1_nbest_choice` | 从 8 个全部合法的本地候选中选 ID | 直接采用所选方案 | 选择稳定但判断质量可能不足 |
| `H1_sparse_ids` | 输出推荐和避免的稀疏 ID 数组 | 局部过滤冲突 ID 后进入 DP | nano 可能把大量 ID 同时放入两组 |
| `H1_boundary_vote3` | 三次执行逐边界评分 | 每个边界多数投票后进入 DP | 成本约三倍，投票未必提升质量 |

## 推荐算法：guarded lossless projection

```text
if LLM lines can exactly reconstruct source:
    preferred = all validated line ends
    reward = 1.5
else:
    cursor = 0
    preferred = []
    for each non-empty model line:
        if line exactly starts at cursor:
            accept its end; advance cursor
        else if line has one unique exact occurrence after cursor:
            resync to it; accept only its end; advance cursor
        else:
            skip the line
    reward = 0.25

result = local_DP(source, preferred, reward)
```

关键约束：不把模型文本写入结果；只接受原文中的真实位置；跨越缺失区重新同步时，不奖励缺口起点；修改、重复歧义或无法定位的行被局部跳过。

## 边界评分 prompt 示例

```text
Rate each proposed subtitle boundary using only its exact left and right context.
Use prefer for a strong clause or phrase ending, neutral for an acceptable seam,
and avoid when the seam splits a lexical or tightly bound grammatical unit.
Do not judge line length; all combinations are resolved by a local optimizer.
Examples: 把这|个打开 => avoid; 会比较|顺 => avoid;
动作做完之后，|后面的 => prefer; look straight| ahead => avoid.
```

每个动态边界都是 strict JSON Schema 的必填属性，值只允许 `prefer`、`neutral`、`avoid`。这保证结构完整，但不保证标签判断正确。

## 执行规模

- 新增在线调用 377 次：`H1_sparse_ids` 91、`H1_nbest_choice` 91、`H1_boundary_ratings` 195。
- 三个新协议的 377/377 响应全部满足严格 schema。
- rating 组为全部 65 条执行三次；另两个组只在 13 条 development 上执行额外两次。
- 旧 H1 的 minimal/low 原始结果直接复用，没有重复付费。

OpenAI 官方模型页确认该固定 GPT-5 nano 快照支持 Structured Outputs；固定快照用于减少模型版本漂移：<https://developers.openai.com/api/docs/models/gpt-5-nano>。

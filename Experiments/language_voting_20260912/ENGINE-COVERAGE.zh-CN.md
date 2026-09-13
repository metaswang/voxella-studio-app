# ASR 引擎覆盖路由修正

本说明取代旧报告中的“任何语言冲突都应切换 Whisper”验收标准。旧报告和原始模型分数保留为历史数据。

## 最终约定

- LID 只选择引擎，不给自动转写强制语言提示，不预先指定最终文本语言。
- 使用完整语言分布，按引擎实际覆盖聚合；语言集合可以重叠。英语、丹麦语分歧可以走 Parakeet，中文、泰语、罗马尼亚语分歧可以正常走 Qwen。
- 中英冲突优先 Qwen，但仍要求 Qwen 能覆盖当前证据，不能掩盖第三种范围外语言。
- 最终不确定时 Whisper 兜底。Qwen 不是通用不确定性兜底；不要求所有测试音频都避开 Whisper。
- 2 秒等短音频正常执行 LID，依据实际模型输出选择引擎，不按时长预设结果。

## 实现

Qwen3-ASR 的 30 种支持语言与优先语言集合分开维护；Parakeet v3 覆盖 25 种语言。英语同时属于两个模型的能力范围；拉丁语不属于两者，缅甸语不属于 Qwen，马来语属于 Qwen。覆盖来源见 PROTOCOL.md 中的官方模型卡。

每个窗口先归一化完整分布，再按 `min(有效人声秒数, 5)` 加权。移除单语言 margin² 对窗口权重的放大。候选引擎须同时满足：

1. 汇总覆盖分数 >0.50，且相对该引擎范围外分数领先至少 0.15。
2. 每个有效窗口的覆盖分数 >0.50。
3. 所有强语言票都在其支持范围内；强票仍要求概率分数 >=0.75、第一第二候选差 >=0.15。

两个引擎都满足时优先 Parakeet。若 Qwen 满足覆盖要求，且不同窗口存在中英文强票，或某窗口中英文各 >=0.25 且合计 >=0.75，则优先 Qwen。阈值可通过策略注入，未经独立数据校准。

3 秒仅作为划分窗口数量的目标长度，不再过滤短音频。重复窗口不增权，重叠、无效分布和空输入继续安全兜底。日志记录引擎覆盖分数及逐窗口覆盖；范围外分数不是 Whisper 正确率。

## 原分数回放

使用生产 Swift 路由代码在 Docker 中回放原实验的 23 个输入记录。20 个原始 session 的分布从 Qwen 8 / Parakeet 5 / Whisper 7 变为 Qwen 10 / Parakeet 5 / Whisper 5。

| 输入 | 原路由 → 当前路由 | 原因 |
|---|---|---|
| session-01 | Whisper → Whisper | 缅甸语候选使 Qwen 覆盖不足 |
| session-06、08 | Whisper → Whisper | 拉丁语证据超出两个优先引擎范围 |
| session-07 | Whisper → Parakeet | 合并欧洲语言后满足覆盖要求 |
| session-09 | Whisper → Whisper | 窗口候选不稳定、覆盖不足 |
| session-11 | Parakeet → Whisper | 首窗口 Parakeet 25.93%、Qwen 37.53%，不能由后续英语窗口掩盖 |
| session-14、15 | Whisper → Qwen | 冲突语言均在 Qwen 支持范围内 |
| mixed-en-zh | Whisper → Qwen | 中英冲突保护 |

回放中的 short-en 没有历史 LID 分数，仍显示 insufficientSpeech；这不是当前短音频行为的验证结果，必须重新对音频执行模型推理。详见 `results-engine-coverage-replay.json`。

## 验证边界

- 本地 Docker：39 项检查通过，包含生产代码回放 23 条记录。
- 原生 BundledSpeech 构建通过；原生路由与投票两个测试 suite 通过。
- 完整 23 音频重跑在进入 LID 前被 `ASRSpeechProbabilityError.missingModel` 阻断：当前 Silero VAD MLX 未通过安装检查。因此不能把分数回放称为完整音频管线复验。
- 独立短音频实验 `identifyShortAudioWithoutDurationGate` 使用 2 秒原始输入和给定的完整语音范围，专门验证 LID 模型与路由入口；它不代替 VAD 检测验收。
- 独立短音频实测通过：ECAPA 接收 2.0 秒音频，生成 1 个窗口，英语分数约 0.90，按正常覆盖规则选择 Parakeet。实际 GPU 推理测试耗时约 0.23 秒，结果保存在 `results-short-input-lid.json`；测试没有预设引擎结果。

上述回放隔离路由规则变化，不代表重新执行过音频模型。原实验部分输入来自 listen 音轨；生产输入等价性需单独验证。用户已确认原始 session 为中英文，但历史 reference 字段保留，不能把其中 da 等标签当作真实语言。

本次未通过调阈值追求零 Whisper，也未测量完整转写 WER/CER。session-11 的新增兜底明确暴露了逐窗口保护的保守性；独立数据校准应同时衡量错误专用引擎路由和不必要的兜底。

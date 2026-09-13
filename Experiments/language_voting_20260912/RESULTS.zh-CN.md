# 语言投票实验结果（2026-09-12）

本文保留原 margin² 策略的历史实验结果；当前路由约定、回放结果和验证限制见 [ASR 引擎覆盖路由修正](ENGINE-COVERAGE.zh-CN.md)。

## 结论

平方 margin 加权、可靠锚点、冲突兜底和非重叠取样通过验证。此结果说明路由保护规则有效，不代表已校准的语言识别准确率提高。Studio 使用 ECAPA，参考 worker 使用 AmberNet，因此没有将 worker 的单个案例分数当作 Studio 的实测结果。

权重为 `min(有效人声秒数, 5) × (top1 − top2)²`；可靠锚点门槛为 0.75 / 0.15，池化分数必须 >0.50 且领先 >=0.15。阈值是可注入的工程策略，未针对本批 session 调参。

## 验证

- Docker 编译实际生产 Swift 源码：27 项测试通过（包含参数化边界用例）。
- 两份原生管线均运行 27 项单元测试和一次 23 输入 session 实验：已提交版本的 Core ML VAD，以及发布快照中现有的语音概率预处理。
- 未上传音频或转写内容；随提交保存匿名窗口坐标、模型概率、权重和路由结果。
- 20 个不同 session 媒体的前 90 秒以内片段；另加 2 秒短语音、0.03 幅度英语、中英各 15 秒拼接。
- 同一组 ECAPA 概率分别执行旧平均/引擎语言组策略和新策略，隔离投票规则变化；不是旧取样器完整重跑。

## 发布快照结果

| 输入 | session 参考标签 | 旧路由 / top-1 | 新路由 / top-1 | 原因 | Whisper 提示 |
|---|---|---|---|---|---|
| session-01 | zh-CN | whisper / my | whisper / my | noReliableLanguageAnchor | 无 |
| session-02 | zh | qwen / zh | qwen / zh | weightedEvidence | 无 |
| session-03 | zh | qwen / zh | qwen / zh | weightedEvidence | 无 |
| session-04 | zh | qwen / zh | qwen / zh | weightedEvidence | 无 |
| session-05 | zh | qwen / zh | qwen / zh | weightedEvidence | 无 |
| session-06 | en | whisper / la | whisper / la | weightedEvidence | 无 |
| session-07 | da | parakeet / en | whisper / en | noReliableLanguageAnchor | 无 |
| session-08 | en | whisper / la | whisper / la | weightedEvidence | 无 |
| session-09 | en | whisper / la | whisper / la | noReliableLanguageAnchor | 无 |
| session-10 | en | parakeet / en | parakeet / en | weightedEvidence | 无 |
| session-11 | en | parakeet / en | parakeet / en | weightedEvidence | 无 |
| session-12 | en | parakeet / en | parakeet / en | weightedEvidence | 无 |
| session-13 | en | parakeet / en | parakeet / en | weightedEvidence | 无 |
| session-14 | zh | qwen / zh | whisper / zh | mixedLanguages | 无 |
| session-15 | zh | qwen / zh | whisper / zh | mixedLanguages | 无 |
| session-16 | zh | qwen / zh | qwen / zh | weightedEvidence | 无 |
| session-17 | zh | qwen / zh | qwen / zh | weightedEvidence | 无 |
| session-18 | en | parakeet / en | parakeet / en | weightedEvidence | 无 |
| session-19 | unknown | qwen / zh | qwen / zh | weightedEvidence | 无 |
| session-20 | zh-CN | qwen / zh | qwen / zh | weightedEvidence | 无 |
| short-en | insufficient | whisper / — | whisper / — | insufficientSpeech | 无 |
| quiet-en | en | parakeet / en | parakeet / en | weightedEvidence | 无 |
| mixed-en-zh | mixed | qwen / zh | whisper / zh | mixedLanguages | 无 |

原始 20 个 session：旧引擎分布 `{'whisper': 4, 'qwen': 10, 'parakeet': 6}`，新引擎分布 `{'whisper': 7, 'qwen': 8, 'parakeet': 5}`。

## 发现与边界

- 一些参考标签为英语的录音出现高置信度拉丁语，说明模型分数不是正确率。强票可主导池化，但不能因此替 Whisper 锁定语言：只有每个有效窗口都给胜出语言至少 0.80 时，才附带语言提示。用户显式语言选择不受限制。
- 两种语言都有可靠强票时，即使它们属于同一 ASR 引擎支持范围，也使用不带语言提示的 Whisper。这样的保守策略可能增加单语录音的兜底率。
- 原始 session 标签来自已有转写，未人工独立标注。不能据此报告准确率、错误路由率或温度校准结果。
- 保留 `topLanguage` 作为池化候选用于诊断；遇到拒绝原因时，不能将其解释为已确认的语言。
- 未完成整批音频的 ASR WER/CER、人类语言标注、macOS 15 真机登录测试或 UI 人工验收。

## 重现

参见 [实验协议](PROTOCOL.md)、[Docker 检查脚本](check-docker.sh)、`Tests/PalmierProTests/LocalAI/LanguageVoteSessionExperiment.swift`。

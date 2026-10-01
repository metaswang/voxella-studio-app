# 参考音语音输入：实现与实验

## 结果

参考音管理入口迁至 Settings → Voice Library，配音页的管理链接同步打开设置。录音使用 Record & Transcribe 的真实流动波形组件；停止后才发布完成的文件。空脚本在导入或录音结束后自动识别，用户输入的脚本不会被自动替换。

公共模块位于 `Sources/VoxstudioPro/SpeechInput/`：录音器负责后台录音和临时文件生命周期，控制器负责识别状态与取消，限时解码器负责读取前十秒，SwiftUI 控件负责显示和转发操作。识别继续由 `LocalSpeechPipeline` 的单一模型实例、语言路由、VAD、文本清理和全局推理锁执行。文本用途在获得最终文字和语种后结束，不加载对齐模型或进行说话人处理。

自动识别的参考音保存对应的前十秒（不足十秒则保存全段）；预先输入脚本时保留原来的完整音频流程。录音仍执行已有的边界静音处理。界面明确显示自动参考音的保存范围。语言默认自动检测，有识别结果时填入受支持语种；用户明确选择的语种不被覆盖。

## 实测

输入为应用本地参考音库中三份音频的隔离副本，未修改原参考音。每份音频运行三组对照，交错文本/完整转写的先后顺序。以下为后两组的中位数，表示模型已加载时的延迟；不是冷启动承诺。最终实验单独运行，排除了早期并行实验的推理锁等待。

| 输入 | 完整转写 | 最终文字 | 耗时减少 | 首段预览 |
|---|---:|---:|---:|---:|
| 中文，截取 10 秒 | 1.532 s | 1.034 s | 32.5% | 0.536 s |
| 中文，5 秒 | 1.171 s | 0.756 s | 35.4% | 0.372 s |
| 英文，9.68 秒 | 1.534 s | 0.835 s | 45.6% | 无，Whisper 路径 |

三份输入的主要文字内容与完整转写一致，标点有少量差异。中文由 Qwen 识别。英文的预期引擎是 Parakeet TDT 0.6B v3，但本次样本发生了路由前的语种识别异常：第一个窗口输出 `la:0.97`（拉丁语），第二个窗口输出 `lo:0.37`（老挝语）；引擎分数为 Qwen 0.13、Parakeet 0.16、Whisper 0.71，因此触发 `whisperDominant`。最终文本语种虽解析为 `en`，但这发生在 ASR 之后，没有重新路由。上述英文数据仅代表这次误路由后的 Whisper 路径，不能作为预期英文 Parakeet 路径的性能结论。语种识别异常的具体根因尚未修复或确认，需进一步检查音频预处理、LID 模型输出及标签映射。此前将其描述为正常自动路由不准确。这是小规模本机实验，不代表所有语言、设备、录音条件或冷启动表现。结果见 `final_measurements.json`。

## Streaming 决策

现有 Qwen Swift `generateStream(audio:)` 针对已获得的音频逐 token 输出；官方真正的音频流方案还维护分块上下文和回退 token。单独比较同一个已加载 Qwen 模型时，流式首字约 0.27 秒，最终延迟和一次性生成接近。该模型级数字不包含应用的 VAD 与语种识别。

生产代码在原有同步推理循环中加入可选的部分文字回调，每四个 token 更新一次预览，并在 token 与预填充边界检查取消。这样逐步展示文字时仍由原推理锁覆盖完整模型生命周期，不使用 detached 流消费者，不额外创建模型实例。最终清理后的结果完成前，预览不会写进用户脚本。Whisper 与 Parakeet 继续沿用原有识别路径。

语音输入最多生成 512 个 token；达到限制明确失败，不把截断结果当作成功脚本。持续麦克风 PCM 的增量推理未实现，本次采用“录音中显示波形，停止后识别与逐步预览”，符合停止后转文字的交互。

来源：
- [Swift Qwen 实现](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift)
- [官方 Qwen 流式实现](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)
- [官方实时演示](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/cli/demo_streaming.py)

## 验证与限制

聚焦回归测试覆盖设置入口、十秒解码边界、保存音频的对应长度、取消后拒绝旧结果。测试曾发现旧采样率转换少保留约 16 ms；自动参考音已改为共用限时解码，并通过对应性测试。

实验所需的 Silero VAD MLX 模型约 1.3 MB，已通过应用现有下载器安装。默认测试不会下载模型或读取用户参考音；真实音频与流式实验均显式 opt-in。

Mac 锁屏阻止了实际 UI 检查。需在解锁后按 `PROTOCOL.md` 的界面清单确认最小窗口尺寸、录音、麦克风权限、键盘/Escape、切换设置页、取消、文件替换和保存行为；当前不声称 UI 已通过。

完整 `swift test` 已尝试执行，但未完成：3 个 `MediaFlowTests` 字幕分段断言失败，随后大量测试停滞。线程采样显示 `AgentService.reloadAPIKeys → AgentCredentialSnapshot.loadFromKeychain → KeychainStore.load` 等待锁屏期间的钥匙串访问；已终止本次启动的停滞测试进程。三个失败场景为 `subtitleSegmentationRecoversChangedTextWithoutRetry`、`subtitleProcessorAcceptsNaturalTextWithoutForcedPunctuation`、`subtitleProcessorDoesNotRejectPunctuationByScript`；涉及的字幕处理实现不在本次修改范围。未将完整测试报告为通过。

聚焦命令 `swift test --traits BundledSpeech --filter 'SpeechInput|ASRAudioPreprocessorTests|ASREngineRouterTests|ASRSpeechPreparationTests|RecordingPermissionTests'` 通过：42 项检查，其中 5 项按显式实验开关跳过。另行启用真实模型取消实验 `VOXELLA_RUN_LOCAL_FIXTURES=1 VOXELLA_SPEECH_INPUT_CANCELLATION=1 VOXELLA_SPEECH_INPUT_CORPUS=/tmp/voxella-speech-input-corpus swift test --skip-build --traits BundledSpeech --filter cancellationDuringPreviewReleasesInference` 通过：在首段预览时取消，随后一次识别正常完成。未运行 Thread Sanitizer；编译使用 Swift 6 并发检查，另有上述确定性取消回归及真实模型取消验证。

构建验证：`swift build` 与 `swift build --traits BundledSpeech` 均成功；最终语种选项调整后的 BundledSpeech 增量构建亦成功。`git diff --check` 通过。实验使用的三份临时音频副本已清理，原始参考音未修改。后续重跑实验需重新准备隔离副本并设置 `VOXELLA_SPEECH_INPUT_CORPUS`。

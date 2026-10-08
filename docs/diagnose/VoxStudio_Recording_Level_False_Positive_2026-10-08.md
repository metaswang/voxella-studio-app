# 录音音量过低误报：2026-10-08

## 最新应用证据

- 日志：`~/Library/Logs/Voxella Studio/app.log`。应用支持目录已迁移为 `VoxStudio`，日志仍使用已有的旧目录。
- 21:52:22–21:52:28（新加坡时间），会话 `EDE03749-424A-4C0E-A3C4-D417A8A38B06`：6.912 秒，整段 RMS −45.47 dBFS，峰值 −24.80 dBFS。触发截图中的录音完成告警。该原始音频目前已不在录音目录，不能重放。
- 21:56:55–21:57:02，会话 `93CE117D-C9AF-44E1-B315-C132225FE2C9`：7.392 秒，整段 RMS −42.35 dBFS，峰值 −26.54 dBFS。也触发相同告警。
- 两次都是内置麦克风、仅录音，`droppedMic=0`、`failedAppends=0`、`restarts=0`，完成结果为 `complete`。
- 可重放的最新文件：`~/Library/Application Support/VoxStudio/Recordings/Recording-20261008-215655-f06fcbaa.m4a`。最新工作台会话已完成转录；增强播放文件为相邻的 `.listen-moss2.m4a`。

## 根因

1. 原检测直接以**整段 RMS < −40 dBFS**作为告警条件，包含开始等待、词间停顿、结束静音。没有区分有声片段和停顿，因此实际说话电平足够的短录音仍会被告警。
2. 最新原始音频解码后两个声道相同，各声道 RMS 为 −42.36 dBFS、峰值 −26.53 dBFS，与捕获日志吻合。因此此案例是告警决策误报，不能归因于捕获数值读取错误。
3. 最新增强播放文件整段 RMS 为约 −15.6 dBFS。`ListenTrackEnhancer` 进行降噪、混合、响度归一化；捕获告警读的是增强前的原始 PCM。播放音量大和捕获整段平均电平低可以同时发生。
4. 实时告警也使用从录音开始累计的 RMS，并由 `didIssueLowLevelWarning` 锁定只发一次；即使后续声音恢复，也没有恢复事件清除提示。

## 修复

- 把电平测量拆为独立的 `RecordingAudioLevelMeter`。保留原始 RMS、峰值、时长用于诊断，新增有声窗口 RMS 与健康电平累计时长。
- 使用 100 毫秒窗口，在各窗口中取电平最高的声道，避免多声道中无声通道稀释判断。根据最响且累计至少 300 毫秒的窗口确定参考电平，以相对低 15 dB、绝对不低于 −60 dBFS 的门限排除静音和低噪声。
- 整段使用固定大小的 1 dB 直方图，避免长录音无限积累数据；不足 3 秒的录音不触发完成后的低音量提示。需要至少 300 毫秒的健康窗口，避免单个点击声掩盖持续静音。
- 实时判断使用最近 8 秒窗口，允许低音量 → 正常 → 再次低音量的状态变化；恢复时发送清除事件。
- 控制器分别保存低音量提示与录音恢复/保存等提示，恢复音量不会误清除其他录音反馈；停止、丢弃或重新录音时清除实时低音量状态。
- 所有录音停止均记录整段与有声电平及是否触发告警，以便直接从最新应用日志核对判断。
- PCM 按 `AVAudioPCMBuffer.stride` 读取 Float32/Int16/Int32，支持交错和非交错多声道；时长按每个输入缓冲区的采样率累加。相关 API 语义：[Apple floatChannelData 文档](https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/floatchanneldata)。此项是额外修正，不是最新案例的根因；生产录音先转换成固定的非交错 Float32 格式。

## 最新音频的判定

按最新原始文件重放测量，有声门限约 −51 dBFS，门限以上片段约 3.5 秒，健康窗口约 1.5 秒，有声 RMS 约 **−39.19 dBFS**。旧判断为低音量，新判断正常。原始音频和增强音频不修改。

## 验证

回归测试覆盖说话与停顿、长静音后保留有效声音、持续低音量、纯静音、单个点击声、短录音、实时恢复与再次告警、单边有声立体声、交错 Float32/Int16/Int32，以及采样率变化和分片缓冲区。

真实录音回放由环境变量 `VOX_RECORDING_LEVEL_REPLAY` 指定文件，经过生产 `CMSampleBuffer` 测量入口；无需把用户音频提交到代码仓库。

已运行项目默认测试配置：**39 项测试、6 个套件全部通过**。真实录音经生产测量入口得到 7.392 秒、整段 RMS −42.3514 dBFS、有声 RMS −39.1882 dBFS，完成告警为 `nil`。测试日志保存在 `/private/tmp/voxstudio-recording-level-tests.log`。

```sh
VOX_RECORDING_LEVEL_REPLAY='/Users/adamwang/Library/Application Support/VoxStudio/Recordings/Recording-20261008-215655-f06fcbaa.m4a' \
swift test --filter 'RecordingAudioLevelTests|ASRAudioPreprocessorTests|RecordingHealthStateMachineTests|RecordingTimeoutTests|RecordingJournalRecoveryTests|RecordingUpgradeTests'
```

注意：现有 `AppUpdaterTests` 的依赖注入构造器不适用于 `SparkleUpdates` 分发配置，带该 trait 的测试构建会在已有更新器测试处报错。本次使用默认测试配置验证录音；签名应用仍按项目规定的 `./scripts/bundle.sh debug --sign` 构建。

`./scripts/bundle.sh debug --sign` 已成功；应用及内嵌框架签名校验通过。产物为项目 `.build/VoxStudio.app`，构建日志为 `/private/tmp/voxstudio-recording-level-bundle.log`。

签名应用已重启，原生界面正常显示最新“数一到十”会话，状态为 Ready。真实音频误报修复通过上述生产代码回放测试验证；未额外创建用户录音。

# 应用录制与本地会议入口验证

日期：2026-09-30。环境：Apple Silicon、签名 Debug macOS 应用。

## 实现范围

- Record 新增 App 模式，可选择一个显示器上的多个应用。选择器支持搜索、刷新、多选、取消与调整窗口大小；列表滚动，底部操作保留在窗口内。
- 参考本机 `../../QuickRecorder/` 的 ScreenCaptureKit 应用过滤方式，独立实现 `SCContentFilter(display:including:exceptingWindows:)`。选中应用的窗口及应用音频被纳入，其他应用和桌面使用黑色背景；麦克风可以关闭。
- 开始前重新校验显示器与应用进程。恢复录制时只使用原选择的 bundle ID 与 PID，保留应用范围；部分应用退出继续录制，全部退出或显示器移除则停止并保存。
- 应用画面静止、空白或暂停显示时，不把正常回调误判为视频冻结；空白帧写入黑色背景，静止帧保持画面。
- Meeting Recorder 下方显示已打开的原生会议应用、图标与“录制此应用”。支持 Zoom、Teams、Webex、腾讯会议/VooV、飞书/Lark、钉钉、Slack、Discord、FaceTime。检测表示应用已打开，不推断通话是否进行中。
- 快捷入口保留当前麦克风开关，启用应用音频。跨显示器的应用需要选择显示器。网页会议使用手动窗口选择。
- 新增界面及错误文案提供英文和简体中文资源。

## 自动化与构建

录制相关回归：56 项测试、16 个 suite 全部通过。

```sh
swift test \
  --filter 'RecordingApplicationSelectionTests|MeetingAppPresenceTests|LocalMeetingRecordingTests|RecordingPermissionTests|RecordingScreenCaptureAuthorizationTests|Recording.*Tests' \
  --skip LocalFirstWorkbenchTests
./scripts/bundle.sh debug --sign
open "$PWD/.build/VoxStudio.app"
```

新增测试覆盖多显示器窗口归属、多选有效性、小窗口、隐藏窗口、排除自身、进程重启和 PID 复用、恢复选择范围、麦克风 Off、中文文案、静止/空白视频健康策略、旧静止帧时间戳与新的时钟时间、会议软件 bundle ID 与多个进程实例，以及并行媒体检查完成顺序不影响分段拼接顺序。

最终构建通过签名验证，`codesign` 验证 valid on disk / satisfies its Designated Requirement。工作区应用已启动；调试包未做 notarization。

更宽的测试筛选共执行 68 项，有 5 个与本次修改无关的失败：一个测试依赖本机已不存在的 VoiceLibrary WAV，四个全局中文覆盖测试报告原有未翻译键（例如 Mac、MCP/AI provider 状态及视频字幕文案）。本次新增的中文文案断言通过。

日志保存在本机临时目录：

- `/private/tmp/voxstudio-app-recording-target-exit-tests.log`
- `/private/tmp/voxstudio-app-recording-tests.log`
- `/private/tmp/voxstudio-app-recording-target-exit-bundle.log`

## 端测说明

按用户要求由 `gpt-6-luna` 执行原生 UI 端测。选择器的早期“未显示”报告已更正：用户截图证实它已显示；另一次自动化误选了 Display 模式，进入 macOS 的显示器选择流程。最终构建的 App 选择器已由主代理实际确认出现在辅助功能树中，含应用列表、显示器、搜索和完整底部操作。

Luna 已通过应用多选（Finder + QuickTime）、搜索后保留选择、取消返回空闲、两次重开清空旧选择、麦克风 Off，以及 FaceTime 本机检测。FaceTime 入口显示“Meeting app is open / Record FaceTime”，并保留 Microphone off；没有发起通话或登录。

首轮 QuickTime 应用录制保存了可播放的 AAC + H.264 文件（3024 × 1964、130.288 秒），但约两分钟处出现 writer 切换，随后视频冻结检测停止录制。本轮没有算作长录制通过。已修复两处实际问题：新 writer 的视频 PTS 重置为本段时间线；并行媒体校验返回顺序不再改变拼接顺序。底层 writer 的失败信息也保留在日志中。

首轮视频中含另一段 VoxStudio 界面，是录制开始前已经在 QuickTime 打开的两个电影窗口；Luna 读取 Window 菜单确认了文件名。App 模式包含该应用所有窗口，这些窗口属于所选 QuickTime，不能把它们作为其他应用泄漏的证据。

第二轮 QuickTime 应用录制通过：209.547 秒、H.264 3024 × 1964 + AAC 48 kHz 双声道；视频从 0 延续至 209.547 秒，音频至 209.488 秒。停止日志记录 `user stop / complete / segments=1 / failedAppends=0 / restarts=0`。Luna 用 QuickTime 播放至 11 秒并暂停，取消处理选项，没有开始转写或云端处理。

该轮仅选择 QuickTime，麦克风 Off；QuickTime 播放 440 Hz，未选择的 Chrome 播放 880 Hz，两者重叠约 40–45 秒。没有精确记录重叠起止时间，因此主代理扫描整段音频的全部 209 个一秒窗口：440 Hz 峰值功率约 -29.03 dB，880 Hz 最高约 -93.37 dB，低约 64.34 dB。未检出同幅度的 Chrome 880 Hz 测试音。频谱数值是固定频率 Goertzel 功率测量，不是人声隔离或实际会议质量评测。

媒体文件：`~/Library/Application Support/VoxStudio/Recordings/Recording-20260930-160711-7fa6afc8.mp4`。测量证据：`/private/tmp/voxstudio-app-capture-qa/final-media-check.json`、`full-audio-scan.json`。

后续 FaceTime 实测复现 `AVFoundationErrorDomain -11800 → NSOSStatusErrorDomain -16341`，停止时也超时。这些轮次未算作通过。FaceTime 当时包含实时摄像头预览，不能作为静止画面验证。原始片段视频 PTS 最大间隔分别约 0.070 / 0.108 秒，没有明显的视频中断；可播放长度少了最后一个 10 秒 fragment，不能据此推断视频在错误前 10 秒停止。系统日志将错误定位到 `MovieHeaderMaker` 的分段头写入。

静止/空白帧另外使用当前 host clock 并定时补帧，写入停滞仍受健康检测保护。Apple 对 [idle 状态](https://developer.apple.com/documentation/screencapturekit/scframestatus/idle) 的定义是画面不变时没有生成新帧。该策略需要用真正静止的窗口另行端测。

为 App 模式增加明确的 H.264 实时编码参数：关闭帧重排、最长 2 秒关键帧间隔、30 fps 预期输入以及按输出分辨率控制平均码率。参考 QuickRecorder 的显式码率及帧率配置；对于变帧率 App 捕获，采用顺序解码以简化 fragment 的帧时序。Apple 的 [压缩设置文档](https://developer.apple.com/documentation/avfoundation/avvideocompressionpropertieskey)说明这些设置控制码率、B 帧和 I 帧间隔。以下长录制、最小化恢复和停止保存端测通过；`-16341` 的内部含义没有公开文档，这些证据支持编码配置修复的效果，但没有独立证明其内部根因。

最终编码修复的 FaceTime 长录制通过：Luna 经本地会议入口开始，麦克风 Off，约一分钟处最小化并恢复，UI 5:00 时停止并返回空闲。Luna 用 QuickTime 播放，时间线推进至 11.25 秒。保存文件为 `Recording-20260930-164139-c203073f.mp4`，302.522 秒、H.264 3024 × 1964、8818 帧、`has_b_frames=0`，AAC 48 kHz 双声道至 302.460 秒。日志记录 `outcome=complete / segments=1 / failedAppends=0 / restarts=0`，停止后约 0.13 秒完成；未再出现写入错误或超时。处理选项已取消，没有执行转写或云端处理。媒体证据：`/private/tmp/voxstudio-app-capture-qa/encoder-final-media-check.json`；完成日志：`/private/tmp/voxstudio-encoder-final.log`。

Finder 静止窗口录制通过：只选 Finder，显示 `/tmp/voxstudio-app-capture-qa` 文件夹，麦克风 Off，保持窗口后停止并返回空闲。保存文件 `Recording-20260930-165028-24412b44.mp4` 为 85.705 秒、H.264 + AAC、单段，日志 `outcome=complete / failedAppends=0 / restarts=0`；没有视频冻结、写入错误或停止超时。该测试证明静止窗口可正常录制保存；ScreenCaptureKit 仍持续提供帧，不能据此声明验证了完全无回调场景。媒体证据：`/private/tmp/voxstudio-app-capture-qa/static-media-check.json`；日志：`/private/tmp/voxstudio-static-final.log`。

第一次目标退出端测未通过：FaceTime 在录制约 12 秒时 Cmd-Q，VoxStudio 仍继续录制；手动停止得到 75.047 秒可播放文件。已补强生命周期检查：终止通知直接使用退出进程 ID，避免依赖通知时可能滞后的运行应用快照；录制期间每秒通过 `NSRunningApplication(processIdentifier:)` 复核原目标 PID 与 bundle ID。最终目标退出端测通过：Luna 经 FaceTime 快捷入口录制，正常 Cmd-Q 后原 PID 77590 确认已退出。VoxStudio 自动停止，显示“所选应用已全部退出，已保存录制的内容”，处理选项取消后返回空闲。保存文件 `Recording-20260930-170221-282b7961.mp4` 为 35.988 秒、H.264 3024 × 1964 + AAC，单段。日志在 17:02:57.788 检出目标退出，17:02:57.939 完成保存，`reason=capture target lost / outcome=complete / failedAppends=0 / restarts=0`。媒体证据：`/private/tmp/voxstudio-app-capture-qa/target-exit-media-check.json`；日志：`/private/tmp/voxstudio-target-exit-final.log`。

## 验证边界

本机没有安装 Zoom、Teams、Webex，未进行这些软件的真实会议通话测试；其原生进程检测由 catalog 测试覆盖，真实 UI 快捷录制使用 FaceTime 验证。只在内置显示器上完成端测，跨显示器候选与范围恢复有自动化测试，未进行外接屏拔插、系统睡眠恢复或撤销录屏权限的人工端测。测试视频只保存在本机，未转写、上传或外发。

验证结束时 VoxStudio 保持空闲，测试音频全部暂停；本次启动的 localhost:18796 音频测试服务器已关闭。

# USB 设备录制、录后裁剪与区域设置

日期：2026-10-01。分支：`codex/recording-mobile-trim-region`，独立 worktree 从 `54fe22a7` 创建。

## 实现

1. Record 增加 Mobile Device 模式，枚举 USB 连接的 iPhone/iPad，支持刷新、设备质量预设、原生实时预览、设备音频及可选 Mac 麦克风。设备音频默认开启，Mac 麦克风默认关闭；支持无声视频。预览和录制复用同一个 AVCaptureSession，关闭预览窗口不停止录制，可从浮动控制或菜单重新打开。采集与停止在专用队列完成，USB 样本转换到 host clock 后接入既有写入、暂停、音频混合和保存流程。
2. 显示器、应用、窗口、区域及移动设备的可播放录制停止后，先打开原生 AVPlayerView 时间裁剪。保留完整视频或裁剪成功后才进入既有转写流程；无声视频只保存。取消保留原文件且不启动转写。不可播放的恢复分段继续使用既有恢复流程。
3. 裁剪采用精确重新编码，先导出临时文件，验证视频、音轨和时长，再写入最终路径及 journal，最后清理本次原录制与分段。失败保留原文件；pendingReview/pendingTrim 状态可在重启后恢复裁剪。清理限制在本次录制目录，不删除最终文件。
4. 区域选择增加适配 VoxStudio 外观的独立设置栏：宽高、重选、取消、分辨率、15/30/60 FPS、质量、光标、系统音频、麦克风和开始录制。优先放在选区外；开始前关闭设置栏和选择蒙层，ScreenCaptureKit 的显示器过滤及恢复过滤同时排除本进程，避免录入录制控制。
5. 桌面视频设置共享并持久化；输出保持纵横比例、不放大小尺寸源，使用偶数像素尺寸。新增英文及简体中文文案、相机权限说明和对应签名 entitlement。

本机 QuickRecorder 仅用于交互与 AVFoundation/ScreenCaptureKit API 参考，未复制其 AGPL 源码或资源。没有引入新的依赖。

## 自动化验证

```sh
swift test --filter 'RecordingUpgradeTests|RecordingPermissionTests|RecordingRegionGeometryTests|RecordingApplicationSelectionTests|RecordingScreenCaptureAuthorizationTests|RecordingTimeoutTests|RecordingJournalRecoveryTests|RecordingHealthStateMachineTests|RecordingCommitCursorTests|RecordingDeviceSelectionTests|RecordingFinishIsolationTests|LocalMeetingRecordingTests|ClipRangeControlTests|UserFacingCopyTests'
./scripts/bundle.sh debug --sign
```

默认 traits 下 61 项测试、14 个 suite 全部通过。新增 7 项测试覆盖移动设备默认值和权限分离、无声视频、纵向输出与设置持久化，以及真实 H.264/AAC 文件的两秒精确裁剪、音轨保留、原文件和分段清理、失败保全、journal 恢复与目录外文件保护。

较宽的测试筛选遇到原有语音库样例文件缺失及全局本地化断言失败；新增录制 key 不在失败列表。带 SparkleUpdates 的 test 编译还遇到既有 AppUpdaterTests 初始化参数与当前 API 不一致，默认 traits 的录制测试及签名 app 构建分别验证。

## 人工验收与边界

移动设备入口的 USB 连接、解锁和信任提示，以及无设备时禁用开始/预览按钮，已在签名应用中检查。本机没有连接 iPhone/iPad；实际设备画面、锁屏、方向切换、设备声音、Mac 麦克风同步、暂停恢复和拔线保存仍需实机验收。

Developer ID 与 MAS 两种签名构建均通过 bundle 与签名验证。系统设置显示同名 VoxStudio 的录屏开关已开启，但两个 worktree 签名进程均返回 TCC 未授权，无法进入真实录屏；未更改系统隐私设置。区域设置栏、录后原生裁剪交互及控制栏不入镜仍需在授权生效的环境完成端测，相关几何、设置与媒体裁剪逻辑已通过自动化测试。

所有媒体测试均为本机生成的合成音视频，未启动转写或上传。

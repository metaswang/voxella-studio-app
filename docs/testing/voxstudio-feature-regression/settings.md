# 设置与语音输入回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="s01"></a>

## S01 本地模型与资源管理

范围：Local Features readiness、安装、取消、空间。前置标记：L。定位：`Sources/VoxstudioPro/Settings/ModelsPane.swift`、`Sources/VoxstudioPro/Workbench/LocalModelInstallPlan.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| S01-C01 | 准备/P0 | 检查转录/字幕、speaker、dub、语义检索/rank、增强资源并实际调用对应小任务 | Ready有功能证据；不只读UI状态 |
| S01-C02 | 安装/P1 | 隔离测试用户缺一组模型时安装并执行小任务 | 下载完成/文件校验后可调用；进度真实 |
| S01-C03 | 中断/P1 | 下载过程中取消/断网，再恢复重试 | 支持恢复或重新下载；无假Ready/残留busy |
| S01-C04 | 磁盘/P1 | 受控低空间/损坏缓存副本环境准备模型 | 原因明确；不删除无关资源；可修复重试 |
| S01-C05 | 重启/P1 | 安装/准备后重启app查看feature状态 | 识别已有有效模型；版本不匹配时提示清楚 |

<a id="s02"></a>

## S02 BYOK Provider与模型路由

范围：API provider、测试连接、模型发现、task overrides。前置标记：B。定位：`Sources/VoxstudioPro/Settings/AISettingsPane.swift`、`Sources/VoxstudioPro/Settings/AIRequestOverridesView.swift`、`Sources/VoxstudioPro/LLM`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| S02-C01 | 连接/P0 | 在独立测试配置中使用已授权provider进行最小连接/QA请求 | 凭据不出报告；请求走选择的provider |
| S02-C02 | 模型/P1 | 刷新models、设置不同task model/effort/override并调用小任务 | 实际路由与设置对应；失败不会偷偷变更目的地 |
| S02-C03 | 无效/P1 | 用测试无效key/base URL/不存在model执行连接 | 清晰错误/恢复入口；不会无限spinner |
| S02-C04 | 持久化/P1 | 保存测试provider重启再读取masked状态 | 配置可用且Keychain/显示不泄漏secret |
| S02-C05 | 清理/P1 | 移除仅测试provider后恢复原配置并试无provider状态 | 不误删原provider；缺配置说明正确 |

<a id="s03"></a>

## S03 录制与Voice Input偏好

范围：默认视频配置、音频增强开关、dictation快捷键。前置标记：P。定位：`Sources/VoxstudioPro/Settings/RecordingPane.swift`、`Sources/VoxstudioPro/Settings/VoiceInputSettingsPane.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| S03-C01 | 默认/P1 | 隔离偏好修改录制默认质量/音源等可用项后创建录制 | 新任务应用设置；旧任务不意外改变 |
| S03-C02 | 增强/P1 | 切换本地/Cloud语音相关选项并查看后续处理选项 | 选择真实生效；Cloud依授权条件门控 |
| S03-C03 | 快捷键/P1 | 给Voice Input设置允许组合并触发/停止 | 一次触发一个面板；与常用编辑快捷键冲突可理解 |
| S03-C04 | 重启/P1 | 保存偏好退出重开，再进入Record/Voice Input | 设置持久化且按钮可操作 |
| S03-C05 | 取消/P1 | 取消快捷键录入/在失效设备偏好下打开录制 | 取消不改原值；失效设备可选择替代 |

<a id="s04"></a>

## S04 存储、缓存与媒体索引

范围：Storage统计、indexing开关、清理与重建。前置标记：L。定位：`Sources/VoxstudioPro/Settings/StoragePane.swift`、`Sources/VoxstudioPro/Search/Indexing`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| S04-C01 | 统计/P0 | 生成测试session/索引后查看Storage与文件大小 | 统计有合理变化；没有负大小或无限计算 |
| S04-C02 | 索引/P1 | 隔离设置关闭/开启media indexing并导入测试媒体 | 索引行为与开关一致；关闭不破坏原媒体 |
| S04-C03 | 清缓存/P1 | 只在一次性测试用户清理缓存再播放/打开session | 缓存清理范围明确；必要时可重建；原下载素材不删 |
| S04-C04 | 清索引/P1 | 只在隔离测试用户清理index后重建并搜索 | 状态清晰；重建后召回恢复；原项目/session保留 |
| S04-C05 | 失败/P1 | 无写权限/文件被占用时执行测试清理/索引 | 错误透明且UI可恢复；不宣称已清理全部 |

<a id="s05"></a>

## S05 通知、隐私与诊断偏好

范围：notifications、analytics/crash reports、保存。前置标记：L。定位：`Sources/VoxstudioPro/Settings/NotificationsPane.swift`、`Sources/VoxstudioPro/Settings/PrivacyPane.swift`、`Sources/VoxstudioPro/Telemetry`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| S05-C01 | 偏好/P1 | 在隔离设置修改analytics/crash选项并重启 | 偏好持久化；不把开关状态当作实际网络审计结论 |
| S05-C02 | 通知/P1 | 经人工允许通知后完成/失败各一个测试任务 | 通知类型/标题关联正确；不暴露无关内容 |
| S05-C03 | 禁用/P1 | 在隔离用户禁用通知再完成任务 | 无弹出通知；app内结果仍可发现 |
| S05-C04 | 取消/P1 | 通知授权被拒绝/系统勿扰时再次进入设置 | 状态可理解；不出现强迫授权循环 |
| S05-C05 | 显示/P2 | 中文/英文检查privacy解释、账户signed-out和开关焦点 | 文案可理解；导航和键盘操作可达 |

<a id="s06"></a>

## S06 Help、反馈与更新

范围：About/shortcuts、反馈预览、Sparkle渠道。前置标记：X。定位：`Sources/VoxstudioPro/Help/HelpView.swift`、`Sources/VoxstudioPro/Help/FeedbackView.swift`、`Sources/VoxstudioPro/Settings/UpdatesPane.swift`、`Sources/VoxstudioPro/App/AppUpdater.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| S06-C01 | 信息/P0 | 打开About、Keyboard Shortcuts和Local Features帮助 | 版本/快捷键与当前渠道一致；帮助可关闭 |
| S06-C02 | 反馈/P1 | 创建测试反馈草稿并查看截图/附件预览，取消提交 | 附带内容可审查；取消不外发 |
| S06-C03 | 更新/P1 | direct build执行Check for Updates只查看结果 | 成功/无更新/网络错误区分；不误用MAS更新入口 |
| S06-C04 | 渠道/P1 | 在MAS与direct对应构建检查更新菜单和链接 | MAS不显示Sparkle流程；direct存在正确入口 |
| S06-C05 | 异常/P1 | 离线打开需要网络的帮助/更新页面 | 有可恢复提示；本地编辑仍可进行 |

<a id="s07"></a>

## S07 Dictation与语音输入

范围：mic准备、global/inline输入、取消和恢复。前置标记：P。定位：`Sources/VoxstudioPro/SpeechInput/VoiceInputCoordinator.swift`、`Sources/VoxstudioPro/SpeechInput/SpeechInputRecovery.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| S07-C01 | 正常/P0 | 人工准备mic后在普通测试文本框口述已知中英文短句 | 转写插入目标输入；没有丢尾词 |
| S07-C02 | 快捷入口/P1 | 分别从Create Dictation及支持的inline control启动 | 使用正确焦点/输入上下文；一次只一录音会话 |
| S07-C03 | 取消/P1 | 中途停止/取消语音输入，再输入普通文字 | 取消不插入残留；键盘焦点恢复 |
| S07-C04 | 异常/P1 | mic禁用/设备断开/模型缺失时启动并恢复 | 原因可见；无无限Preparing；恢复后可再录 |
| S07-C05 | 边界/P1 | 长停顿、噪音、长句和应用切焦点期间录音 | 无大量幻觉/错框插入；恢复或错误说明明确 |

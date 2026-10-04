# 账户、Cloud及可选集成回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="c01"></a>

## C01 账户与VoxStudio Cloud登录

范围：signed-out、Google/Apple登录、登出与会话。前置标记：C。定位：`Sources/VoxstudioPro/Account`、`Sources/VoxstudioPro/Settings/AccountPane.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| C01-C01 | 未登录/P0 | 不登录打开Account及本地转录 | signed-out明确；允许的本地路径可使用 |
| C01-C02 | 登录/P1 | 仅显式授权后用测试账号走支持的Google/Apple渠道登录 | 账户身份正确；不切换未授权账号 |
| C01-C03 | 取消/P1 | 取消浏览器/native登录或返回错误callback | 不假登录；本地已有数据保留 |
| C01-C04 | 过期/P1 | 测试凭据过期/离线再进入Cloud依赖页面 | 显示需恢复会话；不无限循环登录 |
| C01-C05 | 登出/P1 | 在隔离测试账户登出再重启 | Cloud会话移除；本机数据按说明保留/处理；未误删除 |

<a id="c02"></a>

## C02 Cloud处理、上传与同步

范围：process/keep in Cloud、同步状态、retry。前置标记：C。定位：`Sources/VoxstudioPro/Workbench/CloudSessionSync.swift`、`Sources/VoxstudioPro/Workbench/ProcessingOptionsSheet.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| C02-C01 | 本地/P0 | 保持Process/Keep Cloud未选完成本地小任务 | 本地结果可用；不把Ready写成Cloud上传完成 |
| C02-C02 | 处理/P1 | 明确授权测试素材+Cloud目的地后仅Process Cloud完成任务 | 实际处理来源/输出可追踪；状态真实 |
| C02-C03 | 保留/P1 | 授权后仅Keep Cloud同步本地完成结果 | 本地处理与上传状态分开；Cloud可见需另证 |
| C02-C04 | 失败/P1 | 受控断网/超时中断同步再Retry cloud sync | 明确同步失败；本地结果可用；retry不重复创建错误session |
| C02-C05 | 冲突/P1 | 同一测试session在两端修改/删除后同步 | 冲突/删除策略可理解；不默默丢失用户修改 |

<a id="c03"></a>

## C03 授权、购买与恢复（仅测试环境）

范围：direct license、MAS lifetime、restore、entitlements。前置标记：X。定位：`Sources/VoxstudioPro/Account`、`Sources/VoxstudioPro/Settings/AccountPane.swift`；参考：[License设计](../../design/mac-license-key-activation.md)。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| C03-C01 | 门控/P0 | 不交易查看未授权/已授权测试状态及本地任务入口 | 功能门控与渠道/既有entitlement一致 |
| C03-C02 | 激活/P1 | 显式授权后用专用测试license key在隔离环境激活 | 正确状态生效；报告不含key；不消费真实license |
| C03-C03 | 购买/P1 | 只在确认StoreKit sandbox且获明确授权后测试成功购买流程 | receipt/entitlement对应测试product；无真实扣款 |
| C03-C04 | 取消失败/P1 | sandbox中取消购买、网络失败/无效测试license | 不授予假权限；可重试且状态可解释 |
| C03-C05 | 恢复/P1 | 明确授权后在sandbox恢复测试购买并重启 | entitlement可恢复且持久化；不触发新购买 |

<a id="c04"></a>

## C04 Calendar与云会议Bot

范围：Google Calendar OAuth、会议列表、bot启用重试。前置标记：C。定位：`Sources/VoxstudioPro/MeetBot/GoogleCalendarSettingsPane.swift`、`Sources/VoxstudioPro/MeetBot/MeetBotView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| C04-C01 | 未连接/P0 | 未登录/未连接Calendar打开会议页 | 本地录制入口和连接前置明确；无旧用户会议泄漏 |
| C04-C02 | 连接/P1 | 显式授权后仅测试日历账号OAuth并读取测试会议 | scope/账号和时间范围正确；取消不假连接 |
| C04-C03 | 会议/P1 | 输入有效/无效测试会议链接、可选标题和bot name | 类型/URL校验准确；不向真实会议派出bot |
| C04-C04 | bot/P1 | 授权后在自有测试会议Enable/Disable/Retry并观察join/结果 | 实际join/结束有证据；不凭queued认为已参会 |
| C04-C05 | 恢复/P1 | OAuth过期、无会议、日历断网及bot被拒入 | 错误/重试清晰；不重复加入或显示假Ready |

<a id="c05"></a>

## C05 在线视频导入

范围：YouTube URL/元信息/音频导入/浮窗播放。前置标记：X。定位：`Sources/VoxstudioPro/Workbench/NetVideo`、`Sources/VoxstudioPro/Workbench/NetVideoFloatingPlayer.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| C05-C01 | 正常/P0 | 授权联网并选择有权使用的短测试URL导入 | 元信息与素材对应；真实媒体可转录/预览 |
| C05-C02 | 校验/P1 | 输入无效URL、不支持domain、私人/已删除视频 | 清晰拒绝或说明访问失败；不生成空成功session |
| C05-C03 | 范围/P1 | 支持时选择片段范围并导入 | 时长/内容对应所选range；不误传全长 |
| C05-C04 | 播放/P1 | 打开浮动播放器、pause/seek/关闭后回session | 控制对应当前来源；无多个残留播放 |
| C05-C05 | 恢复/P1 | 导入中取消/断网后重试另一短URL | 任务有终态；可重新导入；没有重复结果 |

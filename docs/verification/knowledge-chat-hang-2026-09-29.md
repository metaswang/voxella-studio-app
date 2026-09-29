# 知识库聊天发送卡死修复验证

日期：2026-09-29。环境：Apple Silicon、macOS 26.6.1、签名 Debug 非 MAS 应用。

## 故障证据

- 原进程 PID 88858 的 Activity Monitor 内存从 4.93 GB 增至 12.44 GB、21.80 GB，持续 Not Responding。
- 用户确认在按 Return 发送问题后立即卡死；原会话包含约 3518 字符的长摘要、一个引用，以及问题“此视频多长”。
- 原进程采样的主线程持续停在 SwiftUI / AttributeGraph 布局事务、文本测量和 GeometryReader 调用链。后续 vmmap 显示约 24 GB footprint，其中 MALLOC_SMALL 约 23.4 GB；GPU 分配约 122 MB。
- 这些证据支持主线程布局失控和小对象大量分配。没有通过逐项开关旧组件确定唯一触发组件，因此不将某一个视图宣称为已经单独证实的根因。

## 实现

- 输入框改用原生 NSTextView；通过纯 `sizeThatFits` 测量，限制 1–5 行并在内部滚动，移除布局测量写回 SwiftUI 高度状态的路径。Return 在原生事件结束后异步提交问题快照，同一事件周期去重；保留中文输入法候选确认和 Shift+Return 换行。
- 聊天区域和消息卡片使用有限宽度；消息行按稳定 ID 独立比较。等待状态使用标准进度指示器、单行状态和停止按钮，移除三组 TimelineView 动画及消息移动动画。
- 底部滚动请求延迟合并并取消过时任务。使用 `ScrollPosition` 的底部边缘保持长回答和引用增长时的跟随；只有用户滚动会更新跟随意图，向上翻阅后不抢回底部。
- 已经完整生成的回答直接发出一个终止事件，不再人为切成小块逐字重放；保留真正的 delta 事件兼容性。
- 停止立即清理等待状态，保留已经接受的问题和有内容的部分回答；会话切换、取消后的旧事件不能写入当前会话。第一个终止事件立即结束消费并仅持久化一次，不依赖服务端主动关闭流。
- 注入测试用答案来源、聊天存储和模型可用性，不改变默认生产行为。

## 自动化验证

```sh
swift test -j 4 --traits BundledSpeech --filter Knowledge
VOXSTUDIO_KB_STRESS_SECONDS=600 swift test --skip-build --traits BundledSpeech --filter repeatedSendCancelAndWaitingMemoryStayBounded
```

测试覆盖原生回车延迟提交及去重、输入框高度增减和封顶、长摘要与引用、窄宽度及 80%–150% 缩放、重复发送/取消、迟到事件、异常结束、部分回答保存、重复终止事件、会话切换、Markdown 表格和代码块、长回答完成后底部可见。

压力测试使用实际 SwiftUI 聊天面板和 controller、临时聊天存储、可控答案流，先预热 5 次，再运行 50 次交替发送/取消或完成，随后保持等待 600 秒。用 `task_info(TASK_VM_INFO).phys_footprint` 采集物理内存，并在主线程每 100 ms 调度一次布局及心跳。它验证聊天 UI 和生命周期，不包含真实 LLM / embedding 模型加载。

最终知识库测试：95 项、23 个 suite 全部通过（3.640 秒）；其中长回答完成后底部保持可见的原生窗口回归测试用时 0.203 秒。

为避免占用同工作区的 SwiftPM 构建锁，600 秒测试实际使用上述构建生成的测试 bundle，直接通过 Xcode 的 `swiftpm-testing-helper` 运行，并设置 `DYLD_FRAMEWORK_PATH` 指向 Xcode 的 macOS Testing framework。测试参数和代码与 `swift test --skip-build` 相同。

两次试运行分别记录了 623.8 ms 和 629.1 ms 心跳延迟，超过 500 ms 验收线，因此这两轮没有算作通过。两次延迟均与对测试进程执行外部 `vmmap -summary` 的时刻重合，采样扰动是可能的影响因素；第一轮还同时进行了签名打包。最终测试在构建完成后停止所有外部进程采样，只读取进程内部记录的数据，验收门槛保持不变。前两轮日志保留在 `/private/tmp/voxstudio-kb-stress-during-build.log` 和 `/private/tmp/voxstudio-kb-stress-with-vmmap.log`。

最终 600 秒测试通过，总运行时间 602.879 秒（包含预热和 50 次循环），未记录失败断言。

| 指标 | 结果 | 验收条件 |
| --- | --- | --- |
| 预热后的物理内存基线 | 172 MiB | 预热 5 次后记录 |
| 循环及等待期间采样峰值 | 183 MiB，较基线增加约 11 MiB | 增长小于 200 MiB |
| 最后五分钟内存变化 | 小于 50 MiB 的断言通过；第 5 / 9 分钟采样为 61 / 62 MiB | 增长小于 50 MiB |
| 最大主线程心跳延迟 | 36 ms | 小于 500 ms |
| 每次显式布局调用 | 所有小于 500 ms 的断言通过 | 小于 500 ms |
| 最终取消及布局 | 小于 500 ms 的断言通过，等待消息已清理 | 小于 500 ms |

内存数值为二进制 MiB；峰值是测试在预热之后记录的采样峰值。最终取消检查直接执行与停止按钮相同的 controller 操作，并测量随后原生窗口布局；没有单独输出取消耗时数值。第 0 / 1 / 2 / 3 / 5 / 7 / 9 分钟的等待采样分别为 146 / 66 / 66 / 61 / 61 / 61 / 62 MiB。

最终测试日志：`/private/tmp/voxstudio-kb-tests-final.log`、`/private/tmp/voxstudio-kb-stress-final.log`。签名构建日志：`/private/tmp/voxstudio-kb-build-final.log`。

## 签名应用实测

启动命令遵循仓库要求：`./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"`。

最终签名构建通过 `codesign --verify --deep --strict --verbose=2`，签名为 Developer ID Application: GREATWAY GLOBAL PTE. LTD.，Team ID `4DMAQ32SNU`；应用 ID `com.voxella.studio`。麦克风和 Keychain entitlement 存在，未启用 Apple Sign In；Developer ID provisioning profile 和 Sparkle 均已内嵌。Designated Requirement 约束 Apple Developer ID 签名链、上述应用 ID 和 Team ID。

构建后的首次 `open` 紧接着终止旧进程返回 Launch Services `-600`，旧进程退出后重试成功。最终开发应用已经运行。

实际打开原故障视频会话并按 Return 发送同一个问题；等待状态正常更新，问答正常结束，应用可以读取 UI 状态。回答本身返回“证据不足以确定视频总时长”，回答质量不属于本次性能修复的验收项。

修复后采样 PID 20812：主线程 101/102 个样本在正常 AppKit 事件循环等待，未出现原来的持续布局循环；footprint 约 2.2 GB、峰值约 2.9 GB（包含实际模型和整个应用的运行内存，与隔离 UI 压力测试不能直接比较）。第一轮实测还发现回答引用增长后底部被遮挡，已经补充滚动跟随修复及专门的回归测试。

原始现场证据保存在本机临时目录：`/private/tmp/voxstudio-kb-hang-88858.sample.txt`、`/private/tmp/voxstudio-kb-fixed.sample.txt`。临时目录中的证据不是版本库中的持久工件。

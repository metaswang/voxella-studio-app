# 应用与工作区回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="a01"></a>

## A01 应用启动与构建身份

范围：本地包启动、单实例、版本和签名。前置标记：L。定位：`Sources/VoxstudioPro/App/AppDelegate.swift`、`Sources/VoxstudioPro/App/main.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| A01-C01 | 正常/P0 | 使用已签名的指定 app 绝对路径启动，打开 About | 进程可用；显示的版本/build 与该包 Info.plist 一致 |
| A01-C02 | 身份/P0 | 核对运行进程可执行路径、bundle ID、Team ID、designated requirement | 运行的确为目标包；不把 /Applications 或旧签名实例当作目标 |
| A01-C03 | 重启/P1 | 退出并从同一绝对路径重新启动 | 无重复窗口/服务；已有 session 和项目可重开 |
| A01-C04 | 异常/P1 | 在一次性测试目录使用缺失/损坏包路径启动 | 清晰失败；不自动启动另一个同名旧包 |
| A01-C05 | 恢复/P1 | 运行中再次 open 同一包，随后正常退出 | 聚焦现有实例；无重复录制/MCP 服务；退出不挂起 |

<a id="a02"></a>

## A02 首次运行与本地准备

范围：引导、功能介绍、模型准备和重新进入。前置标记：L。定位：`Sources/VoxstudioPro/Onboarding/OnboardingView.swift`、`Sources/VoxstudioPro/Onboarding/LocalFeaturePreparation.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| A02-C01 | 正常/P0 | 在隔离测试用户中完成首次引导并选择本地准备 | 引导完成后进入工作区；选择有明确效果 |
| A02-C02 | 取消/P1 | 准备过程中取消/离开并重新进入 | 状态可恢复；没有假 Ready 或永久 Preparing |
| A02-C03 | 离线/P1 | 缺少模型且离线进入引导 | 指出缺少资源和重试入口；不宣称可本地处理 |
| A02-C04 | 边界/P1 | 已安装模型的测试用户再次打开引导入口 | 识别已准备状态；不重复下载已有完整资源 |
| A02-C05 | 显示/P2 | 小窗口与中英文分别走完介绍 | 按钮可达；文案无裁切；介绍结束不丢失任务 |

<a id="a03"></a>

## A03 工作区导航与任务检索

范围：Create、Recent、前进后退、全局 session 搜索。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/WorkbenchNavigator.swift`、`Sources/VoxstudioPro/Workbench/SessionSearchPalette.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| A03-C01 | 正常/P0 | 依次进入 Transcribe、Voiceover、Knowledge、Video Editor，再前进/后退 | 返回正确位置；当前任务和编辑内容保留 |
| A03-C02 | 检索/P1 | 以中文、英文、空格搜索已知 session，点击结果 | 结果对应匹配 session；打开正确任务 |
| A03-C03 | 空态/P1 | 搜索不存在标题并清空搜索 | 显示空结果；清空后恢复列表 |
| A03-C04 | 状态/P1 | Recent 中同时准备完成、运行、失败任务并筛选 | 状态筛选不混淆；运行任务可继续查看 |
| A03-C05 | 快捷键/P2 | 在文本输入中与非输入焦点分别使用任务搜索快捷键 | 搜索面板可关闭；文本编辑快捷键不误触任务操作 |

<a id="a04"></a>

## A04 界面布局与操作可达性

范围：面板、应用缩放、全屏、主题、本地化、快捷键。前置标记：L。定位：`Sources/VoxstudioPro/App/MainMenu.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Layout.swift`、`Sources/VoxstudioPro/Localization`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| A04-C01 | 布局/P1 | 切换 Default/Media/Vertical 布局并显示/隐藏各面板 | 当前项目不变；预览、时间线和 Inspector 均可重新找回 |
| A04-C02 | 缩放/P1 | 放大/缩小/重置应用缩放，调到最小窗口再恢复 | 控件可见可点击；比例恢复准确 |
| A04-C03 | 全屏/P2 | 切换全屏及最大化焦点面板，再退出 | 焦点/选中片段保留；布局无重叠 |
| A04-C04 | 本地化/P1 | 在隔离设置中切换中文/英文、浅色/深色后重开 | 文字与主题按选择生效；必要重启有提示 |
| A04-C05 | 键盘/P1 | 有无片段选择及文本焦点时使用 V/C/T、Undo、Save | 正确作用于当前对象；文本框不会被剪辑快捷键破坏 |

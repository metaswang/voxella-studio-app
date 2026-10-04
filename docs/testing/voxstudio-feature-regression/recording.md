# 录制回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="r01"></a>

## R01 录制权限与目标包身份

范围：路径一致、enabled、签名、人工授权与实录复核。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/RecordingScreenCaptureAuthorization.swift`；参考：[签名/TCC记录](../../../skills/voxstudio-debug-build/references/signing-and-tcc.md)。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R01-C01 | 正常/P0 | 记录运行目标路径/签名；人工确认Settings同一包且屏幕录制enabled；录10秒 | 视频有帧、可播；system audio开时有音轨；不是仅开关截图 |
| R01-C02 | 错路径/P0 | 在隔离权限准备环境发现同名/旧路径条目；人工删除旧项并加入目标包、enabled、重启 | 明确确认路径和签名；重启后的目标实际采集成功 |
| R01-C03 | 禁用/P1 | 人工在隔离用户中禁用目标权限，再触发录制 | 可理解权限说明；无假成功或永久Preparing；人工恢复后可录 |
| R01-C04 | 身份/P0 | 对比 Developer ID 与其他签名模式的包身份及授权状态 | 不复用同名enabled作为证据；身份不匹配明确Blocked而非录制通过 |
| R01-C05 | 弹窗/P1 | 首次请求/重新确认/认证弹窗出现时交给用户准备并确认 | 记录实际弹窗与处理者；没有CUA绕过；确认后复核录制 |

<a id="r02"></a>

## R02 音频源与混音

范围：麦克风、system audio、独立选择、音量警告。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/RecordingAudioMixer.swift`、`Sources/VoxstudioPro/Workbench/Recording/RecordingAudioDevices.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R02-C01 | 麦克风/P0 | Audio模式只开默认麦克风，口述已知短句录15秒 | 输出包含口述；不包含关闭的系统音源 |
| R02-C02 | 系统音/P0 | 麦克风Off、system audioOn，播放Downloads短音频 | 输出含播放内容；Off的麦克风不混入 |
| R02-C03 | 混音/P1 | 同时播放素材并口述，分别静音/取消静音麦克风 | 混音两路可辨；静音阶段不捕获麦克风 |
| R02-C04 | 设备/P1 | 选择外接输入并在测试中断开，之后恢复默认输入 | 丢失设备有提示/可恢复；不会无限录制无声 |
| R02-C05 | 空源/P1 | 尝试关闭所有音源；用静音输入观察波形/低音量提示 | 防止无效Audio配置；提示与实际输入状态一致 |

<a id="r03"></a>

## R03 整屏录制

范围：Display选择、多屏、画面及系统音。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift`、`Sources/VoxstudioPro/Workbench/Recording/RecordingContentPicker.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R03-C01 | 正常/P0 | 选择主屏播放测试视频并录制20秒 | 有完整画面和所选音频；时长/帧尺寸合理 |
| R03-C02 | 多屏/P1 | 有第二屏时选择另一屏，在两个屏幕显示不同标记 | 输出只含目标屏；无法接屏则Blocked-Hardware |
| R03-C03 | 取消/P1 | 在Display系统选择器取消，再重新选择开始 | 取消回到可操作状态；第二次可成功 |
| R03-C04 | 中断/P1 | 隔离测试中移除/睡眠目标外接屏，停止并检查输出 | 中断理由可见；已写部分可恢复或明确失败 |
| R03-C05 | 权限/P0 | 分别验证屏幕enabled但身份不匹配与准备正确后的Display | 不能以Window成功替代Display；正确身份实际出帧 |

<a id="r04"></a>

## R04 指定应用录制

范围：App选择、进程、多应用和音频。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/RecordingApplicationSelection.swift`、`Sources/VoxstudioPro/Workbench/Recording/RecordingApplicationPicker.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R04-C01 | 正常/P0 | 选播放测试媒体的应用，录制其窗口和声音 | 只包含所选应用内容；输出可播放 |
| R04-C02 | 多应用/P1 | 选择支持的多个应用并在其间切换窗口 | 选中应用可捕获；未选应用不意外出现 |
| R04-C03 | 进程/P1 | 同名应用/多个实例中选择指定PID并查看实际画面 | 目标进程正确；列表标签/选择可区分 |
| R04-C04 | 目标丢失/P1 | 关闭所选测试应用的所有窗口/退出进程 | 可理解目标丢失状态；无假持续画面 |
| R04-C05 | 刷新/P1 | 先打开选择器后启动新测试应用、刷新列表并取消重选 | 新应用可发现；过期条目不会误录别的应用 |

<a id="r05"></a>

## R05 指定窗口录制

范围：系统窗口选择器、单窗、重选。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/RecordingWindowSelection.swift`、`Sources/VoxstudioPro/Workbench/Recording/RecordingContentPicker.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R05-C01 | 正常/P0 | 选择测试播放器窗口并录15秒 | 画面来自目标单窗；系统音选项效果可核对 |
| R05-C02 | 取消/P1 | 取消系统选择器后再选另一窗口 | 取消不创建伪录制；可重新选择成功 |
| R05-C03 | 变化/P1 | 录制时移动/调整目标窗尺寸并用其他窗遮挡 | 输出行为与捕获策略一致；无崩溃/永久冻结 |
| R05-C04 | 目标关闭/P1 | 录制期间关闭目标测试窗口 | 终态/错误清晰；已写文件可处理 |
| R05-C05 | 隔离/P0 | 验证Window成功后单独执行Display/Region准备检查 | 不推断全局屏幕权限已有效；每种模式单独留证 |

<a id="r06"></a>

## R06 区域录制

范围：Region框选、坐标、多屏与取消。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/DisplayRegionOverlay.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R06-C01 | 正常/P0 | 圈定播放器中央带标记区域录15秒 | 输出裁剪区域正确；不包含框外测试标记 |
| R06-C02 | 边界/P1 | 选择屏幕边缘、小区域和极宽区域 | 最小尺寸校验明确；输出不倒置、不越屏幕边界 |
| R06-C03 | 取消/P1 | 框选过程中Escape，再重新圈选 | 浮层消失；可再次开始；不遗留鼠标拦截 |
| R06-C04 | 多屏/P1 | 在外接屏不同缩放比例上选已知矩形 | 坐标与像素尺寸对应；不录到主屏其他区域 |
| R06-C05 | 重启/P1 | 重开app后再次进入Region并完成短录 | 权限/区域状态不永久缓存旧坐标；文件实际有帧 |

<a id="r07"></a>

## R07 USB移动设备录制

范围：iPhone/iPad枚举、屏幕、device audio、可选mic。前置标记：H。定位：`Sources/VoxstudioPro/Workbench/Recording/MobileDeviceCaptureSource.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R07-C01 | 正常/P0 | 连接已信任的USB iPhone/iPad，播放合法测试内容并录20秒 | 设备可选；输出设备屏幕且有真实帧 |
| R07-C02 | 音源/P1 | 分别device audioOn/Off、micOn/Off录短片 | 音源选择真实生效；不混入未选Mac系统音 |
| R07-C03 | 旋转/P1 | 录制时设备纵横屏切换并查看输出尺寸 | 方向/缩放合理；不花屏或永久冻结 |
| R07-C04 | 断开/P0 | 录制中拔USB，再重连尝试录制 | 中断有终态及恢复入口；再次可发现设备 |
| R07-C05 | 信任/P1 | 未解锁/未信任/无设备时进入模式 | 显示设备前置条件；Trust弹窗由人处理；无设备不伪成功 |

<a id="r08"></a>

## R08 录制视频质量设置

范围：Automatic/1080p/720p、帧率、质量与预设。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/RecordingVideoSettings.swift`、`Sources/VoxstudioPro/Workbench/Recording/RecordingVideoSettingsView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R08-C01 | 分辨率/P0 | 对同一目标分别录Automatic、1080p、720p | ffprobe尺寸符合保持比例/上限规则；画面不拉伸 |
| R08-C02 | 帧率/P1 | 按界面提供帧率分别录动态测试视频 | 实际fps可核对；时间连续且无明显冻结 |
| R08-C03 | 质量/P1 | 低/中/高质量录同一时长同一目标 | 文件可解码；质量/体积变化合理且能记录 |
| R08-C04 | 持久化/P1 | 修改设置后关闭重开，再切换Audio与视频模式 | 有效视频设置保留；Audio模式不显示错误视频要求 |
| R08-C05 | 输入边界/P1 | 小窗、Retina大屏及纵向移动设备使用预设 | 按比例缩放；不零尺寸、不超过所选上限 |

<a id="r09"></a>

## R09 录制控制与运行状态

范围：开始、pause/resume、停止、浮窗、菜单栏。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/RecordingFloatingControls.swift`、`Sources/VoxstudioPro/Workbench/Recording/RecordingStatusItemController.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R09-C01 | 正常/P0 | 开始→Pause→Resume→Stop，核对计时及输出 | 暂停段不误计有效录制内容；恢复后继续；文件完整 |
| R09-C02 | 控件/P1 | 主窗/浮窗/菜单栏分别停止一次独立录制 | 均操作同一session；停止只执行一次 |
| R09-C03 | 快速操作/P1 | 连续快速Start/Stop或双击Stop | 状态串行合理；无多个writer或损坏伪Ready |
| R09-C04 | 导航/P1 | 录制时切换工作区/最小化主窗，再找回录制 | 录制持续可控；浮窗/菜单栏能返回正确状态 |
| R09-C05 | 终止/P1 | 隔离短录时退出app或系统停止共享 | 停止原因明确；资源释放；重开可发现可恢复产物 |

<a id="r10"></a>

## R10 录制审阅、裁剪与后续转录

范围：Review、保留全长、裁剪、取消、恢复。前置标记：P。定位：`Sources/VoxstudioPro/Workbench/Recording/RecordingReview.swift`、`Sources/VoxstudioPro/Workbench/Recording/RecordingSessionManifest.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R10-C01 | 保留/P0 | 短录结束后选择Keep full recording & continue | 完整媒体保存并进入明确后续任务；首尾存在 |
| R10-C02 | 裁剪/P0 | 只保留中间有已知话语的范围并继续 | 输出长度与范围相符；后续转录对应保留内容 |
| R10-C03 | 取消/P1 | 审阅取消/放弃仅本次标记可丢弃测试录制 | 不会误删既有录制；确认前动作可撤回 |
| R10-C04 | 异常/P1 | 在隔离磁盘配额环境模拟写失败/空间不足 | 提示原因且无伪成功文件；已有数据不被覆盖 |
| R10-C05 | 恢复/P1 | 审阅/finishing期间异常结束后重开检查manifest与结果 | 显示可恢复/中断状态；不永远busy或丢失完成媒体 |

<a id="r11"></a>

## R11 本地会议快捷录制

范围：检测会议应用、本地App/Window/Display快捷入口。前置标记：P。定位：`Sources/VoxstudioPro/MeetBot/LocalMeetingRecordingSection.swift`、`Sources/VoxstudioPro/MeetBot/MeetingAppPresence.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| R11-C01 | 已打开/P0 | 打开支持的测试会议应用但不登录Cloud，从本地会议入口录制 | 路由到正确应用/进程；系统音打开且本地录制可用 |
| R11-C02 | 无应用/P1 | 关闭所有测试会议应用查看快捷入口 | 显示未发现支持应用；不指向旧PID |
| R11-C03 | 并发/P1 | 打开两个支持应用并分别选择其快捷入口 | 每次目标准确；不能误录另一会议 |
| R11-C04 | 麦克风/P1 | 在快捷录制前明确micOff，跳转后核对音源 | 保留明确mic选择；system audio按会议配置启用 |
| R11-C05 | 恢复/P1 | 目标退出/权限缺失后使用手动Display/Window入口 | 明确提示问题；可回到手动选择，不强迫Cloud登录 |

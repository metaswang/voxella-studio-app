# 视频编辑器回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="e01"></a>

## E01 项目建立、设置与保存

范围：New/Open/Save As、分辨率fps比例、恢复。前置标记：L。定位：`Sources/VoxstudioPro/Project/VideoProject.swift`、`Sources/VoxstudioPro/Project/Settings`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+ProjectSettings.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E01-C01 | 正常/P0 | 在临时目录New项目、导入并保存后重开 | 项目内容/时间线保存；路径对应当前工程 |
| E01-C02 | 设置/P1 | 设置分辨率、帧率、预设比例/自定义比例并保存 | 预览/导出尺寸和时基匹配；无无效零值 |
| E01-C03 | 另存/P1 | Save As到另一临时路径，独立修改两份 | 副本可打开；原工程不被意外覆盖 |
| E01-C04 | 不匹配/P1 | 导入与工程尺寸/fps不一致的媒体并处理提示 | 用户选项生效；没有隐式破坏既有工程设置 |
| E01-C05 | 异常/P1 | 取消New/Open/Save、只读目标、损坏工程副本 | 取消保留原工程；错误明确且可再次打开正常工程 |

<a id="e02"></a>

## E02 媒体库与文件关联

范围：Import、文件夹、sort/filter/search、relink/swap。前置标记：L。定位：`Sources/VoxstudioPro/MediaPanel/MediaTab`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Relink.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+MediaSwap.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E02-C01 | 导入/P0 | 导入Downloads音频/视频/测试图片并查看metadata | 类型、尺寸、时长正确；可预览并加入时间线 |
| E02-C02 | 组织/P1 | 在临时工程创建folder、移动/改名测试媒体、sort/filter/search | 组织和筛选准确；引用片段仍连到相同媒体 |
| E02-C03 | 重链/P0 | 移动测试媒体副本使离线，再执行Relink | 离线提示准确；重链后片段/时长及播放恢复 |
| E02-C04 | 替换/P1 | 对测试媒体执行允许的Media Swap并Undo | 关联片段按规则替换；Undo恢复原源 |
| E02-C05 | 异常/P1 | 取消导入、损坏文件、重复文件及移除仅测试素材 | 错误可理解；不会留下不可操作项目或误删原下载文件 |

<a id="e03"></a>

## E03 时间线添加、选择、移动与吸附

范围：drag/add/insert、位置、范围选择、zoom/snap。前置标记：L。定位：`Sources/VoxstudioPro/Timeline/TimelineInputController.swift`、`Sources/VoxstudioPro/Timeline/SnapEngine.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E03-C01 | 添加/P0 | 把导入媒体拖入空时间线，核对duration后播放并保存 | 真实片段出现在track；duration>0；可播并持久化 |
| E03-C02 | 移动/P1 | 移动片段到已知秒数和不同track，开启/关闭吸附 | 位置按设置生效；吸附指示与实际边界一致 |
| E03-C03 | 多选/P1 | 框选/多选及Select Forward on Track/All Tracks | 选中集合正确；未选片段不被移动 |
| E03-C04 | 范围/P1 | 建立时间线范围后移动/缩放视图 | 范围仍指向正确时码；边界可调整 |
| E03-C05 | 边界/P1 | 拖至0秒前、轨道空白尾部及极大/极小timeline缩放 | 不产生负时长/负start；可定位片段且不丢失 |

<a id="e04"></a>

## E04 剪切、分割与修剪

范围：Razor、Split at playhead、Trim Start/End。前置标记：L。定位：`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+ClipMutations.swift`、`Sources/VoxstudioPro/Toolbar/ToolbarView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E04-C01 | 分割/P0 | 在10秒split一个30秒片段，再播放两侧 | 两片连贯；总有效内容和时长符合原素材 |
| E04-C02 | razor/P1 | 切换Razor在多track测试位置切割，再回Pointer | 只切目标片段；工具焦点和切点准确 |
| E04-C03 | trim/P1 | 拖动边缘及Q/W分别修剪start/end | source入出点正确；音视频同步 |
| E04-C04 | 边界/P1 | 在片段首尾/空白处分割，尝试修剪超过source | 阻止非法空片/越源范围；项目可继续编辑 |
| E04-C05 | 撤销/P0 | 多次剪切修剪后Undo/Redo并重开保存工程 | 逐步恢复对应状态；保存后内容一致 |

<a id="e05"></a>

## E05 Ripple、Overwrite与剪贴板

范围：ripple delete/trim、overwrite、cut/copy/paste、undo。前置标记：L。定位：`Sources/VoxstudioPro/Editor/RippleEngine.swift`、`Sources/VoxstudioPro/Editor/OverwriteEngine.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Clipboard.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E05-C01 | ripple/P0 | 删除中间测试片段用Ripple Delete | 后方片段按规则前移；选中范围/track影响准确 |
| E05-C02 | overwrite/P1 | 在重叠位置执行Overwrite/允许的插入动作 | 被覆盖范围正确；未重叠内容保留 |
| E05-C03 | 剪贴板/P1 | copy/cut/paste单片、多片及跨timeline片段 | 相对位置/链接规则正确；cut仅移除目标 |
| E05-C04 | 撤销/P0 | ripple/overwrite/paste之后连续Undo/Redo | 片段顺序、source范围和track归属完整恢复 |
| E05-C05 | 边界/P1 | 空选择、空剪贴板、锁定track上执行编辑 | 安全禁用或明确提示；无误修改未选内容 |

<a id="e06"></a>

## E06 轨道、链接与片段控制

范围：增删轨、锁定mute/solo、音视频link/unlink。前置标记：L。定位：`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Tracks.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Linking.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E06-C01 | 轨道/P0 | 建立视频/音频track并移动片段、重命名/排序 | 渲染层次/音轨正确；保存后track属性保留 |
| E06-C02 | 锁定/P1 | 锁定track后尝试移动、delete、trim | 锁定内容不变；解锁后可正常编辑 |
| E06-C03 | 音源/P1 | mute/solo不同音频track进行预览与导出 | 实际听到的track与选择一致；非选音源不混入 |
| E06-C04 | 链接/P1 | link音视频再移动/trim；unlink后独立操作 | 联动范围明确且同步；解绑后不意外连带 |
| E06-C05 | 删除/P1 | 仅删可丢弃测试track后Undo | 作用范围明确；Undo恢复片段和轨道属性 |

<a id="e07"></a>

## E07 多时间线与嵌套

范围：new/active timeline、nest/unnest。前置标记：L。定位：`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Timelines.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Nesting.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E07-C01 | 多线/P0 | 新建两条时间线放不同测试素材并切换 | 预览/时长/选中内容属于当前timeline |
| E07-C02 | 嵌套/P1 | 把多个测试片段Nest后播放、展开允许入口 | 嵌套内容顺序/音画/时长正确 |
| E07-C03 | 编辑/P1 | 进入子timeline修改片段，再回父timeline | 父输出反映子更新；不复制错版本 |
| E07-C04 | 保存/P1 | 保存重启并分别导出两条timeline | 层级关系保留；导出使用正确活动timeline |
| E07-C05 | 异常/P1 | 尝试空选嵌套/非法自引用及删除测试子timeline | 拒绝非法循环或明确依赖；不崩溃/丢失父工程 |

<a id="e08"></a>

## E08 多机位与同步

范围：音频同步、时间对齐、多机位角度切换。前置标记：L。定位：`Sources/VoxstudioPro/Timeline/MulticamEngine.swift`、`Sources/VoxstudioPro/Inspector/Tabs/MulticamTab.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Sync.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E08-C01 | 同步/P0 | 两份含相同拍手声但偏移不同的测试片段执行同步 | 拍手声/画面对齐；偏移量符合已知标记 |
| E08-C02 | 多机位/P1 | 创建多机位并切换不同angle播放 | 对应angle画面正确；共用时间基准不跳跃 |
| E08-C03 | 剪辑/P1 | 在多个时点切换angle并保存/导出 | 成片按已记录切点切镜头；声音策略一致 |
| E08-C04 | 失败/P1 | 无共用音频/静音来源执行音频同步 | 说明无法对齐；不假装精确同步 |
| E08-C05 | 撤销/P1 | 同步和切angle后Undo/Redo并重开 | 原偏移/angle状态恢复准确；项目结构可重建 |

<a id="e09"></a>

## E09 预览播放、速度与帧抓取

范围：play/seek/frame step/speed/zoom、capture frame。前置标记：L。定位：`Sources/VoxstudioPro/Preview`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+FrameCapture.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E09-C01 | 播放/P0 | 预览非空timeline，pause/seek到已知画面 | 播放计时、音画和所选timeline一致 |
| E09-C02 | 帧步/P1 | 在30fps工程逐帧前后并跳到起止 | 步进时间对应时基；边界不会越界 |
| E09-C03 | 速度/P1 | 用界面提供的低/高速播放并恢复1× | 计时/声音策略合理；不改变工程内容 |
| E09-C04 | zoom/P2 | Fit与缩放预览、改变窗口大小 | 画面比例正确；操作不改变导出尺寸 |
| E09-C05 | 抓帧/P1 | 在已知时刻Capture Frame to Media并重新打开图片 | 图片来自该帧；尺寸正确；库里可加入时间线 |

<a id="e10"></a>

## E10 变换、属性与关键帧

范围：position/scale/rotate/opacity、插值、keyframe。前置标记：L。定位：`Sources/VoxstudioPro/Inspector/Keyframes`、`Sources/VoxstudioPro/Inspector/Components/InspectorPositionFields.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Keyframes.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E10-C01 | 变换/P0 | 修改clip位置、比例、旋转及opacity并预览/导出 | 画面属性与设定值对应；源文件不变 |
| E10-C02 | 动画/P1 | 为支持属性添加至少3个keyframe再seek中间时刻 | 插值连续；keyframe时刻值精确 |
| E10-C03 | 编辑/P1 | 移动/删除keyframe、复制片段后核对动画 | 关键帧与source/time约定一致；修改不污染原片 |
| E10-C04 | 边界/P1 | 零opacity、极限允许缩放/旋转及无选择状态输入 | 有规范化/校验；不产生NaN或不可恢复画面 |
| E10-C05 | 撤销/P1 | 关键帧/变换Undo/Redo及保存重开 | 数值、曲线和最终渲染一致恢复 |

<a id="e11"></a>

## E11 文字与时间线字幕

范围：Add Text、字体/颜色/样式、captions导入和编辑。前置标记：L。定位：`Sources/VoxstudioPro/Inspector/Tabs/TextTab.swift`、`Sources/VoxstudioPro/MediaPanel/CaptionsTab`、`Sources/VoxstudioPro/Toolbar/ToolbarView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E11-C01 | 文字/P0 | Add Text输入中文/英文多行，调字体/颜色/背景 | 预览和导出可读，文字不被截断或缺字 |
| E11-C02 | 样式/P1 | 调大小、粗斜体、对齐、position/rotation等可用项 | 属性有实际效果；仅影响选择的text clip |
| E11-C03 | 字幕/P0 | 从测试session将字幕加入timeline并播放 | cue与音画对应；轨道时长/位置正确 |
| E11-C04 | 边界/P1 | 超长行、emoji、竖屏字幕及屏幕边缘位置 | 换行/裁切策略可理解；无崩溃/零尺寸文本 |
| E11-C05 | 持久化/P1 | 修改cue文字/样式后Undo、保存重开并导出 | 版本一致；导出不是旧文字或默认样式 |

<a id="e12"></a>

## E12 调色、特效与抠像

范围：Adjust、curves/color wheels、chroma key/matte。前置标记：L。定位：`Sources/VoxstudioPro/Inspector/Tabs/AdjustTab.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+ChromaKey.swift`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+Matte.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E12-C01 | 调色/P0 | 使用颜色标记测试图调曝光/色彩等可用参数 | 预览/成片同向变化；reset恢复原图 |
| E12-C02 | 曲线/P1 | 修改曲线/色轮并比较首尾多个frame | 实际生效且无异常色块；保存值保留 |
| E12-C03 | 抠像/P1 | 在绿幕测试片叠加背景执行Chroma Key并调阈值 | 目标颜色透明；主体保留，边缘效果可核对 |
| E12-C04 | matte/P1 | 用允许的Matte/遮罩配置改变覆盖区域 | 遮罩作用在正确片段/坐标；导出与预览一致 |
| E12-C05 | 边界/P1 | 极端允许参数、删除背景track、Undo/Redo和重开 | 安全处理缺依赖；效果状态可准确恢复 |

<a id="e13"></a>

## E13 音频剪辑、节奏与空白处理

范围：gain/fades/speed、enhance、dead air、beats。前置标记：L。定位：`Sources/VoxstudioPro/Inspector/Tabs/AudioTab.swift`、`Sources/VoxstudioPro/Audio/Beats`、`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+DeadAir.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E13-C01 | 音量/P0 | 调clip gain/fade in/out并试听和导出 | 声音包络对应参数；无意外静音/明显削波 |
| E13-C02 | 速度/P1 | 对允许的音频speed设置改变速率并核对时长 | 时长/声音策略正确；关联视频同步规则明确 |
| E13-C03 | 空白/P1 | 带已知静音区间的测试音频执行dead-air处理 | 删/缩范围对应阈值；说话段不误删 |
| E13-C04 | 节奏/P1 | 检测已知节拍音乐并使用beat标记对齐片段 | 标记落点合理；timeline缩放后时间位置不变 |
| E13-C05 | 增强恢复/P1 | 音频增强后Undo/Redo及缺模型情况再次尝试 | 原音可找回；缺资源不生成假增强输出 |

<a id="e14"></a>

## E14 成片编码与导出队列

范围：H264/H265/ProRes/HDR、resolution、queue。前置标记：L。定位：`Sources/VoxstudioPro/Export/ExportView.swift`、`Sources/VoxstudioPro/Export/ExportQueue.swift`、`Sources/VoxstudioPro/Export/HDRVideoExporter.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E14-C01 | H264/P0 | 导出非空测试timeline为H.264 MP4，ffprobe且外部播放首中尾 | codec/尺寸/fps/时长正确；音画、文字和结尾完整 |
| E14-C02 | 编码/P1 | 同一timeline导出H.265和ProRes（分开记录），HDR仅在可用素材/渠道 | 每个文件实际使用所选codec；HDR色彩元数据有证据 |
| E14-C03 | 分辨率/P1 | 分别Match Timeline/720p/1080p/4K导出短片 | 尺寸与选择/比例规则匹配；无拉伸或零大小 |
| E14-C04 | 队列/P1 | 排两个短任务，取消一个并重试，查看finished与Reveal | 状态和文件一一对应；取消不破坏另一输出 |
| E14-C05 | 异常/P0 | 空timeline、同名文件、只读路径/受控空间不足时导出 | 阻止无效或明确错误；不把零字节/半成品标成功 |

<a id="e15"></a>

## E15 时间线交换与项目打包导出

范围：XML/FCPXML、Palmier Project及媒体完整性。前置标记：L。定位：`Sources/VoxstudioPro/Export/XMLExporter.swift`、`Sources/VoxstudioPro/Export/FCPXMLExporter.swift`、`Sources/VoxstudioPro/Export/PalmierProjectExporter.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| E15-C01 | XML/P0 | 导出含trim/多track的测试timeline XML并在兼容工具导入 | 片段时码/source引用/层次可核对；格式可解析 |
| E15-C02 | FCPXML/P1 | 导出FCPXML含音视频/text配置并导入兼容工具 | 支持内容保留；不支持项明确记录而非默默宣称一致 |
| E15-C03 | 项目/P0 | 导出Palmier Project并在另一临时路径打开 | 项目可用；媒体依赖/打包策略明确且可核对 |
| E15-C04 | 离线/P1 | 导出后移走测试源副本，在隔离环境重开打包输出 | 包含媒体则正常；外链则提示缺失并可重链 |
| E15-C05 | 异常/P1 | 取消保存、空timeline和损坏外链导出 | 无假成功；源工程不改；输出错误可恢复 |

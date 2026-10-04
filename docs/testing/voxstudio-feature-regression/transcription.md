# 转录与会话回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="t01"></a>

## T01 音视频导入与范围选择

范围：本地文件、音轨提取、起止范围和输入校验。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/TranscribeWorkbenchView.swift`、`Sources/VoxstudioPro/Workbench/MediaRangeExtractor.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T01-C01 | 正常/P0 | 选择 Downloads 的短 MP3，保持完整范围并提交本地处理 | 识别时长/音轨；创建对应 session |
| T01-C02 | 视频/P0 | 选择带 AAC 的 MP4，处理完整范围 | 从视频提取音频；原视频关联仍可预览 |
| T01-C03 | 裁剪/P1 | 只转录中间已知话语区间 | 输出对应片段；时间轴起点约定明确且导出一致 |
| T01-C04 | 边界/P1 | 尝试零长、起止相反、超出时长范围 | 阻止无效提交或规范化；不生成伪成功任务 |
| T01-C05 | 异常/P1 | 取消文件选择，再选择损坏/无音轨素材副本 | 取消无任务；无效媒体提示可恢复并可再次选择 |

<a id="t02"></a>

## T02 本地转录与说话人识别

范围：语音识别、语言、时间段、说话人标签。前置标记：L。定位：`Sources/VoxstudioPro/Transcription`、`Sources/VoxstudioPro/LocalAI`、`Sources/VoxstudioPro/Workbench/TranscriptionProcessingView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T02-C01 | 正常/P0 | 用有人工核对锚点的中文 MP3执行本地转录 | 锚点话语可读；时间段覆盖实际语音；存在结果文件 |
| T02-C02 | 语言/P1 | 分别处理英文和中英混合语音 | 语言识别/指定选择生效；专名和混合文字可核对 |
| T02-C03 | 说话人/P1 | 处理已知双人轮流说话的素材 | 标签与实际换人基本对应；无空白/错误复用 |
| T02-C04 | 静音/P1 | 处理静音、音乐和带噪音的短音频 | 静音不大段幻觉；失败或低可信情况有可理解反馈 |
| T02-C05 | 边界/P1 | 对 16 kHz 单声道 WAV 和 48 kHz 双声道 MP3各转录一次 | 输入差异不导致崩溃；输出时间不越界 |

<a id="t03"></a>

## T03 转录任务生命周期与恢复

范围：进度、取消、失败、重转录、刷新状态。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/WorkbenchSessionStatus.swift`、`Sources/VoxstudioPro/Workbench/WorkbenchStore.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T03-C01 | 正常/P0 | 观察提交→处理中→Ready全过程并切换页面 | 进度有更新；结果可打开；任务不因导航丢失 |
| T03-C02 | 取消/P1 | 取消正在处理的长任务后再次提交短素材 | 取消有终态；新任务可正常完成 |
| T03-C03 | 失败/P0 | 模拟资源缺失/处理失败，打开状态说明 | Needs attention 的具体工作与错误可见；已有结果不被假完成掩盖 |
| T03-C04 | 重试/P1 | 用已完成测试 session 执行 Re-transcribe | 新的处理状态明确；旧结果替换/保留规则可追踪 |
| T03-C05 | 重启/P1 | 处理期间正常退出并重开、刷新状态 | 任务恢复或明确中断；不永久运行或产生重复 session |

<a id="t04"></a>

## T04 转录文本与说话人编辑

范围：段落编辑、split/merge、说话人增改。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/SessionSegmentEditor.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T04-C01 | 文本/P0 | 修改一段中文长文本，保存并重新打开 session | 修改持久化；段落高度足够；后续导出为新文字 |
| T04-C02 | 拆分/P1 | 在段落中部拆分，再合并相邻段 | 文字顺序不丢失；时间边界不倒置 |
| T04-C03 | 说话人/P1 | 重命名 Speaker 并为一段新增/选择说话人 | 对应段落标签更新；未选择段落的归属不意外变化 |
| T04-C04 | 边界/P1 | 输入多行、emoji、超长词；尝试空名称/空段文本 | 合法字符保留；空值处理明确且不崩溃 |
| T04-C05 | 撤销/P1 | 编辑后取消，再保存另一处编辑并重启 | 取消不污染保存结果；仅已保存内容持久化 |

<a id="t05"></a>

## T05 字幕分段与重新分段

范围：词级时间、cue 长度与重建。前置标记：L。定位：`Sources/VoxstudioPro/MediaPanel/CaptionsTab/CaptionBuilder.swift`、`Sources/VoxstudioPro/Workbench/SubtitleSegmentationInfoButton.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T05-C01 | 正常/P0 | 对完整转录执行 Segment subtitles | 生成可播放的细粒度 cue；不只是段落复制 |
| T05-C02 | 边界/P1 | 处理快语速、长句、标点和中英混合 | cue 文字顺序完整；开始<结束且不越媒体时长 |
| T05-C03 | 重建/P1 | 编辑测试转录后执行 Re-segment subtitles | 提示/重建规则可理解；显示及导出使用同一版本 |
| T05-C04 | 失败/P1 | 字幕 AI/资源不可用时执行分段 | 显示失败/Needs attention；原始转录仍可用 |
| T05-C05 | 重入/P1 | 重复请求同一 session 分段并在过程中导航 | 没有重复 cue/重复任务；最终字幕轨可选择 |

<a id="t06"></a>

## T06 多语言翻译与双语轨

范围：英文等翻译、多轨、字幕选择、双语顺序。前置标记：B。定位：`Sources/VoxstudioPro/Workbench/WorkbenchSessionView.swift`、`Sources/VoxstudioPro/Workbench/SessionExport.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T06-C01 | 正常/P0 | 把已知中文 session 翻译为英文，等到终态并选中英文轨 | 英文轨真实存在可预览/导出；不能仅凭 Ready 判通过 |
| T06-C02 | 多轨/P1 | 增加第二目标语言后在原文/两种译文间切换 | 既有语言轨保留；切换不串文字或时间 |
| T06-C03 | 双语/P1 | 分别导出 original-first 与 translation-first 双语字幕 | 两种顺序正确；时间码与 cue 对应 |
| T06-C04 | 失败/P0 | 用隔离无效 provider 配置/离线重现翻译失败 | 具体错误可见；Original可用；不会导出空英文轨 |
| T06-C05 | 重试/P1 | 修复测试配置后重试失败语言，检查既有轨 | 重试完成且无重复语言；其他轨不被覆盖 |

<a id="t07"></a>

## T07 摘要与模板

范围：摘要生成、My Template、重新生成。前置标记：B。定位：`Sources/VoxstudioPro/Workbench/SessionSummaryTemplateSheet.swift`、`Sources/VoxstudioPro/Workbench/WorkbenchSessionView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T07-C01 | 正常/P0 | 生成测试转录摘要并对照已知事实 | 摘要对应来源；没有明显编造或遗漏主要事件 |
| T07-C02 | 模板/P1 | 用隔离模板请求要点/行动项格式并 Regenerate | 输出遵循模板；模板选择和结果可追踪 |
| T07-C03 | 空态/P1 | 空转录/无摘要 session 打开摘要区 | 说明前置条件；不显示另一 session 旧摘要 |
| T07-C04 | 失败/P1 | 取消或使摘要服务不可用，再恢复重试 | 取消/错误有终态；原摘要处理规则明确 |
| T07-C05 | 保存/P1 | 模板生成后切换 session、重启再打开 | 摘要/模板关联正确；不同 session 互不污染 |

<a id="t08"></a>

## T08 会话媒体播放与字幕同步

范围：原音/增强/配音、seek、字幕显示。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/SessionMediaPlayback.swift`、`Sources/VoxstudioPro/Workbench/AudioPlaybackCoordinator.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T08-C01 | 正常/P0 | 播放/暂停原音，跳转指定段时间 | 声音与计时同步；段落跳转落在合理范围 |
| T08-C02 | 字幕/P1 | 在视频 session 切换字幕轨并拖动播放位置 | 当前 cue 随时间变化；没有旧字幕残留 |
| T08-C03 | 切换/P1 | 在存在输出的 session 切换原音、增强音和配音 | 实际播放所选文件；缺失版本不伪装可用 |
| T08-C04 | 竞争/P1 | 播放 A 后打开 B并启动 B播放，再回 A | 没有双重播放；每个进度对应正确媒体 |
| T08-C05 | 边界/P1 | seek 到0、最后一秒及媒体缺失状态 | 边界不崩溃；缺失可定位恢复；结束状态正确 |

<a id="t09"></a>

## T09 转录与字幕导出

范围：TXT/SRT/VTT、复制、原文/译文/双语。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/SessionExport.swift`、`Sources/VoxstudioPro/Workbench/SessionExportCenter.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T09-C01 | TXT/P0 | 导出 TXT并复制转录；重新读取文件/剪贴板内容 | UTF-8文字完整；说话人/文本与当前版本一致 |
| T09-C02 | SRT/P0 | 导出细粒度 SRT并用外部播放器加载 | 编号连续、逗号毫秒时间合法；字幕可显示同步 |
| T09-C03 | VTT/P0 | 导出 VTT检查头、时间码及特殊字符 | WEBVTT格式合法；cue不空缺或超范围 |
| T09-C04 | 变体/P1 | 有翻译的样本导出译文及双语两种顺序 | 语言、排序、当前版本与所选项一致 |
| T09-C05 | 异常/P1 | 空结果/缺译文、取消保存、同名文件已存在时尝试导出 | 明确阻止或提示；取消无假成功；不无提示覆盖用户文件 |

<a id="t10"></a>

## T10 音频增强与音频导出

范围：本地增强、试听、Original/Enhanced/Dub导出。前置标记：L。定位：`Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel+AudioEnhance.swift`、`Sources/VoxstudioPro/Workbench/SessionExport.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T10-C01 | 正常/P0 | 对有可控背景噪音的测试语音进行本地增强并 A/B试听 | 生成独立增强输出；人声可辨且未变静音 |
| T10-C02 | 导出/P0 | 分别导出 Original 与 Enhanced并 ffprobe核验 | 两个变体指向正确文件；时长/采样率可记录 |
| T10-C03 | 配音/P1 | 对已有 Dub 的 session导出 Dub音频 | 输出实际配音音轨；未误导出原音 |
| T10-C04 | 失败/P1 | 模型缺失/无音频 session点击增强/音频导出 | 缺前置状态明确；原媒体不丢失 |
| T10-C05 | 边界/P1 | 短音频、长噪声段与立体声输入分别增强 | 输出可解码；不截断结尾或产生明显削波 |

<a id="t11"></a>

## T11 会话库与本机数据管理

范围：列表、筛选、源文件定位、测试会话删除。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/WorkbenchLibraryView.swift`、`Sources/VoxstudioPro/Workbench/WorkbenchSessionListRow.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| T11-C01 | 正常/P0 | 新建转录和配音后查看 Recent及列表再重开 | 类型、标题、状态、时长对应真实 session |
| T11-C02 | 筛选/P1 | 按 Ready/运行/Needs attention筛选并搜索标题 | 筛选交集正确；失败任务仍可发现 |
| T11-C03 | 定位/P1 | Reveal source/dub in Finder，核对路径和文件 | 定位属于当前 session；缺文件有提示 |
| T11-C04 | 删除/P1 | 仅对标记可丢弃的测试 session取消删除再确认删除 | 取消保留；确认作用于正确测试对象及已说明的数据范围 |
| T11-C05 | 持久化/P1 | 同时存在本地/Cloud标签数据时重启查看 | 来源标签真实；不把本地 Ready当作Cloud同步完成 |

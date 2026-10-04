# 配音与声音库回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="d01"></a>

## D01 本地文字配音

范围：文本、语言、声音、生成、播放与输出。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/DubWorkbenchView.swift`、`Sources/VoxstudioPro/Workbench/DubOutputPlayer.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| D01-C01 | 正常/P0 | 输入短英文测试文本，选默认本地声音并生成/播放 | 输出为可解码非静音音频；口述与文本对应 |
| D01-C02 | 语言/P1 | 分别使用中文、英文、中英混合及数字 | 发音/语言选择可核对；没有整段丢失 |
| D01-C03 | 边界/P1 | 提交空白、仅标点、长多行文字和emoji | 无效输入阻止或有明确结果；长输入不静默截断 |
| D01-C04 | 失败/P1 | 模型不可用/内存不足时生成，再恢复资源重试 | 错误可恢复；不出现假Ready或永久进度 |
| D01-C05 | 持久化/P1 | 生成后导航、重启、再次播放及Reveal in Finder | 文件/任务对应且保留；重复生成版本可辨 |

<a id="d02"></a>

## D02 多段配音、转录导入与AI改写

范围：段落顺序、Speaker声音、Source/Translation导入。前置标记：B。定位：`Sources/VoxstudioPro/Workbench/DubWorkbenchView.swift`、`Sources/VoxstudioPro/Workbench/DubRewriteController.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| D02-C01 | 多段/P0 | 建立三段测试文字并给不同speaker分配声音 | 输出顺序完整；声音映射符合配置 |
| D02-C02 | 导入/P1 | 从完成转录导入Source，再从已有翻译轨导入 | 文字、语言和段落对应所选track；未串入其他session |
| D02-C03 | 编辑/P1 | 增加/删除/修改中间段后再生成 | 只生成当前段落集合；旧输出版本可追踪 |
| D02-C04 | 改写/P1 | 用明确指令AI改写测试段，预览后应用/取消各一次 | 应用使用新文字；取消保留原文字；不自动生成未确认内容 |
| D02-C05 | 失败/P1 | 改写服务断网/取消后切换任务再恢复 | 运行状态终止；文字不被半成品污染；可重试 |

<a id="d03"></a>

## D03 声音参考与声音库

范围：导入/录制reference、文本、头像、默认声音、预览。前置标记：L。定位：`Sources/VoxstudioPro/Workbench/VoiceLibraryView.swift`、`Sources/VoxstudioPro/Workbench/VoiceReferenceSpeechGate.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| D03-C01 | 创建/P0 | 用获授权的3–30秒测试语音及准确文本建立reference并用于配音 | 声音入库可选；预览和配音实际使用该reference |
| D03-C02 | 边界/P1 | 提交过短/过长/静音/无语音reference和不匹配转录 | 验证提示明确；不创建不可用的伪reference |
| D03-C03 | 编辑/P1 | 改名、头像、语言/允许字段并设为默认，再重开 | 属性持久化；默认选择与新配音一致 |
| D03-C04 | 录制/P1 | 经人工mic准备后录reference，取消一次再保存一次 | 取消不入库；保存音频与文字对应 |
| D03-C05 | 删除/P1 | 仅删除可丢弃测试reference，再打开依赖它的测试配音 | 无误删默认内置voice；依赖缺失明确提示/回退可追踪 |

<a id="d04"></a>

## D04 从转录创建配音与版本

范围：目标语言、speaker映射、dub revisions。前置标记：B。定位：`Sources/VoxstudioPro/Workbench/WorkbenchSessionView.swift`、`Sources/VoxstudioPro/Editor/EditorDubSheet.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| D04-C01 | 正常/P0 | 从完成转录创建原语言配音并试听 | 配音段与源文本对应；有可播放Dub变体 |
| D04-C02 | 翻译/P1 | 选已有目标译文或目标语言创建配音 | 输出语言正确；缺译文不使用错误语言 |
| D04-C03 | speaker/P1 | 双speaker素材为两人分配不同reference | speaker归属/音色对应，段落顺序正确 |
| D04-C04 | 版本/P1 | 修改一段再生成，切换Revision并导出不同版本 | 版本内容可辨；选择/导出同一版本 |
| D04-C05 | 失败/P1 | 生成中取消/服务失败，返回原转录与既有revision | 原结果可用；失败版本不会当作成功输出 |

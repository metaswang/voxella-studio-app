# 跨 speaker 句首归属修复（2026-10-03）

## 证据与本例修复

截图中的 `My` 原生时间为 27.200000763–27.280000687 秒、Speaker 1，相对置信度约 0.963。全音频 Sortformer 本地重放中该窗获胜绝对概率仅约 0.091；高相对比例不能证明有足够的语音或时间窗正确。声学帧只积分实际重叠，不能将零重叠邻帧按整帧计权。

25–31 秒独立 Parakeet 重跑将 `My` 放在 27.24–27.48、`name` 放在 27.48–27.72、`is` 放在 27.72–27.88、Jeff 对应的语音 token 放在 27.88–28.36；句号 token 延伸至静音。该重跑把 Jeff 识别成 Jev，因此只用于时间核对，不替换原文本。20ms 波形在约 27.38 秒明显起声。

Qwen 的局部对齐在窗口边缘和静音尾部出现不可靠时间。通用复核按声学支持和窗口校验拒绝整个补丁，保留原词并计入 unresolved。不得将这次拒绝报告成自动接受或模型验证成功。

依据用户确认的 speaker 归属与上述局部证据，单独修正本例：

| 原词索引 | 词 | 保存时间（秒） | Speaker | 时间质量 |
|---|---|---|---|---|
| 87 | Jev. | 26.40–26.92 | 1 | estimated |
| 88 | My | 27.38–27.48 | 2 | estimated |
| 89 | name | 27.48–27.72 | 2 | estimated |
| 90 | is | 27.72–27.88 | 2 | estimated |
| 91 | Jeff. | 27.88–28.36 | 2 | estimated |

调整词的 speakerConfidence 清空，My 明确开启 Speaker 2，后续 And 保持原 Speaker 1。时间是估计值，没有人工听审或逐样本精确对齐的声明。

通过 WorkbenchStore 的 compare-and-swap 更新词、重建 Transcript、更新受影响源字幕。独立 My 字幕并入 name is Jeff.，来源词索引维持 [88,89,90,91]。全文、词序、editedText、其他会话、翻译与 dub 不变。源字幕中已有文字编辑不匹配时拒绝修复。

## 通用逻辑

- 只累计帧的真实重叠；无有效窗口/证据返回 nil；输出绝对概率和有效支持时长。
- 相对置信度与绝对概率分别使用。渐弱的前一词不抹掉明确的后一 speaker 边界。
- 切换附近两帧以内短词、高置信短词、低质量时间和句首残留参与候选发现。
- 两侧约 2 秒文字上下文，完整词及 0.6 秒音频边缘余量；合并邻近窗口，单次最长 12 秒。
- 使用已有 Qwen 强制对齐器（offlineMode）一次复核每个窗口，保持原文本/词序；重映射中文/标点 token。
- 时间越界、文本遗漏、时间坍缩、声学归属模糊、模型缺失或失败保留原窗口；取消传播，不提交部分修复。
- 每个重对齐 lexical unit 需相对置信度至少 0.84、绝对概率至少 0.55、margin 至少 0.2 和有效支持。
- 短 turn 仅在相对与绝对证据均弱时平滑；明确单词插话与重叠说话保持。
- 普通转录及 known-text 的 diarize 路径在最终分段前复核；单 speaker、禁用 speaker、providedSpans 保留快速路径。
- 诊断新增 candidate/accepted/unresolved，旧数据缺省为零。pipeline 缓存 schema 升为 10。

## 验证与可恢复性

回归测试覆盖：短词跨帧、零重叠邻帧、零/非法时间、静音、弱绝对概率、真实单词插话、重叠说话、中英文 token、模型缺失、失败、取消、单 speaker 快速路径、12 秒上限、旧诊断解码、字幕词来源及持久化。

本例模型重放及 WorkbenchStore 保存只写入 `.build/speaker-boundary-case/attempt4` 隔离目录。目录包含完整修复前快照、局部对齐、声学帧、词结果、job 差异、SRT/VTT 导出和应用前/后快照。实际应用仅替换本例 result/subtitleTrack/诊断及修订元数据，原子替换前核对快照且要求 app 已退出。

模型尚未稳定地精确对齐这个片段。通用逻辑的目标是减少错误并显式保留疑点，不保证所有句首边界自动修复。

扩大到 LocalFirstWorkbenchTests 的一次 BundledSpeech 测试共运行 99 项，本例重放和四个相关 suite 通过；两个无关测试出现 3 个断言问题：catalog 数量期望 12/实际 13、recommended 期望 9/实际 10，以及旧 VoiceLibrary 路径缺少 reference.wav。本次不修改模型目录或录音环境来迎合这些断言。

最终相关回归：普通模式 38 项通过，BundledSpeech 39 项通过；最终本例模型重放及隔离 WorkbenchStore/磁盘/导出验收 1 项通过。实际应用修改词索引 87–91，源字幕 94 条变为 93 条；其他 transcriptions、dubs 及根字段逐项相同。

持久备份目录（构建目录之外）：`/Users/adamwang/Library/Application Support/VoxStudio/Backups/speaker-boundary-2026-10-03-401902CA`。其中 `workbench-before-apply.json` 是应用前完整快照，`job.diff` 是本例差异，`case-review.json` 区分用户确认修复与未接受的自动对齐。

重放已修复会话时，用 `VOXSTUDIO_SPEAKER_INPUT` 指向上述修复前快照，`VOXSTUDIO_SPEAKER_ARTIFACTS` 指向一个新的空目录，并设置 `VOXSTUDIO_SPEAKER_REPLAY=1`；测试默认禁用且不写实际 Workbench。

运行验收：按 AGENTS.md 执行 `./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"` 成功。`codesign --verify --deep --strict` 通过；Developer ID Application 为 GREATWAY GLOBAL PTE. LTD.，Team ID 4DMAQ32SNU，嵌入 profile/Sparkle，包含 microphone/Keychain entitlement，无 Apple Sign-in entitlement。

已在本轮 `.build/VoxStudio.app` 窗口确认：重启后 Transcript 的 Speaker 1 结束于 Its name is Jev.，Speaker 2 为完整 My name is Jeff.；Subtitles 同一行归 Speaker 2，后续 And this... 归 Speaker 1。从 Speaker 2 按钮播放定位 00:27，视频字幕和活动文本高亮覆盖完整 My name is Jeff.。播放已暂停。启动及 UI 检查后再次读取磁盘，result/source cues 与隔离补丁完全一致，其他会话/dub/根字段仍相同。

提交前将暂存内容导出到独立目录，排除工作区其他未提交功能；BundledSpeech 下六个相关 suite 共 57 项测试通过，包含字幕元数据兼容解码与往返保存检查。

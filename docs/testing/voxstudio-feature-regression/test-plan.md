# VoxStudio 功能回归测试计划

设计日期：2026-10-01。输入：[功能地图](../../design/voxstudio-feature-map.md)、[上一轮端测记录](../../test/voxstudio-local-e2e-2026-10-01.md)、当前源码与签名/TCC排障记录。

设计包含 **71 个feature、357 个cases**，每个feature至少5cases；这些是计划，尚未执行。测试执行记录保存在 `docs/test/voxstudio-feature-regression-YYYY-MM-DD-HHMM.md`；大体积媒体放临时输出目录，仅把经审查的证据和日志放该报告对应 `-evidence/` 目录。

## 测试集索引

| 模块 | Feature数 | Case数 | 用例文档 |
|---|---:|---:|---|
| 应用与工作区 | 4 | 20 | [app.md](app.md) |
| 转录与会话 | 11 | 55 | [transcription.md](transcription.md) |
| 录制 | 11 | 55 | [recording.md](recording.md) |
| 配音与声音库 | 4 | 20 | [voiceover.md](voiceover.md) |
| 知识库 | 5 | 25 | [knowledge.md](knowledge.md) |
| 视频编辑器 | 15 | 75 | [video-editor.md](video-editor.md) |
| 生成、Agent与MCP | 9 | 47 | [agent-mcp.md](agent-mcp.md) |
| 设置与语音输入 | 7 | 35 | [settings.md](settings.md) |
| 账户、Cloud及可选集成 | 5 | 25 | [cloud-optional.md](cloud-optional.md) |

## 执行范围

- 默认本地回归：A/T/R/D/K/E/S及本地MCP与Agent相关允许用例。Cloud登录、购买/恢复、license激活、Calendar OAuth、云bot、未授权上传/生成/安装/反馈发送保持 Skip-Scope。BYOK前置未满足则 Blocked-Dependency，不以无输出为Pass。
- 全量或按feature回归：明确记录选中ID、用户排除项、渠道与已授权外部目的地/预算；“全量”不等于授权真实交易、对外发反馈或加入真实会议。
- P0优先，随后P1/P2。每个feature至少5cases全部在清单中；快速检查只能称smoke，不能标作该feature完整回归。
- 只操作专用临时项目/测试session/隔离测试用户。负向权限、缓存/索引清理、provider/模型更换、删除和异常终止优先在隔离用户执行，防止污染用户原数据/全局配置。删除必须确认对象属于本轮可丢弃数据及其恢复规则。

## 通用前置与素材矩阵

1. 冻结包路径/版本/签名；读取仓库AGENTS启动约定，必要时按signed debug流程构建。已明确仅打开现有包时复用该包；权限准备后只重启同一已核验包，避免中途重签改变身份。
2. 记录运行进程的实际可执行路径（例如 `ps -axo pid=,comm= | rg 'VoxStudio.app/Contents/MacOS/VoxStudio'`），核对指定绝对路径。单独 `open` 返回成功不足以证明目标进程正确。
3. 录制先读[权限准备与Computer Use研究](../../../skills/voxstudio-feature-regression/references/recording-permissions.md)。人工确认路径一致、enabled、相关microphone权限及重启后，再录可控短素材验证实际帧/音轨。
4. 从 `~/Downloads` 选择获授权的测试音视频，使用 `ffprobe`、`file`、hash记录实际素材。不能假设下列文件一直存在或时长固定。

| Fixture | 建议输入/制作方式 | 需要的已知真值/用途 |
|---|---|---|
| F01 | Downloads/test_2min.mp3（若仍存在） | 短中文音频；人工记录至少3个话语/时间锚点；上次120.012s、48kHz stereo。 |
| F02 | Downloads/test_3min_16khz.wav（若仍存在） | 单声道16kHz，采样率、长任务/尾部不丢失。 |
| F03 | Downloads/voxstudio_short_019f8a5d-1fc9-700c-83a1-42debb162360.mp4（或替代） | 动态视频+音轨；上次约103.933s、1920×1080 H264/AAC；记录首中尾画面。 |
| F04 | 临时目录中从本地素材副本派生短片、静音、截断/损坏文件 | 正确标记时長、失效类型；不改Downloads原文件。 |
| F05 | 获授权的英文、中英混合、双speaker及带噪语音 | 人工真值转录、换人点、reference音频3–30s及准确文本。缺素材记Blocked-Fixture。 |
| F06 | 主屏/外接屏播放F03，USB测试iPhone/iPad播放自有内容 | 屏幕区域标记、音源开关、设备/USB/信任状态；只记录获授权窗口。 |
| F07 | 临时工程含3片视频、两音轨、text/captions、嵌套/多机位变体 | 片段源范围/offset/track/输出真值，供剪辑、撤销、导出对照。 |
| F08 | 两份有互斥事实的测试转录与已知问答 | scope泄漏、检索、引用、图谱、多轮QA的标准证据。 |
| F09 | 隔离provider、测试日历/会议、StoreKit sandbox | 只为已授权可选cases准备；缺前置记录Blocked或Skip。 |

记录fixtures绝对路径、SHA-256、codec、duration、sample rate/channels、width/height/fps；边界用例通过副本派生，生成过程与预期真值写入报告。

## 用例约定与验收

每个模块表格按 `Feature-ID-C01…` 标识；表中的操作和预期都需要实际证据。共同前置为正确target、隔离测试数据及该feature标记对应条件；特殊前置写在具体操作中。不同参数列出“分别”时必须分项记录，不能只跑其中一项即整行Pass。

- P0：核心成功/身份/数据完整性；P1：异常、边界、恢复、其他主要路径；P2：显示/便利性。优先级不意味着可以无说明省略。
- Pass：预期全满足；Fail：前置已满足但行为/输出不符合；Blocked-Permission/Hardware/Fixture/Dependency：具体前置无法满足；Skip-Scope：用户排除/未授权；N/A：确定该渠道/配置不支持且有依据；Not-run：未尝试。
- 不把点击、Ready标签、模型Ready、UI开关enabled、任务queued或空timeline导出当成功。转录需检查文字/时间；翻译需真实语言轨及可导出文本；配音需可播音频；录屏需实际视频帧；导出需文件可解码且内容正确。
- UI用例使用Computer Use真实入口；MCP仅用于明确MCP用例，不能替代拖拽/快捷键/UI导出等用例后把UI标Pass。失败至少保留最后AX状态/经审查截图、操作、错误、文件metadata及可复现范围。
- 文件验证：`file`、`ffprobe`、SHA-256；转录/字幕读UTF-8内容并核对时间码与锚点；成片从首、中、尾外部播放验证，不只看文件大小。禁止截取用户秘密/无关内容作为证据。
- 相同失败在环境/配置未改变时最多一次额外重试；先记录根因线索，再继续独立feature。永久Preparing/无响应要记录等待时长与状态，不能无期限轮询。
- 收尾恢复本轮改过的非安全偏好；人工权限准备保留情况写入报告。保留已有源码和文档变化，不主动commit/push/upload。

## 覆盖报告

逐case记录 `ID | 状态 | fixture/前置 | 实际操作 | 实际结果 | 证据 | 问题ID`，另列feature/module汇总。功能地图的全部357项是设计总数，本次选择N项是执行分母。

- 执行覆盖率 = (Pass + Fail) / 本次选中case数；Blocked、Skip、Not-run仍列在本次清单，不悄悄减少分母。
- 执行通过率 = Pass / (Pass + Fail)；分母0时写N/A。N/A行另统计；调整选中范围必须说明原因。
- feature完整通过仅在其全部选中且适用用例Pass时成立；任何Blocked/Not-run都明确标feature未完成。至少5个设计用例不等于至少5个实测通过。

本任务只设计文档与skill；不复用2026-10-01旧记录冒充这些用例已经执行。

# Claude CLI × VoxStudio MCP 定向端测 — 2026-10-03

## 测试设计与运行基线

用户要求通过 Settings → MCP → Claude CLI 接入并测试知识问答、视频编辑、可选参考音的配音和 Downloads 文件转录。Computer Use 禁止访问 Terminal；设置、编辑器和播放由 Computer Use 核验，Claude CLI 由命令工具执行。没有安装 Claude CLI（原有版本 2.1.225）；执行设置页命令安装项目级 `voxstudio` HTTP 连接，`claude mcp list` 显示 Connected。

当前 target：`/Users/adamwang/Project/subdub/voxella-studio-app/.build/VoxStudio.app`，7.0.30 (116)，Developer ID / Team 4DMAQ32SNU。PID 62637 持有 19789 端口。另有 /Applications 包 PID 63482；后续 UI 绑定 debug 路径。binary SHA256：`e0b57ac57d9100d3b8d36d8ab716772650d6be7fa941035f49962bd62d3812b6`。沿用正在运行的签名包，未重新启动或构建。仓库 HEAD 94543e2f，已有大量暂存/未暂存修改，全部保留。

范围为定向 smoke，不声称完整 feature 回归。使用 Claude CLI 当前配置；首轮输出模型名为 `deepseek-v4-flash`，没有改 provider。原始运行日志放 `/private/tmp/voxstudio-claude-e2e-20261003/`（首轮发现日志 `/private/tmp/voxstudio-claude-discovery.jsonl`）。最终证据过滤 thinking/敏感配置。

## 选中 cases 与验收标准

| ID | 对应基线 | 操作 | 预期 |
|---|---|---|---|
| SETUP | G06-C01 | Settings 查看 Claude Code 命令，安装连接并读取本地 voices/sessions | 当前 debug 实例 Connected、真实返回 |
| QA-1 | G08-C01 / docs QA #1 | AI State…：DeepSeek R1 被描述成什么样的事件？ | 回答原文支持，引用实际来源与时间 |
| QA-25 | G08-C01 / docs QA #25 | Origin…：cuneiform 含义、19世纪重新发现地点 | wedge-shaped、Iraq，引用原文 |
| QA-18 | G08-C01 / docs QA #18 | 两个 Lemonade session 的共同建议 | 两边来源，承认挫折、采取建设性行动 |
| QA-SCOPE | G08-C02 | 只允许 Origin，却询问 AI DeepSeek | 缺证据，不引用范围外来源 |
| EDIT | G06-C02（定向变体） | 新测试项目，导入短视频、split/move、标题、undo 验证、导出 | 时间线真实变化、撤销正确、导出非空且可解码/播放 |
| VOICE | G07-C03（list/preview/dubbing 子集） | 列表让用户选择、短脚本生成、状态/预览 | 使用所选 ID、真实可播输出 |
| TRANS-ZH | G07-C01/C04 | Downloads 6.269s 中文 wav 转录、预览 | session ready、真实文字、合法时间 |
| TRANS-EN | G07-C01/C04 | Downloads 4.844s 英文 wav 转录、预览 | session ready、真实文字、合法时间 |
| TRANS-BAD | G07-C05 | 不存在的测试路径 | 结构化错误，不生成假成功 |

配音中文脚本：欢迎来到 VoxStudio。今天，我们把灵感变成清晰的表达。先整理知识，再剪辑视频，最后用熟悉的声音讲述故事。准备好了吗？让我们开始。

配音英文脚本：Welcome to VoxStudio. Today, we turn ideas into clear expression. First, organize knowledge. Then, edit the video. Finally, tell the story in a familiar voice. Ready? Let's begin.

参考音实测列表：ABC（zh，8.128s）、Reference Voice（zh，11.24s，原 transcript 空）、adam_en_2（en，9.68s）、ad_english（en，9.38s）、Ad测试（zh，5s）。用户选择 Ad测试，ID `D0AA2E85-0D7C-4157-8424-47FE656D7750`；实际创建参数与选择一致。

## 授权与限制

知识问答首个命令被 automatic approval review 拒绝，原因是 CLI 会把本机 transcript 发送给外部模型；`allow_cloud=false` 只约束 App 内回答路由，并不阻止 CLI 自身外发。用户随后明确授权四个指定来源的相关片段发往 `api.deepseek.com`，后续执行成功。所有 QA 调用仍指定 `allow_cloud=false, origin=local`；这不等于全链路离线。App 按当前配置进行回答/summary，无更改 provider。

额外尝试将生成配音做一次 ASR 回读，经 CLI 发往 DeepSeek；automatic review 再次拒绝，认为生成和本地查看不包括这项新增披露。命令未运行、未创建 ASR session；没有绕过或再次提交。使用已完成的本地播放、解码和字幕核验作为本次 VOICE 验收；独立音频语义回读、自然度及声纹相似度不在通过结论内。

本轮不涉及录屏/麦克风系统权限、新账号、付款、社区 skill 安装、对外反馈或代码修改。复用了已运行的签名包，未触发新启动约定。Claude MCP 安装保留在该仓库项目级配置；没有安装或升级 Claude CLI。

## 实际素材

路径前缀均为 `/Users/adamwang/Downloads/Voxella-Test-Fixtures/`。哈希见 [fixture-hashes.json](voxstudio-claude-cli-e2e-2026-10-03-evidence/fixture-hashes.json)。

| 文件 | 实际 metadata | 真值/验收锚点 |
|---|---|---|
| zh-single.wav | PCM s16le，16kHz mono，6.268938s | 仓库 LocalModelInferenceTests 要求 欢迎/测试/时间 ≥2；本次3个均命中 |
| en-single.wav | PCM s16le，16kHz mono，4.843625s | 同测试要求 welcome/local/timestamp ≥2；本次3个均命中 |
| caption-link-video.mp4 | H.264，1280×720，AAC 16kHz mono，9.237s | 彩条、动态线条/计数；剪切后源时间偏移、标题和1秒空隙 |

## 逐 case 实际结果

证据目录：[voxstudio-claude-cli-e2e-2026-10-03-evidence](voxstudio-claude-cli-e2e-2026-10-03-evidence/)。JSON 仅保留实际 tool calls/results、最终结果及运行元数据，剔除 thinking 和初始化配置；媒体放临时目录。所有已完成 CLI 运行 `permission_denials=[]`。

| ID | 状态 | 实际结果与证据 | 问题 |
|---|---|---|---|
| SETUP | Pass | 签名 debug Settings 的 Claude Code 命令与已安装命令一致；端口属于 PID62637；CLI Connected，5个参考音及4个指定 session 真实返回。[discovery](voxstudio-claude-cli-e2e-2026-10-03-evidence/voxstudio-claude-discovery.json) | 初始 CU 用名称绑定到 /Applications 包，核对进程后改用绝对 debug 路径；后续 UI/服务一致 |
| QA-1 | Fail | 回答 DeepSeek 时刻、2025年1月、较低算力近SOTA、竞争升温。主引用为 `sessionSummary`，另一个正文引用2241.80–2288.68s只支持发布时间/技术特点；独立正文检索定位93.28–173.36s支持主结论。[knowledge](voxstudio-claude-cli-e2e-2026-10-03-evidence/knowledge.json) | QA-I1：主引用未落到 canonical 正文；原文 allegedly 的保留语气丢失 |
| QA-25 | Fail | 内容含楔形、cuneus、1840–1850、Iraq。答案仅引用377.07–423.79s、chars5783–6481的词典保护片段，不能支持这些结论；正确片段424.59–517.07s、chars6481–7920。正文可以验证内容，但返回引用不正确。[knowledge](voxstudio-claude-cli-e2e-2026-10-03-evidence/knowledge.json) | QA-I2：返回引用指向相邻不支持片段 |
| QA-18 | Pass | 承认挫折、选择实际小行动、耐心/希望/感恩；4个 `original_segments` 引用覆盖两个来源0–约104s。独立检索与原文核对均支持。[knowledge](voxstudio-claude-cli-e2e-2026-10-03-evidence/knowledge.json) | — |
| QA-SCOPE | Pass | 只含 Origin 时说明当前来源没有 AI 内容，未引用 AI session、未补外部答案；literal DeepSeek 查词为0、checked_sources1、complete=true。[knowledge](voxstudio-claude-cli-e2e-2026-10-03-evidence/knowledge.json) | — |
| EDIT | Pass | 新项目导入277帧；90帧分割；后段移到120，Undo回90，再移120；音视频同为[90,120]空隙；标题[0,90]；307帧导出完成。UI实际标题可见，QuickTime播放至10.233s；ffmpeg全文件解码成功，首/空隙/中/尾帧符合预期。[editor](voxstudio-claude-cli-e2e-2026-10-03-evidence/editor.json)、[帧核验](voxstudio-claude-cli-e2e-2026-10-03-evidence/video-contact-sheet.png) | — |
| VOICE | Pass | 用户选 Ad测试，voice.preview ID正确；dubbing completed，WAV24kHz mono12.96s；6条字幕覆盖完整脚本、speaker均Ad测试；App播放进度到100%/00:12，ffmpeg解码成功且非静音。[media](voxstudio-claude-cli-e2e-2026-10-03-evidence/media.json)、[preview](voxstudio-claude-cli-e2e-2026-10-03-evidence/preview.json) | 不含自然度、参考音相似度或独立ASR准确率结论 |
| TRANS-ZH | Pass | session `4BE2D051-403A-42DA-9DAE-970D9000F455` completed/zh；0–5.920s：欢迎使用Voicella Studio。这句话用于测试中文转写和词级时间戳。UI原文及音频播放器0–6s一致。[preview](voxstudio-claude-cli-e2e-2026-10-03-evidence/preview.json) | 品牌拼写不在本次关键词oracle中；没有宣称逐字准确率 |
| TRANS-EN | Pass | session `5B6E1C2C-E083-4F00-A9D8-1D725F5C3DAC` completed/en；0–4.800s：Welcome to Voxella Studio. This sentence tests local word timestamps. UI一致。[preview](voxstudio-claude-cli-e2e-2026-10-03-evidence/preview.json) | 4.5秒预览返回完整重叠cue，cue end4.8s；这是重叠句段而非裁剪句段，未判越源时间 |
| TRANS-BAD | Pass | 不存在路径返回 `“nonexistent.wav” could not be opened.`，无session ID/假成功。[media](voxstudio-claude-cli-e2e-2026-10-03-evidence/media.json) | — |

所有 positive media 首轮曾 queued/running，仅记 pending；第二轮明确 completed 后才做 preview/文件/UI验收。不是把 Ready 标签当作唯一证据。QA-I1/I2 未用重试替换首轮结果，也未在本轮修改产品代码。

## 视频编辑精确状态

工程：`/Users/adamwang/Documents/Voxella Studio/Claude MCP E2E 20261003 Video.voxella`，project ID `05B6F760-B2F0-44BB-B014-C45C269A3D9D`，timeline `6664B37D`，30fps、1280×720。

| 状态 | 前段video/audio | 后段video/audio | 总帧 |
|---|---|---|---:|
| 添加 | [0,277] | — | 277 |
| split90 | [0,90] | [90,277]，trimStart90 | 277 |
| move120 | [0,90] | [120,307]，trimStart90 | 307 |
| undo | [0,90] | [90,277]，trimStart90 | 277 |
| final move120 | [0,90] | [120,307]，trimStart90 | 307 |

标题 `VoxStudio MCP Test` 占[0,90]，白色居中，在UI和输出0.5秒帧实际可见。导出3.5秒帧是预期黑色空隙；5秒输出画面source计数为4秒，9.8秒画面source计数为8.8秒，符合插入1秒空隙。工程autosave，本轮未close/reopen，不声明重开持久化验收。

视频输出：`/private/tmp/voxstudio-claude-e2e-20261003/editor-output.mp4`，H.2641280×72030fps、307帧、AAC16kHz mono、10.233333s、7,554,274bytes；SHA256 `c97864afbd68ad772b3f161421e2d797dd33b080dfcde45b9b4bb8b975f6e8ac`。全文件decode退出0、无错误。

## 配音与转录输出

配音 session `46E25F9D-393F-45AF-8739-8C0FF9BE6886`。原输出 `/Users/adamwang/Library/Application Support/VoxStudio/Dubs/dub-flow-6AC69957-9139-42AF-8481-23016C956071.wav`；交付副本 `/private/tmp/voxstudio-claude-e2e-20261003/Ad测试-voiceover.wav`。PCM f32le24kHz mono、12.960s、1,248,256bytes、SHA256 `f09737781b8e9be54353819f9d27027904e44aed966b68f2505be5c5d35cfb30`。ffmpeg全文件decode退出0；mean_volume −17.8dB、max_volume −2.2dB，证明有非静音信号，不等于语义/自然度验证。

真实cue文本交付：`/private/tmp/voxstudio-claude-e2e-20261003/transcription-zh.txt`、`transcription-en.txt`、`voiceover-script.txt`；证据目录保留同名副本。配音字幕六条：0.016–1.296、2.336–5.796、6.016–8.496、8.816–11.296、11.456–12.336、12.576–12.928s，按原脚本次序完整覆盖，均标Ad测试。

## 覆盖与收尾

本轮10个定向cases：**8 Pass、2 Fail、0 Blocked、0 Skip、0 Not-run**。执行覆盖率100%；通过率80%。知识QA为2/4通过（两个内容可核对但引用不合格）；视频MCP定向编辑1/1；媒体定向4/4；安装发现1/1。原357条全量回归未执行；没有将G06/G07/G08全部feature标完整通过。

本轮保留新测试项目、3个测试session和输出便于复核；未删除或改写原Downloads文件、既有工程或来源。MCP项目级安装和Claude Code设置页选择保留；其余App配置未修改。UI最终显示测试配音播放完毕，QuickTime视频播放完毕。代码无新增修改；新增本报告与证据文件。未commit/push。

需修复/重测：QA-I1主引用canonical正文及保留语气，QA-I2引用与答案claim对齐。测试任务本身已执行完成，两个问题保留Fail。

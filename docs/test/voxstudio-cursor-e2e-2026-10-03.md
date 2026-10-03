# Cursor × VoxStudio MCP 定向端测 — 2026-10-03

与 [Claude CLI 同用例报告](voxstudio-claude-cli-e2e-2026-10-03.md) 使用相同4个知识QA、视频编辑、Ad测试中文配音、中文/英文转录和缺文件负向用例，共10项（含安装发现）。这是定向smoke，不是357项完整回归。

本轮安装和Cursor输入/执行全程Computer Use。Settings → MCP → Cursor → Install in Cursor 打开原生安装确认：name `voxstudio`，URL `http://127.0.0.1:19789/mcp`，无需headers或OAuth。Install后Cursor Customize/MCP显示Connected、100tools/6resources enabled。没有安装Cursor软件或改既有MCP。

目标为已运行的签名 `.build/VoxStudio.app`。使用Cursor专用新聊天，项目voxella-studio-app、This Mac、main；没有切换branch/修改代码。模型为界面当前Grok4.7High（准备时由用户从HighFast改为High，本轮保持该选择）。复用用户选择Ad测试中文声音与上一轮脚本。

新项目、session与媒体输出使用Cursor测试名前缀，与Claude轮输出分开；原Downloads文件保留。用户本轮明确要求在Cursor复用同样测试内容，范围限于上一轮4个指定来源与合成fixtures，不读取其他正文。

## 实际结果

10项已执行完成：9 Pass，1恢复后Pass，0 Fail/Blocked/Not-run。视频跨构建恢复，不能作为单一冻结构建的无中断通过。媒体结果来自原构建；后续文件/播放验证未重新生成任务；QA在授权后新构建完成。没有改产品代码或提交。

| ID | 操作/预期 | 状态 |
|---|---|---|
| SETUP | 安装Cursor MCP并真实发现工具 | Pass：Connected，100 tools/6 resources；实际创建任务与编辑成功 |
| QA-1 | DeepSeek事件，scope仅AI，原文与引用/保留语气正确 | Pass：93.28–173.36s正文；保留“据称” |
| QA-25 | cuneiform含义与重新发现地点，正文引用正确 | Pass：424.59–517.07s词源/地点，1306.19–1401.22s支持尼尼微补充 |
| QA-18 | 两个Lemonade来源共同建议，两边正文支持 | Pass：4个original_segments引用覆盖两个来源 |
| QA-SCOPE | 只Origin问DeepSeek，缺证据且无范围外引用 | Pass：明确无法确认；仅Origin sessionCard，无AI正文或外部补答 |
| EDIT | 新30fps720p项目，split90/move120/undo90/re-move120、标题、导出 | 恢复后Pass，第一次因应用替换/重启断连 |
| VOICE | Ad测试ID生成相同中文脚本、status/preview/文件/播放核验 | Pass：completed、6 cues、文件解码与完整播放 |
| TRANS-ZH | Downloads zh-single.wav转录与有界预览 | Pass：completed，zh，3/3关键词，预览解码成功 |
| TRANS-EN | Downloads en-single.wav转录与有界预览 | Pass：completed，en，3/3关键词，预览解码成功 |
| TRANS-BAD | 不存在路径明确报错、无假成功 | Pass：could not be opened，无session ID |

## 构建与执行边界

Cursor 3.22.12，Grok 4.7 High。VoxStudio 7.0.30(116)，Developer ID GREATWAY GLOBAL PTE. LTD.，Team 4DMAQ32SNU。原 `.build` PID64226，19789端口，SHA256 `e0b57ac57d9100d3b8d36d8ab716772650d6be7fa941035f49962bd62d3812b6`。本轮未执行bundle或重启命令，因为目标已运行。

18:47期间目标进程变为PID78872，二进制SHA256变为 `3271670c00a965dd5a6ba3b081de845923852e947a560329e66a211d0cb664c4`；签名时间18:47:28，版本/Team一致。本测试没有发起替换或重启，无法从此证据确定外部操作者。`add_texts` fetch failed，后续Not connected。通过Cursor Customize → voxstudio → Reload恢复Connected，再打开同一工程核对后恢复；没有创建第二个工程。

知识问答初次QA1和检索已在Cursor后台调用，点击展开时自动审批拒绝继续：此前允许的目的地是DeepSeek，不能延伸到Grok。立即Stop generation。用户随后明确回复“允许。请继续”，授权四个既定来源相关片段用于Cursor/Grok问答与引用核验。19:09恢复同一Cursor聊天，重新调用四题，不把暂停时的未核验返回当通过。来源仅AI State of the Art & Future、Origin of Writing和两个Lemonade视频。恢复前确认目标PID78872/SHA2563271670c…未变；没有利用直接连接或CLI绕过阻断。

## 知识问答实际核验（19:09–19:12授权后）

同一Cursor聊天“VoxStudio MCP testing process”，四题分别一次knowledge.ask，均status=completed、allow_cloud=false/origin=local/answer_mode=normal；后续只做指定来源相关session.search_segments，不用修正答案替代原始返回。原始答案、scope、引用字段及核验记录见 [knowledge-ui-verification.json](voxstudio-cursor-e2e-2026-10-03-evidence/knowledge-ui-verification.json)。这份证据从Computer Use可见输出人工转录，不是原始网络日志。通过工具菜单Copy output粘贴到未发送输入框读取完整AX内容，再清空草稿，没有发送这些草稿。

| 用例 | 原始答案要点 | 引用与原文支持 |
|---|---|---|
| QA-1 | DeepSeek moment，2025年1月、中国开放权重R1、接近/达到SOTA、据称更少算力更便宜、竞争加速 | AI正文93.28–173.36s，chars1316–2487，original_segments/sessionTranscript，正文全部支持；据称保留allegedly |
| QA-25 | 楔形，拉丁cuneus；19世纪在Iraq/Syrian/Babylonian城市发现，补充Nineveh | Origin正文424.59–517.07s，chars6481–7920支持词源/1840–1850/地理；1306.19–1401.22s，chars20247–21675尾部明确1850s/Nineveh/library，支持补充结论 |
| QA-18 | 承认困难、选择下一步小行动、不被挫折定义、启发/前进、耐心/希望 | 两个来源各2个original_segments，约0–45s与45–103.9s，完整引用正文均支持共同建议；两边独立sourceID |
| QA-SCOPE | 当前目录仅Origin，无法确认AI场次或DeepSeek内容 | 唯一引用Origin sessionCard/chunkIndex−1；无AI正文/范围外引用；按拒答与scope判Pass |

Q1的snippet/matchText显示播客开场白；Q25第二引用snippet显示苏美尔泥板/two rooms，未展示尾部Nineveh。这是短预览与完整证据块的显示限制，值得改进。判定基于sourceID/time/character范围对应的完整canonical正文，不要求每个截断snippet支持全部claims。Q25第二引用附于地理段，未用于词源句；完整被引块明确支持尼尼微，因此不判为上一轮“相邻但无关正文”问题。

Q-SCOPE的语义检索仍返回Origin范围内的若干书写候选块；不把semantic search结果当作literal零命中/穷尽不存在证明。此题验收仅确认工具拒答、没有范围外证据或外部补答。QA不是全链路离线：allow_cloud=false约束App路由，Cursor仍使用用户授权的Grok模型目的地。

## 媒体证据

Cursor聊天“VoxStudio MCP media testing”。首次两轮status内ZH完成，EN和VOICE仍running；后续在同聊天分别再次status，各completed/progress1，才preview。未重复创建。

| 用例 | session | 实际cue |
|---|---|---|
| ZH | `28DE5FBA-8C10-487C-87F7-E4779374E398` | zh，0–5.92s，欢迎使用Voicella Studio。这句话用于测试中文转写和词级时间戳。speaker空，欢迎/测试/时间全中 |
| EN | `DC3AE2D6-CAEB-47F4-837F-908FB9C42671` | en，0–4.80s，Welcome to Voxella Studio. This sentence tests local word timestamps. speaker空，welcome/local/timestamp全中 |
| VOICE | `A1928D3A-5E98-4A4C-A619-B2CDDAE1A3EA` | zh，6 cues，各speaker Ad测试，按序拼接与提交脚本一致 |

参考音 `D0AA2E85-0D7C-4157-8424-47FE656D7750`，voice.list和voice.preview(play=false)返回Ad测试/zh/5s。脚本：“欢迎来到 VoxStudio。今天，我们把灵感变成清晰的表达。先整理知识，再剪辑视频，最后用熟悉的声音讲述故事。准备好了吗？让我们开始。”

配音cue：0–1.28欢迎来到VoxStudio；2.24–5.44今天句；5.76–7.14先整理知识，再；7.92–11.36剪辑视频至讲述故事；11.60–12.64准备好了吗；12.80–13.61让我们开始。切成6个cue并不等于输入必须有6个句号。

本地输出 `/Users/adamwang/Library/Application Support/VoxStudio/Dubs/dub-flow-5CC7E4FB-1B7A-401A-8D94-A133EC2BDA37.wav`，交付副本 `/private/tmp/voxstudio-cursor-e2e-20261003/Ad测试-voiceover.wav`。13.642667s，24kHz mono PCM float，SHA256 `65d8e0179262acaff4c709b87b4b99244a7491d1b5893319fae971ecab80251a`。完整ffmpeg解码无错误，mean −17.8dB/max −1.5dB；QuickTime UI从0播放至13.642667s自动停止。仅验证可播放、非静音、脚本文本和标签；未评价自然度或声纹相似度，没有额外ASR。

三个preview皆start0/open=false/play=false，请求ZH6s/EN4.5s/VOICE15s；实际AAC文件6.144/4.672/13.738667s，均完整解码。EN返回跨窗口cue0–4.8，文件包含编码尾长，因此不宣称严格逐样本窗口裁剪。具体路径见preview-validation.json。

负向 `/private/tmp/voxstudio-cursor-e2e-20261003/nonexistent.wav` 返回 `“nonexistent.wav” could not be opened.`，没有session ID。

## 视频证据

Cursor聊天“VoxStudio MCP video editing”。独立工程 `/Users/adamwang/Documents/Voxella Studio/Cursor MCP E2E 20261003 Video.voxella`，timeline `87F4F6E6`，素材 `D5659581` ready，1280×720/30fps/9.234s。初态只读Claude时间线6664B37D，没有编辑。

导入：video `FAF3DFCE`/audio `144FFA81` [0,277)。split90：前段[0,90)，trimEnd187；后段 `F42FEC8F`/linked audio `B5C807F3` [90,277)，trimStart90。move120后307帧且V/A都空隙[90,120)；undo回277帧、后段90、空隙消失；再次move120的读回正确，但重启后磁盘仅保留撤销后的277帧状态。恢复连接后读取同ID，确认无标题，重新move120并添加一次标题 `645C1417`，V2 [0,90)，白色96居中0.5/0.5。UI与抽帧确认文字正确、居中。

export_project：video/H.264/720p/fps30/307frames/overwrite=false；job `71C72037-DD85-4654-BFAA-F680579F6B7A` started，一次manage_exports completed/progress100。输出 `/private/tmp/voxstudio-cursor-e2e-20261003/editor-output.mp4`：H264 1280×720 30fps307帧，AAC16k mono，10.233333s，7551344bytes，SHA256 `60ff9f059dd2122b13eed04628c1c9dc0d93d6c78decfec3cea63e07ab5ae587`，完整解码无错误。

抽帧：t1标题居中；t3.5空隙黑帧；t4.5源时间3.5且标题已消失；t9.2源时间8.2。QuickTime UI播放从0到10.233333s自动停止，无打开错误；工程保持打开。

## 对比与证据文件

Claude与Cursor媒体均通过同样smoke：转录文本/语言/关键词一致；配音采用同音同稿，时长12.96s与13.642667s不同，不以字节一致为预期。Cursor视频恢复后参数/长度符合相同用例，但跨构建和自动保存丢失造成比较限制。授权后Cursor QA为4/4通过；Claude QA为2/4通过，QA1/QA25原引用失败。本轮Cursor两题正文引用已对齐，但App二进制与模型目的地均不同，不能据此归因于Cursor客户端，或宣称同构建复测已修复Claude问题。

本报告根据Computer Use可见工具返回及最终表格记录，未读取Cursor隐藏聊天数据库。文件证据在同名 `voxstudio-cursor-e2e-2026-10-03-evidence/`：knowledge-ui-verification.json、video/voice/preview-validation.json，4张视频抽帧，保存工程project.json副本。执行测试使用Cursor MCP，ffprobe/ffmpeg仅验证本地落盘结果。收尾三个Cursor测试聊天均Completed、未发送草稿清空；MCP安装、测试项目/会话及输出保留，未commit/push。

# VoxStudio 本地回归端测记录

- 日期：2026-10-01（Asia/Singapore）
- 范围：本地 `.build/VoxStudio.app`；不上传 TestFlight；跳过购买与 VoxStudio Cloud 登录。
- 结果：核心本地转录、字幕导出、配音、知识问答与视频导入/预览有成功路径；字幕翻译显示 `Needs attention` 且未生成可导出的英文轨；屏幕录制受 macOS 权限阻挡；视频时间线剪辑/导出未完成。

## 构建与环境

- 构建并启动：`./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"`，成功。
- 应用版本：7.0.30（build 116）。签名：`Developer ID Application: GREATWAY GLOBAL PTE. LTD. (4DMAQ32SNU)`；本机 codesign 验证通过。此 Debug 包未做公证。
- 构建输出有 Swift 编译警告，但打包、签名和启动均完成。
- 输入音频：`~/Downloads/test_2min.mp3`，120.012 秒，48 kHz 双声道 MP3。
- 输入视频：`~/Downloads/voxstudio_short_019f8a5d-1fc9-700c-83a1-42debb162360.mp4`，约 103.933 秒，H.264 1920×1080 + AAC。
- 未使用的另一份音频：`~/Downloads/test_3min_16khz.wav`；未使用的较长视频：`~/Downloads/Video_editor_export2.mp4`。
- 视频编辑临时项目位于 `/private/tmp/VoxStudio-E2E.voxella`，未写入仓库。

## 回归结果

| 功能 | 状态 | 结果与证据 |
|---|---|---|
| Debug 打包、签名、启动 | 通过 | `.build/VoxStudio.app` 本地启动；签名校验通过。 |
| 本地音频转录 | 通过 | 选择 `test_2min.mp3`，不勾选 VoxStudio Cloud 选项后完成；生成本机 session，状态含 `Ready`，显示中文转录、说话人标签、时间段和摘要。 |
| 转录播放 | 通过 | session 内音频可播放。 |
| TXT 转录导出 | 通过 | 保存 `/private/tmp/voxstudio-e2e-transcript.txt`；UTF-8 文本，约 1.9 KB，含说话人和转录内容。SHA-256：`9b3d5b35af0249d904f9517ed1a9c2d45c6698171d877b5e0147133e6580638d`。 |
| 字幕生成与 VTT 导出 | 通过 | 生成细粒度字幕 cue，保存 `/private/tmp/voxstudio-e2e-subtitles.vtt`；文件以 `WEBVTT` 开头，时间码格式正常。SHA-256：`1fdd5300fd836f855a2ac1eecce3c718900cf0ab06369efe8566d46304bd9c29`。 |
| 源音频导出 | 通过 | 导出 `/private/tmp/voxstudio-e2e-audio.mp3`；ffprobe 识别为 MP3、48 kHz、双声道、120.012 秒。SHA-256：`cfa50afe46a4a804c3b26ee416a210bccf4b48bf7e701159f810376e468f62d5`。 |
| 转录翻译（英文） | 失败 | 选择英语后进入字幕清理/翻译任务；任务结束时 session 为 `Ready, Needs attention`，导出选项只有 Original，没有英文字幕轨。 |
| 本地语音合成 / Voiceover | 通过 | 输入 `This is a local voiceover regression test.`，生成并播放本机语音；输出为容器内 WAV，24 kHz 单声道、2.688 秒、262,144 bytes。处理时 Cloud 选项未勾选。 |
| Knowledge 搜索 | 通过（基础） | 本地知识列表和标题检索可用；标题关键词可筛选新建 session。未把单个源标题检索当作全文检索验证。 |
| Knowledge 问答与引用跳转 | 通过 | 使用预配置的 BYOK 问答设置询问测试转录；答案引用 `00:47–01:33`，点击引用可打开对应转录范围。未登录 VoxStudio Cloud。 |
| 视频媒体导入与预览 | 通过 | 从 `~/Downloads` 导入上述 MP4；媒体库显示约 1:43，预览播放正常，文件信息显示 1920×1080、30 fps。 |
| 视频时间线剪辑与视频导出 | 未完成 | 临时项目时间线仍为 `0:00`；导出队列显示 `No exports yet`、时长 `00:00:00:00`、大小约零 KB。没有生成空视频，因此剪切、分割、文字叠加及成片导出未验证。 |
| 屏幕 / 系统音频录制 | 阻挡 | Record 页面提示需在 System Settings → Privacy & Security → Screen & System Audio Recording 授权 VoxStudio。未改系统隐私权限，未开始录制。 |
| Dictation / 麦克风实录 | 未执行 | 需要麦克风权限的实录路径本轮未执行。 |
| 设置与本地功能状态页 | 通过（页面检查） | 检查 Account、General、Local Features、Voice Library、AI Service、MCP、Skills、Storage 页面。Local Features 面板显示转录/字幕、说话人识别、配音、知识排序和音频增强为 Ready；未清缓存或索引。 |

## 约定跳过项与限制

- 未打开登录流程、未登录 VoxStudio Cloud；Account 页面显示 Signed out。转录和配音的 Cloud 选项均保持未选中。
- 未触发购买、恢复购买或任何 TestFlight 上传操作。
- Meeting Recorder 未登录 Google/Apple，也未开始屏幕/音频录制。
- 本轮属于手工 UI 回归；Local Features 的 Ready 状态是界面检查，并不表示每个模型/功能都已分别端到端调用。
- 测试中仅新增本记录；应用源代码没有修改。`docs/diagnose/mobile-recording-e2e-2026-10-01.md` 是开始前已存在的未跟踪文件，本轮未触碰。

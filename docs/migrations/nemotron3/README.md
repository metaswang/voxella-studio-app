# Nemotron 3 八人说话人分离与声纹识别迁移记录

分支：`feat/nemotron3-diarization-8spk`。记录日期：2026-10-08。

## 模型与资源

| 项目 | 值 |
| --- | --- |
| 源 checkpoint | `nvidia/Nemotron-3-Diarization` @ `a435e9867d79e789e90053f9b6d6834053af564a` |
| 导出 | `aufklarer/Nemotron-3-Diarization-100M-MLX-INT8` @ `8be6cfb8a8009b1e11419208c819f6e20c94b4a3` |
| 权重 | `model.safetensors` 106,541,384 B，SHA-256 `78b2131b…b67ac3`（与 HF LFS oid 一致） |
| 许可证 | OpenMDW-1.1（`LICENSE`、`NOTICE` 随资源发布并纳入安装校验） |
| R2 | `studio-models/aufklarer/Nemotron-3-Diarization-100M-MLX-INT8/8be6cfb8…/` 四个文件，见 `r2-publish-nemotron3.json`；大小、ETag(MD5)、SHA-256 元数据均已远端核对 |
| 快照接口 | 生产 `POST /api/v1/studio-models/snapshot` 已返回四个文件的分块 CDN 下载地址 |

## 代码结构

- `Vendor/Nemotron3Diarization`：从 speech-swift `231f8eb9`（v0.0.28 后的合并提交）抽取的 MLX INT8 推理、DSP 与说话人缓存更新；其余 speech-swift 依赖保持 0.0.21。与上游的差异：
  - 前端按源 checkpoint `processor_config.json` 与 transformers 参考实现修正：0.97 预加重、零填充居中 STFT、去除 vDSP 正向 FFT 的 ×2 缩放、丢弃末尾居中帧。speech-swift 原实现缺少预加重且功率谱放大 4 倍。
  - 按块计算 mel，长音频不再整段生成频谱。
  - 头部子像素卷积前把有效长度之后的行置零，与参考实现动态形状一致。
- `Vendor/WeSpeakerEmbedding`：原 ResNet34 权重不变；Kaldi FBank 前端（int16 缩放、snip_edges、逐帧去直流与预加重、Hamming、Kaldi mel、float eps 下限、CMN）与无偏标准差统计池化。
- App：`Nemotron3DiarizationEngine` 输出 8 通道、0.01 s 概率；离线配置每块确认 340 行（27.2 s）+ 40 行右侧上下文（3.2 s）；活动阈值 0.5，0.25 仅用于缓存筛选；状态每次录音重置。

## 数值验证

| 检查 | 结果 |
| --- | --- |
| Nemotron mel vs 参考配方（torch.stft + librosa Slaney） | 通过，max abs < 5e-3，mean < 2e-4（`Nemotron3MelParityTests`） |
| WeSpeaker FBank vs `torchaudio.compliance.kaldi.fbank` | 通过，max abs < 2e-3，mean < 2e-4（`KaldiFbankParityTests`） |
| 真实 INT8 权重多块推理 | 62 s → 3 块，每 10 ms 一行，概率 ∈ [0,1]；取消不返回部分结果 |
| 真实 WeSpeaker 权重 | 同一说话人余弦 0.85，不同说话人 0.13 |
| 冷安装 | App 经快照接口下载、校验 Nemotron，安装后自动删除本地 Sortformer；英文两人样本检出 2 人，RTF 0.057 |
| 60 / 120 分钟回放 | 44.6 s / 89.1 s（RTF 0.012），133 / 265 块，MLX 峰值约 420 MB 且不随时长增长，取消约 0.33 s 内退出 |

BF16 对照：未运行。需要下载 397 MB 源权重并实现 BF16 推理路径；导出方在 `config.json` 中报告的 INT8 对源模型 high-resolution cosine 为 0.99975。

## 尚未完成（需要数据或确认）

1. **DER / JER**：仓库内没有带 RTTM 的 1–8 人中英文评测集。已提供 `Nemotron3EvaluationTests/exportsHypothesisRTTM()` 输出假设 RTTM，配合 `tools/diarization_eval` 分别用 collar 0 与 0.25 计分；“5–8 人 DER 相对降低 20%”需在同一数据上对比旧流程。
2. **身份阈值标定**：`SpeakerMatchCalibration.calibrate` 已实现（按目标错误命名率选阈值和差值门槛，并报告召回率与 Wilson 置信区间）。当前 `0.62 / 0.10 / 2 s` 为临时值，需用独立验证集替换。
3. **旧 Sortformer R2 清理与 CDN 前缀清除**：脚本 `scripts/studio_model_r2.py retire / purge-cdn / check-retired` 已就绪并做过 dry-run（2 个对象，约 236 MB）。当前已发布的 7.0.x 仍从该路径首次下载说话人模型，删除前需确认新版本发布节奏。

## 端到端样本评测（2026-10-08）

样本与来源见 `eval/SOURCES.md`。共 7 段：英文 VoxConverse test 5 段（2/4/5/7/8 人）、普通话 AISHELL-4 test 2 段（5/7 人）。全部使用 `auto` 人数，参考 RTTM 为数据集自带标注。

评分：`tools/diarization_eval`（pyannote.metrics），包含重叠语音，无 UEM，collar 0.25。

| 样本 | 参考/检出人数 | 分离时间线 DER | 分离时间线 JER | 应用词级 DER |
| --- | --- | --- | --- | --- |
| en_gyomp | 5/5 | 0.6% | 0.9% | 3.6% |
| en_kpjud | 8/8 | 7.2% | 18.0% | 41.5% |
| en_erslt | 7/7 | 2.8% | 5.2% | 11.8% |
| en_lubpm | 2/2 | 1.4% | 2.0% | 5.0% |
| en_eucfa | 4/3 | 7.0% | 36.0% | 18.1% |
| zh_S_R004S04C01 | 5/5 | 3.3% | 4.2% | 13.6% |
| zh_L_R004S01C01 | 7/6 | 3.8% | 20.0% | 15.5% |

- 5–8 人组（5 段）分离时间线 DER：0.6–7.2%；1–4 人组（2 段）：1.4% 与 7.0%。
- 人数准确 4/7；两次漏检 1 人（en_eucfa、zh_L）。
- 应用词级 DER 偏高主要来自 ASR 词覆盖不足（en_kpjud 漏检占比很高），并不代表分离本身；且词级结果无法表达重叠说话。
- 样本仅 7 段，不足以满足“5–8 人 DER 相对降低 ≥ 20%”的验收；缺少同集旧流程基线（旧 Sortformer 权重已在迁移后清理），因此相对降幅仍未验证。
- 另外，`zh_S`/`zh_L` 原始 FLAC 为 8 声道（数据集卡片写的是单声道），本次取声道平均降为单声道 16 kHz。

应用端 UI 验证：`app_session` 打开会话后截图，确认分说话人显示、时间戳与摘要正常；但截图显示的是 7 人普通话会话，而非 8 人英文会话（会话未切换）。

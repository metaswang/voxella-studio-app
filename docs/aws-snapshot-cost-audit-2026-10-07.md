# AWS 快照费用与模型镜像检查

> 最新状态：用户随后要求全部退役 AWS 模型 fallback。ASR、Dub 的 AMI/快照也已删除，17 个当前启用区域的自有 EBS 快照和回收站均为 0；代码清理位于新分支。以下保留此前各阶段调研过程，其中“保留 ASR/Dub”的状态已被后续操作替代。详见 [AWS fallback 退役记录](/Users/adamwang/Project/subdub/voxella-studio-app/docs/aws-fallback-retirement-2026-10-07.md)。

检查日期：2026-10-07。AWS 账户：VoxStudio（945139114947）。费用来源为账单页面，资源来源为 Chrome 中的 EC2 控制台；代码检查涉及部署、scaler、transcribe、dub、audiotools 和 attendee 仓库。没有为检查磁盘内容启动付费 AWS builder 或恢复快照。因此，下文把控制台实测、代码发现和待验证的磁盘占用分开说明。

## 费用与资源总览

2026 年 8、9 月，Frankfurt EBS 快照每月计费使用量为 322.641 GB-Mo，单价 $0.054/GB-Mo，金额约 $17.42/月。Secrets Manager 另约 $0.40/月。10 月截至检查时快照费用为 $2.81、Secret 为 $0.08，均被当前 credits 抵扣；净账单为零不代表资源没有持续消耗额度。

删除前，四份快照均为 Standard、Completed，完整快照大小合计 385.28 GiB。这个数字不同于账单的计费存储量，不能用各快照完整大小的比例分摊 $17.42，也不能用根卷容量估算快照费用。用户确认后已删除音频和裁剪两组资源；现在剩余 ASR、Dub 两份，完整大小合计 238.14 GiB。

| 工作负载 | AMI | 根卷快照 | 完整快照大小 | 根卷容量 | 最后启动时间（GMT+8） |
| --- | --- | --- | ---: | ---: | --- |
| ASR / transcribe | `ami-03042ad8415dc59d5` | `snap-080229e7dd5ccdd43` | 85.49 GiB | 220 GiB | 2026-07-17 11:48 |
| Dub | `ami-0f88b5536cedbf100` | `snap-0d6cd925351395b66` | 152.65 GiB | 300 GiB | 2026-06-11 16:23 |
| Video smart crop | `ami-079bb1cf6977eef85` | `snap-0c601fa799dc7705f` | 79.96 GiB | 220 GiB | 2026-06-12 02:27 |
| Audio tools | `ami-0e295153a3295554a` | `snap-0e0023f1de00d27f9` | 67.18 GiB | 220 GiB | 2026-06-12 01:45 |

这四项不是 Meetbot 镜像。当前 Meetbot 运行手册显示生产使用 GCP 动态 runtime；AWS 本次已识别的四份快照没有 attendee/meetbot 项。不能据此推断 GCP 没有另外的镜像费用。

控制台链接：[Frankfurt AMI 列表](https://eu-central-1.console.aws.amazon.com/ec2/home?region=eu-central-1#Images:visibility=owned-by-me)、[快照列表](https://eu-central-1.console.aws.amazon.com/ec2/home?region=eu-central-1#Snapshots:)。

## 运行架构纠正：GCP 只承接 Meetbot runtime

此前把生产配置中的 `ASR_PROVIDER_ORDER=modal,gcp` 解读为“ASR 在 Modal/GCP 运行”，这个结论不成立。2026-10-07 根据用户纠正，重新直接读取 GCP 资源、生产容器配置与代码，并查询 Modal 已部署函数。

| 工作负载 | 当前承载 / 调度目标 | 本次核实证据 |
| --- | --- | --- |
| Meetbot runtime | GCP | 运行中 attendee-scheduler 的 `GCP_PROJECT_ID=gen-lang-client-0396714319`、`GCP_BOT_SOURCE_IMAGE_FAMILY=attendee-bot-golden`；VPS 槽位为 `{"myvps2":0,"myvps3":0}`。GCP 对应镜像 READY、20 GB。检查时没有活动 VM；这里确认的是调度配置及镜像，不是实际入会验收。 |
| faster-whisper ASR | Modal | 生产认证读取 `voxella-gpu-transcribe / drain_gpu_transcribe`，函数存在且 hydration 成功。 |
| Parakeet / Qwen ASR | Modal | `voxella-asr-parakeet / drain_parakeet_transcribe`、`voxella-asr-qwen / QwenASRService.drain` 均查找成功。 |
| Dub | Modal | `voxella-gpu-dub / DubDrainWorker.drain` 查找成功；AWS 总开关 false。 |

GCP 项目 `gen-lang-client-0396714319` 全部区域的 instances、disks、snapshots 列表均为空。自有 images 只有两项：

- `attendee-bot-golden-20260904-chrome134`，family 为 `attendee-bot-golden`，20 GB；用于 Meetbot。
- `voxella-arq-video-encode-golden-20260604075625`，family 为 `voxella-arq-video-encode-golden`，30 GB；是遗留视频编码镜像。当前 video_encode provider order 为 `modal`，没有活动 VM。这份镜像未删除；它的存在不代表当前视频编码在 GCP 运行。

配置所引用的 `voxella-arq-asr-golden`、`voxella-arq-dub-golden`、`voxella-arq-audio-tools-golden`、通用 `voxella-arq-worker-golden` family 都不在实际镜像清单中。生产 scaler 的所有 GCP target Docker `image` 均为空；`worker/gcp_provider.py:703` 会返回 `missing_gcp_docker_image_config`，不能构成可工作的 ASR/Dub fallback。当前 GPU reconciliation 对 Modal / AWS 分配容量，并显式以 `provider="modal"` 调用 Modal 调度；GCP provider 实现和旧 build 脚本的存在都不能作为实际部署证据。

近 30 天 Compute Engine 实例创建审计查询没有返回记录；这仅描述可查询的记录，不证明更早从未部署过模型 worker。Modal 函数查询没有执行付费推理，也不等于媒体任务端到端验收。

因此：**当前 ASR / Dub 主服务使用 Modal；GCP 是 Meetbot runtime 的调度目标，不能把 GCP 算作 ASR / Dub 灾备。AWS 旧快照是否保留，应按是否需要另外建设 AWS 恢复入口判断。** 本次复核只纠正报告，没有修改 ASR / Dub 生产路由或删除其他云资源。

## 已执行的策略调整

按用户要求，audio_tools 与 video_smart_crop 仅在 Modal 执行，不再为这两项保留 AWS fallback 配置。

- scaler `worker/settings.py` 中，两项 provider order 默认值由继承全局顺序的 `None` 改为显式 `modal`。保留现有通用 provider 实现，配置可明确覆盖默认值。
- `env.example` 和 README 改为两项 `modal`，AMI 示例只含 ASR、Dub。
- 部署仓库当前 `.env`、开发环境、生产主机环境与 `.env.prod.workers` 中，两项 provider order 改为 `modal`，从 `AWS_DRAIN__TARGET_AMI_IDS_JSON` 和已有 `AWS_DRAIN__TARGETS_JSON` 删除这两个 target。
- 历史备份文件保留，不能把旧备份作为未来回滚依据而重新启用这两项 AWS fallback。
- myvps2、myvps3 的当前生产环境文件作相同定向更新，保留其他配置；myvps2 的 scaler 默认值同时更新。
- 使用现有 `voxstudio-workers-v1`，只重建 myvps2 `modal-scaler` 容器以载入新环境，没有构建 Docker 镜像。

运行中容器解析结果：

```json
{
  "audio_tools_provider_order": "modal",
  "video_smart_crop_provider_order": "modal",
  "aws_enabled": false,
  "aws_ami_targets": ["asr", "dub"],
  "asr_provider_order": "modal,gcp",
  "dub_provider_order": "modal,aws"
}
```

容器已正常启动，运行状态为 running，OOM=false，Restarts=0；日志显示 GPU reconciliation 正常执行，两项 AWS 路径均为 disabled_or_ineligible。没有额外提交媒体业务任务来测试。

部署后执行两台 `check_myvps_health.sh` 均退出 0：API/Web/TEI 健康，两台音频 worker 均 running、无 OOM/restart；myvps2 Meetbot、数据库备份与 workshop 路由检查通过。

myvps2 回滚备份后缀为 `.pre-modal-only-20261007T084305Z`，myvps3 为 `.pre-modal-only-20261007T084340Z`。环境备份权限为 600。只恢复某份旧配置会重新带回旧 AWS 引用，恢复前应保留本次策略。

**AWS 音频和裁剪两组资源已删除。** 最初自动审批要求明确批准具体资源；用户随后确认。已在 AWS 控制台注销 `ami-079bb1cf6977eef85`、`ami-0e295153a3295554a`，勾选删除关联快照。AMI 列表显示成功注销两份，快照列表只剩 ASR 和 Dub，EBS 快照回收站显示 No resources found。ASR、Dub 两组未删除。实际费用下降需要等待账单使用量更新，不能提前宣布精确节省金额。

![删除后只剩 ASR 和 Dub](/private/tmp/aws-snapshots-after-cleanup-2026-10-07.jpg)

## 逐项检查

### Audio tools：退役 AWS 副本

模型代码 `voxella-modal-audiotools/worker/models.py:107` 的预下载包括 MossFormerGAN_SE_16K、torchaudio HDEMUCS_HIGH_MUSDB_PLUS、Silero VAD。这些模型仍由 Modal 工作负载需要，不能为了清理 AWS 而删除 Modal 的模型资产。

AWS 副本对应 67.18 GiB 的完整快照。最后启动在 6 月 12 日，现已从 provider 配置与 AMI 映射中移除。最直接的省费方式是注销上述 AMI 并删除其快照，不再为这个已退役 AWS target 重建更小镜像。

### Video smart crop：退役 AWS 副本

模型清单包括 `yolo11s.pt`、`yolov8x_person_face.pt`、LR-ASD `finetuning_TalkSet.model`，可在 `voxella-modal-transcribe/worker/modal_videoenc_app.py:170` 对应预热代码找到。

部署脚本 `voxella-docker-deploy/scripts/gcp-workers/build-push-images.sh:85` 先构建 transcribe 镜像，再将同一镜像打标签为 video-encode 和 video-smart-crop。这会让裁剪的 Docker 镜像包含 ASR 的广泛依赖。它是代码层面确认的精简机会，但不能据此量化当前 AWS 快照中冗余依赖占了多少空间。

AWS 副本为 79.96 GiB，最后启动在 6 月 12 日。现已从路由和 AMI 配置移除并完成删除。按用户策略，裁剪继续使用 Modal。本次没有改变 GCP 或 Modal 镜像构建；旧 GCP 构建脚本不代表现有 GCP 承载裁剪业务。

### ASR / transcribe：检查 fallback 的实际必要性，再做精简

当前 ASR 主服务为 Modal，native ASR 同样为 Modal。生产 `modal,gcp` 是遗留 provider order：GCP target Docker image 为空，所引用的 ASR 镜像 family 不存在，不能解释为实际 GCP fallback。AWS 总开关为 false。6 月的 AWS AMI 引用仍保留，但它并不是当前正在工作的 AWS fallback。

`scripts/aws-workers/build-ami.sh:299` 的 ASR 预热主要包含：

- faster-whisper-large-v3-turbo；
- zh、ja、ko、pt、nl 对应的 wav2vec2 对齐仓库；
- 启用 speaker profile 时的分类模型；
- NVIDIA Sortformer，且随后还调用 NeMo `from_pretrained`。

该脚本的默认语言清单与配置合并，不能仅通过缩短配置清单取消所有默认预热项。`snapshot_download` 没有固定 revision 或限制文件清单，可能下载同一仓库内不同格式/不需要的文件；NeMo 另一路缓存有重复的可能，需要磁盘清单验证。

当前 ASR 路由已经包含 Parakeet、Qwen、faster_whisper；不能把 6 月的 Whisper/Sortformer 预热镜像当成已经覆盖当前全部 ASR 功能的证据。

若继续保留 AWS ASR：从干净基础卷构建，只烘焙实际 AWS fallback 使用的后端与固定模型 revision；保留国际语言支持，其他语言按需下载或从独立模型资产仓读取，并接受对应的首次启动延迟。若 ASR 仅保留当前 Modal 主服务，不再建设 AWS 恢复入口，则 ASR AWS AMI 可成为后续退役候选；不能以“已有 GCP ASR fallback”为删除理由。本次未改动它。

### Dub：剩余资源中最值得检查磁盘构成

Dub 的完整快照为 152.65 GiB，是四项中最大的一份，最后启动在 6 月 11 日。需要的主要模型为 Qwen3-TTS-12Hz-1.7B-Base 与 Qwen3-ForcedAligner-0.6B。

历史实验文档 `docs/aws-dub-g6-load-latency-experiment-20260610.md:371` 记录 TTS、aligner、metadata 的预热读取总量 10,928,354,332 bytes，约 10.18 GiB。进一步检查 `worker/aws_provider.py:1013`，统计使用 `stat -L` 跟随软链接，并以路径去重而不是以 inode 去重；同一个 blob 可被多条 snapshot 路径重复统计/读取。因此，这个数字不是模型的物理磁盘实占，不能直接与完整快照大小相减。当前官方 TTS 仓库约 4.54 GB、aligner 仓库约 1.84 GB，合计约 6.38 GB；仍不是旧 AMI 磁盘的实测值。[TTS 文件清单](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base/tree/main)、[aligner 文件清单](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B/tree/main)

生产配置仍列 `modal,aws`，但 AWS 总开关关闭；运行时 AWS target 配置缺少已烘焙 Docker image 等完整启动参数。仅保留 AMI 并不等于有一个经过验证的可用 fallback。

若保留 AWS Dub，优先检查 Docker image/layer、builder cache、旧模型 revision 和父镜像继承内容。模型本身先维持现有精度和功能，避免为了省磁盘先做未经评估的量化或移除 aligner。

## 跨镜像的代码问题

1. **继承旧 AMI，且缺少烘焙前的资产盘点。** `build-ami.sh:155` 默认可从该 target 既有 AMI 启动，随后 pull 新镜像。烘焙结束清理了凭据与 cloud-init 日志，但没有对旧 Docker image、构建缓存、其他模型目录或旧 revision 做定向保留管理。存在累积风险，具体冗余 bytes 尚未测得。应使用干净来源，并在 CreateImage 前生成 `docker system df`、目录占用与模型 revision 清单，再按明确 allowlist 只保留当前启动依赖。避免不加范围地 prune 持久化资产。

2. **先 COPY 全仓库，再下一层删除开发文件。** Dub、transcribe、audio tools Dockerfile 都存在整个源码目录 COPY 后再 `RUN rm` 的方式。删除在下一层发生，不会消除下层已写入镜像的内容。应在构建上下文的 `.dockerignore` 中递归排除 `.venv`、测试/缓存、数据、reference 和无关 artifacts，再精确 COPY；也可分离构建依赖与运行依赖。当前父目录 `.dockerignore` 缺少这组完整的递归排除策略。不能把本机当前 `.venv` 大小当成 6 月 AWS 镜像中的实测浪费。[Docker 镜像层说明](https://docs.docker.com/get-started/docker-concepts/building-images/understanding-image-layers/)

3. **模型下载范围和版本没有充分固定。** Dub 与 ASR 使用整仓库 `snapshot_download`，没有固定 revision 和 allow_patterns。应根据实际加载器建立版本化资产清单，保留权重、tokenizer、config、index 与必需代码；Hugging Face 的 snapshots/refs/blob 引用和 symlink 关系必须保留，不能简单按扩展名删除。

4. **没有 AMI/快照保留上限。** 当前烘焙脚本不负责旧 AMI 和快照生命周期。今后可为仍保留的 ASR/Dub 只保留当前版本和明确的回滚版本；替换配置、验证新版本后再删除旧资源。代码修改或新建小镜像不会自动停止旧快照计费。

## 省费预期与操作顺序

本次退役的音频与裁剪完整大小合计 147.14 GiB。共享块、增量 lineage 与可能的回收站规则会影响释放量，因此不承诺删除后固定节省 $7.95/月。应比较删除后稳定的快照计费 GB-Mo；在当前账单单价下，每减少 10 GB 的稳定计费存储约省 $0.54/月。

如果最终不保留任何这四份 AWS 快照，在没有其他快照或回收站继续计费的前提下，可以消除当前观察到的约 $17.42/月快照支出，约 $209.04/年，均为 credits 抵扣前金额。本次只指定退役两项，因此不能宣布全部 $17.42 已节省。

本次操作已完成：注销两个指定 AMI，同时删除两个指定根卷快照，并检查 EC2 AMI/快照列表及回收站结果。AWS 要求已注册 AMI 使用的根卷快照先解除 AMI 注册；删除只释放未被其他快照引用的块。[AWS 删除快照说明](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-deleting-snapshot.html)

对仍需保留的 ASR/Dub，如果只用于长期灾备而不要求及时启动，可考虑归档。归档有 90 天最低期限，恢复可能需要 72 小时，使用前必须回到 Standard，关联 AMI 要先禁用；归档按完整快照计算，不能简单把现有增量费用乘以折扣。因此它不适合要求快速接管的 fallback，应先确认保留目标并核算 Frankfurt 实际报价。[AWS 归档限制](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-archive-considerations.html)

缩小 220/300 GiB 的根卷容量只改变未来启动卷的容量与相关费用，不会直接缩小现有快照。真正减少旧快照费需要清理资产后生成干净的新快照，并退役旧快照。

## ASR / Dub 快照是否必需：补充代码调研

结论：**按现在的生产配置，这两份自有 AWS 快照不是在线 ASR / Dub 服务必需的。若继续采用当前预装 AMI 的 AWS 启动方式，则需要这些 AMI 的底层快照或一组经过验证的替代快照。** 不需要永久保留这两份旧版本才能实现 AWS 工作负载。

2026-10-07 再次读取生产容器的实际 Settings，确认 AWS 总开关 false；ASR provider order 遗留 modal,gcp，但 GCP Docker image 和对应云镜像均缺失，ASR 当前使用 Modal；native ASR 为 modal；Dub 为 modal,aws，但 AWS disabled。ASR 和 Dub 的 AWS target `image` 都为空；即使打开 AWS 总开关，仍会返回 `missing_aws_docker_image_config`。两份旧快照并没有构成一个已启用、完整的生产 fallback。GCP 只承接 Meetbot runtime，不是这些模型的替代备份。

| 判断 | 代码证据 | 删除 AWS 快照的影响 |
| --- | --- | --- |
| Modal ASR 模型独立存储 | `voxella-modal-transcribe/worker/modal_transcribe_app.py:141` 创建 Modal Volume，`:179` 挂载；native ASR `worker/modal_native_app.py:37` 同样独立挂载 | 不删除 Modal 模型，不直接改变现有推理 |
| Modal Dub 模型独立存储 | `voxella-modal-dub/worker/modal_app.py:175` 创建 Modal Volume，`:233` 挂载 | 不删除 Modal TTS/aligner 模型 |
| AWS 当前没有启动路径 | scaler `worker/aws_provider.py:1631` 先检查 enabled，再检查 Docker image、AMI | 当前主服务不读取这两份 AWS 快照 |
| 当前 AWS bootstrap 依赖预装模型 | `worker/aws_provider.py:1060` 将缓存只读挂载并设置 `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`；缺目录或 marker 时自终止 | 换成普通基础 AMI，不能只改 AMI ID；需先准备模型或改 bootstrap |
| 旧环境不能再一键复原 | EC2 AMI 的根设备映射直接引用指定快照 | 注销并删除后无法从旧 AMI 新建实例；已运行实例不受 AMI 注销影响 |

[AWS AMI 注销说明](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/deregister-ami.html)

### 没有自有预热快照的负面影响

1. 如果以后要把任务转到 AWS，需要重新构建 GPU 基础环境、拉取 Docker image、下载模型、确认驱动和依赖兼容；恢复时间更长，受网络、registry、Hugging Face 和 GPU 配额/容量影响。
2. 删除后丢失的是 6 月旧运行环境的恢复入口；如果 registry 标签或未固定的模型版本发生变化，重建不能保证与旧环境逐字节一致。模型资产、Docker digest、代码 revision 和依赖 lock 应单独记录。
3. 当前代码强制 AWS 模型离线并只读挂载，普通 GPU AMI 缺预热目录会失败。要做无自有模型快照的 AWS 启动，需要一个显式的准备阶段：下载固定资产、完整性检查、写 marker，再启动只读离线 worker。把 `model_cache_required=false` 改掉并不足以完成这个准备阶段。
4. ASR / Dub 当前主服务是 Modal；独立 AWS 运行环境能提供另一条恢复选择，删除会放弃这两份旧 AMI 的恢复入口。GCP 没有可工作的 ASR / Dub fallback，Modal 故障时不能据此宣称可由 GCP 接管。当前 AWS 入口本来就未启用，不能把“保存旧快照”视为自动跨云接管的保证。

AWS EBS 快照、Hugging Face 本地 cache 的 `snapshots` 目录、Modal GPU/memory snapshot 是三种不同的机制；本次只删除指定 EBS 资源。

### 如果继续保留 AWS，建议按此顺序瘦身

**第一步：先确定 AWS target 的范围。** ASR 的旧预热脚本覆盖 faster-whisper/WhisperX/Sortformer，而当前语言路由还包含专用 Parakeet/Qwen。若 AWS 只承担 legacy faster-whisper fallback，就只烘焙这个后端真正使用的模型；若要覆盖 native ASR，需要单独完善启动与预热支持，不能宣称旧 AMI 已覆盖全部功能。不能通过删除语言来缩减国际语言支持。

**第二步：将整仓下载改为模型级资产清单。** `build-ami.sh:359` 的 `snapshot_download` 未限制文件。已核对官方清单：

| wav2vec2 仓库 | 当前 PyTorch 权重 | 当前 Flax 权重 | 新构建可排除的重复格式 |
| --- | ---: | ---: | --- |
| Chinese | 约 1.28 GB | 约 1.28 GB | Flax `.msgpack` |
| Japanese | 约 1.27 GB | 约 1.27 GB | Flax `.msgpack` |
| Portuguese | 约 1.26 GB | 约 1.26 GB | Flax `.msgpack` |
| Dutch | 约 1.26 GB | 约 1.26 GB | Flax `.msgpack` |

这四项合计约 5.07 GB 的 Flax 文件，是基于当前仓库清单的可避免下载量，不是旧 AWS 快照释放量的实测。运行时 `worker/runner.py:652` 使用 PyTorch WhisperX aligner；应保留 PyTorch 权重、processor、config、词表。不能全局忽略 `.bin`，faster-whisper 的 CTranslate2 `model.bin` 和 wav2vec2 的 PyTorch `.bin` 都可能是必需文件。

[Chinese](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-chinese-zh-cn/tree/main)、[Japanese](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-japanese/tree/main)、[Portuguese](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-portuguese/tree/main)、[Dutch](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-dutch/tree/main)

葡语仓库还带约 1.19 GB 的 `language_model`；若只用于 WhisperX 强制对齐，应结合锁定版本的实际加载器验证后排除，而不是在没核对加载行为时删除。[葡语 language_model](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-portuguese/tree/main/language_model)

每个模型应配置 `revision`、`allow_patterns`/`ignore_patterns`，保留必要 tokenizer/config。Dub 的 TTS 还要保留 `speech_tokenizer/**`；不能只保留顶层 `model.safetensors`。[Hugging Face 下载筛选](https://huggingface.co/docs/huggingface_hub/guides/download#filter-files-to-download)

**第三步：避免模型 revision 和 cache layout 的重复。** Dub `worker/model_cache.py:20` 当前从本地 snapshots 中按 mtime 选最新目录，缺少明确 revision 选择；应记录期望 revision 并只保留该版本及必要 refs/blobs。ASR 同时使用 HF 下载和 NeMo `from_pretrained`，需统一/cache 盘点，不应仅凭两条调用断定已经有双份物理数据。预热文件统计应按实际 inode 或解析后的规范路径去重，避免重复读取及误判容量。

**第四步：在 COPY 之前排除开发资产。** 增加 Dockerfile 专用 `Dockerfile.aws-dub.dockerignore` / `Dockerfile.gcp.dockerignore`，模式相对于父构建上下文，以 `**/.venv`、`**/.git` 等递归匹配排除开发资产；确保 commons、lockfile、模型加载代码仍包含。使用专用 ignore 文件可避免修改父目录通用规则时误伤其他项目。COPY 后下一层 rm 不能消除已有层内容。运行镜像再通过多阶段构建去除不再需要的 build-essential/git，CUDA/Torch 则按实际依赖保留。[Docker 上下文与专用 ignore 文件](https://docs.docker.com/build/concepts/context/#dockerignore-files)

**第五步：从干净来源创建新 AMI。** `build-ami.sh:155` 会默认继承旧 target AMI；它的 220/300 GiB 根卷容量也继承到新实例。不能简单设置一个更小 `ROOT_VOLUME_SIZE` 就缩卷，因为从快照创建的卷不能小于来源卷。应使用兼容的干净 GPU 基础 AMI，复制并安装唯一需要的运行 image 和模型，再创建新 AMI。[AWS 卷大小约束](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateVolume.html)

**第六步：用实测选择容量和验收目标。** 在受控 builder 上记录 `docker system df -v`、`docker history`、`du -x`、按 inode 去重的模型文件清单、revision 与 image digest，证明根卷中只有当前 target 所需资产。新 AMI 要确认 Docker image 已存在、模型离线加载成功、marker/运行路径一致、启动时没有二次下载，之后切换配置并退役旧 AMI/快照。当前没有启动付费 builder，因此不承诺瘦身后一定是某个 GB 或某个百分比。

**建议：** 按当前部署，优先评估是否还需要 AWS 恢复入口；如果不需要，就不必为 ASR/Dub 重建预热快照。若明确需要 AWS 快速恢复，优先做 Docker/旧资产清理和固定模型清单，再保留一份可用当前版本，避免先改模型精度或牺牲语言覆盖来省存储。本次未改变 ASR/Dub 路由，也未删除它们的资源。

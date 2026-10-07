# AWS 模型 fallback 退役记录

日期：2026-10-07。AWS 账户：VoxStudio（945139114947）。工作分支：`codex/retire-aws-model-fallback`。

## AWS 资源结果

用户要求删除所有 AWS 快照后，通过 AWS 控制台已登录的 CloudShell 盘点所有当前启用区域。直接 API 返回 34 个区域，其中 17 个已启用，17 个 `not-opted-in`；先前将 34 个可列出的区域描述为全部已启用不准确。未启用区域没有为此次清理而开启。

盘点仅在 Frankfurt 找到以下两份剩余自有 EBS 快照；已先注销关联 AMI，再永久删除快照：

| 服务 | 已注销 AMI | 已删除快照 |
| --- | --- | --- |
| ASR | `ami-03042ad8415dc59d5` | `snap-080229e7dd5ccdd43` |
| Dub | `ami-0f88b5536cedbf100` | `snap-0d6cd925351395b66` |

此前 audio_tools、video_smart_crop 两组已删除。本轮完成后，17 个当前启用区域的自有 EBS 快照与 EBS 快照回收站均为 **0**，Frankfurt 自有 AMI 为 **0**。

复核区域：`ap-northeast-1`、`ap-northeast-2`、`ap-northeast-3`、`ap-south-1`、`ap-southeast-1`、`ap-southeast-2`、`ca-central-1`、`eu-central-1`、`eu-north-1`、`eu-west-1`、`eu-west-2`、`eu-west-3`、`sa-east-1`、`us-east-1`、`us-east-2`、`us-west-1`、`us-west-2`。

回收站使用 EC2 的 `list-snapshots-in-recycle-bin` 查询，并包含分页结果；没有回收站保留项。[AWS 官方命令说明](https://docs.aws.amazon.com/cli/latest/reference/ec2/list-snapshots-in-recycle-bin.html)

![全启用区域快照与回收站均为零](/Users/adamwang/Project/subdub/voxella-studio-app/docs/assets/aws-all-enabled-regions-snapshots-zero-2026-10-07.png)

过去观察到的快照存储消耗约 $17.42/月已失去对应存储资源，费用变化需等待账单更新；不能把历史已发生费用视为退款。Secrets Manager 的既有 Secret 未在此次快照清理范围内，不能宣称 AWS 所有费用归零。本次未删除 RDS、AWS Backup 等其他服务的备份，也未查询未启用区域的存储资源。

## 新分支中的代码与配置

同名分支已在 studio-app、modal-scaler、modal-dub、modal-transcribe、modal-audiotools 和 docker-deploy 仓库创建；保留各仓库原有工作区改动。实际业务代码改动集中在 scaler、Dub 和部署仓库；transcribe/audiotools 无需移除其 R2 依赖。

### Modal scaler

- 删除 `worker/aws_provider.py`、AWS preflight 入口和 EC2/AMI 启动实现。
- 删除 AWS GPU 配额、overflow 容量快照、overflow policy 发布、AWS 空闲实例回收和 AWS bootstrap TTL 延长逻辑。
- 模型工作负载仅调用 Modal。保留租户公平分配、workspace 总预算、各 target 上限、非抢占活跃任务、启动租约、Modal health/circuit 和失败后的租约清理。
- provider order 仅接受 `modal`；遗留 `modal,aws` 或 `modal,gcp` 配置需在部署前改为 `modal`，否则配置校验会拒绝启动。
- 从 `pyproject.toml` 和 `uv.lock` 移除直接 `boto3` 依赖，以及无需再安装的 `botocore`、`jmespath`、`s3transfer`、`python-dateutil`、`six`，合计六个包。其余已锁定包未升级。
- 更新 README、示例配置和已有测试对退休接口的引用；删除只覆盖退休路径的测试。没有新增或执行测试。

### Dub

- 删除 `worker/aws_drain.py`、`worker/aws_qwen_runtime.py`、`Dockerfile.aws-dub` 和 AWS 专用 runtime 测试。
- 删除主推理路径中的 `VOXELLA_RUNTIME_PROVIDER=aws` 分支，继续使用原 Modal 的 `FasterQwen3TTS.from_pretrained` 加载方式。
- 实验脚本移除对已删除 AWS loader 的引用；通用 GPU 实验 helper 保留。
- 原独立 drain 入口对 `AwsDrainSettings` 的耦合改为通用 `DrainRuntimeSettings`，保持原 idle 默认值；这涉及 Dub 模型入口，不涉及 attendee/Meetbot runtime。

### 部署配置

- 删除 `scripts/aws-workers/build-ami.sh`、`build-push-dub-image.sh`。
- 本地当前开发/生产配置移除 `AWS_DRAIN__*`、AWS GPU budget 和 AWS fallback 凭据变量；所有已有 `SCALER_*PROVIDER_ORDER` 改为 `modal`。
- 本地 `.env` 文件不受 Git 跟踪，review 时应以 scaler 的 `env.example` 和本记录核对迁移要求；历史备份不是新配置的回滚来源。
- 旧 AWS 延迟实验记录和计划标记为退役，保留历史证据。

## 保留的边界

- **GCP Meetbot runtime、attendee 仓库、Meetbot 调度配置、GCP 资源均未修改。** GCP 项目、镜像 family、服务账号、VPS 槽位等配置没有被清理脚本改写。
- scaler 的 GCP 配置模型、provider 文件和 Google SDK 保留，但模型调度入口只走 Modal；不将这些遗留文件描述为实际工作的 GCP ASR fallback。
- `aioboto3/botocore` 在 transcribe、Dub、audiotools 中仍用于 Cloudflare R2 的 S3 兼容协议，必须保留；`R2__*` 配置未改动。
- `libs/commons` 未修改，Modal 模型 Volume、模型精度及语言支持未改动。

## 交付与发布状态

AWS 快照删除已经生效。代码和本地配置改动留在新分支，**未提交、未推送、未部署到 VPS 或 Modal**。本轮做了源文件语法整理、依赖锁文件更新和改动审阅，没有运行单元测试、媒体推理或 Meet 入会测试。

后续发布必须先同步 provider order 与环境配置，再按依赖变更流程在 myvps2 更新 scaler 运行依赖；不得只同步新 scaler 源码而保留 `modal,gcp`/`modal,aws` 的旧环境值。发布仅涉及模型服务，GCP Meetbot runtime 保持现有路径。

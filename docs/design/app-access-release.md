# Mac DMG 购买与发布

2026-09-12 确认：Mac 仅分发 Developer ID DMG，不发布 TestFlight 或 Mac App Store。iOS 是独立的 TestFlight 发布。

## 发布路径

DMG 通过浏览器打开现有 Stripe Checkout 与 billing portal。正式构建使用 `BundledSpeech,SparkleUpdates`，不启用 `MacAppStore` trait，不使用 `--mas`。本次无需 Mac App Store 商品、描述文件或 Apple 私钥。

仅打包使用 `RELEASE_TARGET=dmg ./scripts/release.sh`；如需包含已检查的工作区修改，另外设置 `RELEASE_INCLUDE_WORKTREE=1`。该路径自动递增版本并完成 Developer ID 签名、公证和 DMG，不提交代码、不上传文件，也不要求用于发布 Sparkle 更新源的签名元数据。其他发布路径仍保留 Sparkle 签名检查。

`MAC_ACCESS_ENABLED` 控制后端 Mac 访问授权业务，`MAC_ACCESS_APP_STORE_ENABLED` 默认 false 并独立关闭 Mac Apple 入口。客户端 `VoxStudioPaidAccessEnabled` 必须与可用的后端及 Stripe 价格配置一起交付，不能仅因客户端编译通过便启用发行。

## 服务契约

- API 验签、验证账户和环境后把完整 webhook 写入 PostgreSQL；独立 billing worker 查询 Stripe 当前状态并交付。API 不直接入账。
- 终身授权和充值必须确认付款成功。订阅积分只从已确认 invoice 发放，Checkout 订阅事件负责关联和核对。
- 同一账户各渠道真实订阅状态保留，选择最高有效套餐，积分不叠加；旧订阅取消不能撤销其他有效订阅。
- 试用每个主账户只能登记一次，服务器和客户端都检查期限；既有项目的打开、编辑、保存及导出保留。
- 终身活动默认赠送 500 积分，由 `MAC_ACCESS_PROMOTION_*` 配置。截止时刻为 `2027-09-10T16:00:00Z`，对应新加坡 2027-09-11 00:00，不包含截止时刻。每个账户首次符合条件的购买只赠送一次。
- 充值和订阅积分分桶；退款只回收对应订单未消费部分，已消费部分记录异常。拒付冻结该订单未消费部分，胜诉释放、败诉按退款规则回收。
- 访问查询以服务端计算结果为准。终身访问的离线缓存存放设备钥匙串，租期由服务器给出，最长 30 天；登出删除缓存，拒绝早于验证时间的本地时钟回退。
- 账户变更通过持久化 outbox 重试缓存失效与 SSE。SSE 是刷新提示，客户端继续以访问查询结果为准。

## 实施与发布顺序

API 配置模板是 `../voxella-api/mac-app-access.env.example`。先执行 Mac 基础迁移和 `20260912_billing_event_pipeline.sql`，再部署 commons 与兼容旧任务的 billing worker，最后切换 API。只配置已确认的 USD Stripe Lifetime Price ID；缺少价格时不能静默使用充值价格。

完整架构、测试与 VPS 预部署记录见 `../voxella-docker-deploy/docs/billing-pipeline-rollout-20260912.md`。发布打包使用本仓库 `skills/voxstudio-release/SKILL.md`。

## 验证

默认 DMG 构建的 `AppAccessTests` 与 `VoxellaAuthServiceTests` 共 32 项通过。实际发行还需验证 Stripe test 支付、取消、支付后断网、退款、账户切换和 webhook 重放，确认交付唯一且不能绑定其他账户。

检查试用到期后的新建门禁、既有项目操作、重复激活、登出和重新打开购买窗口。挂载签名并公证的 DMG 验证 Developer ID、麦克风权限、最低系统版本及 Gatekeeper；不把 SwiftPM 测试视为完整安装或登录验收。

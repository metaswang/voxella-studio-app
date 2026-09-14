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

## 访问门禁矩阵（PR1 起）

产品规则（已定）：

1. **Lifetime**：购买结账需登录（绑定账户并发放设备凭证）；之后本机本地功能可不登录使用。设备凭证签发/校验见 PR2–PR3；换机与 N 台设备见后续 PR。
2. **14 天试用**：首次使用 Mac 应用时在本机 `ThisDeviceOnly` Keychain 启动；未登录或免费登录均可使用本地功能（付费云/积分仍需登录）。跨设备账户试用合并见 PR4。
3. **付费订阅**：登录与离线租期逻辑不变；订阅路径仍要求登录。
4. **退款 / 设备上限**：PR5。

`AppAccessGate` / `prepareNewContentAccess`：未登录用户可进入试用；订阅与付费云路径仍走登录。试用时钟不因登出清除（与 `AppAccessCache` 账户离线缓存分离）。

## PR1 验收 Blocker（2026-09-14 Research）

PR1 功能可合入开发分支做联调，但**不可标为可发行/验收通过**，直至下列项关闭：

### B1 — 未登录试用可被本地重置（Critical）
当前 `DeviceTrialClock` 仅 Keychain 存明文 `startedAt`，无服务端登记。删除 Keychain / 重装 / 新用户目录后会 `ensureStarted()` 重开 14 天。

### B2 — Lifetime stub 曾可伪造（Critical，已收紧）
原 stub 对任意非空 Keychain blob 返回 true。PR1 已改为 **`isPresent()` 恒为 false**：拒绝未签名/未校验凭证，直至 PR2 落地真实签名校验后再按 verified credential 返回 true。

### 推荐补强（适合「无 VoxStudio 登录、可联网」）
行业常见模式（Keygen/Keyforge/Paddle 类 desktop licensing、Tessera 文档对照）：

1. **匿名设备试用 = license state**：首次能联网时 `POST` 登记  
   `device_fingerprint = HMAC-SHA256(IOPlatformUUID, app_pepper)`（只上传哈希）  
2. 服务端写入 `fingerprint + trial_started_at`，返回 **Ed25519 / JWT 签名试用 token**（含 `ends_at`）  
3. 客户端 Keychain 存签名 token；离线验公钥 + 到期；联网周期复检；同指纹已过期拒重开  
4. 离线 grace（如 24h–7d）避免断网误锁；时钟回退检测  
5. 登录后与账号试用取 **earliest**（PR4）

**不作为最终方案**：仅多锚点本地存储（Keychain + 隐藏文件）——挡普通人，挡不住清干净/VM。  
**不默认采用**：iCloud `CKRecord` userRecordID（需 Apple ID，与「无 VoxStudio 登录」不完全同构，可作后续增强）。

关闭路径：将「匿名签名试用 token + 服务端 fingerprint 登记」前移为 **PR1.1**，或并入 **PR3** 且在此之前不开启生产 `VoxStudioPaidAccessEnabled` 依赖本地试用防滥用。

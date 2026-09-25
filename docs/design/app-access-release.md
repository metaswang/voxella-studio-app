# Mac DMG 购买与发布

2026-09-12 确认：Mac 仅分发 Developer ID DMG，不发布 TestFlight 或 Mac App Store。iOS 是独立的 TestFlight 发布。

## 发布路径

DMG 通过浏览器打开现有 Stripe Checkout 与 billing portal。正式构建使用 `BundledSpeech`，不启用 `MacAppStore` trait，不使用 `--mas`。运行时不再嵌入 Sparkle 安装器；appcast 仍用于检查版本并提供下载链接。本次无需 Mac App Store 商品。Developer ID 签名需要授权钥匙串 access group 的 provisioning profile。

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

### B1 — 未登录试用可被本地重置（Critical）→ **已定 Solution**
当前 `DeviceTrialClock` 仅 Keychain 存明文 `startedAt`，无服务端登记。删除 Keychain / 重装 / 新用户目录后会 `ensureStarted()` 重开 14 天。

**B1 实现方案（已定 = PR1.1）：匿名设备试用 = 签名 license**

适用：无 VoxStudio 登录也可试用，且允许联网校验。

| 步骤 | 行为 |
| --- | --- |
| 指纹 | 客户端取 `IOPlatformUUID`，本地算 `device_fingerprint = HMAC-SHA256(uuid, app_pepper)`，**只上传哈希** |
| 登记 | 首次受控功能且可联网时 `POST /api/v1/app-access/device-trial`（无需 user JWT）；body: `{ fingerprint, client_started_at? }` |
| 签发 | 服务端对指纹 `UPSERT`：新指纹写入 `trial_started_at`；已存在则返回原开始时间。签发 **Ed25519 JWT（EdDSA）**：`{ typ: device_trial, fp, started_at, ends_at=started+14d, iat, jti }` |
| 本地 | Keychain `ThisDeviceOnly` 存签名 token（取代明文 `startedAt` 作为权威）；平时门禁只验本地公钥 + `ends_at` + 时钟不早于 `started_at`/`iat` |
| 复检 | **不要每次启动、不要每次 `prepareNewContentAccess`。** 仅当距上次成功校验 **≥24h**（对照登录态 `AppAccessRefreshSchedule` 的 6h）或 **token 将过期前 24h** 才 `POST .../device-trial/verify`。首次受控功能可联网时登记一次 `POST /device-trial`。同指纹已过期 → 拒绝重开 |
| 离线 | 上次成功校验后 grace **7d**（`lastVerifiedAt + 7d`，且不超过 `ends_at`）；超 grace 且无网 → `verificationRequired`，不重开试用 |
| 登录合并 | PR4：账号 `trial_started_at` 与设备 token 取 **earliest**；换机同账号继承剩余天数 |

明确不做：仅靠多锚点本地文件/Keychain 当最终防滥用；不默认绑 iCloud `CKRecord`（可作后续增强）。

**B1 验收关闭条件**：清 Keychain 后再次联网仍拿到同一 `ends_at`；篡改 token 验签失败；过期指纹不能新开 14 天。实现归属 **PR1.1**（优先于把试用防滥用押在生产门禁上）。

**PR1.1 调度（已实现）**

- 首次受控功能且可联网：`POST /api/v1/app-access/device-trial` 一次（无需 user JWT）。
- 之后平时门禁只验 Keychain 签名 token；`configure()` / 启动不打 verify。
- `POST /device-trial/verify` 仅当 `lastVerifiedAt` 已满 24h，或 `now + 24h >= ends_at`。失败重试间隔 5 分钟，避免连点 `prepareNewContentAccess` 打爆接口。
- 离线 grace = 7 天；超 grace 无网 → `verificationRequired`。
- 清 Keychain 后再联网走登记 UPSERT，服务端返回原 `trial_started_at`，因此 `ends_at` 不变。

### B2 — Lifetime stub 曾可伪造（Critical，已收紧）
原 stub 对任意非空 Keychain blob 返回 true。PR1 已改为 **`isPresent()` 恒为 false**：拒绝未签名/未校验凭证，直至 PR2 落地真实签名校验后再按 verified credential 返回 true。

### B2 关闭（PR2）— DMG Lifetime 设备凭证

DMG 购买结账需登录；服务端确认 Lifetime 后签发 **Ed25519 JWT**，claims：`{ typ: lifetime_device, uid, fp, iat, jti }`（与 device-trial 共用 `MAC_ACCESS_DEVICE_TRIAL_PRIVATE_KEY`，`kid=lifetime-device-v1`）。MAS 构建只通过 StoreKit 购买 Lifetime，不使用此设备凭证。

| 步骤 | 行为 |
| --- | --- |
| 购买 | DMG Lifetime checkout 要求已登录（绑定账户） |
| 签发 | `POST /api/v1/app-access/lifetime-device`（需 user JWT）；body `{ fingerprint }`；校验 `mac_app_purchases` Lifetime 未撤销后 UPSERT `mac_lifetime_devices(user_id, fingerprint)` 并签发 token |
| 本地 | Keychain `voxstudio.app-access.lifetime-credential`（`ThisDeviceOnly`，**独立于** `AppAccessCache`）；登出不得删除 |
| 门禁 | `LifetimeLocalCredential.isPresent()` = 验签 + fingerprint 匹配后为 true；未登录可用本地功能 |
| 复检 | 登录态下 ≥24h 调 `POST .../lifetime-device/verify`；失败保留已验签本地凭证（PR3 可加强吊销） |

**验收**：购买后 Keychain 有签名 token；登出后本地功能仍可用；篡改 token 验签失败；未购买账户签发返回 403。

### B2 续（PR3）— 未登录 Lifetime lease 续期（默认 14d，env 可配）

购买后签发的 Lifetime JWT 含 `exp`（租期由 `MAC_ACCESS_LIFETIME_LEASE_DAYS` 控制，默认 14 天；试用为 `MAC_ACCESS_TRIAL_DAYS`，默认 14）。客户端可在**未登录**时用本地 license token 续租：

| 步骤 | 行为 |
| --- | --- |
| 签发 | `POST /lifetime-device`（需登录）返回 token + `lease_ends_at`（默认 ≤14d） |
| 未登录续期 | `POST /api/v1/app-access/lifetime/verify`（**无需 user JWT**）；body `{ token }`；验签后确认购买与设备行未撤销，再签发新 lease（默认 ≤14d） |
| 本地 | Keychain 存新 token；门禁要求 `now < exp`；登出不删除 |
| 复检 | 距上次成功校验 ≥24h，或 `now + 24h >= exp` 时续期；失败保留未过期本地凭证 |

**验收**：登出后联网可续期；退款/撤销后续期 403；篡改 token 失败；租期不超过配置天数（默认 14）。客户端以 token `exp` / `lease_ends_at` 为准，不硬编码 30。

### PR4 — 登录合并试用 earliest

登录 / 账户刷新时 `POST /trial` 携带本地 device-trial `started_at`（或 token）。服务端与账户 `trial_started_at` 取 **earliest**；换机同账号继承剩余天数，不重开 14 天。

### PR5 — 退款吊销 + 多设备上限

- 退款/拒付 webhook：`mac_app_purchases.revoked` 且 `mac_lifetime_devices.revoked=true`（billing worker）。
- 默认最多 **3** 台（`MAC_ACCESS_LIFETIME_MAX_DEVICES`）；签发新设备时踢掉 `last_verified_at` 最旧的一台；账户页可 `POST /lifetime-device/deactivate`。
- 客户端续期收到 403 时清除本地 Lifetime Keychain。

## 当前实现核对：未登录试用显示与匿名设备登记（2026-09-17）

### 产品行为

- 下载、启动 App，或仅停留在未登录状态时，**不会开始试用，也不会显示剩余试用天数**。
- 第一次触发受保护的本地功能（例如创建项目、录音、转写或生成）时，`prepareNewContentAccess()` 才启动设备试用流程。
- 试用期间不要求登录；侧边栏、账户弹窗和账户设置显示倒计时，并每 60 秒刷新一次。
- 剩余时间按向上取整显示：剩余至少 24 小时显示天数，少于 24 小时显示小时数，少于 1 小时显示 `Less than 1 hour left`。剩余 72 小时以内使用警告颜色。
- Lifetime 或有效订阅优先于试用，不显示试用倒计时。
- 试用结束后不再显示活动倒计时；创建新内容被阻止，但已有项目仍可打开、编辑和导出，并在受保护操作触发时提示升级。

### 从未登录用户的通信流程

App 启动时，`AccountService.configure()` 只恢复登录状态和本地授权覆盖层；未登录用户不会因此调用设备试用登记接口。

第一次受保护操作的 DMG 流程如下：

```text
prepareNewContentAccess()
  └─ ensureDeviceTrialStarted()
       └─ POST /api/v1/app-access/device-trial   （无需 user JWT）
```

请求 body 为：

```json
{
  "fingerprint": "64 位十六进制字符串",
  "client_started_at": "可选的客户端最早开始时间"
}
```

`fingerprint` 由 `IOPlatformUUID` 使用内置 pepper 做 HMAC-SHA256 得到；原始 IOPlatformUUID 不上传。服务端在 `mac_device_trials` 中以 fingerprint 为主键 UPSERT：新设备记录开始时间，已登记设备保留最早的开始时间，并返回 Ed25519 签名的 device-trial token。客户端验证签名和 fingerprint 后，将 token 存入 `ThisDeviceOnly` Keychain，token 的 `ends_at` 是本机试用倒计时的权威。

因此，用户始终不登录时：

- 不调用 `/api/v1/users/me`、`/api/v1/billing/plans`、`/api/v1/billing/balance` 作为试用登记的一部分；
- 不调用需要登录的 `/api/v1/app-access/trial`；
- 只会在首次受保护操作及后续必要复检时调用匿名 device-trial 接口。

如果首次使用时无网络，客户端当前会保存一个 provisional 本地 14 天时钟；网络恢复后，在下一次受保护操作时使用原始开始时间尝试登记，不会通过登记重新获得完整 14 天。

### 调用时机与频率

| 接口 | 当前调用时机 | 客户端频率控制 |
| --- | --- | --- |
| `POST /device-trial` | 首次受保护操作；或 provisional 记录需要升级为签名 token 时 | 不在启动时调用；正常成功后不重复登记 |
| `POST /device-trial/verify` | 上次成功验证已满 24 小时、距离 `ends_at` 不足 24 小时，或已超过离线 grace 时 | 失败重试间隔 5 分钟；不在启动时调用 |
| `POST /trial` | 登录或账户刷新时，把设备试用合并到用户账户 | 未登录用户不会调用 |
| 登录态账户刷新 | App 激活时按 6 小时计划刷新；只适用于已登录用户 | `AppAccessRefreshSchedule` 控制 |

服务端还配置了匿名接口限流：device-trial 登记为 10 次/分钟、50 次/小时；verify 为 20 次/分钟、100 次/小时。

### 当前实现与原设计的差异

原设计写明“离线 grace 超过 7 天且无法验证时返回 `verificationRequired`”。但当前实现和测试采用的是软 grace：超过 7 天后仍允许本地使用，只是在下一次受保护操作时尝试验证；只有 token 的绝对 `ends_at` 到期才阻止本地创建内容。

此外，provisional 登记失败时，当前实现没有复用 5 分钟的失败重试保护；连续触发受保护操作可能重复请求 `/device-trial`，目前主要依靠服务端限流兜底。若产品要求严格按设计文档执行，需要统一 grace 策略，并为 provisional 登记失败增加客户端退避。

# Mac License Key — 设备绑定（fingerprint）模型

日期：2026-09-20  
范围：`voxella-api` + `voxella-admin-web` + `voxella-studio-app`  
状态：取代「兑码必须登录 → mac_app_purchases」的账号兑码模型

---

## 1. 目标

1. **验证 license key 可不登录**：按本机 `fingerprint` 绑定；登录可选，仅用于把 fingerprint（及 key）与账号关联。  
2. **一 key 多设备**：默认最多 **5** 台（`MAC_ACCESS_LICENSE_KEY_MAX_DEVICES`，校验时读配置；单 key 可覆盖）。  
3. **用户自助管理设备**：App 内查看已绑定设备、解绑释放配额，方便新设备激活。

非目标：离线免网首次激活；把 license key 当可转让二手市场；MAS 内购替代（MAS 仍走 App Store）。

---

## 2. 与试用 / 购买 Lifetime 的关系

| 路径 | 识别 | 登录 | 凭证 |
|------|------|------|------|
| 14d 试用 | fingerprint → `device_trial` JWT | 不需要 | `DeviceTrialClock` |
| Stripe/App Store Lifetime | 账号 purchase → `lifetime_device` JWT | 购买要登录 | `LifetimeLocalCredential` |
| **License key（本设计）** | key + fingerprint → `license_key_device` JWT | **激活不需要**；登录只关联 | 独立 Keychain（可与 Lifetime 门闸同等放行） |

`access` 优先级：有效 Lifetime **或** 有效 license-key 设备凭证 > 试用 > none。

---

## 3. 数据模型

### 3.1 `mac_license_keys`（演进）

保留生成/吊销；`status`：`unused` | `active` | `revoked`  
（首次成功绑设备 → `active`；admin revoke → `revoked` 并解绑全部设备）

新增列：

- `max_devices int NULL` — 空则用全局配置默认 5  
- `owner_user_id uuid NULL` — 可选；用户登录后「关联到我的账号」时写入  

不再要求兑码写 `mac_app_purchases`（购买 Lifetime 仍走原表）。若需运营统计，可另记事件，不挡激活。

### 3.2 `mac_license_key_devices`（新）

```sql
CREATE TABLE mac_license_key_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  license_key_id uuid NOT NULL REFERENCES mac_license_keys(id),
  fingerprint text NOT NULL,          -- 64 hex
  device_label text,                 -- 客户端可选展示名
  linked_user_id uuid REFERENCES users(id),  -- 绑定时若已登录
  bound_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  unbound_at timestamptz,            -- 非空 = 已解绑，不占配额
  UNIQUE (license_key_id, fingerprint)
);
CREATE INDEX mac_license_key_devices_active_idx
  ON mac_license_key_devices (license_key_id) WHERE unbound_at IS NULL;
```

活跃设备数 = `unbound_at IS NULL` 的行数；须 `< max_devices`（或全局默认）才允许新 fingerprint 绑定。

---

## 4. API

配置：`MAC_ACCESS_LICENSE_KEY_MAX_DEVICES`（默认 5）。

### 4.1 激活（**无需** Bearer）

`POST /api/v1/app-access/license-keys/activate`  
Body: `{ key, fingerprint, device_label? }`  
可选 Bearer：若带登录态，写入 `linked_user_id`（及可设 `owner_user_id`）。

行为：

1. normalize + hash 查 key；revoked → 4xx；env 不匹配 → 4xx  
2. 若该 fingerprint 已绑定且未解绑 → 幂等续签 JWT  
3. 否则检查活跃设备数 < 上限 → INSERT 绑定  
4. 签发 `license_key_device` JWT（lease 可用 `MAC_ACCESS_LIFETIME_LEASE_DAYS`）  
5. key `unused` → `active`

响应：`{ token, fingerprint, license_key_id, lease_ends_at, max_devices, devices_used, devices: [...] }`

### 4.2 续期（无需登录，凭设备 token）

`POST /api/v1/app-access/license-keys/verify`  
Body: `{ token }` 或 `{ token, fingerprint }`  
校验 JWT + 行仍绑定且 key 未吊销 → 续签。

### 4.3 列出设备

`GET /api/v1/app-access/license-keys/devices`  
鉴权之一：

- `Authorization: Bearer <user>` 且为 `owner_user_id` / 任一 `linked_user_id`，或  
- Header/body 带激活时下发的 device token（claims 含 `lkid`）

返回：fingerprint（可脱敏中间）、device_label、bound_at、last_seen_at、is_current、linked_user_email?

### 4.4 解绑

`POST /api/v1/app-access/license-keys/devices/unbind`  
Body: `{ fingerprint }` + 同上鉴权  
将对应行 `unbound_at=now()`；该设备 token 后续 verify 失败。

### 4.5 关联账号（可选）

`POST /api/v1/app-access/license-keys/link-account`（需登录）  
Body: `{ token }` 或 `{ key, fingerprint }`  
设置 `linked_user_id` / `owner_user_id`。

### 4.6 Admin（保持）

generate / list / revoke；revoke 时解绑全部设备。list 可展示 `devices_used / max_devices`。

---

## 5. Studio

1. **Activate License…**（非 MAS）：始终可输入 key；**不要求先登录**。提交时带本机 fingerprint；成功则存 `license_key_device` 凭证并刷新门闸为 Lifetime 等价。  
2. 若用户之后登录：可调 `link-account`（静默或设置里「关联到当前账号」）。  
3. **设置 → License / Account**：设备列表（当前机标注）、解绑（确认后释放配额）。  
4. 门闸：有效 license-key 设备凭证与购买 Lifetime 同等放行；与试用并行，优先级高于试用。

---

## 6. 验收

1. 未登录：Activate 成功 → 本机 Lifetime 能力；Keychain 有 license-key 设备证。  
2. 同 key 第 2…N 台（N=配置）可激活；第 N+1 台失败并提示解绑。  
3. 设置中可见设备列表；解绑一台后新机可激活。  
4. 登录后 link：设备行带 `linked_user_id`；换账号登录不自动丢设备证（仍以 fingerprint+token 为准）。  
5. Admin revoke key → 所有设备 verify 失败。

---

## 7. 实现顺序

1. API migration + activate/verify/list/unbind/link + 配置项  
2. Studio：activate 无登录 + 凭证存储 + 门闸  
3. Studio：设备管理 UI  
4. Admin：列表展示占用数（可选）

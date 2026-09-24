# PR25 非 MAS 增量更新测试

## 目标

验证 PR25 合并后的 Developer ID/非 MAS 构建可通过 Sparkle 2 安装增量更新；全量 DMG 仍能作为回退。测试使用隔离的本地 appcast 和临时签名密钥，不向生产 R2 上传或改写发布内容。

## 用例

| ID | 场景与步骤 | 通过标准 | 优先级 |
| --- | --- | --- | --- |
| BUILD-01 | 构建 `debug --sign`，检查 app 签名、`Sparkle.framework`、Mach-O 链接、`SUFeedURL` 和 `SUPublicEDKey`；构建配置切到 MAS 时检查 Sparkle 被排除。 | 非 MAS app 可启动且配置完整；MAS 产物不含 Sparkle、不含 Sparkle feed 配置。 | P0 |
| DELTA-01 | 以 build N 和 N+1 的同 Team 签名 app 生成 appcast；检查 N→N+1 delta、签名和完整 DMG enclosure。 | delta 的 `sparkle:deltaFrom` 精确指向 N；delta 与 DMG EdDSA 签名可验证；delta URL 使用 `/downloads/voxstudio/releases/.../deltas/`；完整 DMG 仍在 feed 中。 | P0 |
| UPDATE-01 | 启动 N，点“检查更新”，下载并安装 N+1，等待 Sparkle 重启。 | 出现正确版本提示；delta 被选中且下载量小于 DMG；安装后 app 自动重启，bundle build/version 为 N+1，签名仍有效，主要功能可打开。 | P0 |
| UPDATE-02 | 再次检查已经是最新版本的 N+1。 | 显示“已是最新版本”，不下载或替换 app。 | P1 |
| FALLBACK-01 | 用没有对应 delta 的旧 build 检查同一 feed。 | Sparkle 选择全量 DMG，更新仍可完成。 | P1 |
| FALLBACK-02 | 测试 feed 中提供不可应用或签名错误的 delta，同时保留有效 DMG。 | 不安装损坏内容；若 Sparkle 执行全量回退，则安装后验签通过；否则明确提示失败且旧 app 保持可启动。 | P1 |
| SECURITY-01 | 用错误 EdDSA 签名替换 delta 或 DMG 后检查更新。 | Sparkle 拒绝未通过签名验证的内容，不替换已安装版本。 | P0 |
| NETWORK-01 | 离线、HTTP 错误、格式错误的 appcast 各检查一次。 | UI 给出失败状态且可重试；当前 app 保持可启动。 | P1 |
| COMPAT-01 | 设置高于当前 macOS 的 `sparkle:minimumSystemVersion`。 | 不安装不兼容版本，并显示兼容性说明。 | P1 |
| CANCEL-01 | 在下载阶段取消更新。 | 取消后继续运行旧版本；再次检查仍可更新。 | P2 |
| MAS-01 | 检查 MAS 构建的二进制、资源与主菜单。 | 不链接或嵌入 Sparkle，不含 `SU*` feed/key 配置，也不显示“检查更新”；更新交由 App Store。 | P0 |

## 执行记录

执行环境：macOS 26.6.1、Apple Silicon M5、Sparkle 2.9.2。测试 feed 与 EdDSA 密钥均为本机临时资源；生产 appcast 只读检查，没有向生产发布。

| 用例 | 结果 | 证据/说明 |
| --- | --- | --- |
| BUILD-01（非 MAS） | 通过 | `debug --sign` 构建成功；app 内含并链接 Sparkle.framework，签名校验通过。MAS 产物检查未执行。 |
| DELTA-01 | 通过 | build 105→106 生成本地 appcast；delta `deltaFrom=105`，并保留完整 DMG enclosure。EdDSA 签名校验通过。另有发布 URL 单测覆盖 `/downloads/voxstudio/releases/.../deltas/`。 |
| UPDATE-01 | 通过 | 从 7.0.24/build 105 在 app 菜单检查更新，Sparkle 显示 7.0.25；下载并应用 36,582 字节 delta，然后重启到 build 106。本地 HTTP 日志只有 appcast 和 delta 请求，没有 DMG 请求；DMG 为 121,625,447 字节。重启后首页可见，`codesign --verify --deep --strict` 通过。 |
| 其余用例 | 未执行 | UPDATE-02、全量回退、坏签名、断网/坏 feed、系统版本兼容、取消更新和 MAS 产物仍需按上表执行。 |

验证命令：`python3 Tests/R2ReleaseTests.py`（18 项通过）；`swift test --disable-sandbox --filter AppUpdaterTests`（9 项通过）。打包时修复了 `scripts/bundle.sh` 中 `awk exit` 提前关闭 `otool` 管道、触发 `pipefail` 的问题。

# VoxStudio 核心插件发布（0.3.0）

当前包仅含 `voxstudio` 核心插件，连接 `/chatgpt/mcp`，技能白名单为 onboarding、knowledge-qa、session-retrieval、media-workflow。文档编辑与视频编辑技能位于 NativeMCP/skills，不进入核心 ZIP；普通 `voxstudio_native` 使用独立配置。

打包器使用明确文件白名单，生成可重现 ZIP、FILES.sha256 和不可变 R2 对象路径。App 内置 ZIP 与 R2 发布包使用相同字节。安装器在修改客户端配置前验证新 App 端点；普通 MCP 可通过 `--native-only` 独立配置。

```sh
uv run --no-project python scripts/build-openai-plugin.py
uv run --no-project python scripts/package-openai-plugin.py
```

回归在本地 Docker 中执行；macOS App 编译和签名在 Mac 完成。远程发布、R2 上传及服务更新从 myvps2 执行。API 代码使用卷挂载，代码变更只需同步和重启，不重建镜像。

固定[下载入口](https://assets.voxstudio.me/downloads/voxstudio/plugins/voxstudio/VoxStudio-OpenAI-Plugin.zip)通过无缓存 302 指向已验证的不可变 ZIP。发布只条件更新 latest.json，不覆盖历史 ZIP；推广前检查 R2 字节、SHA-256、元数据和 CDN 下载结果。Cloud 插件另行打包、发布和管理，安装器不再重复注册同名普通 Cloud MCP。

验收分别记录核心模型工具数、紧凑 JSON 字节数、包含 App-only 的目录容量、实际宿主可见性、核心/普通/Cloud 的调用归属及旧端点兼容性。目录和 HTTP 验证不能代替真实宿主 UI 验收；未验证的项保持明确记录。

历史 0.2.x 发布记录保留在 docs/testing/unified-plugin-release-2026-10-05/，历史包继续作为回滚资产。

# 回归报告模板

复制到`docs/test/voxstudio-feature-regression-YYYY-MM-DD-HHMM.md`并填写实际数据。占位值、设计预期及旧记录不能作为本次实测结果。

```markdown
# VoxStudio 功能回归 — <时间>

## 范围与基线

- 模式：全量 / 指定feature / smoke
- 用户要求、排除项、选中case清单：
- 地图/测试集基线commit及dirty状态：
- target绝对路径、实际运行可执行路径、PID：
- version/build、渠道、authority、Team ID、DR、binary SHA-256：
- macOS/build、硬件、显示器、输入设备：
- 本地模型、BYOK/远程目的地与允许预算（不含secret）：
- 开始/结束时间、临时输出目录：
- 原有源码/文档变化：

## 权限准备

- 人工确认时间/摘要、Settings对应target的证据、enabled：
- 旧项删除/重新加入情况、mic/screen+audio/USB Trust：
- 系统dialog实际文字、工具可见性/错误与人工处理：
- 重启动作、target身份未变的证据：
- 各模式短录、文件metadata/播放证据：
- 待人工处理项：

## Fixtures

| Fixture | 绝对路径/派生方式 | SHA-256 | codec/时长/音视频参数 | 真值锚点 |
|---|---|---|---|---|

## 逐case结果

| Case ID | 状态 | 前置/fixture | 实际操作 | 实际结果 | 证据/输出 | Issue |
|---|---|---|---|---|---|---|
<!-- 每个选中ID一行；未执行写Not-run/Blocked/Skip，不省略。 -->
<!-- 多变体分开记录，全部满足后才能整行Pass。 -->

## Feature与模块汇总

| Feature/模块 | 选中 | Pass | Fail | Blocked | Skip | N/A | Not-run | 完整通过/未完成 |
|---|---:|---:|---:|---:|---:|---:|---:|---|

- 设计总数、本轮选中N：
- 执行覆盖率=(Pass+Fail)/N：
- 执行通过率=Pass/(Pass+Fail)：
- 范围调整及原因：

## 问题记录

| Issue ID | Case IDs | 严重度 | 最小复现 | 实际/预期 | 文件/日志/截图证据 | 一次重试及前置变化 |
|---|---|---|---|---|---|---|

## 收尾与剩余工作

- 恢复了哪些本轮偏好/临时配置：
- 权限/测试数据保留情况、输出路径：
- git状态与本轮文件变化：
- 未完成case与具体人工/硬件/服务依赖：
- 是否满足所请求覆盖、下次必须重测ID：
```

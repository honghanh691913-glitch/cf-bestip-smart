# Changelog

## 1.2.0

- NRT IPv4/IPv6 网段完全外置到 `ranges/NRT/ipv4.txt` 与 `ranges/NRT/ipv6.txt`。
- 不再要求把具体 NRT CIDR 写进 Python 或 `config.json`。
- 预留 `ranges/WEST/`，默认关闭美西池，避免空网段影响 NRT 测试。
- Compose 改为独立测试实例：`cf-bestip-smart-nrt-test`，避免与旧容器名冲突。
- GitHub 发布默认关闭，测试阶段不会覆盖旧仓库结果。
- 新增 `GITHUB_PUBLISH_ENABLED` 环境变量覆盖；支持 `GITHUB_OWNER/REPO/BRANCH` 环境变量覆盖。
- TXT 通过 bind mount 注入，后期修改网段无需重新 build。

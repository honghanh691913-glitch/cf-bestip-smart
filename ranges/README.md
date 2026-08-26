# ranges

候选网段是 **file-only**，不会回退到 Cloudflare 官方全集。

目录：

- `NRT/ipv4.txt`
- `NRT/ipv6.txt`
- `WEST/ipv4.txt`
- `WEST/ipv6.txt`

每行一个 CIDR，可用 `#` 写注释。

推荐工作方式：

1. 在 GitHub 仓库维护四个 TXT。
2. Compose 的 `RANGE_SYNC_MODE=github` 时，每次“重新部署/重新构建”会把仓库 TXT 同步到宿主机。
3. `config.json` 不会被重新部署覆盖，方便直接在 NAS 文件管理器修改。
4. TXT 不存在或为空时直接报错；绝不自动扫描官方全集。

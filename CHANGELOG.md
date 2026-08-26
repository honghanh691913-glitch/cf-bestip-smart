# Changelog

## 1.3.0

- 候选来源锁定为 `file_only`。
- NRT / WEST IPv4 / IPv6 全部只读取仓库 TXT。
- 删除配置层面的官方全集回退入口。
- TXT 缺失/为空直接失败，禁止隐藏全网段扫描。
- Compose 新增 bootstrap：首次自动生成宿主机 config。
- GitHub ranges 默认在每次重新部署时同步到宿主机。
- config.json 始终保留宿主机版本，便于 NAS 文件管理器修改。
- 固定部署路径 `/vol1/1000/Docker/samrt-ip`。
- healthcheck 改为校验所有启用池。
- 保留 NRT Colo 精确过滤与美西 Colo 组过滤。

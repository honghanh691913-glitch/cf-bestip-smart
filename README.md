# cf-bestip-smart v1.3.0

面向 NRT / 美西的 Cloudflare BestIP 定向优选器。核心原则：**只扫你维护的区域 TXT，不扫描 Cloudflare 官方全集。**

## 1. 最终数据流

```text
GitHub 仓库
├─ ranges/NRT/ipv4.txt
├─ ranges/NRT/ipv6.txt
├─ ranges/WEST/ipv4.txt
└─ ranges/WEST/ipv6.txt
        │
        │ 重新部署 / Rebuild
        ▼
Docker build 拉取 GitHub 最新代码与 TXT
        │
        ▼
bootstrap
├─ config.json：宿主机不存在/为空时才初始化
└─ ranges：默认每次以 GitHub TXT 覆盖同步到宿主机
        │
        ▼
/vol1/1000/Docker/samrt-ip/
├─ config.json
├─ ranges/
│  ├─ NRT/{ipv4.txt,ipv6.txt}
│  └─ WEST/{ipv4.txt,ipv6.txt}
├─ generated/
└─ runtime/
        │
        ▼
bestip
├─ 只读取启用池的 TXT
├─ CIDR 分段随机探测
├─ HTTPing + Colo 过滤
├─ 候选池补齐
├─ 最终下载测速
└─ Top N 输出
```

## 2. 不再出现官方全集回退

`candidate_source` 固定为：

```json
"candidate_source": "file_only"
```

每个池的 IPv4 / IPv6 都必须：

```json
"source": "file"
```

如果 TXT 缺失、为空、地址族写错，会直接报错并停止本轮，不会自动去扫描 Cloudflare 全球官方网段。

## 3. NRT 与美西

### NRT

仓库维护：

```text
ranges/NRT/ipv4.txt
ranges/NRT/ipv6.txt
```

配置默认启用，最终 Colo 只接受 `NRT`。

### WEST

仓库维护：

```text
ranges/WEST/ipv4.txt
ranges/WEST/ipv6.txt
```

默认关闭。填好两个 TXT 后，把宿主机 `config.json` 中：

```json
"west": {
  "enabled": false
}
```

改成：

```json
"enabled": true
```

美西接受 `us_west` 组：

`LAX / SJC / SEA / PHX / LAS / PDX / DEN / SLC / SAN`

TXT 只负责缩小搜索范围，最终仍以 CFST 检测到的 Colo 做区域确认。

## 4. Compose 面板部署

已经提供 `compose.yaml` / `compose-panel.yaml`，路径固定为：

```text
/vol1/1000/Docker/samrt-ip
```

直接在 Docker 面板粘贴 Compose 部署即可，不需要 SSH。

第一次部署时 `bootstrap` 自动建立宿主机目录和 `config.json`。

### 修改什么，需要做什么？

| 修改 | 操作 |
|---|---|
| GitHub `ranges/*.txt` | 面板“重新部署/重新构建” |
| 宿主机 `config.json` | 只需重启 `cf-bestip-smart` |
| Compose | 重新部署 |
| Python / Dockerfile | 重新部署/重新构建 |

默认：

```yaml
RANGE_SYNC_MODE: "github"
```

因此 GitHub 中四个 ranges TXT 是候选网段的主数据源。

如果未来想改成“宿主机 ranges 为主”，把它改为：

```yaml
RANGE_SYNC_MODE: "preserve"
```

## 5. 默认测速流程

每个启用池、每个 IP 家族：

1. 读取对应 TXT；
2. 每个 CIDR 随机抽样；
3. 最多 3 轮入场探测；
4. 只保留延迟/丢包阈值内且 Colo 正确的地址；
5. 从活跃 CIDR 补充候选，默认目标 255；
6. 最终最多 200 个候选做下载测速；
7. 依据丢包、速度、延迟排序；
8. 默认发布 Top 5。

关键参数都在宿主机：

```text
/vol1/1000/Docker/samrt-ip/config.json
```

## 6. 输出

本地输出：

```text
/vol1/1000/Docker/samrt-ip/generated/
```

包含：

```text
output/apac/ipv4.txt
output/apac/ipv6.txt
output/west/ipv4.txt
output/west/ipv6.txt
output/all/best20.txt
status.json
```

`apac` 是历史兼容目录名，当前配置中实际代表 NRT。

运行状态：

```text
/vol1/1000/Docker/samrt-ip/runtime/
```

## 7. GitHub 结果发布

测试阶段 Compose 默认：

```yaml
GITHUB_PUBLISH_ENABLED: "false"
```

稳定后如需自动把 `generated` 结果原子提交到 GitHub，再开启并配置 Token。

## 8. 更新候选网段

以后不需要修改 Python。

只维护：

```text
ranges/NRT/ipv4.txt
ranges/NRT/ipv6.txt
ranges/WEST/ipv4.txt
ranges/WEST/ipv6.txt
```

然后重新部署即可。

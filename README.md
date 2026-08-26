# Cloudflare BestIP Orchestrator v1.0.0

这个项目不修改 Cloudflare-BestIP / CFST 测速核心，而是在 CFST 外面加一层 **分段抽样 → Colo 过滤 → 255 合格候选池 → 200 个最终下载测速 → Top 5 → GitHub 原子发布 → Worker 展示**。

## 默认目标

每 6 小时生成 4 个池：

- 亚太/NRT IPv4：Top 5
- 亚太/NRT IPv6：Top 5
- 美西 IPv4：Top 5
- 美西 IPv6：Top 5
- 合计 `output/all/best20.txt`：20 条

TXT 格式对 IPv6 使用 `[IPv6]:443#备注`，IPv4 使用 `IPv4:443#备注`，方便 CFnew / EdgeTunnel / 自定义订阅直接消费。

## 核心算法

### 1. 每个 CIDR 先做“分裂探测”

对每个 IPv4/IPv6 CIDR：

1. 随机 4 个地址。
2. 4 个都没有合格结果，再随机 4 个。
3. 最多 3 轮（共 12 个）。
4. 三轮都失败，这个 CIDR 本轮直接淘汰，不继续浪费时间。
5. 只要任意一轮出现合格 IP，该 CIDR 进入“活跃段”。

### 2. 从活跃段补齐 255 个可用候选

只从活跃段继续随机抽样。**Colo 不符合的 IP 即使连通也不计入 255**。

默认：

- `candidate_target = 255`
- 最终从其中延迟/丢包较好的前 `200` 个执行下载测速
- 每类取 Top `5`

IPv6 不枚举巨大地址空间，只随机抽样，因此不会因为 `/32`、`/48` 太大而爆内存。

### 3. Colo 分类

默认亚太池严格要求 `NRT`。

默认美西池只允许：

`LAX,SJC,SEA,PHX,LAS,PDX,DEN,SLC,SAN`

并额外排除整个 APAC 组：`NRT/KIX/HKG/ICN/TPE/SIN/...`。

这些全部可以在 `config.json` 修改。

> 注意：Cloudflare Anycast 的 Colo 是“从当前测速机器访问该 IP 时命中的 PoP”，不是 IP 永久属于某城市。如果你需要“本地到 NRT”和“凤凰城 VPS 到 LAX”两个真正独立的网络视角，最好在两个位置各跑一份。单台机器只能准确代表它自己的出口路径。

## CIDR 来源

`west` 默认实时读取 Cloudflare 官方 IPv4/IPv6 大段。

`apac` 默认 `custom_or_official`：

- 你在 `pools.apac.ipv4.cidrs` / `ipv6.cidrs` 填入自己已经确认的 NRT 段时，只跑这些段。
- 留空则回退 Cloudflare 官方大段，再通过 HTTPing Colo 筛 NRT。

示例：

```json
"apac": {
  "include_colos": ["NRT"],
  "ipv4": {
    "source": "custom",
    "cidrs": ["你的NRT-v4段1", "你的NRT-v4段2"]
  },
  "ipv6": {
    "source": "custom",
    "cidrs": ["你的NRT-v6段1", "你的NRT-v6段2"]
  }
}
```

## 安装

Linux：

```bash
unzip cf-bestip-orchestrator-v1.0.0.zip
cd cf-bestip-orchestrator-v1.0.0
sudo ./install.sh
```

`install.sh` 会从 XIU2/CloudflareSpeedTest 最新 Release 下载当前 CPU 架构的 `cfst`。

先自检：

```bash
python3 bestip_orchestrator.py --self-test
```

先不推 GitHub 测一遍：

```bash
python3 bestip_orchestrator.py --dry-run
```

本地结果在 `generated/`。

## GitHub 发布

建议新建一个**公开结果仓库**，例如：

`YOUR_GITHUB_USER/BestIP-Result`

创建 Fine-grained PAT，只授权这个仓库，Repository permissions 只给：

- Contents: Read and write

Token 不要写进 `config.json`。Linux systemd 默认读取：

```text
/etc/cf-bestip.env
```

内容：

```bash
GITHUB_TOKEN=github_pat_xxxxxxxxx
```

权限：

```bash
sudo chmod 600 /etc/cf-bestip.env
```

然后修改 `config.json`：

```json
"github": {
  "enabled": true,
  "owner": "你的GitHub用户名",
  "repo": "BestIP-Result",
  "branch": "main",
  "token_env": "GITHUB_TOKEN"
}
```

发布使用 GitHub Git Data API **一次提交所有文件并最后移动 branch ref**，不是逐个文件覆盖；只有四个池全部达到 Top 5 才发布。任一池不足，整轮终止，GitHub 保留上一版。

## 输出

```text
output/
├── apac/
│   ├── ipv4.txt
│   ├── ipv4.csv
│   ├── ipv4-pool.csv
│   ├── ipv6.txt
│   ├── ipv6.csv
│   └── ipv6-pool.csv
├── west/
│   ├── ipv4.txt
│   ├── ipv4.csv
│   ├── ipv4-pool.csv
│   ├── ipv6.txt
│   ├── ipv6.csv
│   └── ipv6-pool.csv
└── all/
    ├── best20.txt
    └── best20.csv
status.json
```

`*-pool.csv` 保存本轮最终测速的全部合格候选，Top 5 文件只放最终结果。

## 排序

默认不是“延迟最低优先”，而是：

1. 丢包更低
2. 下载速度更高
3. 延迟更低

这更适合代理/CDN实际使用，而不是只追求 ping 数字。

## Worker 页面

把 `worker.js` 部署到 Cloudflare Workers，然后配置变量：

- `GITHUB_OWNER`
- `GITHUB_REPO`
- `GITHUB_BRANCH`（可选，默认 `main`）

根页面自动显示四个表格：

- 亚太 IPv4
- 亚太 IPv6
- 美西 IPv4
- 美西 IPv6

另外提供：

```text
/health
/api/status
/raw/apac/ipv4
/raw/apac/ipv6
/raw/west/ipv4
/raw/west/ipv6
/raw/all/best20
```

其中 `/raw/...` 直接返回 TXT，后续也可以给 CFnew / EdgeTunnel 作为 URL 来源。

## 6 小时自动运行

`install.sh` 在 root + systemd 环境会安装：

```text
cf-bestip.service
cf-bestip.timer
```

时间：每天 `00:05 / 06:05 / 12:05 / 18:05`，并随机延迟最多 120 秒，避免每次整点集中请求。

查看：

```bash
systemctl status cf-bestip.timer
journalctl -u cf-bestip.service -n 200 --no-pager
```

手动跑：

```bash
sudo systemctl start cf-bestip.service
```

## 关于代理

默认清理 `HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY` 环境变量，避免 CFST 被 SOCKS5/全局代理污染测试结果。如果你明确需要让测速走代理，把：

```json
"clear_proxy_env": false
```

但这样测出来的是“代理出口到 Cloudflare”的结果，不再代表本机直连质量。

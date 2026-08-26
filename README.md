# cf-bestip-smart v1.2.0

Cloudflare IPv4/IPv6 BestIP 测速调度器。此版把目标网段完全外置到 TXT，Python 与 `config.json` 不再保存具体 NRT 网段内容。

## 这一版的目录

```text
cf-bestip-smart-v1.2.0-final/
├── compose.yaml
├── Dockerfile
├── config.json
├── .env.example
├── bestip_orchestrator.py
├── scheduler.py
├── healthcheck.py
├── install_cfst.py
├── worker.js
├── ranges/
│   ├── NRT/
│   │   ├── ipv4.txt
│   │   └── ipv6.txt
│   └── WEST/
│       ├── ipv4.txt
│       └── ipv6.txt
└── data/
    ├── generated/
    └── runtime/
```

## 你以后只需要改这里

当前默认只启用 NRT：

```text
ranges/NRT/ipv4.txt
ranges/NRT/ipv6.txt
```

一行一个 CIDR：

```text
# IPv4
203.0.113.0/24
```

```text
# IPv6
2001:db8::/32
```

空行和 `#` 注释会被忽略。

**网段内容不用写进 Python，也不用写进 config.json。** 后期换网段只修改两个 TXT。Compose 把整个 `ranges/` 以只读方式挂载到容器，因此修改本机 TXT 后无需重新 build，下一轮测速直接读取新内容。

> 如果 TXT 是通过 GitHub 仓库维护的，在 VPS 执行 `git pull` 后，新内容下一轮就会生效。

## NRT 筛选逻辑

默认启用池：

```text
apac/ipv4 -> 只接受 NRT
apac/ipv6 -> 只接受 NRT
```

程序从 TXT CIDR 中随机抽取地址，用 CloudflareSpeedTest 进行快速筛选和最终下载测速，并根据实际 HTTPing/测速得到的 Cloudflare Colo 判断是否进入 `NRT`。

注意：Cloudflare 是 Anycast。NRT 表示**当前测速 VPS 从自己的网络出口访问该地址时实际落到 NRT**，不是某个 IP 永久属于东京。

## 美西目录

已经预留：

```text
ranges/WEST/ipv4.txt
ranges/WEST/ipv6.txt
```

当前 `config.json` 中：

```json
"west": {
  "enabled": false
}
```

所以不会参与当前 NRT 测试。以后需要时，把美西网段放进这两个 TXT，再把 `west.enabled` 改为 `true` 即可。

## 与旧 BestIP 测试隔离

此包的 Compose 使用独立名称：

```text
Compose project: cf-bestip-smart-nrt-test
container:       cf-bestip-smart-nrt-test
image:           cf-bestip-smart:nrt-test-v1.2.0
```

并使用当前目录自己的：

```text
data/generated/
data/runtime/
```

因此不会复用旧容器的数据目录。

测试阶段 GitHub 自动发布**默认关闭**：

```env
GITHUB_PUBLISH_ENABLED=false
```

这样即使你启动新容器，也不会覆盖旧仓库中的稳定测速结果。

## 部署

### 1. 解压并进入目录

```bash
unzip cf-bestip-smart-v1.2.0-final.zip
cd cf-bestip-smart-v1.2.0-final
```

### 2. 填入 NRT 网段

编辑：

```bash
nano ranges/NRT/ipv4.txt
nano ranges/NRT/ipv6.txt
```

确保至少各有一个有效 CIDR；只有注释或空文件时，程序会拒绝启动测速，防止误用其他网段。

### 3. 准备环境变量

```bash
cp .env.example .env
```

测试阶段保持：

```env
GITHUB_PUBLISH_ENABLED=false
```

### 4. 如果旧容器正在测速，先停旧容器

如果旧项目也是 Compose 部署，在旧项目目录执行：

```bash
docker compose down
```

如果只想停止、不删除：

```bash
docker compose stop
```

旧配置、旧结果文件不会因为 stop 被删除。

### 5. 构建并启动新测试

```bash
docker compose -f compose.yaml build --pull
docker compose -f compose.yaml up -d
```

### 6. 看日志

```bash
docker compose -f compose.yaml logs -f bestip
```

第一次启动默认立即跑一轮：

```env
RUN_ON_START=true
```

之后默认：

```text
00:05
06:05
12:05
18:05
```

并加入最多 120 秒随机延迟。

## 手动立即跑一轮

```bash
docker compose -f compose.yaml exec bestip \
  python3 /app/bestip_orchestrator.py --config /app/config.json --run-now
```

## 查看本地结果

成功后看：

```text
data/generated/
```

运行状态：

```text
data/runtime/last-success.json
data/runtime/last-failure.json
```

## 稳定后开启 GitHub 发布

确认新测试稳定后，编辑 `.env`：

```env
GITHUB_PUBLISH_ENABLED=true
GITHUB_TOKEN=github_pat_xxxxxxxxx
GITHUB_OWNER=honghanh691913-glitch
GITHUB_REPO=cf-bestip-smart
GITHUB_BRANCH=main
```

然后：

```bash
docker compose -f compose.yaml up -d --force-recreate
```

也可以继续保持 `false`，只把它当纯测速容器。

## 当前关键参数

`config.json` 默认：

```text
目标有效候选：255
每段初探：4 个 IP
初探轮数：3
最终下载候选：200
最终 Top N：5
最大延迟：350 ms
最大丢包：20%
测速端口：443
```

## 更新 TXT 后是否需要重建镜像？

不需要。

因为 Compose 有：

```yaml
- ./ranges:/app/ranges:ro
```

所以只需修改 TXT；想立即测试就手动执行一次 `--run-now`。

## 安全说明

- `.env` 不要提交真实 GitHub Token。
- 默认清除代理环境变量，减少测速误走 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` 的概率。
- `network_mode: host` 是为了让 VPS 上的测速尽量代表宿主机真实出口。
- 如果宿主机本身有 TUN/透明代理/策略路由，仍可能影响测速，应在测试时注意。

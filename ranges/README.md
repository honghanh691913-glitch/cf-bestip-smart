# ranges

网段完全外置，不写死在 Python。

当前测试默认只启用 NRT：

- `NRT/ipv4.txt`
- `NRT/ipv6.txt`

规则：一行一个 CIDR；允许空行；`#` 开头为注释。

后期只修改 TXT。Docker Compose 通过只读 bind mount 挂载整个 `ranges/`，无需重新 build；下一轮测速会读取新内容。

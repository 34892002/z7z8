# z7z8

Linux 工具脚本集合。

## 脚本清单

| 脚本 | 功能 | 说明 |
|------|------|------|
| `getv4.sh` | WARP IPv4 出口管理 | 通过 wgcf 注册 Cloudflare WARP 账号，创建 WireGuard 隧道获取 IPv4 出口，支持 v4/v6 双栈及 v6-only 环境 |
| `test_ipv6.sh` | IPv6 连通性测试 | 逐个测试本机所有全局 IPv6 地址到目标主机的连通性，支持自定义目标和超时时间 |
| `start-socks5.sh` | SOCKS5 代理管理 | 基于 microsocks 的多实例 SOCKS5 代理管理，支持添加/删除/查看状态，通过 systemd 实现开机自启 |
| `3xui-cn-install.sh` | 3x-ui 面板安装（国内版） | 同步官方 `install.sh`，GitHub 下载地址改走 gh-proxy.com 代理并强制 IPv4 |

## 使用方式

```bash
# 克隆仓库
git clone https://github.com/34892002/z7z8.git
cd z7z8

# 添加执行权限
chmod +x *.sh

# 运行脚本（以 getv4.sh 为例）
sudo bash getv4.sh
```

## 环境要求

- Bash 4.0+
- root 权限（部分脚本需要）
- 依赖工具见各脚本内说明

## 3xui-cn-install.sh 安装 3x-ui

脚本基于官方 `install.sh`，所有 GitHub 下载地址（release 包、`x-ui.sh`、systemd unit 等）都已改为经 `gh-proxy.com` 代理并强制 IPv4，国内机器可直接安装。

一键安装（需 root，建议先 `sudo -i`）：

```bash
bash <(curl -4 -Ls https://gh-proxy.com/https://raw.githubusercontent.com/34892002/z7z8/main/3xui-cn-install.sh)
```

或先下载再执行（便于排查失败原因）：

```bash
curl -4 -fL -o /tmp/3xui-cn-install.sh \
  https://gh-proxy.com/https://raw.githubusercontent.com/34892002/z7z8/main/3xui-cn-install.sh
sudo bash /tmp/3xui-cn-install.sh
```

安装过程会交互询问数据库（SQLite / PostgreSQL）、面板端口和 SSL 方式（Let's Encrypt 域名或 IP 证书、自定义证书、跳过），结束后打印用户名、密码、端口、WebBasePath、访问地址与 API Token。

```bash
# 安装指定版本（也可传 dev 获取滚动构建）
sudo bash /tmp/3xui-cn-install.sh v3.11.0

# 非交互安装，全部选项由 XUI_* 环境变量决定
sudo XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none bash /tmp/3xui-cn-install.sh

# 安装完成后用 x-ui 管理（启动/停止/更新/日志/卸载）
x-ui
```

> 脚本用 `curl -4` 强制 IPv4，因为代理节点经常无法走 IPv6；纯 IPv6 机器请先去掉脚本中的 `-4`。

## start-socks5.sh 代理配置

脚本顶部 `PROXIES` 数组定义所有代理实例，格式 `"端口 出站IP"`：

```bash
PROXIES=(
    "3366 240d:1b:c8:e910:a:b409:e9c6:f097"
    "3367 240d:1b:c8:e910:a:b409:e9c6:f097"
)
```

添加新代理只需加一行，菜单自动识别。每个代理可绑定不同的出站 IP。

# z7z8

Linux 工具脚本集合。

## 脚本清单

| 脚本 | 功能 | 说明 |
|------|------|------|
| `getv4.sh` | WARP IPv4 出口管理 | 通过 wgcf 注册 Cloudflare WARP 账号，创建 WireGuard 隧道获取 IPv4 出口，支持 v4/v6 双栈及 v6-only 环境 |
| `test_ipv6.sh` | IPv6 连通性测试 | 逐个测试本机所有全局 IPv6 地址到目标主机的连通性，支持自定义目标和超时时间 |

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

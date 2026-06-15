#!/usr/bin/env bash
#
# WARP IPv4 出口管理脚本
# 通过 wgcf 注册 Cloudflare WARP 账号，创建 WireGuard 隧道获取 IPv4 出口
# 支持 v4/v6 双栈及 v6-only 环境（自动通过 GitHub IPv6 代理下载 wgcf）
#
# 功能: 注册/删除 WARP 账号、添加/删除 warp-ipv4 接口、查看状态
#
set -Eeuo pipefail

IFACE="warp-ipv4"
CONF="/etc/wireguard/${IFACE}.conf"
WORKDIR="/etc/wireguard/${IFACE}-work"
WGCF_BIN="/usr/local/bin/wgcf"

# wgcf 下载地址（更换仓库只改这两行）
WGCF_API_URL="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
WGCF_WEB_URL="https://github.com/ViRb3/wgcf/releases/latest"

# GitHub IPv6 代理（修改 /etc/hosts 实现）
# https://danwin1210.de/github-ipv6-proxy.php
# 脚本使用到的github部分，只改这两行即可
GITHUB_PROXY_IP="2a01:4f8:c010:d56::2"
GITHUB_API_PROXY_IP="2a01:4f8:c010:d56::3"

BACKUP_CONF=""

log()  { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die()  { warn "$*"; exit 1; }

# ── /etc/hosts 代理管理 ───────────────────────────────────

HOSTS_PATCHED=false
HOSTS_BACKUP=""

apply_hosts_proxy() {
  HOSTS_BACKUP="/etc/hosts.bak.$(date +%s%N)"
  cp -f /etc/hosts "$HOSTS_BACKUP"
  sed -i '/github\.com$/d' /etc/hosts
  echo "$GITHUB_PROXY_IP github.com" >> /etc/hosts
  echo "$GITHUB_API_PROXY_IP api.github.com" >> /etc/hosts
  HOSTS_PATCHED=true
  log "已临时写入 /etc/hosts GitHub 代理（原文件已备份）"
}

restore_hosts() {
  if [ "$HOSTS_PATCHED" = true ] && [ -n "$HOSTS_BACKUP" ] && [ -f "$HOSTS_BACKUP" ]; then
    cp -f "$HOSTS_BACKUP" /etc/hosts
    rm -f "$HOSTS_BACKUP"
    HOSTS_PATCHED=false
    log "已还原 /etc/hosts"
  fi
}

cleanup_hosts() {
  restore_hosts
}

# ── 基础检查 ──────────────────────────────────────────────

need_root() {
  [ "$EUID" -eq 0 ] || die "请用 root 运行"
}

is_v6only() {
  ! ip -4 addr show | grep -q 'inet .* scope global'
}

ensure_deps() {
  local need_pkgs=()

  command -v curl >/dev/null 2>&1 || need_pkgs+=(curl)
  command -v jq >/dev/null 2>&1 || need_pkgs+=(jq)
  command -v wg-quick >/dev/null 2>&1 || need_pkgs+=(wireguard-tools)
  command -v ip >/dev/null 2>&1 || need_pkgs+=(iproute2)

  if [ "${#need_pkgs[@]}" -gt 0 ]; then
    log "安装依赖: ${need_pkgs[*]}"
    apt-get update
    apt-get install -y "${need_pkgs[@]}"
  fi
}

# ── wgcf 管理 ─────────────────────────────────────────────

ensure_wgcf() {
  # 1. 本地预放的二进制（v6-only 环境的主要方式）
  if [ -x /root/wgcf ]; then
    log "发现本地 /root/wgcf，优先使用"
    install -m 755 /root/wgcf "$WGCF_BIN"
    return 0
  fi

  # 2. 系统 PATH 中已有
  if command -v wgcf >/dev/null 2>&1; then
    WGCF_BIN="$(command -v wgcf)"
    log "系统中已存在 wgcf: $WGCF_BIN"
    return 0
  fi

  # 3. v6-only 环境，通过 GitHub 代理下载
  if is_v6only; then
    local arch pat url
    arch="$(uname -m)"

    case "$arch" in
      x86_64|amd64)  pat='linux_amd64$' ;;
      aarch64|arm64) pat='linux_arm64$' ;;
      armv7l)        pat='linux_armv7$' ;;
      *)             die "不支持的架构: $arch" ;;
    esac

    log "当前为 IPv6-only 环境，通过 GitHub 代理下载 wgcf"
    trap cleanup_hosts EXIT
    apply_hosts_proxy

    url="$(
      curl -fsSL "$WGCF_API_URL" \
      | jq -r --arg pat "$pat" '.assets[] | select(.name|test($pat)) | .browser_download_url' \
      | head -n 1
    )"

    if [ -n "${url:-}" ] && [ "$url" != "null" ]; then
      curl -fsSL "$url" -o "$WGCF_BIN"
      chmod +x "$WGCF_BIN"
      restore_hosts
      trap - EXIT
      log "wgcf 已通过代理下载到 $WGCF_BIN"
      return 0
    fi

    restore_hosts
    trap - EXIT
    warn "代理下载失败，请手动下载:"
    warn "  $WGCF_WEB_URL"
    warn "下载后 scp 到本机 $WGCF_BIN，然后重新运行本脚本"
    die "缺少 wgcf 二进制"
  fi

  # 4. 有 IPv4 环境，直接在线下载
  log "本地没有 wgcf，开始在线下载"
  local arch pat url
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64)  pat='linux_amd64$' ;;
    aarch64|arm64) pat='linux_arm64$' ;;
    armv7l)        pat='linux_armv7$' ;;
    *)
      die "不支持的架构: $arch"
      ;;
  esac

  url="$(
    curl -fsSL "$WGCF_API_URL" \
    | jq -r --arg pat "$pat" '.assets[] | select(.name|test($pat)) | .browser_download_url' \
    | head -n 1
  )"

  [ -n "${url:-}" ] && [ "$url" != "null" ] || die "没有找到适合当前架构的 wgcf 下载地址"

  curl -fsSL "$url" -o "$WGCF_BIN"
  chmod +x "$WGCF_BIN"
  log "wgcf 已下载到 $WGCF_BIN"
}

# ── 备份与回滚 ────────────────────────────────────────────

backup_existing_conf() {
  if [ -f "$CONF" ]; then
    BACKUP_CONF="${CONF}.bak.$(date +%F_%H%M%S)"
    cp -f "$CONF" "$BACKUP_CONF"
    log "已备份旧配置: $BACKUP_CONF"
  fi
}

cleanup_iface() {
  systemctl disable --now "wg-quick@${IFACE}" >/dev/null 2>&1 || true
  wg-quick down "$IFACE" >/dev/null 2>&1 || true
  ip link del "$IFACE" >/dev/null 2>&1 || true
}

restore_backup() {
  if [ -n "${BACKUP_CONF:-}" ] && [ -f "$BACKUP_CONF" ]; then
    cp -f "$BACKUP_CONF" "$CONF"
    log "已恢复旧配置: $CONF"
  fi
}

rollback() {
  warn "执行回滚..."
  cleanup_iface
  restore_backup
}

# ── 账号管理（独立于接口） ────────────────────────────────

register_account() {
  need_root
  ensure_deps
  ensure_wgcf

  mkdir -p "$WORKDIR"

  if [ -f "$WORKDIR/wgcf-account.toml" ]; then
    log "已存在 WARP 账号，跳过注册"
    return 0
  fi

  log "注册 WARP 账号..."
  cd "$WORKDIR"
  "$WGCF_BIN" register --accept-tos
  log "WARP 账号注册完成"
}

delete_account() {
  need_root

  if [ ! -d "$WORKDIR" ]; then
    log "没有找到 WARP 账号目录，无需删除"
    return 0
  fi

  # 删除账号前先下线接口
  cleanup_iface
  rm -f "$CONF"
  rm -rf "$WORKDIR"
  log "WARP 账号及工作目录已删除"
}

ensure_account() {
  if [ -f "$WORKDIR/wgcf-account.toml" ]; then
    return 0
  fi
  log "未检测到 WARP 账号，自动注册..."
  register_account
}

# ── 接口管理 ──────────────────────────────────────────────

generate_conf() {
  log "生成 warp-ipv4 配置..."
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  # account 由 ensure_account 保证存在，这里只生成 profile
  "$WGCF_BIN" generate

  cp -f wgcf-profile.conf "$CONF"

  # 只保留 IPv4 默认路由，不接管 IPv6
  sed -i -E '0,/AllowedIPs = /s|AllowedIPs = .*|AllowedIPs = 0.0.0.0/0|' "$CONF"

  # 避免 WARP 接管 DNS，尽量减少副作用
  sed -i '/^[[:space:]]*DNS = /d' "$CONF"

  chmod 600 "$CONF"
  log "配置已写入: $CONF"
}

wait_handshake() {
  local timeout="${1:-60}"
  local interval=2
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    if wg show "$IFACE" latest-handshakes 2>/dev/null \
      | awk '$2 > 0 { ok=1 } END { exit !ok }'; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

health_check() {
  log "开始健康检查..."

  if ! wait_handshake 20; then
    warn "WARP 握手超时，隧道未真正连通"
    return 1
  fi

  local v4ip v6ip

  if ! v4ip="$(curl -4 --connect-timeout 5 --max-time 10 -fsS https://api.ipify.org)"; then
    warn "IPv4 健康检查失败"
    return 1
  fi

  if ! v6ip="$(curl -6 --connect-timeout 5 --max-time 10 -fsS https://api64.ipify.org)"; then
    warn "IPv6 健康检查失败"
    return 1
  fi

  if ! ip -6 route show default | grep -q '^default'; then
    warn "未检测到 IPv6 默认路由"
    return 1
  fi

  log "IPv4 出口: $v4ip"
  log "IPv6 出口: $v6ip"
  log "健康检查通过"
  return 0
}

# ── 菜单功能 ──────────────────────────────────────────────

add_warp_ipv4() {
  need_root
  ensure_deps
  ensure_wgcf
  ensure_account

  backup_existing_conf
  cleanup_iface
  generate_conf

  log "启动 ${IFACE}..."
  wg-quick up "$IFACE"

  if health_check; then
    systemctl enable "wg-quick@${IFACE}" >/dev/null 2>&1 || true
    log "warp-ipv4 已成功启用"
  else
    rollback
    die "健康检查失败，已回滚"
  fi
}

delete_warp_ipv4() {
  need_root
  log "删除 ${IFACE} 接口..."
  cleanup_iface
  rm -f "$CONF"
  # 保留 WARP 账号，以便重新添加时复用
  log "已删除 ${IFACE}（WARP 账号已保留）"
}

show_status() {
  ensure_deps

  # ── WARP 账号状态 ──
  echo
  echo "========== WARP 账号 =========="
  if [ -f "$WORKDIR/wgcf-account.toml" ]; then
    echo "账号文件: 存在 ($WORKDIR/wgcf-account.toml)"
    local private_key
    private_key="$(grep '^private_key' "$WORKDIR/wgcf-account.toml" 2>/dev/null | cut -d'"' -f2)"
    if [ -n "$private_key" ]; then
      echo "私钥: ${private_key:0:8}...${private_key: -4}"
    fi
    if command -v wgcf >/dev/null 2>&1; then
      echo
      echo "----- wgcf 账号详情 -----"
      (cd "$WORKDIR" && "$WGCF_BIN" status 2>/dev/null) || echo "(wgcf status 不可用)"
    fi
  else
    echo "账号文件: 未注册"
  fi

  # ── 接口状态 ──
  echo
  echo "========== warp-ipv4 接口 =========="
  if systemctl is-active "wg-quick@${IFACE}" >/dev/null 2>&1; then
    echo "systemd: active"
  else
    echo "systemd: inactive"
  fi

  echo
  echo "----- WireGuard 详情 -----"
  wg show "$IFACE" 2>/dev/null || echo "wg 接口不存在"

  echo
  echo "----- IPv4 路由 -----"
  ip route show || true

  echo
  echo "----- IPv6 路由 -----"
  ip -6 route show || true

  # ── 出口测试 ──
  echo
  echo "========== 出口测试 =========="
  if v4ip="$(curl -4 --connect-timeout 8 --max-time 12 -fsS https://api.ipify.org)"; then
    echo "IPv4: $v4ip"
  else
    echo "IPv4: 不可用"
  fi

  if v6ip="$(curl -6 --connect-timeout 8 --max-time 12 -fsS https://api64.ipify.org)"; then
    echo "IPv6: $v6ip"
  else
    echo "IPv6: 不可用"
  fi
}

# ── 主菜单 ────────────────────────────────────────────────

menu() {
  while true; do
    echo
    echo "===================================="
    echo "  WARP IPv4 管理菜单"
    echo "===================================="
    echo "1. 注册 WARP 账号"
    echo "2. 删除 WARP 账号"
    echo "3. 添加 warp-ipv4"
    echo "4. 删除 warp-ipv4"
    echo "5. 查看状态"
    echo "0. 退出"
    echo

    read -rp "请选择 [0-5]: " choice
    case "$choice" in
      1) register_account ;;
      2) delete_account ;;
      3) add_warp_ipv4 ;;
      4) delete_warp_ipv4 ;;
      5) show_status ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

menu

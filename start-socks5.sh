#!/bin/bash

# microsocks SOCKS5 代理管理脚本
# 支持多实例、systemd 服务管理

# ============================================================
# 代理配置（格式: "端口 出站IP"）
# 需要新增代理只需在此添加一行
# ============================================================
PROXIES=(
    "3366 2400:1b:c8:e9:b:1"
    "3367 2400:1b:c8:e9:b:2"
)

PROXY_USER="proxy"
PROXY_PASS="proxy"
BIND_ADDR="::"
SERVICE_DIR="/etc/systemd/system"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 权限运行此脚本"
        exit 1
    fi
}

# 解析配置项，返回 port 和 outbound
parse_proxy() {
    PROXY_PORT=$(echo "$1" | awk '{print $1}')
    PROXY_OUTBOUND=$(echo "$1" | awk '{print $2}')
}

# ============================================================
# 安装 microsocks
# ============================================================
install_microsocks() {
    info "开始安装 microsocks ..."

    if command -v microsocks &>/dev/null; then
        warn "microsocks 已安装: $(which microsocks)"
        return
    fi

    apt-get update -y
    apt-get install -y microsocks

    if command -v microsocks &>/dev/null; then
        info "microsocks 安装完成"
    else
        error "安装失败，请检查 apt 源"
    fi
}

# ============================================================
# 创建 systemd 服务
# ============================================================
create_service() {
    local port=$1
    local outbound=$2
    local service_name="microsocks-${port}"
    local service_file="${SERVICE_DIR}/${service_name}.service"

    if [[ -f "$service_file" ]]; then
        warn "服务 ${service_name} 已存在，跳过"
        return
    fi

    cat > "$service_file" <<EOF
[Unit]
Description=microsocks SOCKS5 Proxy on port ${port}
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/microsocks -i ${BIND_ADDR} -p ${port} -b ${outbound} -u ${PROXY_USER} -P ${PROXY_PASS}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$service_name"

    if systemctl is-active --quiet "$service_name"; then
        info "代理 ${service_name} 已启动 (端口 ${port})"
    else
        error "代理 ${service_name} 启动失败，查看日志: journalctl -u ${service_name}"
    fi
}

# ============================================================
# 2. 添加代理
# ============================================================
add_proxy() {
    local available=()
    for entry in "${PROXIES[@]}"; do
        parse_proxy "$entry"
        if [[ ! -f "${SERVICE_DIR}/microsocks-${PROXY_PORT}.service" ]]; then
            available+=("$entry")
        fi
    done

    if [[ ${#available[@]} -eq 0 ]]; then
        warn "所有配置的代理都已添加，没有可用的代理"
        return
    fi

    echo ""
    echo -e "${CYAN}可添加的代理:${NC}"
    echo ""
    for i in "${!available[@]}"; do
        parse_proxy "${available[$i]}"
        echo "  $((i+1))) 端口 ${PROXY_PORT}  出站 ${PROXY_OUTBOUND}"
    done
    echo "  0) 返回"
    echo ""

    read -p "请选择 [0-${#available[@]}]: " idx
    [[ "$idx" == "0" || -z "$idx" ]] && return

    if [[ "$idx" -ge 1 && "$idx" -le ${#available[@]} ]]; then
        parse_proxy "${available[$((idx-1))]}"
        create_service "$PROXY_PORT" "$PROXY_OUTBOUND"
    else
        error "无效选项"
    fi
}

# ============================================================
# 3. 查看代理状态
# ============================================================
show_status() {
    echo ""
    echo -e "${CYAN}========== 代理状态 ==========${NC}"
    echo ""

    local found=false
    for entry in "${PROXIES[@]}"; do
        parse_proxy "$entry"
        found=true
        local service_name="microsocks-${PROXY_PORT}"
        local service_file="${SERVICE_DIR}/${service_name}.service"
        local status

        if [[ -f "$service_file" ]]; then
            if systemctl is-active --quiet "$service_name"; then
                status="${GREEN}运行中${NC}"
            else
                status="${RED}已停止${NC}"
            fi
        else
            status="${YELLOW}未添加${NC}"
        fi
        echo -e "  端口: ${PROXY_PORT}  出站: ${PROXY_OUTBOUND}  状态: ${status}"
    done

    if [[ "$found" == false ]]; then
        warn "脚本中未配置任何代理 (请编辑 PROXIES 数组)"
    fi

    echo ""
    echo -e "${CYAN}==============================${NC}"
    echo ""
}

# ============================================================
# 4. 删除代理
# ============================================================
remove_proxy() {
    local running=()
    for entry in "${PROXIES[@]}"; do
        parse_proxy "$entry"
        if [[ -f "${SERVICE_DIR}/microsocks-${PROXY_PORT}.service" ]]; then
            running+=("$entry")
        fi
    done

    if [[ ${#running[@]} -eq 0 ]]; then
        warn "没有已添加的代理"
        return
    fi

    echo ""
    echo -e "${CYAN}可删除的代理:${NC}"
    echo ""
    for i in "${!running[@]}"; do
        parse_proxy "${running[$i]}"
        local service_name="microsocks-${PROXY_PORT}"
        local status
        if systemctl is-active --quiet "$service_name"; then
            status="${GREEN}运行中${NC}"
        else
            status="${RED}已停止${NC}"
        fi
        echo -e "  $((i+1))) 端口 ${PROXY_PORT}  状态: ${status}"
    done
    echo "  a) 删除全部"
    echo "  0) 返回"
    echo ""

    read -p "请选择: " choice

    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        for entry in "${running[@]}"; do
            parse_proxy "$entry"
            local service_name="microsocks-${PROXY_PORT}"
            systemctl disable --now "$service_name" 2>/dev/null
            rm -f "${SERVICE_DIR}/${service_name}.service"
            info "已删除 ${service_name}"
        done
        systemctl daemon-reload
    elif [[ "$choice" -ge 1 && "$choice" -le ${#running[@]} ]]; then
        parse_proxy "${running[$((choice-1))]}"
        local service_name="microsocks-${PROXY_PORT}"
        systemctl disable --now "$service_name" 2>/dev/null
        rm -f "${SERVICE_DIR}/${service_name}.service"
        systemctl daemon-reload
        info "已删除 ${service_name}"
    elif [[ "$choice" != "0" ]]; then
        error "无效选项"
    fi
}

# ============================================================
# 卸载 microsocks
# ============================================================
uninstall_microsocks() {
    read -p "确认卸载 microsocks 并删除所有代理？(y/N): " choice
    [[ "$choice" != "y" && "$choice" != "Y" ]] && return

    for entry in "${PROXIES[@]}"; do
        parse_proxy "$entry"
        local service_name="microsocks-${PROXY_PORT}"
        systemctl disable --now "$service_name" 2>/dev/null
        rm -f "${SERVICE_DIR}/${service_name}.service"
    done
    systemctl daemon-reload

    apt-get remove -y microsocks
    info "microsocks 已卸载"
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}   microsocks SOCKS5 代理管理${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo ""
    echo "  1) 安装 microsocks"
    echo "  2) 添加代理"
    echo "  3) 查看代理状态"
    echo "  4) 删除代理"
    echo "  5) 卸载 microsocks"
    echo "  0) 退出"
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo ""
}

# ============================================================
# 主逻辑
# ============================================================
check_root

while true; do
    show_menu
    read -p "请输入选项 [0-5]: " choice
    case "$choice" in
        1) install_microsocks ;;
        2) add_proxy ;;
        3) show_status ;;
        4) remove_proxy ;;
        5) uninstall_microsocks ;;
        0) echo "再见!"; exit 0 ;;
        *) error "无效选项，请重新输入" ;;
    esac
done

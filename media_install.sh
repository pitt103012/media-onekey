#!/bin/bash
# shellcheck shell=bash
#
# 媒体服务器 Docker 容器一键安装脚本  v2.01
# 支持: qBittorrent / Transmission / iYUUPlus / MoviePilot V2 (+PostgreSQL/Redis) / Vertex / Emby / Jellyfin / Plex
# 功能: 一键安装 | 容器升级（数据无损）
# ——————————————————————————————————————————————————————————————————————————————————

# ——————————————————————————————————————————————————————————————————————————————————
# 颜色与日志
# ——————————————————————————————————————————————————————————————————————————————————
Green="\033[32m"
Red="\033[31m"
Yellow='\033[33m'
Blue='\033[34m'
Cyan='\033[36m'
Bold='\033[1m'
Font="\033[0m"
INFO="[${Green}INFO${Font}]"
ERROR="[${Red}ERROR${Font}]"
WARN="[${Yellow}WARN${Font}]"
PROMPT="[${Cyan}?${Font}]"

function INFO()  { echo -e "${INFO} ${1}"; }
function ERROR() { echo -e "${ERROR} ${1}"; }
function WARN()  { echo -e "${WARN} ${1}"; }
function TITLE() { echo -e "\n${Bold}${Blue}--- ${1} ---${Font}\n"; }

function input() {
    local prompt="$1" default="$2" var_name="$3"
    local value
    if [ -n "$default" ]; then
        read -r -p "$(echo -e "${PROMPT} ${prompt} [${default}]: ")" value
        value="${value:-$default}"
    else
        read -r -p "$(echo -e "${PROMPT} ${prompt}: ")" value
    fi
    eval "$var_name='$value'"
}

function confirm() {
    local prompt="$1" default="${2:-y}"
    local yn
    if [ "$default" = "y" ]; then
        read -r -p "$(echo -e "${PROMPT} ${prompt} [Y/n]: ")" yn
        [[ "$yn" =~ ^[Nn]$ ]] && return 1 || return 0
    else
        read -r -p "$(echo -e "${PROMPT} ${prompt} [y/N]: ")" yn
        [[ "$yn" =~ ^[Yy]$ ]] && return 0 || return 1
    fi
}

function press_enter() {
    echo ""
    read -r -p "$(echo -e "${PROMPT} 按回车键继续...")" _
}

# ——————————————————————————————————————————————————————————————————————————————————
# 自动检测 UID / GID
# ——————————————————————————————————————————————————————————————————————————————————
detect_uid_gid() {
    PUID=$(id -u)
    PGID=$(id -g)

    if [ "$PUID" -eq 0 ]; then
        if [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
            PUID=$SUDO_UID
            PGID=$SUDO_GID
        elif [ -n "$PKEXEC_UID" ]; then
            PUID=$PKEXEC_UID
            PGID=$(id -g "$PUID" 2>/dev/null || echo 1000)
        else
            PUID=1000
            PGID=1000
        fi
    fi

    INFO "检测到用户 UID=${PUID} GID=${PGID}"
}

detect_uid_gid

# ——————————————————————————————————————————————————————————————————————————————————
# 环境检测
# ——————————————————————————————————————————————————————————————————————————————————
function check_docker() {
    TITLE "环境检测"

    if ! command -v docker &>/dev/null; then
        ERROR "未检测到 Docker，请先安装 Docker！"
        INFO "安装命令: curl -fsSL https://get.docker.com | bash"
        exit 1
    fi
    INFO "Docker 已安装: $(docker --version)"
}

# ——————————————————————————————————————————————————————————————————————————————————
# Docker 数据目录检测
# ——————————————————————————————————————————————————————————————————————————————————
DOCKER_BASE_PATH=""

function detect_docker_path() {
    TITLE "Docker 数据目录检测"
    INFO "正在搜索系统中的 docker/Docker 目录..."

    local candidates=()
    local search_paths=("/mnt" "/opt" "/home" "/root")

    while IFS= read -r dir; do
        [ -n "$dir" ] && candidates+=("$dir")
    done < <(find "${search_paths[@]}" / -maxdepth 3 -type d \( -name "docker" -o -name "Docker" \) 2>/dev/null | sort -u)

    # 去重，优先较短的路径（层级更浅的）
    local -a unique=()
    for dir in "${candidates[@]}"; do
        local duplicate=0
        for u in "${unique[@]}"; do
            [ "$dir" = "$u" ] && duplicate=1 && break
        done
        [ "$duplicate" -eq 0 ] && unique+=("$dir")
    done

    if [ ${#unique[@]} -eq 0 ]; then
        WARN "未检测到 docker/Docker 目录，使用默认路径 /opt/docker"
        DOCKER_BASE_PATH="/opt/docker"
        mkdir -p "$DOCKER_BASE_PATH" 2>/dev/null || true
        press_enter
        return
    fi

    if [ ${#unique[@]} -eq 1 ]; then
        DOCKER_BASE_PATH="${unique[0]}"
        INFO "检测到唯一目录: ${Green}${DOCKER_BASE_PATH}${Font}"
        press_enter
        return
    fi

    INFO "检测到多个 docker/Docker 目录:"
    echo ""
    local i=1
    for dir in "${unique[@]}"; do
        printf "  ${Green}%2d${Font}) %s\n" "$i" "$dir"
        ((i++))
    done
    echo ""

    local choice
    read -r -p "$(echo -e "${PROMPT} 请选择数据目录 [1]: ")" choice
    choice="${choice:-1}"

    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#unique[@]}" ]; then
        DOCKER_BASE_PATH="${unique[$((choice - 1))]}"
    else
        DOCKER_BASE_PATH="${unique[0]}"
    fi
    INFO "已选择: ${Green}${DOCKER_BASE_PATH}${Font}"
    press_enter
}

# ——————————————————————————————————————————————————————————————————————————————————
# 现有容器检测
# ——————————————————————————————————————————————————————————————————————————————————
declare -A EXISTING_STATUS EXISTING_NAME EXISTING_IMAGE EXISTING_PORTS

function detect_container() {
    local key="$1" pattern="$2"
    local match
    match=$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null | grep -iE "$pattern" | head -1)
    if [ -n "$match" ]; then
        EXISTING_NAME["$key"]=$(echo "$match" | cut -d'|' -f1)
        EXISTING_IMAGE["$key"]=$(echo "$match" | cut -d'|' -f2)
        local status_raw
        status_raw=$(echo "$match" | cut -d'|' -f3)
        EXISTING_PORTS["$key"]=$(echo "$match" | cut -d'|' -f4)
        if echo "$status_raw" | grep -qi "Up"; then
            EXISTING_STATUS["$key"]="running"
        elif echo "$status_raw" | grep -qi "Exited"; then
            EXISTING_STATUS["$key"]="stopped"
        else
            EXISTING_STATUS["$key"]="other"
        fi
        return 0
    fi
    EXISTING_STATUS["$key"]="none"
    return 1
}

function check_existing_containers() {
    detect_container "qbittorrent" "qbittorrent"
    detect_container "transmission" "transmission"
    detect_container "iyuu"        "iyuuplus"
    detect_container "moviepilot"  "moviepilot"
    detect_container "vertex"      "vertex"
    detect_container "emby"        "emby|embyserver"
    detect_container "jellyfin"    "jellyfin"
    detect_container "plex"        "plex|pms-docker"
}

# ——————————————————————————————————————————————————————————————————————————————————
# 镜像源检测与选择
# ——————————————————————————————————————————————————————————————————————————————————
MIRROR_LIST=(
    "docker.1panel.dev"
    "docker.ketches.cn"
    "docker.m.daocloud.io"
    "hub.geekery.cn"
    "ghcr.geekery.cn"
    "docker.rainbond.cc"
    "docker.udayun.com"
    "docker.fxxk.dedyn.io"
    "docker.211678.top"
    "dockerproxy.cn"
    "dockerpull.com"
    "swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io"
    "docker.1panel.live"
    "docker.zhai.cm"
    "docker.1ms.run"
)

SELECTED_MIRROR=""
MIRROR_PREFIX=""

function test_mirror() {
    local mirror="$1"
    local result
    result=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
        --connect-timeout 2 --max-time 4 "https://${mirror}/v2/" 2>/dev/null)
    echo "$result"
}

function select_mirror() {
    TITLE "Docker 镜像源选择"
    INFO "正在检测各镜像源连通性，请稍候..."

    local -a reachable=()
    local -a reachable_times=()
    local -a unreachable=()
    local best_idx=0
    local best_time=999

    local i=1
    for mirror in "${MIRROR_LIST[@]}"; do
        printf "  [%2d/%2d] 检测 %s ... " "$i" "${#MIRROR_LIST[@]}" "$mirror" >&2
        local result
        result=$(test_mirror "$mirror")
        local http_code
        http_code=$(echo "$result" | awk '{print $1}')
        local time_total
        time_total=$(echo "$result" | awk '{print $2}')

        if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
            printf "${Green}可达${Font} (%.2fs, HTTP %s)\n" "$time_total" "$http_code" >&2
            reachable+=("$mirror")
            reachable_times+=("$time_total")
            local time_ms best_ms
            time_ms=$(echo "$time_total" | awk '{printf "%d", $1 * 1000}')
            best_ms=$(echo "$best_time" | awk '{printf "%d", $1 * 1000}')
            if [ "$time_ms" -lt "$best_ms" ]; then
                best_time="$time_total"
                best_idx=$((${#reachable[@]} - 1))
            fi
        else
            printf "${Red}不可达${Font}\n" >&2
            unreachable+=("$mirror")
        fi
        ((i++))
    done

    echo ""

    if [ ${#reachable[@]} -eq 0 ]; then
        WARN "所有镜像源均不可达，将使用 Docker Hub 官方源（可能较慢）"
        SELECTED_MIRROR=""
        MIRROR_PREFIX=""
        press_enter
        return
    fi

    INFO "可达镜像源列表:"
    echo ""
    local j=1
    for mirror in "${reachable[@]}"; do
        local marker=""
        if [ "$((j - 1))" -eq "$best_idx" ]; then
            marker=" ${Green}(推荐 - 延迟最低)${Font}"
        fi
        printf "  ${Green}%2d${Font}) %s (%.2fs)%s\n" "$j" "$mirror" "${reachable_times[$((j - 1))]}" "$marker"
        ((j++))
    done

    echo ""
    echo -e "  ${Green} 0${Font}) 不使用镜像源 (直连 Docker Hub)"
    echo ""

    local choice
    read -r -p "$(echo -e "${PROMPT} 请选择镜像源 [推荐: $((best_idx + 1))]: ")" choice

    if [ "$choice" = "0" ]; then
        SELECTED_MIRROR=""
        MIRROR_PREFIX=""
        INFO "已选择直连 Docker Hub"
    elif [ -z "$choice" ]; then
        SELECTED_MIRROR="${reachable[$best_idx]}"
        MIRROR_PREFIX="${SELECTED_MIRROR}/"
        INFO "已选择推荐源: ${Green}${SELECTED_MIRROR}${Font}"
    elif [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#reachable[@]}" ]; then
        SELECTED_MIRROR="${reachable[$((choice - 1))]}"
        MIRROR_PREFIX="${SELECTED_MIRROR}/"
        INFO "已选择镜像源: ${Green}${SELECTED_MIRROR}${Font}"
    else
        WARN "无效选择，自动使用推荐源"
        SELECTED_MIRROR="${reachable[$best_idx]}"
        MIRROR_PREFIX="${SELECTED_MIRROR}/"
        INFO "已选择推荐源: ${Green}${SELECTED_MIRROR}${Font}"
    fi
}

# ——————————————————————————————————————————————————————————————————————————————————
# 容器选择
# ——————————————————————————————————————————————————————————————————————————————————
CONTAINER_LIST=(
    "qbittorrent|qBittorrent (BT/PT 下载器)"
    "transmission|Transmission (BT/PT 下载器)"
    "iyuu|iYUUPlus (PT 辅种自动化)"
    "moviepilot|MoviePilot V2 (影视管理自动化)"
    "vertex|Vertex (PT 助手)"
    "emby|Emby (媒体服务器)"
    "jellyfin|Jellyfin (媒体服务器)"
    "plex|Plex (媒体服务器)"
)

SELECTED=()

function select_containers() {
    SELECTED=()

    TITLE "选择要安装的容器"
    echo -e "输入容器编号（多个用空格分隔），输入 ${Green}all${Font} 安装全部，输入 ${Green}0${Font} 退出"
    echo -e "${Yellow}提示：选择已有容器将会停止并重建${Font}\n"

    local i=1
    for item in "${CONTAINER_LIST[@]}"; do
        local key="${item%%|*}"
        local name="${item##*|}"
        if [ "${EXISTING_STATUS[$key]}" != "none" ] && [ -n "${EXISTING_STATUS[$key]}" ]; then
            local status_tag
            case "${EXISTING_STATUS[$key]}" in
                running) status_tag="${Green}(已安装-运行中)${Font}" ;;
                stopped) status_tag="${Yellow}(已安装-已停止)${Font}" ;;
                *)       status_tag="${Red}(已安装)${Font}" ;;
            esac
            printf "  ${Green}%2d${Font}) %-40s %b\n" "$i" "$name" "$status_tag"
        else
            printf "  ${Green}%2d${Font}) %s\n" "$i" "$name"
        fi
        ((i++))
    done

    local mirror_label="${SELECTED_MIRROR:-直连}"
    printf "  ${Green}%2d${Font}) %s\n" "$i" "切换镜像源（当前: ${mirror_label}）"
    local mirror_opt=$i
    ((i++))
    printf "  ${Green}%2d${Font}) %s\n" "$i" "升级已安装容器（数据无损）"
    local upgrade_opt=$i
    ((i++))
    echo -e "  ${Green} 0${Font}) 退出脚本"
    echo ""
    read -r -p "$(echo -e "${PROMPT} 请输入编号: ")" selection

    if [ "$selection" = "0" ] || [ -z "$selection" ]; then
        return 1
    fi

    local need_mirror=0
    local need_upgrade=0
    if [ "$selection" = "all" ]; then
        for item in "${CONTAINER_LIST[@]}"; do
            SELECTED+=("${item%%|*}")
        done
    else
        for num in $selection; do
            if [ "$num" = "$mirror_opt" ]; then
                need_mirror=1
            elif [ "$num" = "$upgrade_opt" ]; then
                need_upgrade=1
            elif [ "$num" -ge 1 ] 2>/dev/null && [ "$num" -le "${#CONTAINER_LIST[@]}" ]; then
                local item="${CONTAINER_LIST[$((num - 1))]}"
                SELECTED+=("${item%%|*}")
            fi
        done
    fi

    if [ "$need_upgrade" -eq 1 ]; then
        upgrade_containers
        return 1
    fi

    if [ "$need_mirror" -eq 1 ]; then
        select_mirror
        if [ ${#SELECTED[@]} -eq 0 ]; then
            press_enter
            return 1
        fi
    fi

    if [ ${#SELECTED[@]} -eq 0 ]; then
        ERROR "未选择任何有效容器"
        press_enter
        return 1
    fi

    echo ""
    INFO "已选择: ${Green}${SELECTED[*]}${Font}"
    press_enter
    return 0
}

# ——————————————————————————————————————————————————————————————————————————————————
# 容器配置变量
# ——————————————————————————————————————————————————————————————————————————————————
declare -A CFG_NAME CFG_IMAGE CFG_PORTS CFG_VOLUMES CFG_ENV CFG_DEVICES CFG_NETWORK CFG_RESTART

# MoviePilot 可选 PostgreSQL / Redis 集成标记
MP_NEED_PG=0
MP_NEED_REDIS=0
MP_PG_NETWORK=""
MP_REDIS_NETWORK=""
MP_PG_CONTAINER=""
MP_REDIS_CONTAINER=""

# 共享网络名称（用于 inter-container 通信）
MP_NETWORK="media"

function add_port()    { CFG_PORTS["$1"]="${CFG_PORTS[$1]:+${CFG_PORTS[$1]},}$2"; }
function add_volume()  { CFG_VOLUMES["$1"]="${CFG_VOLUMES[$1]:+${CFG_VOLUMES[$1]},}$2"; }
function add_env()     { CFG_ENV["$1"]="${CFG_ENV[$1]:+${CFG_ENV[$1]},}$2"; }
function add_device()  { CFG_DEVICES["$1"]="${CFG_DEVICES[$1]:+${CFG_DEVICES[$1]},}$2"; }

function set_cfg() {
    local key="$1"
    CFG_NAME["$key"]="$2"
    CFG_IMAGE["$key"]="$3"
    CFG_NETWORK["$key"]="${4:-bridge}"
    CFG_RESTART["$key"]="unless-stopped"
    add_env "$key" "PUID=${PUID:-0}"
    add_env "$key" "PGID=${PGID:-0}"
    add_env "$key" "TZ=${TZ:-Asia/Shanghai}"
    add_env "$key" "UMASK_SET=022"
}

# ——————————————————————————————————————————————————————————————————————————————————
# 各容器配置函数
# ——————————————————————————————————————————————————————————————————————————————————

function configure_qbittorrent() {
    local key="qbittorrent"
    TITLE "配置 qBittorrent"
    WARN "BT/PT 下载建议使用 host 网络模式以获得更好的连接性"

    set_cfg "$key" "qbittorrent" "linuxserver/qbittorrent:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/qbittorrent/config"   config_dir
    input "下载目录"           "${DOCKER_BASE_PATH}/qbittorrent/downloads"            downloads_dir
    input "Web UI 端口"        "8080"                      web_port
    input "BT 连接端口 (TCP)"  "6881"                      bt_port
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/config"
    add_volume "$key" "${downloads_dir}:/downloads"
    add_port   "$key" "${web_port}:${web_port}"
    if [ "${CFG_NETWORK[$key]}" != "host" ]; then
        add_port "$key" "${bt_port}:${bt_port}"
        add_port "$key" "${bt_port}:${bt_port}/udp"
    fi
    add_env "$key" "WEBUI_PORT=${web_port}"

    INFO "qBittorrent 配置完成"
}

function configure_transmission() {
    local key="transmission"
    TITLE "配置 Transmission"

    set_cfg "$key" "transmission" "chisbread/transmission:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/transmission/config"  config_dir
    input "下载目录"           "${DOCKER_BASE_PATH}/transmission/downloads"            downloads_dir
    input "监控目录（种子自动添加）" "${DOCKER_BASE_PATH}/transmission/watch" watch_dir
    input "Web UI 用户名"      "admin"                     user_name
    input "Web UI 密码"        ""                          user_pass
    input "Web UI 端口"        "9091"                      web_port
    input "Peer 端口 (TCP/UDP)" "51413"                    peer_port
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/config"
    add_volume "$key" "${downloads_dir}:/downloads"
    add_volume "$key" "${watch_dir}:/watch"
    add_port   "$key" "${web_port}:9091"
    add_port   "$key" "${peer_port}:51413"
    add_port   "$key" "${peer_port}:51413/udp"
    add_env "$key" "USER=${user_name:-admin}"
    if [ -n "$user_pass" ]; then
        add_env "$key" "PASS=$user_pass"
    else
        add_env "$key" "PASS=admin"
    fi

    # 保存用于部署后同步密码
    TR_PASS="${user_pass:-admin}"
    TR_USER="${user_name:-admin}"

    INFO "Transmission 配置完成"
}

function configure_iyuu() {
    local key="iyuu"
    TITLE "配置 iYUUPlus (PT 辅种自动化)"
    WARN "iYUUPlus 需要能够访问下载器的种子目录"

    set_cfg "$key" "IYUUPlus" "iyuucn/iyuuplus:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/iyuu/db"   config_dir
    input "Web UI 端口"        "8787"                      web_port
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/IYUU/db"
    add_port   "$key" "${web_port}:8787"

    # 自动检测并挂载下载器的种子目录
    if [ -n "${CFG_VOLUMES[qbittorrent]}" ]; then
        local qb_bt_dir=""
        IFS=',' read -ra _vols <<< "${CFG_VOLUMES[qbittorrent]}"
        for _v in "${_vols[@]}"; do
            [ -z "$_v" ] && continue
            [ "${_v##*:}" = "/config" ] && qb_bt_dir="${_v%%:*}/qBittorrent/BT_backup" && break
        done
        if [ -n "$qb_bt_dir" ] && [ -d "$qb_bt_dir" ]; then
            add_volume "$key" "${qb_bt_dir}:/BT_backup"
            INFO "已挂载 qBittorrent 种子目录: ${qb_bt_dir}"
        else
            WARN "qBittorrent BT_backup 目录不存在，跳过挂载"
        fi
    fi

    if [ -n "${CFG_VOLUMES[transmission]}" ]; then
        local tr_torrents_dir=""
        IFS=',' read -ra _vols <<< "${CFG_VOLUMES[transmission]}"
        for _v in "${_vols[@]}"; do
            [ -z "$_v" ] && continue
            [ "${_v##*:}" = "/config" ] && tr_torrents_dir="${_v%%:*}/torrents" && break
        done
        if [ -n "$tr_torrents_dir" ] && [ -d "$tr_torrents_dir" ]; then
            add_volume "$key" "${tr_torrents_dir}:/torrents"
            INFO "已挂载 Transmission 种子目录: ${tr_torrents_dir}"
        else
            WARN "Transmission torrents 目录不存在，跳过挂载"
        fi
    fi

    INFO "iYUUPlus 配置完成"
}

function configure_moviepilot() {
    local key="moviepilot"
    TITLE "配置 MoviePilot V2"
    WARN "MoviePilot V2 需要能够访问下载器和媒体服务器"

    set_cfg "$key" "moviepilot" "jxxghp/moviepilot-v2:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/moviepilot/config"    config_dir
    input "媒体库目录"         "${DOCKER_BASE_PATH}/media"                media_dir
    input "Web UI 端口"        "3000"                      web_port
    input "API 端口"           "3001"                      api_port
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/config"
    add_volume "$key" "${media_dir}:/media"
    add_port   "$key" "${web_port}:3000"
    add_port   "$key" "${api_port}:3001"
    add_env "$key" "NGINX_PORT=3000"

    # 自动检测并挂载下载器的种子目录
    if [ -n "${CFG_VOLUMES[qbittorrent]}" ]; then
        local qb_bt_dir=""
        IFS=',' read -ra _vols <<< "${CFG_VOLUMES[qbittorrent]}"
        for _v in "${_vols[@]}"; do
            [ -z "$_v" ] && continue
            [ "${_v##*:}" = "/config" ] && qb_bt_dir="${_v%%:*}/qBittorrent/BT_backup" && break
        done
        if [ -n "$qb_bt_dir" ] && [ -d "$qb_bt_dir" ]; then
            add_volume "$key" "${qb_bt_dir}:/BT_backup"
            INFO "已挂载 qBittorrent 种子目录: ${qb_bt_dir}"
        else
            WARN "qBittorrent BT_backup 目录不存在，跳过挂载"
        fi
    fi

    if [ -n "${CFG_VOLUMES[transmission]}" ]; then
        local tr_torrents_dir=""
        IFS=',' read -ra _vols <<< "${CFG_VOLUMES[transmission]}"
        for _v in "${_vols[@]}"; do
            [ -z "$_v" ] && continue
            [ "${_v##*:}" = "/config" ] && tr_torrents_dir="${_v%%:*}/torrents" && break
        done
        if [ -n "$tr_torrents_dir" ] && [ -d "$tr_torrents_dir" ]; then
            add_volume "$key" "${tr_torrents_dir}:/torrents"
            INFO "已挂载 Transmission 种子目录: ${tr_torrents_dir}"
        else
            WARN "Transmission torrents 目录不存在，跳过挂载"
        fi
    fi

    # 可选 PostgreSQL 数据库集成
    if confirm "是否启用 PostgreSQL 数据库（MoviePilot 高级特性，大规模部署推荐）？" "n"; then
        MP_NEED_PG=1
        MP_PG_NETWORK="${MP_NETWORK}"
        MP_PG_CONTAINER="moviepilot-postgres"
    fi

    # 可选 Redis 缓存集成
    if confirm "是否启用 Redis 缓存（MoviePilot 高级特性，大规模部署推荐）？" "n"; then
        MP_NEED_REDIS=1
        MP_REDIS_NETWORK="${MP_NETWORK}"
        MP_REDIS_CONTAINER="moviepilot-redis"
    fi

    INFO "MoviePilot V2 配置完成"
}

function configure_postgresql() {
    TITLE "配置 PostgreSQL (MoviePilot 数据库)"

    local key="moviepilot-postgres"
    set_cfg "$key" "$key" "postgres:16-alpine"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "数据目录"           "${DOCKER_BASE_PATH}/postgresql/data"   data_dir
    input "数据库名"           "moviepilot"                db_name
    input "数据库用户"         "moviepilot"                db_user
    input "数据库密码"         "moviepilot123"             db_pass
    input "端口"               "5432"                      db_port
    input "网络模式 (bridge/host)" "bridge"                CFG_NETWORK["$key"]

    add_volume "$key" "${data_dir}:/var/lib/postgresql/data"
    add_port   "$key" "${db_port}:5432"
    add_env "$key" "POSTGRES_DB=${db_name}"
    add_env "$key" "POSTGRES_USER=${db_user}"
    add_env "$key" "POSTGRES_PASSWORD=${db_pass}"

    MP_PG_HOST="${CFG_NAME[$key]}"
    MP_PG_PORT="5432"
    MP_PG_DB="${db_name}"
    MP_PG_USER="${db_user}"
    MP_PG_PASS="${db_pass}"

    INFO "PostgreSQL 配置完成"
}

function configure_redis() {
    TITLE "配置 Redis (MoviePilot 缓存)"

    local key="moviepilot-redis"
    set_cfg "$key" "$key" "redis:7-alpine"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "数据目录"           "${DOCKER_BASE_PATH}/redis/data"    data_dir
    input "最大内存"           "1024mb"                    max_memory
    input "端口"               "6379"                      redis_port
    input "网络模式 (bridge/host)" "bridge"                CFG_NETWORK["$key"]

    add_volume "$key" "${data_dir}:/data"
    add_port   "$key" "${redis_port}:6379"
    add_env "$key" "REDIS_MAXMEMORY=${max_memory}"

    MP_REDIS_HOST="${CFG_NAME[$key]}"
    MP_REDIS_PORT="6379"
    MP_REDIS_MAXMEMORY="${max_memory}"

    INFO "Redis 配置完成"
}

function configure_vertex() {
    local key="vertex"
    TITLE "配置 Vertex"

    set_cfg "$key" "vertex" "lswl/vertex:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/vertex/config"        config_dir
    input "下载目录"           "${DOCKER_BASE_PATH}/vertex/downloads"            downloads_dir
    input "Web UI 端口"        "3200"                      web_port
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/config"
    add_volume "$key" "${downloads_dir}:/downloads"
    add_port   "$key" "${web_port}:3000"

    INFO "Vertex 配置完成"
}

function configure_emby() {
    local key="emby"
    TITLE "配置 Emby"

    set_cfg "$key" "emby" "emby/embyserver:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/emby/config"          config_dir
    input "媒体库目录"         "${DOCKER_BASE_PATH}/media"                media_dir
    input "HTTP 端口"          "8096"                      http_port
    input "HTTPS 端口"         "8920"                      https_port
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/config"
    add_volume "$key" "${media_dir}:/media"
    add_port   "$key" "${http_port}:8096"
    add_port   "$key" "${https_port}:8920"
    add_env "$key" "UID=${PUID:-0}"
    add_env "$key" "GID=${PGID:-0}"

    if [ -e /dev/dri ]; then
        if confirm "启用硬件加速 (Intel QSV / VAAPI)？" "n"; then
            add_device "$key" "/dev/dri:/dev/dri"
            INFO "已添加 /dev/dri 设备映射"
        fi
    else
        INFO "未检测到 /dev/dri，跳过硬件加速"
    fi

    INFO "Emby 配置完成"
}

function configure_jellyfin() {
    local key="jellyfin"
    TITLE "配置 Jellyfin"

    set_cfg "$key" "jellyfin" "jellyfin/jellyfin:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/jellyfin/config"      config_dir
    input "缓存目录"           "${DOCKER_BASE_PATH}/jellyfin/cache"       cache_dir
    input "媒体库目录"         "${DOCKER_BASE_PATH}/media"                media_dir
    input "HTTP 端口"          "8096"                      http_port
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/config"
    add_volume "$key" "${cache_dir}:/cache"
    add_volume "$key" "${media_dir}:/media"
    add_port   "$key" "${http_port}:8096"

    if [ -e /dev/dri ]; then
        if confirm "启用硬件加速 (Intel QSV / VAAPI)？" "n"; then
            add_device "$key" "/dev/dri:/dev/dri"
            INFO "已添加 /dev/dri 设备映射"
        fi
    else
        INFO "未检测到 /dev/dri，跳过硬件加速"
    fi

    INFO "Jellyfin 配置完成"
}

function configure_plex() {
    local key="plex"
    TITLE "配置 Plex"

    set_cfg "$key" "plex" "plexinc/pms-docker:latest"

    input "镜像地址"           "${CFG_IMAGE[$key]}"        CFG_IMAGE["$key"]
    input "容器名称"           "${CFG_NAME[$key]}"         CFG_NAME["$key"]
    input "配置目录"           "${DOCKER_BASE_PATH}/plex/config"          config_dir
    input "转码目录"           "${DOCKER_BASE_PATH}/plex/transcode"       transcode_dir
    input "媒体库目录"         "${DOCKER_BASE_PATH}/media"                media_dir
    input "Web UI 端口"        "32400"                     web_port

    # Plex 需要 host 网络或大量端口映射
    WARN "Plex 推荐使用 host 网络模式以获得完整的 DLNA/GDM 发现功能"
    input "网络模式 (bridge/host)" "${CFG_NETWORK[$key]}"  CFG_NETWORK["$key"]

    add_volume "$key" "${config_dir}:/config"
    add_volume "$key" "${transcode_dir}:/transcode"
    add_volume "$key" "${media_dir}:/media"
    add_port "$key" "${web_port}:32400"
    add_env "$key" "PLEX_UID=${PUID:-0}"
    add_env "$key" "PLEX_GID=${PGID:-0}"

    if [ "${CFG_NETWORK[$key]}" != "host" ]; then
        add_port "$key" "3005:3005"
        add_port "$key" "8324:8324"
        add_port "$key" "32469:32469"
        add_port "$key" "1900:1900/udp"
        add_port "$key" "32410:32410/udp"
        add_port "$key" "32412:32412/udp"
        add_port "$key" "32413:32413/udp"
        add_port "$key" "32414:32414/udp"
    fi

    if [ -e /dev/dri ]; then
        if confirm "启用硬件加速 (Intel QSV / VAAPI)？" "n"; then
            add_device "$key" "/dev/dri:/dev/dri"
            INFO "已添加 /dev/dri 设备映射"
        fi
    else
        INFO "未检测到 /dev/dri，跳过硬件加速"
    fi

    INFO "Plex 配置完成"
}

# ——————————————————————————————————————————————————————————————————————————————————
# 配置汇总与确认
# ——————————————————————————————————————————————————————————————————————————————————
function show_summary() {
    TITLE "配置汇总"

    for key in "${SELECTED[@]}"; do
        echo -e "${Bold}${Green}>>> ${CFG_NAME[$key]}${Font}"
        echo -e "  镜像:     ${CFG_IMAGE[$key]}"
        echo -e "  网络:     ${CFG_NETWORK[$key]}"
        echo -e "  端口:     ${CFG_PORTS[$key]//,/ }"
        echo -e "  挂载:     ${CFG_VOLUMES[$key]//,/ }"
        if [ -n "${CFG_DEVICES[$key]}" ]; then
            echo -e "  设备:     ${CFG_DEVICES[$key]//,/ }"
        fi
        echo ""
    done
}

# ——————————————————————————————————————————————————————————————————————————————————
# 部署 (docker run)
# ——————————————————————————————————————————————————————————————————————————————————
function _deploy_single() {
    local key="$1" shared_network="$2"

    INFO "部署 ${CFG_NAME[$key]} ..."

    IFS=',' read -ra vols <<< "${CFG_VOLUMES[$key]}"
    for vol in "${vols[@]}"; do
        [ -z "$vol" ] && continue
        local host_dir="${vol%%:*}"
        [ -d "$host_dir" ] || mkdir -p "$host_dir"
    done

    IFS=',' read -ra vols <<< "${CFG_VOLUMES[$key]}"
    for vol in "${vols[@]}"; do
        [ -z "$vol" ] && continue
        local host_dir="${vol%%:*}"
        chown -R 1000:1000 "$host_dir" 2>/dev/null || true
    done

    local image_full="${CFG_IMAGE[$key]}"
    if docker image inspect "$image_full" &>/dev/null; then
        INFO "  镜像已存在，跳过拉取: ${CFG_IMAGE[$key]}"
    else
        INFO "  拉取镜像: $image_full"
        docker pull "$image_full"
    fi

    docker stop "${CFG_NAME[$key]}" 2>/dev/null || true
    docker rm "${CFG_NAME[$key]}" 2>/dev/null || true

    # Transmission 修复: 清除旧配置并预创建 settings.json 避免散列密码 401
    if [ "$key" = "transmission" ]; then
        IFS=',' read -ra _vols <<< "${CFG_VOLUMES[$key]}"
        for _v in "${_vols[@]}"; do
            [ -z "$_v" ] && continue
            if [ "${_v##*:}" = "/config" ]; then
                local _cfg_dir="${_v%%:*}"
                [ -f "$_cfg_dir/settings.json" ] && rm -f "$_cfg_dir/settings.json"
                cat > "$_cfg_dir/settings.json" <<'SETEOF'
{
    "rpc-authentication-required": false,
    "rpc-whitelist": "127.0.0.1,192.168.*.*,10.*.*.*,172.16.*.*",
    "rpc-whitelist-enabled": true,
    "rpc-port": 9091,
    "rpc-bind-address": "0.0.0.0"
}
SETEOF
                chown 1000:1000 "$_cfg_dir/settings.json" 2>/dev/null || true
                WARN "Transmission 初始配置已重置，Web UI 无需登录即可访问（安装后可在设置中开启认证）"
            fi
        done
        unset _cfg_dir
    fi

    local -a args=(
        -d
        --name "${CFG_NAME[$key]}"
        --restart "${CFG_RESTART[$key]}"
    )

    local use_network="${CFG_NETWORK[$key]}"
    if [ -n "$shared_network" ]; then
        use_network="$shared_network"
    fi

    if [ "$use_network" = "host" ]; then
        args+=(--network host)
    else
        docker network create "$use_network" 2>/dev/null || true
        args+=(--network "$use_network")
        IFS=',' read -ra ports <<< "${CFG_PORTS[$key]}"
        for port in "${ports[@]}"; do
            [ -z "$port" ] && continue
            args+=(-p "$port")
        done
    fi

    IFS=',' read -ra vols <<< "${CFG_VOLUMES[$key]}"
    for vol in "${vols[@]}"; do
        [ -z "$vol" ] && continue
        args+=(-v "$vol")
    done

    IFS=',' read -ra envs <<< "${CFG_ENV[$key]}"
    for env in "${envs[@]}"; do
        [ -z "$env" ] && continue
        args+=(-e "$env")
    done

    IFS=',' read -ra devs <<< "${CFG_DEVICES[$key]}"
    for dev in "${devs[@]}"; do
        [ -z "$dev" ] && continue
        args+=(--device "$dev")
    done

    args+=("$image_full")

    docker run "${args[@]}"

    INFO "  ${CFG_NAME[$key]} 部署完成"
}

function deploy() {
    TITLE "部署容器"

    # 如果启用 PostgreSQL/Redis，创建共享网络
    if [ "$MP_NEED_PG" -eq 1 ] || [ "$MP_NEED_REDIS" -eq 1 ]; then
        docker network create "${MP_NETWORK}" 2>/dev/null || true
        INFO "已创建共享网络: ${MP_NETWORK}"
    fi

    # 先部署 PostgreSQL (需要在 MoviePilot 之前)
    if [ "$MP_NEED_PG" -eq 1 ]; then
        local pg_key="moviepilot-postgres"
        if [ "${CFG_NETWORK[$pg_key]}" != "host" ]; then
            CFG_NETWORK["$pg_key"]="${MP_NETWORK}"
        fi
        _deploy_single "$pg_key" "${MP_NETWORK}"
        MP_PG_HOST="${CFG_NAME[$pg_key]}"
    fi

    # 再部署 Redis (需要在 MoviePilot 之前)
    if [ "$MP_NEED_REDIS" -eq 1 ]; then
        local redis_key="moviepilot-redis"
        if [ "${CFG_NETWORK[$redis_key]}" != "host" ]; then
            CFG_NETWORK["$redis_key"]="${MP_NETWORK}"
        fi
        _deploy_single "$redis_key" "${MP_NETWORK}"
        MP_REDIS_HOST="${CFG_NAME[$redis_key]}"
    fi

    for key in "${SELECTED[@]}"; do
        # 跳过已部署的 PostgreSQL/Redis
        if [ "$key" = "moviepilot-postgres" ] || [ "$key" = "moviepilot-redis" ]; then
            continue
        fi

        # 为 MoviePilot 添加 PostgreSQL/Redis 环境变量
        local shared_net=""
        if [ "$key" = "moviepilot" ]; then
            if [ "$MP_NEED_PG" -eq 1 ]; then
                add_env "moviepilot" "DB_TYPE=postgresql"
                add_env "moviepilot" "DB_POSTGRESQL_HOST=${MP_PG_HOST:-$MP_PG_CONTAINER}"
                add_env "moviepilot" "DB_POSTGRESQL_PORT=${MP_PG_PORT:-5432}"
                add_env "moviepilot" "DB_POSTGRESQL_DATABASE=${MP_PG_DB:-moviepilot}"
                add_env "moviepilot" "DB_POSTGRESQL_USERNAME=${MP_PG_USER:-moviepilot}"
                add_env "moviepilot" "DB_POSTGRESQL_PASSWORD=${MP_PG_PASS:-moviepilot123}"
                add_env "moviepilot" "DB_POSTGRESQL_POOL_SIZE=10"
                add_env "moviepilot" "DB_POSTGRESQL_MAX_OVERFLOW=20"
                shared_net="${MP_NETWORK}"
            fi
            if [ "$MP_NEED_REDIS" -eq 1 ]; then
                add_env "moviepilot" "CACHE_BACKEND_TYPE=redis"
                add_env "moviepilot" "CACHE_BACKEND_URL=redis://${MP_REDIS_HOST:-$MP_REDIS_CONTAINER}:${MP_REDIS_PORT:-6379}/0"
                add_env "moviepilot" "CACHE_REDIS_MAXMEMORY=${MP_REDIS_MAXMEMORY:-1024mb}"
                shared_net="${MP_NETWORK}"
            fi
        fi

        _deploy_single "$key" "$shared_net"
    done

    echo ""
    INFO "========== 部署完成 =========="
    echo ""

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="<服务器IP>"

    for key in "${SELECTED[@]}"; do
        # 跳过已通过 POSTGRESQL/REDIS 显示的辅助容器
        if [ "$key" = "moviepilot-postgres" ] || [ "$key" = "moviepilot-redis" ]; then
            continue
        fi
        local ports="${CFG_PORTS[$key]}"
        if [ -n "$ports" ]; then
            local first_port
            first_port=$(echo "$ports" | awk -F',' '{print $1}' | cut -d: -f1)
            echo -e "  ${Green}${CFG_NAME[$key]}${Font}: http://${ip}:${first_port}"
        elif [ "${CFG_NETWORK[$key]}" = "host" ]; then
            echo -e "  ${Green}${CFG_NAME[$key]}${Font}: host 网络模式，请查看容器文档获取默认端口"
        fi
    done

    echo ""
    INFO "管理命令:"
    echo -e "  查看状态:  ${Yellow}docker ps -a${Font}"
    echo -e "  查看日志:  ${Yellow}docker logs -f <容器名>${Font}"
    echo -e "  停止容器:  ${Yellow}docker stop <容器名>${Font}"
    echo -e "  启动容器:  ${Yellow}docker start <容器名>${Font}"
    echo -e "  重启容器:  ${Yellow}docker restart <容器名>${Font}"
    echo -e "  删除容器:  ${Yellow}docker rm -f <容器名>${Font}"
}

# ——————————————————————————————————————————————————————————————————————————————————
# 容器升级（数据无损）
# ——————————————————————————————————————————————————————————————————————————————————
function upgrade_containers() {
    TITLE "容器升级（数据无损）"
    INFO "正在检测各容器是否需要更新..."

    local -a upg_keys=()
    local -a upg_names=()
    local -a upg_images=()

    local idx=1
    for item in "${CONTAINER_LIST[@]}"; do
        local key="${item%%|*}"
        if [ "${EXISTING_STATUS[$key]}" = "none" ] || [ -z "${EXISTING_STATUS[$key]}" ]; then
            continue
        fi

        local cname="${EXISTING_NAME[$key]}"
        local cimage="${EXISTING_IMAGE[$key]}"

        local old_id
        old_id=$(docker image inspect --format '{{.ID}}' "$cimage" 2>/dev/null)

        INFO "  检测 ${cname} (${cimage}) ..."
        docker pull "$cimage" >/dev/null 2>&1 || {
            WARN "  镜像拉取失败，跳过"
            continue
        }

        local new_id
        new_id=$(docker image inspect --format '{{.ID}}' "$cimage" 2>/dev/null)

        if [ -n "$old_id" ] && [ -n "$new_id" ] && [ "$old_id" != "$new_id" ]; then
            upg_keys+=("$key")
            upg_names+=("$cname")
            upg_images+=("$cimage")
            printf "  ${Green}%2d${Font}) %s  ${Yellow}(有更新)${Font}\n" "$idx" "$cname"
            ((idx++))
        else
            INFO "  ${cname} 已是最新版本"
        fi
    done

    if [ ${#upg_keys[@]} -eq 0 ]; then
        echo ""
        INFO "所有容器均为最新版本，无需升级！"
        press_enter
        return
    fi

    echo ""
    echo -e "  ${Green} 0${Font}) 返回主菜单"
    echo ""

    local selection
    read -r -p "$(echo -e "${PROMPT} 请输入编号 (多个用空格分隔): ")" selection

    [ -z "$selection" ] || [ "$selection" = "0" ] && return

    local -a chosen_keys=()
    for num in $selection; do
        if [ "$num" -ge 1 ] 2>/dev/null && [ "$num" -le "${#upg_keys[@]}" ]; then
            chosen_keys+=("${upg_keys[$((num - 1))]}")
        fi
    done

    if [ ${#chosen_keys[@]} -eq 0 ]; then
        ERROR "未选择任何有效容器"
        press_enter
        return
    fi

    echo ""
    INFO "将要升级以下容器:"
    for key in "${chosen_keys[@]}"; do
        echo -e "  ${Green}${EXISTING_NAME[$key]}${Font} (${EXISTING_IMAGE[$key]})"
    done
    echo ""

    if ! confirm "确认升级？数据不会丢失" "y"; then
        INFO "已取消升级"
        press_enter
        return
    fi

    for key in "${chosen_keys[@]}"; do
        local cname="${EXISTING_NAME[$key]}"
        local cimage="${EXISTING_IMAGE[$key]}"

        echo ""
        INFO "升级容器: ${Green}${cname}${Font}"

        INFO "  提取容器配置..."
        local inspect_data
        inspect_data=$(docker inspect "$cname" 2>/dev/null)
        [ -z "$inspect_data" ] && { ERROR "  无法读取容器配置"; continue; }

        local -a run_args=(-d --name "$cname")

        # Restart policy
        local restart_policy
        restart_policy=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
rp=c.get('HostConfig',{}).get('RestartPolicy',{})
if rp.get('Name')=='always':
    print('--restart always')
elif rp.get('Name')=='unless-stopped':
    print('--restart unless-stopped')
elif rp.get('Name')=='on-failure':
    print('--restart on-failure:'+str(rp.get('MaximumRetryCount',5)))
else:
    print('--restart unless-stopped')
" 2>/dev/null)
        [ -n "$restart_policy" ] && run_args+=($restart_policy)

        # Network
        local net_mode
        net_mode=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
nm=c.get('HostConfig',{}).get('NetworkMode','default')
if nm=='host':
    print('--network host')
else:
    for nid,ncfg in c.get('NetworkSettings',{}).get('Networks',{}).items():
        print(ncfg.get('NetworkID',''))
" 2>/dev/null)

        if echo "$net_mode" | grep -q "^--network host"; then
            run_args+=($net_mode)
        elif [ -n "$net_mode" ]; then
            run_args+=(--network "$net_mode")
        else
            run_args+=(--network bridge)
        fi

        # Ports
        local ports_str
        ports_str=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
for p,v in c.get('NetworkSettings',{}).get('Ports',{}).items():
    if v:
        for h in v:
            print(h.get('HostPort',''),end=' ')
" 2>/dev/null)
        if [ "$net_mode" != "--network host" ] && [ -n "$ports_str" ]; then
            local ports_info
            ports_info=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
for p,v in c.get('NetworkSettings',{}).get('Ports',{}).items():
    if v:
        port_num=p.split('/')[0]
        for h in v:
            print('-p '+h.get('HostPort','')+':'+port_num)
" 2>/dev/null)
            while IFS= read -r _pline; do
                [ -n "$_pline" ] && run_args+=($_pline)
            done <<< "$ports_info"
        fi

        # Mounts
        local mounts
        mounts=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
for m in c.get('Mounts',[]):
    if m.get('Type')=='bind':
        mode=m.get('Mode','rw')
        print('-v '+m.get('Source','')+':'+m.get('Destination','')+(':'+mode if mode!='rw' else ''))
" 2>/dev/null)
        while IFS= read -r _mline; do
            [ -n "$_mline" ] && run_args+=($_mline)
        done <<< "$mounts"

        # Env
        local envs
        envs=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
for e in c.get('Config',{}).get('Env',[]):
    print('-e '+e)
" 2>/dev/null)
        while IFS= read -r _eline; do
            [ -n "$_eline" ] && run_args+=($_eline)
        done <<< "$envs"

        # Devices
        local devices
        devices=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
for d in c.get('HostConfig',{}).get('Devices',[]):
    print('--device '+d.get('PathOnHost','')+':'+d.get('PathInContainer',''))
" 2>/dev/null)
        while IFS= read -r _dline; do
            [ -n "$_dline" ] && run_args+=($_dline)
        done <<< "$devices"

        # Privileged
        local priv
        priv=$(echo "$inspect_data" | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
if c.get('HostConfig',{}).get('Privileged'):
    print('1')
" 2>/dev/null)
        [ "$priv" = "1" ] && run_args+=(--privileged)

        run_args+=("$cimage")

        INFO "  停止容器: $cname"
        docker stop -t 30 "$cname" 2>/dev/null || true
        local wait_count=0
        while docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; do
            sleep 1
            ((wait_count++))
            [ "$wait_count" -ge 30 ] && break
        done

        INFO "  删除旧容器: $cname"
        docker rm "$cname" 2>/dev/null || true

        INFO "  等待端口释放..."
        sleep 2

        INFO "  重建容器: $cname"
        local retry=0
        while [ "$retry" -lt 3 ]; do
            if docker run "${run_args[@]}" 2>/tmp/docker_upgrade_err.$$; then
                rm -f /tmp/docker_upgrade_err.$$
                break
            else
                local err_msg
                err_msg=$(cat /tmp/docker_upgrade_err.$$ 2>/dev/null)
                rm -f /tmp/docker_upgrade_err.$$
                if echo "$err_msg" | grep -qi "already in use"; then
                    WARN "  端口冲突，等待释放后重试 ($((retry + 1))/3)..."
                    sleep 3
                    ((retry++))
                else
                    ERROR "  容器启动失败: $err_msg"
                    ((retry=99))
                    break
                fi
            fi
        done

        local new_status
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            INFO "  ${Green}${cname} 升级成功！${Font}"
        else
            ERROR "  ${cname} 升级后未运行，请检查 docker logs ${cname}"
        fi
    done

    echo ""
    INFO "升级完成！"
    # 刷新容器状态
    check_existing_containers
    press_enter
}

# ——————————————————————————————————————————————————————————————————————————————————
# 主流程
# ——————————————————————————————————————————————————————————————————————————————————
function main() {
    clear
    echo -e "${Bold}${Cyan}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║    媒体服务器 Docker 一键安装脚本 v2.01      ║"
    echo "║   qBittorrent / Transmission / iYUUPlus      ║"
    echo "║   MoviePilot / Vertex / Emby / Jellyfin / Plex ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${Font}"

    check_docker
    detect_docker_path
    check_existing_containers
    select_mirror

    while true; do
        unset CFG_NAME CFG_IMAGE CFG_PORTS CFG_VOLUMES CFG_ENV CFG_DEVICES CFG_NETWORK CFG_RESTART
        declare -gA CFG_NAME CFG_IMAGE CFG_PORTS CFG_VOLUMES CFG_ENV CFG_DEVICES CFG_NETWORK CFG_RESTART
        MP_NEED_PG=0
        MP_NEED_REDIS=0
        MP_PG_NETWORK=""
        MP_REDIS_NETWORK=""
        MP_PG_CONTAINER=""
        MP_REDIS_CONTAINER=""
        MP_PG_HOST=""
        MP_PG_PORT=""
        MP_PG_DB=""
        MP_PG_USER=""
        MP_PG_PASS=""
        MP_REDIS_HOST=""
        MP_REDIS_PORT=""
        MP_REDIS_MAXMEMORY=""

        if ! select_containers; then
            INFO "感谢使用，再见！"
            exit 0
        fi

        for key in "${SELECTED[@]}"; do
            case "$key" in
                qbittorrent)  configure_qbittorrent ;;
                transmission) configure_transmission ;;
                iyuu)         configure_iyuu ;;
                moviepilot)   configure_moviepilot ;;
                vertex)       configure_vertex ;;
                emby)         configure_emby ;;
                jellyfin)     configure_jellyfin ;;
                plex)         configure_plex ;;
            esac
        done

        # MoviePilot 依赖项：PostgreSQL 和 Redis
        if [ "$MP_NEED_PG" -eq 1 ]; then
            configure_postgresql
        fi
        if [ "$MP_NEED_REDIS" -eq 1 ]; then
            configure_redis
        fi

        show_summary

        local has_existing=0
        for key in "${SELECTED[@]}"; do
            if [ "${EXISTING_STATUS[$key]}" != "none" ] && [ -n "${EXISTING_STATUS[$key]}" ]; then
                has_existing=1
                break
            fi
        done
        if [ "$has_existing" -eq 1 ]; then
            WARN "部分选中容器已存在，继续部署将停止并重建现有容器"
        fi

        if ! confirm "确认以上配置并开始部署？" "y"; then
            INFO "已取消部署。"
            continue
        fi

        deploy

        # 刷新容器状态以便下一轮显示
        check_existing_containers
    done
}

main "$@"

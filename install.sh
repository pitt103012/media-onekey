#!/bin/bash
# shellcheck shell=bash
#
# 媒体服务器一键安装 - 引导脚本
# 用法: bash -c "$(curl -fsSL https://你的域名/install.sh)"
#
# ——————————————————————————————————————————————————————————————————————————————————
PATH=${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/opt/homebrew/bin
export PATH

Green="\033[32m"
Red="\033[31m"
Yellow='\033[33m'
Font="\033[0m"
INFO="[${Green}INFO${Font}]"
ERROR="[${Red}ERROR${Font}]"
WARN="[${Yellow}WARN${Font}]"
function INFO() { echo -e "${INFO} ${1}"; }
function ERROR() { echo -e "${ERROR} ${1}"; }
function WARN() { echo -e "${WARN} ${1}"; }

if [[ $EUID -ne 0 ]]; then
    ERROR '此脚本必须以 root 身份运行！'
    exit 1
fi

if [ -f /tmp/media_install.sh ]; then
    rm -rf /tmp/media_install.sh
fi

# ——————————————————————————————————————————————————————————————————————————————————
# 下载主安装脚本（多源回退）
# 请将 BASE_URL 替换为你实际的脚本托管地址
# ——————————————————————————————————————————————————————————————————————————————————
BASE_URL="https://raw.giteeusercontent.com/PITTgogogo/media-onekey/raw/main"

if ! curl -fsSL "${BASE_URL}/media_install.sh" -o /tmp/media_install.sh; then
    ERROR "主脚本下载失败，请检查网络连接或脚本地址！"
    exit 1
fi

INFO "脚本下载成功！"
bash /tmp/media_install.sh "$@"

if [ -f /tmp/media_install.sh ]; then
    rm -rf /tmp/media_install.sh
fi

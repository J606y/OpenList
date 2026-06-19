#!/usr/bin/env bash
# OpenList 定制 fork —— 一键部署 / 更新脚本（Docker + 原生前端构建）
#
# 用法（首次或更新都用同一条）：
#   curl -fsSL https://raw.githubusercontent.com/J606y/OpenList/feat/slim-storage/deploy.sh | bash
# 或克隆后本地跑：
#   ./deploy.sh
#
# 可用环境变量覆盖：GH_USER / BRANCH / BASE_DIR
#   例：BASE_DIR=/opt/openlist bash deploy.sh
#
# 为什么不在 Docker 里编前端：all-in-one 会因 rolldown 原生二进制段错误(exit 139)，
# 所以这里原生 pnpm build 前端，再用 Dockerfile.custom 嵌入。
set -euo pipefail

GH_USER="${GH_USER:-J606y}"
BACKEND_REPO="${BACKEND_REPO:-https://github.com/${GH_USER}/OpenList.git}"
FRONTEND_REPO="${FRONTEND_REPO:-https://github.com/${GH_USER}/OpenList-Frontend.git}"
BRANCH="${BRANCH:-feat/slim-storage}"
BASE_DIR="${BASE_DIR:-$HOME/openlist}"
BACKEND_DIR="$BASE_DIR/OpenList"
FRONTEND_DIR="$BASE_DIR/OpenList-Frontend"

log(){  printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

ensure_git(){ command -v git >/dev/null 2>&1 || { log "安装 git..."; $SUDO apt-get update && $SUDO apt-get install -y git || die "请先安装 git"; }; }

ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    log "安装 Docker..."; curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO usermod -aG docker "$USER" 2>/dev/null || true
  fi
  docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件，请安装 docker-compose-plugin"
  # 当前用户还没进 docker 组时退回 sudo
  DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="$SUDO docker"
}

ensure_node(){
  if command -v node >/dev/null 2>&1 && [ "$(node -v | sed 's/v//;s/\..*//')" -ge 18 ]; then return; fi
  log "安装 Node.js 22..."
  command -v apt-get >/dev/null 2>&1 || die "未检测到 apt；请自行安装 Node.js>=18 后重跑"
  curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
}

ensure_pnpm(){
  command -v pnpm >/dev/null 2>&1 && return
  log "启用 pnpm..."; $SUDO corepack enable 2>/dev/null || $SUDO npm i -g pnpm
  corepack prepare pnpm@latest --activate 2>/dev/null || true
}

clone_or_pull(){ # repo dir [branch]
  local repo="$1" dir="$2" br="${3:-}"
  if [ -d "$dir/.git" ]; then
    log "更新 $(basename "$dir")..."; git -C "$dir" pull --ff-only
  else
    log "克隆 $(basename "$dir")..."
    if [ -n "$br" ]; then git clone -b "$br" "$repo" "$dir"; else git clone "$repo" "$dir"; fi
  fi
}

main(){
  ensure_git; ensure_docker; ensure_node; ensure_pnpm
  mkdir -p "$BASE_DIR"
  clone_or_pull "$BACKEND_REPO"  "$BACKEND_DIR" "$BRANCH"
  clone_or_pull "$FRONTEND_REPO" "$FRONTEND_DIR"

  log "原生构建前端（绕开 Docker 内 rolldown 段错误）..."
  ( cd "$FRONTEND_DIR" && pnpm install && pnpm build )

  log "嵌入前端产物到 public/dist..."
  rm -rf "$BACKEND_DIR/public/dist"
  cp -r "$FRONTEND_DIR/dist" "$BACKEND_DIR/public/dist"

  log "构建并启动容器..."
  export GIT_COMMIT="$(git -C "$BACKEND_DIR" rev-parse --short HEAD 2>/dev/null || echo local)"
  ( cd "$BACKEND_DIR" && $DOCKER compose up -d --build )

  echo
  log "部署完成。容器状态："
  ( cd "$BACKEND_DIR" && $DOCKER compose ps )
  echo
  log "首次启动 → 获取/设置管理员密码："
  echo "  cd $BACKEND_DIR && $DOCKER compose logs openlist | grep -i password"
  echo "  或重设： $DOCKER compose exec openlist ./openlist admin set <新密码>"
  echo
  warn "OpenList 监听 5244。别对公网开放——只在 Oracle 安全列表 + 本地 iptables 放行你两台边缘 IP，由 nginx 反代(proxy_buffering off)。"
}
main "$@"

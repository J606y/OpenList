#!/usr/bin/env bash
# OpenList 定制 fork —— 部署/管理脚本（Docker + 原生前端构建）
#
# 首次安装（全新服务器执行；有终端时会弹出管理面板，选 1 安装）：
#   curl -fsSL https://raw.githubusercontent.com/J606y/OpenList/feat/slim-storage/deploy.sh | bash
#   ↑ 若想更稳地弹出菜单，可改用： bash <(curl -fsSL .../deploy.sh)
#     （无控制终端的纯管道环境如 cloud-init，会自动跳过菜单直接安装）
# 安装后（会软链到 /usr/local/bin/openlist），随处可用：
#   openlist              打开交互管理面板（推荐）
#   openlist update       更新代码并重建
#   openlist restart      重启容器
#   openlist stop|start   停止 / 启动
#   openlist status       查看状态
#   openlist logs         跟踪日志(-f)
#   openlist uninstall    卸载(保留数据卷与代码)；加 --purge 连数据和代码一并删除
# 也可直接： bash deploy.sh <命令>
# 环境变量可覆盖： GH_USER / BRANCH / BASE_DIR
#
# 不在 Docker 内编前端：rolldown 原生二进制会段错误(exit 139)，故原生 pnpm build。
set -euo pipefail

GH_USER="${GH_USER:-J606y}"
BACKEND_REPO="${BACKEND_REPO:-https://github.com/${GH_USER}/OpenList.git}"
FRONTEND_REPO="${FRONTEND_REPO:-https://github.com/${GH_USER}/OpenList-Frontend.git}"
BRANCH="${BRANCH:-feat/slim-storage}"
BASE_DIR="${BASE_DIR:-$HOME/openlist}"

# 若脚本本身位于已安装的后端仓库内(或经软链)，自动定位安装目录
SELF="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  _d="$(cd "$(dirname "$SELF")" && pwd)"
  [ -f "$_d/docker-compose.yml" ] && [ -f "$_d/Dockerfile.custom" ] && BASE_DIR="$(dirname "$_d")"
fi
BACKEND_DIR="$BASE_DIR/OpenList"
FRONTEND_DIR="$BASE_DIR/OpenList-Frontend"

log(){  printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
DOCKER="docker"

# curl|bash 时脚本占用了 stdin，read 读不到键盘输入；若存在控制终端则接管它，让菜单可交互。
ensure_tty(){ [ -t 0 ] || { [ -r /dev/tty ] && exec </dev/tty; }; return 0; }
is_installed(){ [ -d "$BACKEND_DIR/.git" ]; }
# 菜单内的非致命“需已安装”守卫（区别于会 exit 的 require_install）
need_install(){ is_installed || { warn "尚未安装，请先选择 1) 安装 / 重新部署"; return 1; }; }
# 选 docker 调用方式而不 die（菜单用），失败仅 return 1
pick_docker(){ command -v docker >/dev/null 2>&1 || { warn "未检测到 docker，请先安装/部署"; return 1; }; docker info >/dev/null 2>&1 && DOCKER="docker" || DOCKER="$SUDO docker"; return 0; }
# 在 fail-fast 子shell中执行过程性命令：失败只回到菜单，而不退出整个脚本
run(){ ( set -e; "$@" ); }

# 防止 install/update 并发执行互踩 public/dist(需 util-linux 的 flock;无则跳过不阻塞)
acquire_lock(){
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$BASE_DIR/.deploy.lock" 2>/dev/null || return 0
  flock -n 9 || die "已有部署/更新在进行中(锁: $BASE_DIR/.deploy.lock)；请等它结束再试"
}

set_docker(){ command -v docker >/dev/null 2>&1 || die "docker 未安装，请先安装"; DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="$SUDO docker"; }
ensure_git(){ command -v git >/dev/null 2>&1 || { log "安装 git..."; $SUDO apt-get update && $SUDO apt-get install -y git || die "请先装 git"; }; }
ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    log "安装 Docker..."; curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO usermod -aG docker "${USER:-root}" 2>/dev/null || true
  fi
  docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件"
  set_docker
}
ensure_node(){
  if command -v node >/dev/null 2>&1 && [ "$(node -v | sed 's/v//;s/\..*//')" -ge 18 ]; then return; fi
  log "安装 Node.js 22..."
  command -v apt-get >/dev/null 2>&1 || die "未检测到 apt；请自行装 Node>=18 后重跑"
  curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash -
  $SUDO apt-get install -y nodejs
}
ensure_pnpm(){ command -v pnpm >/dev/null 2>&1 && return; log "启用 pnpm..."; $SUDO corepack enable 2>/dev/null || $SUDO npm i -g pnpm; corepack prepare pnpm@latest --activate 2>/dev/null || true; }

clone_or_pull(){ local repo="$1" dir="$2" br="${3:-}";
  if [ -d "$dir/.git" ]; then
    log "更新 $(basename "$dir")..."
    git -C "$dir" fetch --prune origin || die "拉取失败：$dir（检查网络/仓库可达）"
    local ref="origin/HEAD"; [ -n "$br" ] && ref="origin/$br"
    # 部署机以远端为准：硬对齐远端(丢弃本地改动),替代 --ff-only——本地一旦分叉,ff-only 会中断整个更新
    git -C "$dir" reset --hard "$ref" || die "无法对齐 $ref：$dir"
  elif [ -n "$br" ]; then log "克隆 $(basename "$dir")..."; git clone -b "$br" "$repo" "$dir"
  else log "克隆 $(basename "$dir")..."; git clone "$repo" "$dir"; fi; }

compose(){ ( cd "$BACKEND_DIR" && $DOCKER compose "$@" ); }
require_install(){ [ -d "$BACKEND_DIR/.git" ] || die "未找到安装 $BACKEND_DIR，请先安装： curl -fsSL https://raw.githubusercontent.com/${GH_USER}/OpenList/${BRANCH}/deploy.sh | bash"; }

build_and_up(){
  log "原生构建前端（绕开 Docker 内 rolldown 段错误）..."
  ( cd "$FRONTEND_DIR" && pnpm install && pnpm build )
  # 校验产物完整,避免把半个 dist 嵌进去
  [ -f "$FRONTEND_DIR/dist/index.html" ] || die "前端构建产物缺失(dist/index.html)；现有 public/dist 未改动"
  log "嵌入前端到 public/dist（备份旧产物，失败自动回滚）..."
  local dst="$BACKEND_DIR/public/dist" bak="$BACKEND_DIR/public/dist.bak"
  rm -rf "$bak"
  if [ -e "$dst" ]; then mv "$dst" "$bak"; fi
  if ! cp -r "$FRONTEND_DIR/dist" "$dst"; then
    rm -rf "$dst"; if [ -e "$bak" ]; then mv "$bak" "$dst"; fi
    die "嵌入前端失败，已回滚旧产物"
  fi
  log "构建并启动容器..."
  export GIT_COMMIT="$(git -C "$BACKEND_DIR" rev-parse --short HEAD 2>/dev/null || echo local)"
  if ! compose up -d --build; then
    warn "容器构建/启动失败，回滚 public/dist（旧容器若在运行不受影响）"
    rm -rf "$dst"; if [ -e "$bak" ]; then mv "$bak" "$dst"; fi
    die "构建/启动失败，已回滚前端产物；代码已在新版本，如需回退代码： git -C \"$BACKEND_DIR\" reset --hard <旧commit> 后重跑 update"
  fi
  rm -rf "$bak"
}

cmd_install(){
  ensure_git; ensure_docker; ensure_node; ensure_pnpm
  mkdir -p "$BASE_DIR"
  acquire_lock
  clone_or_pull "$BACKEND_REPO"  "$BACKEND_DIR" "$BRANCH"
  clone_or_pull "$FRONTEND_REPO" "$FRONTEND_DIR"
  build_and_up
  $SUDO ln -sf "$BACKEND_DIR/deploy.sh" /usr/local/bin/openlist 2>/dev/null || true
  chmod +x "$BACKEND_DIR/deploy.sh" 2>/dev/null || true
  echo; log "部署完成。"; compose ps; echo
  # 读取首次启动生成的随机管理员密码（轮询日志，最多 ~25s 等服务初始化）
  log "读取管理员账号（首次启动会生成随机密码）..."
  local _logs="" _pw="" _i
  for ((_i=1;_i<=25;_i++)); do
    _logs="$(compose logs openlist 2>&1 || true)"
    _pw="$(printf '%s\n' "$_logs" | grep -F 'initial password is:' | tail -1)"
    [ -n "$_pw" ] && break
    sleep 1
  done
  if [ -n "$_pw" ]; then
    echo; log "管理员账号（首次启动生成，请立即登录并妥善保存）："; printf '    %s\n' "$_pw"
  else
    warn "未捕获到首启密码（多为复用旧数据卷/非首次启动，属正常）：沿用旧账号，或用菜单 8) 重设。"
  fi
  # 探测访问 IP（公网优先，失败回退内网网卡 IP）
  local _ip; _ip="$(curl -fsS4 --max-time 5 ifconfig.me 2>/dev/null || true)"
  [ -z "$_ip" ] && _ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -z "$_ip" ] && _ip="<服务器IP>"
  echo; log "访问地址：  http://${_ip}:5244"
  log "再次管理：  输入  openlist  打开本面板（或 openlist update|restart|logs|status ...）"
  warn "5244 别直接开公网，建议只放行边缘/反代 IP，用 nginx 反代（见 github.com/J606y/nginx-rp）。"
}
cmd_update(){ require_install; set_docker; ensure_node; ensure_pnpm
  acquire_lock
  clone_or_pull "$BACKEND_REPO"  "$BACKEND_DIR" "$BRANCH"
  clone_or_pull "$FRONTEND_REPO" "$FRONTEND_DIR"
  build_and_up
  log "清理悬空镜像..."; $DOCKER image prune -f >/dev/null 2>&1 || true
  log "更新完成。"; compose ps; }
cmd_restart(){ require_install; set_docker; log "重启..."; compose restart; compose ps; }
cmd_stop(){    require_install; set_docker; log "停止..."; compose stop; }
cmd_start(){   require_install; set_docker; log "启动..."; compose up -d; compose ps; }
cmd_status(){  require_install; set_docker; compose ps; }
cmd_logs(){    require_install; set_docker; compose logs -f --tail=100; }
cmd_exec(){    require_install; set_docker; compose exec "$@"; }
cmd_uninstall(){ require_install; set_docker
  if [ "${1:-}" = "--purge" ]; then
    warn "完全卸载：删除容器、镜像、数据卷、代码目录..."
    compose down -v || true
    $DOCKER rmi openlist-custom:latest 2>/dev/null || true
    $SUDO rm -f /usr/local/bin/openlist 2>/dev/null || true
    rm -rf "$BACKEND_DIR" "$FRONTEND_DIR"
    log "已完全卸载（数据已删除）。"
  else
    log "卸载：删除容器和镜像，保留数据卷与代码..."
    compose down || true
    $DOCKER rmi openlist-custom:latest 2>/dev/null || true
    log "已卸载。数据卷 openlist-data 与代码目录保留；彻底清除用： openlist uninstall --purge"
  fi
}

menu(){
  ensure_tty
  set +e   # 交互菜单：单个操作失败只回到菜单，不退出整个脚本
  while true; do
    local st
    if is_installed; then st=$'\033[1;32m● 已安装\033[0m'; else st=$'\033[1;33m○ 未安装\033[0m'; fi
    printf '\n  \033[1;36mOpenList 管理面板\033[0m   %b\n  \033[2m%s\033[0m\n' "$st" "$BASE_DIR"
    cat <<'M'
  ──────────────────────────────
   1) 安装 / 重新部署   （拉取最新代码 + 构建 + 启动）

   2) 更新            3) 重启
   4) 停止            5) 启动
   6) 状态            7) 日志（近200行）
   8) 重设管理员密码
   9) 卸载（保留数据）   10) 彻底卸载（删数据+代码）
   0) 退出
  ──────────────────────────────
M
    printf "  请选择: "; read -r ans || { echo; exit 0; }
    case "$ans" in
      1)  run cmd_install || warn "安装/部署失败，请查看上方错误输出" ;;
      2)  if need_install; then run cmd_update  || warn "更新失败"; fi ;;
      3)  if need_install; then run cmd_restart || warn "重启失败"; fi ;;
      4)  if need_install; then run cmd_stop    || warn "停止失败"; fi ;;
      5)  if need_install; then run cmd_start   || warn "启动失败"; fi ;;
      6)  if need_install && pick_docker; then compose ps; fi ;;
      7)  if need_install && pick_docker; then compose logs --tail=200; fi ;;
      8)  if need_install && pick_docker; then
            printf "  新管理员密码(输入隐藏): "; read -rs pw; echo
            if [ -n "${pw:-}" ]; then compose exec openlist ./openlist admin set "$pw" && log "密码已更新"; else warn "已取消"; fi
          fi ;;
      9)  if need_install; then run cmd_uninstall || warn "卸载失败"; fi ;;
      10) if need_install; then run cmd_uninstall --purge && exit 0 || warn "卸载失败"; fi ;;
      0|q|Q) echo "  再见"; exit 0 ;;
      *) warn "无效选择: $ans"; continue ;;
    esac
    printf "\n  \033[2m按回车返回菜单...\033[0m"; read -r _ || { echo; exit 0; }
  done
}

case "${1:-}" in
  "")  ensure_tty; if [ -t 0 ]; then menu; else cmd_install; fi ;;
  install)        cmd_install ;;
  update|upgrade) cmd_update ;;
  restart)        cmd_restart ;;
  stop)           cmd_stop ;;
  start)          cmd_start ;;
  status|ps)      cmd_status ;;
  logs|log)       cmd_logs ;;
  exec)           shift; cmd_exec "$@" ;;
  uninstall|remove) shift; cmd_uninstall "${1:-}" ;;
  menu)           menu ;;
  -h|--help|help) echo "用法: openlist [menu|install|update|restart|stop|start|status|logs|uninstall [--purge]]；无参数→打开交互管理面板（未安装也可在面板内选 1 安装）" ;;
  *) die "未知命令: $1（openlist --help 查看用法）" ;;
esac

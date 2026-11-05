#!/usr/bin/env bash
# comfyui-tailscale.sh —— 管理走 Tailscale 的 ComfyUI 实例（后台运行 + 自检）
#
# 用法: comfyui-tailscale.sh [start|stop|restart|status|url|logs [-n N]]
#
#   start     后台启动 bin/start-7900xtx-tailscale.sh，输出进
#             logs/comfyui_tailscale_<port>.log；轮到 HTTP 真的应答才返回，
#             然后打印节点实际要访问的地址
#   stop      直接交给 bin/stop-comfyui.sh（TERM → 最多 15s → KILL，再验端口）
#   restart   stop 之后 start
#   status    进程、监听地址、Tailscale 地址、每个 URL 的 HTTP 状态码
#   url       只打印节点用的地址（Tailscale 机器名与 100.64/10 地址）
#   logs      tail -f 日志；logs -n 200 先给 200 行再跟随
#
# 监听地址只由 start-7900xtx-tailscale.sh 决定：回环加 Tailscale 自己的
# 100.64/10 与 fd7a::/64，不含局域网 192.168.1.x（那是 start-7900xtx-v2.sh）。
# ComfyUI 本身没有任何认证，所以可访问范围就等于 Tailscale 网络本身的安全
# 范围；status/url 把这份范围如实打出来，不做假象。
#
# 环境变量: COMFY_PORT（默认 8188）
set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=comfyui-pids.sh
. "${script_dir}/comfyui-pids.sh"   # 进程发现只有这一份，与 stop-comfyui.sh 共用

PORT="${COMFY_PORT:-8188}"
starter="${script_dir}/start-7900xtx-tailscale.sh"
stopper="${script_dir}/stop-comfyui.sh"
log_dir="${COMFY_ROOT}/logs"
log="${log_dir}/comfyui_tailscale_${PORT}.log"

# 文件头就是 help：说明和代码在同一处，不会各自漂走
usage() { sed -ne '2,/^set -uo/p' "$0" | sed -ne '/^#/p'; }
die() { echo "ERROR: $*" >&2; exit 2; }

listening() { ss -ltn 2>/dev/null | grep -q "[:.]${PORT} "; }

# 地址只认 tailscale 命令行；它不给就直说给不了，不从 ss 的输出里猜一个。
ts_ipv4() { command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -n1; }
# 机器名尾部那个点是完整域名写法，人在浏览器里不会打它，这里去掉。
ts_dns()  { command -v tailscale >/dev/null 2>&1 &&
            tailscale status --json 2>/dev/null |
            sed -ne 's/.*"DNSName": "\([^"]*\)".*/\1/p' | head -n1 | sed -e 's/\.$//'; }

# 连不上时 curl 自己就打印 000 并且退出码非零：这里不能再用 `|| echo 000`，
# 那样会拼出 000000，"有没有应答"的判据当场失真（000000 既不是码也不是空）。
http_code() {
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-6}" "$1" 2>/dev/null)
  echo "${c:-000}"
}

do_start() {
  local i code pids
  pids=$(find_pids | tr '\n' ' '); pids=${pids% }
  if listening || [ -n "${pids}" ]; then
    echo "already running: port ${PORT} pid ${pids:-未认出（端口已占）}"
    return 0
  fi
  [ -r "$starter" ] || die "找不到启动脚本 ${starter}"
  mkdir -p "$log_dir"
  # 工作目录取仓库根：进程发现同时按命令行和 cwd 匹配，启动脚本也从这里算路径。
  ( cd "$COMFY_ROOT" && nohup setsid bash "$starter" >>"$log" 2>&1 </dev/null & disown )
  echo "start = 正在启动，日志 ${log}"
  # 判据是一次 HTTP 应答，不是端口：模型加载期间端口早就在听了，只有应答说明
  # 节点那边真能用。300s 覆盖首次加载模型/工作流的时间。
  for i in $(seq 1 300); do
    code=$(http_code "http://127.0.0.1:${PORT}/" 5)
    if [ "${code}" = 000 ]; then sleep 1; continue; fi
    echo "ready = ${i}s 后 http://127.0.0.1:${PORT}/ 应答 ${code}"
    # 进程是刚刚才出现的，启动前查的那一份是空的，这里重查一次。
    pids=$(find_pids | tr '\n' ' '); pids=${pids% }
    echo "pid = ${pids:-未认出}"
    do_url
    return 0
  done
  echo "WARN: 300s 内 ${PORT} 没有应答，见 ${log}" >&2
  tail -n 20 "$log" 2>/dev/null | sed -e 's/^/  /'
  return 1
}

# 停止的口径只在 stop-comfyui.sh 里留一份：这里再抄一遍就是两份会互相漂的
# 超时与判据。
do_stop() {
  [ -r "$stopper" ] || die "找不到停止脚本 ${stopper}"
  COMFY_PORT="${PORT}" bash "$stopper"
}

do_status() {
  local pids ip dns bound u code
  pids=$(find_pids | tr '\n' ' '); pids=${pids% }
  ip=$(ts_ipv4); dns=$(ts_dns)
  if [ -n "${pids}" ]; then echo "state = running (pid ${pids})"
  elif listening; then echo "state = 端口被本脚本认不出的进程占着"
  else echo "state = stopped"; fi
  echo "port = ${PORT}"
  if [ -n "${ip}${dns}" ]; then
    echo "tailscale = ${dns:-无机器名} ${ip:+($ip)}"
  else
    echo "tailscale = 无地址：机器外无法访问，只有本机能开"
  fi
  echo "listen ="
  bound=$(ss -ltn 2>/dev/null | grep "[:.]${PORT} " | awk '{print $4}')
  if [ -n "${bound}" ]; then printf '%s\n' "${bound}" | sed -e 's/^/  /'
  else echo "  无：${PORT} 未监听"; fi
  echo "self-test ="
  # 回环应答只说明本机可用；节点走的是 100.64/10 那条路，得单独测。
  for u in "http://127.0.0.1:${PORT}/" "http://127.0.0.1:${PORT}/history"; do
    code=$(http_code "${u}")
    echo "  ${u} -> ${code}"
  done
  if [ -n "${ip}" ]; then
    for u in "http://${ip}:${PORT}/" "http://${ip}:${PORT}/history"; do
      code=$(http_code "${u}")
      echo "  ${u} -> ${code}"
    done
  fi
  echo "log = ${log}（logs 跟随，logs -n 200 取一段）"
}

do_url() {
  local ip dns
  ip=$(ts_ipv4); dns=$(ts_dns)
  if [ -n "${ip}" ]; then
    echo "url = http://${ip}:${PORT}/"
    [ -n "${dns}" ] && echo "    = http://${dns}:${PORT}/"
  else
    echo "WARN: tailscale 没有地址，节点在机器外访问不到" >&2
  fi
  echo "本机 = http://127.0.0.1:${PORT}/"
  echo "认证 = 无（ComfyUI 不带认证；可访问范围 = 上面的监听地址）"
}

# $2/$3 来自调用者："logs" 直接跟随，"logs -n 200" 先给一段再跟随——远程改
# 完东西想立刻看结果时用的是后者。非数字退回 60。
do_logs() {
  local n=60
  case "${2:-}" in
    n | -n) n="${3:-60}" ;;   # logs -n 200
    -n*) n="${2#-n}" ;;       # logs -n200
  esac
  case "${n}" in '' | *[!0-9]*) n=60 ;; esac
  [ -f "${log}" ] || { echo "没有日志：${log}"; return 1; }
  tail -n "${n}" -f "${log}"
}

case "${1:-status}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop && do_start ;;
  status)  do_status ;;
  url)     do_url ;;
  logs)    do_logs "$@" ;;
  -h|--help|help) usage ;;
  *)       usage; exit 2 ;;
esac

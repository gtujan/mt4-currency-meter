#!/usr/bin/env bash
#
# meterctl.sh - start / stop / restart the Currency Meter bridge server.
#
#   ./meterctl.sh start      launch the bridge in the background
#   ./meterctl.sh stop       stop it
#   ./meterctl.sh restart    stop then start
#   ./meterctl.sh status     show whether it's running + a health check
#   ./meterctl.sh logs       follow the server log (Ctrl-C to stop following)
#   ./meterctl.sh install    install as a launchd daemon (auto-start at boot)
#   ./meterctl.sh uninstall  remove the launchd daemon
#
# Once installed as a daemon, start/stop/restart automatically route through
# launchctl instead of a background process, so you never fight KeepAlive.
# install/uninstall (and start/stop/restart while installed) use sudo; run
# them from a real terminal so the password prompt works.
#
# Defaults are tuned for MT4-under-CrossOver/Wine, which can only reach the
# Mac's LAN IP on port 80:
#   METER_HOST   bind address   (default: auto-detected LAN IP, else 0.0.0.0)
#   METER_PORT   bind port      (default: 80)
# So `./meterctl.sh start` just works - no need to pass anything. Both are
# still overridable, e.g. for a plain local run:
#   METER_HOST=127.0.0.1 METER_PORT=8010 ./meterctl.sh start
# Ports below 1024 need root; this script re-invokes the server under sudo
# automatically in that case.

set -euo pipefail

# Resolve the project directory (where this script lives) so it works from
# anywhere.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON="$DIR/.venv/bin/python"
SERVER="$DIR/bridge/server.py"
LOG="$DIR/server.log"
PATTERN="bridge/server.py"          # what pgrep/pkill match against

# launchd daemon identity/paths.
LABEL="com.currencymeter.bridge"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

# Auto-detect the Mac's LAN IP (the address MT4-under-Wine must POST to).
# Prefer the interface behind the default route, then fall back to the usual
# Wi-Fi/Ethernet interfaces.
detect_ip() {
  local iface ip
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  [ -n "$iface" ] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
  [ -z "${ip:-}" ] && ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [ -z "${ip:-}" ] && ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
  echo "${ip:-}"
}

HOST="${METER_HOST:-$(detect_ip)}"
HOST="${HOST:-0.0.0.0}"             # fall back to all interfaces if no LAN IP
PORT="${METER_PORT:-80}"

# Ports < 1024 require root on macOS. Prefix privileged commands with sudo so
# the server can bind e.g. port 80 for MT4-under-Wine.
SUDO=""
if [ "$PORT" -lt 1024 ]; then
  SUDO="sudo"
fi

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
ok()   { color "32" "$1"; }   # green
warn() { color "33" "$1"; }   # yellow
err()  { color "31" "$1"; }   # red

# Print the PID(s) of any running server, or nothing.
server_pids() {
  pgrep -f "$PATTERN" 2>/dev/null || true
}

is_running() {
  [ -n "$(server_pids)" ]
}

# The daemon is "installed" once its plist is in /Library/LaunchDaemons.
daemon_installed() {
  [ -f "$PLIST_DST" ]
}

do_start() {
  # If installed as a daemon, hand off to launchd rather than spawning our
  # own background process (which launchd's KeepAlive would just duplicate).
  if daemon_installed; then
    echo "daemon installed -> starting via launchctl ..."
    sudo launchctl bootstrap system "$PLIST_DST" 2>/dev/null \
      || sudo launchctl kickstart "system/$LABEL"
    sleep 1
    do_status
    return 0
  fi

  if is_running; then
    echo "$(warn "already running") (PID $(server_pids | tr '\n' ' '))"
    do_status
    return 0
  fi

  if [ ! -x "$PYTHON" ]; then
    echo "$(err "no venv python at $PYTHON")"
    echo "Create it first:  python3 -m venv .venv && .venv/bin/pip install -r bridge/requirements.txt"
    exit 1
  fi

  echo "starting bridge on $(ok "http://$HOST:$PORT") ..."
  if [ -z "${METER_HOST:-}" ] && [ "$HOST" != "0.0.0.0" ]; then
    echo "(auto-detected LAN IP $HOST -- point MT4 at $(ok "http://$HOST$( [ "$PORT" = 80 ] && echo "" || echo ":$PORT" )/tick"))"
  fi
  if [ -n "$SUDO" ]; then
    echo "(port $PORT < 1024 -> using sudo; you may be prompted for your password)"
  fi

  # nohup + background so it survives this shell. sudo drops the activated
  # venv, so we pass the env vars through explicitly and call the venv python
  # by absolute path.
  $SUDO env METER_HOST="$HOST" METER_PORT="$PORT" \
    nohup "$PYTHON" "$SERVER" >>"$LOG" 2>&1 &

  # Give it a moment to bind (or fail).
  sleep 1
  if is_running; then
    echo "$(ok "started") (PID $(server_pids | tr '\n' ' ')), logging to $LOG"
    do_status
  else
    echo "$(err "failed to start") - last log lines:"
    tail -n 15 "$LOG" 2>/dev/null || true
    exit 1
  fi
}

do_stop() {
  # Daemon mode: bootout unloads it (and, with KeepAlive, that's the only way
  # to make it stay down until the next boot or an explicit start).
  if daemon_installed; then
    echo "daemon installed -> stopping via launchctl (bootout) ..."
    sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
    sleep 1
    do_status
    return 0
  fi

  if ! is_running; then
    echo "$(warn "not running")"
    return 0
  fi
  echo "stopping (PID $(server_pids | tr '\n' ' ')) ..."
  # A port-80 server runs as root, so a plain pkill can't touch it. Try
  # without sudo first (covers the common 8010 case with no password
  # prompt); if anything survives, it's root-owned, so escalate to sudo.
  pkill -f "$PATTERN" 2>/dev/null || true
  sleep 1
  if is_running; then
    echo "(escalating to sudo for root-owned server; you may be prompted)"
    sudo pkill -f "$PATTERN" || true
  fi
  # Wait up to ~5s for it to exit, then escalate to SIGKILL.
  for _ in 1 2 3 4 5; do
    is_running || break
    sleep 1
  done
  if is_running; then
    echo "$(warn "did not exit, sending SIGKILL")"
    pkill -9 -f "$PATTERN" 2>/dev/null || true
    sudo pkill -9 -f "$PATTERN" 2>/dev/null || true
    sleep 1
  fi
  if is_running; then
    echo "$(err "still running") (PID $(server_pids | tr '\n' ' '))"
    exit 1
  fi
  echo "$(ok "stopped")"
}

do_status() {
  if is_running; then
    echo "server: $(ok "running") (PID $(server_pids | tr '\n' ' '))"
  else
    echo "server: $(err "stopped")"
    return 0
  fi
  # Health-check the port the server is *actually* on: prefer METER_PORT as
  # seen on the running process's command line (that's how do_start launches
  # it), falling back to this invocation's configured PORT.
  local port host
  port="$(ps -Ao args 2>/dev/null | grep "$PATTERN" | grep -oE 'METER_PORT=[0-9]+' | head -1 | cut -d= -f2)"
  port="${port:-$PORT}"
  host="$HOST"
  # Can't curl a wildcard bind address; hit loopback instead.
  [ "$host" = "0.0.0.0" ] && host="127.0.0.1"
  local url="http://$host:$port/state"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null)"
  code="${code:-000}"
  if [ "$code" = "200" ]; then
    echo "health: $(ok "OK")  ($url -> 200)"
  else
    echo "health: $(warn "no response")  ($url -> $code)"
  fi
}

do_logs() {
  if [ ! -f "$LOG" ]; then
    echo "$(warn "no log file yet at $LOG")"
    exit 0
  fi
  echo "following $LOG (Ctrl-C to stop) ..."
  tail -n 30 -f "$LOG"
}

# Install as a launchd daemon: generate the plist from the current config,
# drop it in /Library/LaunchDaemons, and bootstrap it so it runs now and at
# every boot. Binds 0.0.0.0 by default so it survives DHCP IP changes without
# a reload (override by setting METER_HOST before running install).
do_install() {
  if daemon_installed; then
    echo "$(warn "already installed") at $PLIST_DST"
    echo "Use '$0 restart' to reload, or '$0 uninstall' first to reinstall."
    return 0
  fi
  if [ ! -x "$PYTHON" ]; then
    echo "$(err "no venv python at $PYTHON")"
    echo "Create it first:  python3 -m venv .venv && .venv/bin/pip install -r bridge/requirements.txt"
    exit 1
  fi

  local dhost dport
  dhost="${METER_HOST:-0.0.0.0}"    # daemons prefer all-interfaces (DHCP-proof)
  dport="${METER_PORT:-80}"

  echo "installing daemon $LABEL (bind $dhost:$dport) ..."
  echo "(needs sudo; you may be prompted for your password)"

  # Free port 80 from any manually-started instance so the daemon can bind.
  pkill -f "$PATTERN" 2>/dev/null || true
  sudo pkill -f "$PATTERN" 2>/dev/null || true

  # Generate the plist to a temp file, then install it root-owned.
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$SERVER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>METER_HOST</key>
    <string>$dhost</string>
    <key>METER_PORT</key>
    <string>$dport</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
PLIST

  sudo cp "$tmp" "$PLIST_DST"
  rm -f "$tmp"
  sudo chown root:wheel "$PLIST_DST"
  sudo chmod 644 "$PLIST_DST"
  sudo launchctl bootstrap system "$PLIST_DST"

  sleep 1
  if is_running; then
    echo "$(ok "installed and running") -> $PLIST_DST"
    echo "It now starts automatically at boot. Manage with: $0 {start|stop|restart|status|logs|uninstall}"
    do_status
  else
    echo "$(err "installed but not running") - last log lines:"
    tail -n 15 "$LOG" 2>/dev/null || true
    exit 1
  fi
}

do_uninstall() {
  if ! daemon_installed; then
    echo "$(warn "not installed") (no $PLIST_DST)"
    return 0
  fi
  echo "uninstalling daemon $LABEL ..."
  echo "(needs sudo; you may be prompted for your password)"
  sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
  sudo rm -f "$PLIST_DST"
  sleep 1
  if daemon_installed; then
    echo "$(err "failed to remove") $PLIST_DST"
    exit 1
  fi
  echo "$(ok "uninstalled"). The server is stopped and will not start at boot."
  echo "Run '$0 start' to launch it manually again."
}

usage() {
  echo "usage: $0 {start|stop|restart|status|logs|install|uninstall}"
  exit 2
}

case "${1:-}" in
  start)     do_start ;;
  stop)      do_stop ;;
  restart)
    if daemon_installed; then
      echo "daemon installed -> restarting via launchctl ..."
      sudo launchctl bootstrap system "$PLIST_DST" 2>/dev/null || true
      sudo launchctl kickstart -k "system/$LABEL"
      sleep 1
      do_status
    else
      do_stop; echo; do_start
    fi
    ;;
  status)    do_status ;;
  logs)      do_logs ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
  *)         usage ;;
esac

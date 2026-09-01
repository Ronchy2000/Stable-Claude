#!/usr/bin/env bash
set -euo pipefail

# Read-only preflight and verification. It never installs, stops, deletes, or
# rewrites anything. Run as the non-root SSH user; use sudo only when the
# command being inspected requires it.

mode=preflight
[ $# -ge 1 ] && mode=$1
browser_port=3010
code_port=8080
[ $# -ge 2 ] && browser_port=$2
[ $# -ge 3 ] && code_port=$3

failures=0
warnings=0

say() {
  printf '%s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN: %s\n' "$1" >&2
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

port_listeners() {
  local port=$1
  if have ss; then
    ss -H -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print}'
  fi
}

check_loopback_port() {
  local port=$1 label=$2 lines
  lines=$(port_listeners "$port")
  if [ -z "$lines" ]; then
    fail "$label port $port is not listening"
    return
  fi
  printf '%s\n' "$lines"
  if printf '%s\n' "$lines" | grep -Eq '0\.0\.0\.0|\[::\]|:::|^\*:'; then
    fail "$label port $port is not loopback-only"
  else
    say "$label port $port is loopback-only"
  fi
}

check_unit() {
  local unit=$1 required=$2
  if ! have systemctl; then
    warn "systemctl unavailable; verify $unit on the Ubuntu host"
    return
  fi
  if ! systemctl cat "$unit" >/dev/null 2>&1; then
    if [ "$required" = yes ]; then
      fail "missing systemd unit: $unit"
    else
      warn "optional systemd unit is not installed: $unit"
    fi
    return
  fi
  if systemctl is-active --quiet "$unit"; then
    say "active: $unit"
  else
    if [ "$required" = yes ]; then
      fail "inactive: $unit"
    else
      warn "inactive optional unit: $unit"
    fi
  fi
}

preflight() {
  say "Claude Workspace preflight (read-only)"
  say "mode=preflight browser_port=$browser_port code_port=$code_port"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    say "os=$PRETTY_NAME"
  else
    warn "cannot read /etc/os-release"
  fi
  say "arch=$(uname -m)"
  say "user=$(id -un) uid=$(id -u) groups=$(id -Gn)"
  say "cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown)"
  if have free; then free -h | sed -n '1,3p'; fi
  if have df; then df -h / /srv 2>/dev/null || df -h /; fi

  [ "$(id -u)" -eq 0 ] && warn "running as root; deployment must use a non-root service user"
  for command in systemctl ss curl docker cloudflared; do
    if have "$command"; then
      say "found=$command"
    else
      warn "missing command=$command (the AI may install only the required package)"
    fi
  done

  if [ -n "$(port_listeners "$browser_port")" ]; then
    warn "browser port $browser_port is already occupied; do not take it"
    port_listeners "$browser_port"
  else
    say "browser port $browser_port is free"
  fi
  if [ -n "$(port_listeners "$code_port")" ]; then
    warn "code-server port $code_port is already occupied; do not take it"
    port_listeners "$code_port"
  else
    say "code-server port $code_port is free"
  fi

  if have docker; then
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || \
      warn "docker is installed but current user cannot inspect it"
    docker network ls 2>/dev/null || true
  fi

  for path in /opt/claude-workspace /srv/claude-workspace; do
    if [ -e "$path" ]; then
      warn "workspace path already exists: $path; inspect ownership and provenance before changing it"
    else
      say "workspace path is unused: $path"
    fi
  done

  for unit in claude-workspace-chromium.service \
              code-server-claude-workspace.service \
              cloudflared-claude-workspace.service; do
    check_unit "$unit" no
  done

  say "preflight=complete (warnings=$warnings)"
}

verify() {
  say "Claude Workspace verify (read-only)"
  say "mode=verify browser_port=$browser_port code_port=$code_port"
  check_unit claude-workspace-chromium.service yes
  check_unit code-server-claude-workspace.service yes
  check_unit cloudflared-claude-workspace.service yes
  check_loopback_port "$browser_port" chromium
  check_loopback_port "$code_port" code-server

  if have curl; then
    for url in "http://127.0.0.1:$browser_port/" \
               "http://127.0.0.1:$code_port/healthz"; do
      status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" || printf 000)
      case "$status" in
        2??|3??|401|403) say "http_ok=$url status=$status" ;;
        *) fail "unexpected local response: $url status=$status" ;;
      esac
    done
    ready=$(curl -sS --max-time 5 http://127.0.0.1:20001/ready 2>/dev/null || true)
    [ -n "$ready" ] && say "tunnel_ready=$ready" || warn "Tunnel ready endpoint unavailable"
  fi

  if have docker; then
    if docker inspect claude-workspace-chromium >/dev/null 2>&1; then
      docker inspect claude-workspace-chromium \
        --format 'container={{.Name}} network={{range $name, $value := .NetworkSettings.Networks}}{{$name}} {{end}} restart={{.HostConfig.RestartPolicy.Name}}' \
        2>/dev/null || fail "cannot inspect Chromium container"
    else
      fail "Chromium container claude-workspace-chromium not found"
    fi
  else
    fail "docker command unavailable"
  fi

  if have nft; then
    nft list table inet claude_workspace >/dev/null 2>&1 || \
      warn "optional dedicated-user nftables table is not installed"
  fi

  if [ "$failures" -eq 0 ]; then
    say "verify=ok warnings=$warnings"
  else
    say "verify=failed failures=$failures warnings=$warnings"
    return 1
  fi
}

case "$mode" in
  preflight) preflight ;;
  verify) verify ;;
  *)
    say "usage: $0 [preflight|verify] [browser-port] [code-port]" >&2
    exit 2
    ;;
esac

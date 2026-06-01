#!/usr/bin/env bash
# Security regression guard for the REAPER bridges.
#
# Fails if patterns that previous audits removed reappear, so CI / pre-commit
# catches a regression before it ships. Portable ERE (works with GNU and BSD grep).
set -uo pipefail

cd "$(dirname "$0")/.."

LUA_FILES=(reaper_mcp_bridge.lua reaper_web_server.lua)
ALL_BRIDGE_FILES=(reaper_mcp_bridge.lua reaper_web_server.lua reaper_mcp_server.py)

fail=0

guard() {
  local desc="$1"; shift
  local pattern="$1"; shift
  local matches
  matches="$(grep -nE "$pattern" "$@" 2>/dev/null)"
  if [ -n "$matches" ]; then
    echo "SECURITY GUARD FAILED: $desc"
    echo "$matches"
    echo
    fail=1
  fi
}

# Lua dynamic code execution (the previously-fixed load()-based RCE).
guard "Lua dynamic code execution (load/loadstring/dofile)" \
  '(^|[^[:alnum:]_])(load|loadstring|dofile)[[:space:]]*\(' "${LUA_FILES[@]}"

# Lua shelling out.
guard "Lua shell-out (os.execute / io.popen)" \
  '(os\.execute|io\.popen)' "${LUA_FILES[@]}"

# Generic dispatch fallback (must stay a strict allowlist).
guard "Generic reaper[fname] dispatch fallback" \
  'reaper\[fname\][[:space:]]*\(' "${LUA_FILES[@]}"

# Wildcard CORS on the localhost control plane (matches both the HTTP header
# `Access-Control-Allow-Origin: *` and the Python `send_header(..., '*')` forms).
guard "Wildcard CORS (Access-Control-Allow-Origin: *)" \
  'Access-Control-Allow-Origin.*\*' "${ALL_BRIDGE_FILES[@]}"

if [ "$fail" -ne 0 ]; then
  echo "One or more security guards tripped (see matches above)."
  exit 1
fi
echo "Security guard passed: no dangerous patterns found."

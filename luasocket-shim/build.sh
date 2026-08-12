#!/usr/bin/env bash
#
# Build LuaSocket against REAPER's own embedded Lua and install it where the
# HTTP bridge looks for it.
#
# Stock LuaSocket cannot work inside REAPER: REAPER links Lua statically and
# keeps the C API symbols local, so the module cannot bind them, and linking
# liblua in instead puts a second Lua runtime in the process that misreads
# REAPER's strings. This build force-includes reaper_lua_shim.h into every
# LuaSocket source, so each lua_*/luaL_* call goes through a pointer resolved
# from REAPER's Mach-O symbol table at load time. One runtime, no corruption.
#
# macOS only. Needs clang (Xcode command line tools) and Lua 5.4 headers.
#
#   ./build.sh                 build and install
#   ./build.sh --no-install    build into ./build only
#
# Overrides: LUA_INC, LUASOCKET_SRC, REAPER_APP, REAPER_RESOURCE_PATH, ARCHS

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"

LUASOCKET_VERSION="3.1.0"
LUASOCKET_SHA256="bf033aeb9e62bcaa8d007df68c119c966418e8c9ef7e4f2d7e96bddeca9cca6e"
LUASOCKET_URL="https://github.com/lunarmodules/luasocket/archive/refs/tags/v${LUASOCKET_VERSION}.tar.gz"

REAPER_APP="${REAPER_APP:-/Applications/REAPER.app}"
REAPER_BIN="$REAPER_APP/Contents/MacOS/REAPER"
REAPER_RESOURCE_PATH="${REAPER_RESOURCE_PATH:-$HOME/Library/Application Support/REAPER}"
INSTALL_DIR="$REAPER_RESOURCE_PATH/Scripts/luasocket"

# REAPER ships x86_64 + arm64; match it so the module loads under either.
ARCHS="${ARCHS:--arch arm64 -arch x86_64}"

INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

die() { echo "error: $*" >&2; exit 1; }

# --- prerequisites ---------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "macOS only: the shim reads Mach-O symbol tables."
command -v clang >/dev/null || die "clang not found. Install the Xcode command line tools: xcode-select --install"
[ -x "$REAPER_BIN" ] || die "REAPER not found at $REAPER_BIN (set REAPER_APP)."

if [ -z "${LUA_INC:-}" ]; then
  for candidate in \
    /opt/homebrew/opt/lua@5.4/include/lua5.4 \
    /usr/local/opt/lua@5.4/include/lua5.4 \
    /opt/homebrew/include/lua5.4 \
    /usr/local/include/lua5.4; do
    [ -f "$candidate/lua.h" ] && { LUA_INC="$candidate"; break; }
  done
fi
[ -n "${LUA_INC:-}" ] && [ -f "$LUA_INC/lua.h" ] || die \
  "Lua 5.4 headers not found. Install them (brew install lua@5.4) or set LUA_INC.
   They are used for declarations only -- no Lua library is linked in."

grep -q 'LUA_VERSION_NUM.*504' "$LUA_INC/lua.h" || die \
  "$LUA_INC is not Lua 5.4. REAPER embeds 5.4 and the ABI must match."

# --- REAPER must still be unstripped ---------------------------------------
# Resolution is by symbol name, which is stable, but a stripped build would
# leave nothing to resolve. Check before spending time on a compile.

echo "==> checking REAPER's symbol table"
host_arch="$(uname -m)"
found_syms="$(nm -arch "$host_arch" "$REAPER_BIN" 2>/dev/null \
  | awk '$2=="t" || $2=="T" {print $3}' | grep -cE '^_lua_tolstring$|^_luaL_addlstring$|^_lua_pushinteger$' || true)"
[ "${found_syms:-0}" -ge 3 ] || die \
  "REAPER ($host_arch) does not expose Lua symbols in its symbol table.
   This build of REAPER appears to be stripped, so the shim cannot work.
   Use the file bridge (reaper_mcp_bridge.lua) instead."
echo "    ok: Lua C API symbols present"

if pgrep -x REAPER >/dev/null 2>&1; then
  echo "    note: REAPER is running. Quit it before installing, or it will keep"
  echo "          using the copy already loaded."
fi

# --- source ----------------------------------------------------------------

mkdir -p "$BUILD"
if [ -n "${LUASOCKET_SRC:-}" ]; then
  SRC="$LUASOCKET_SRC"
else
  SRC="$BUILD/luasocket-$LUASOCKET_VERSION/src"
  if [ ! -d "$SRC" ]; then
    echo "==> fetching LuaSocket $LUASOCKET_VERSION"
    tarball="$BUILD/luasocket-$LUASOCKET_VERSION.tar.gz"
    curl -fsSL -o "$tarball" "$LUASOCKET_URL" || die "download failed: $LUASOCKET_URL"
    actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    [ "$actual" = "$LUASOCKET_SHA256" ] || die \
      "checksum mismatch for $tarball
   expected $LUASOCKET_SHA256
   got      $actual"
    tar xzf "$tarball" -C "$BUILD"
  fi
fi
[ -f "$SRC/luasocket.c" ] || die "LuaSocket sources not found in $SRC"

# --- build -----------------------------------------------------------------

OBJ="$BUILD/obj"
OUT="$BUILD/out"
rm -rf "$OBJ" "$OUT"
mkdir -p "$OBJ" "$OUT/socket" "$OUT/mime"

# UNIX_HAS_SUN_LEN and LUASOCKET_DEBUG match what luarocks uses on macOS.
CFLAGS="$ARCHS -O2 -fPIC -Wall -DUNIX_HAS_SUN_LEN -DLUASOCKET_DEBUG -I$LUA_INC -I$SRC -I$HERE"

echo "==> compiling shim"
# Not force-included: the shim defines REAPER_LUA_SHIM_IMPL so it sees the real
# API names. Built once per module so each bundle carries only its own entry.
clang $CFLAGS -DREAPER_SHIM_ENTRY_SOCKET -c -o "$OBJ/shim_socket.o" "$HERE/reaper_lua_shim.c"
clang $CFLAGS -DREAPER_SHIM_ENTRY_MIME   -c -o "$OBJ/shim_mime.o"   "$HERE/reaper_lua_shim.c"

echo "==> compiling LuaSocket"
SOCKET_SRCS="luasocket timeout buffer io auxiliar options inet except select tcp udp compat usocket"
for f in $SOCKET_SRCS mime; do
  clang $CFLAGS -include "$HERE/reaper_lua_shim.h" -c -o "$OBJ/$f.o" "$SRC/$f.c"
done

SOCKET_OBJS=""
for f in $SOCKET_SRCS; do SOCKET_OBJS="$SOCKET_OBJS $OBJ/$f.o"; done

echo "==> linking"
# No liblua and no -undefined dynamic_lookup: the bundles must have zero
# undefined Lua symbols, or we are back to one of the two broken builds.
clang $ARCHS -bundle -o "$OUT/socket/core.so" $SOCKET_OBJS "$OBJ/shim_socket.o"
clang $ARCHS -bundle -o "$OUT/mime/core.so" "$OBJ/mime.o" "$OBJ/compat.o" "$OBJ/shim_mime.o"

# Hard gate: an undefined lua symbol here means the shim did not take effect,
# and the module would fail to load inside REAPER exactly as a stock build does.
for so in "$OUT/socket/core.so" "$OUT/mime/core.so"; do
  leftover="$(nm -u "$so" | grep -E '_lua[A-Z_]|_luaL_' || true)"
  [ -z "$leftover" ] || die "unresolved Lua symbols in $so:
$leftover"
done
echo "    ok: no undefined Lua symbols"

cp "$SRC/socket.lua" "$SRC/mime.lua" "$SRC/ltn12.lua" "$OUT/"
for m in http url tp ftp headers smtp; do cp "$SRC/$m.lua" "$OUT/socket/$m.lua"; done

# --- install ---------------------------------------------------------------

if [ "$INSTALL" -eq 1 ]; then
  echo "==> installing to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/socket" "$INSTALL_DIR/mime"
  cp "$OUT/socket/core.so" "$INSTALL_DIR/socket/core.so"
  cp "$OUT/mime/core.so"   "$INSTALL_DIR/mime/core.so"
  cp "$OUT/socket.lua" "$OUT/mime.lua" "$OUT/ltn12.lua" "$INSTALL_DIR/"
  for m in http url tp ftp headers smtp; do cp "$OUT/socket/$m.lua" "$INSTALL_DIR/socket/$m.lua"; done
  echo
  echo "Installed. reaper_web_server.lua adds this directory to package.cpath,"
  echo "so require(\"socket\") now resolves inside REAPER."
else
  echo
  echo "Built in $OUT (not installed)."
fi

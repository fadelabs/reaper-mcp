# LuaSocket symbol shim for REAPER

Builds LuaSocket so it runs inside REAPER, which makes the HTTP transport
(`reaper_web_server.lua`) usable. Without it, only the file bridge works.

macOS only.

```sh
./build.sh
```

Then quit and relaunch REAPER. `reaper_web_server.lua` adds the install
directory to `package.cpath` itself, so nothing else needs configuring.

## Why a shim is needed

REAPER embeds Lua 5.4, and a native Lua module has to call back into that
runtime. Two obvious routes both fail:

| Approach | Result |
|---|---|
| Stock build (luarocks, lunarmodules) | Will not open. Upstream links `core.so` expecting the host to export Lua's C symbols. The standalone `lua` binary does; REAPER links Lua statically and exports nothing, so `dlopen` fails with `symbol not found in flat namespace '_luaL_addlstring'`. |
| Static-link `liblua.a` into `core.so` | Opens, and sockets genuinely work — but a second Lua runtime is now in the process. Strings allocated by REAPER's Lua are misread by the embedded copy: a 30-byte send returns 30, a **300-byte send returns 0** and the data is dropped silently. Lua's short-string cutoff is 40 bytes, so every real HTTP response vanishes. Worse than not loading. |

The symbols REAPER needs are present in its binary — they are just local rather
than exported, which is why the dynamic linker cannot bind them:

```
$ nm -arch arm64 /Applications/REAPER.app/Contents/MacOS/REAPER | grep _lua_tolstring
0000000100770930 t _lua_tolstring          # 't' = local, not 'T' = exported
```

So the shim reads them out of the host's Mach-O symbol table at module load,
and routes LuaSocket's Lua C API calls through the resulting pointers. One Lua
runtime, so the long-string corruption cannot happen.

## How it works

- `reaper_lua_shim.h` declares one function pointer per Lua C API symbol
  LuaSocket references, typed from the real prototypes, then `#define`s the API
  names onto those pointers. `build.sh` force-includes it (`clang -include`)
  ahead of LuaSocket's own includes.
- `reaper_lua_shim.c` walks the main executable's `LC_SYMTAB` at load time,
  rebasing through `__LINKEDIT`, and fills every pointer in one pass. It is
  read-only: nothing in the host process is modified.
- The real `luaopen_socket_core` / `luaopen_mime_core` are shim wrappers. They
  resolve first, then call LuaSocket's own entry point.
- `build.sh` links with no `liblua` and no `-undefined dynamic_lookup`, then
  fails the build if any undefined `lua_*` symbol is left in the bundle.

### Guards

- **ABI check.** After resolving, the shim calls the host's
  `luaL_checkversion_`, which rejects a mismatched Lua version or differing
  `lua_Number` / `lua_Integer` widths, and separately confirms the host's
  `LUAL_BUFFERSIZE` matches the headers. A layout mismatch would otherwise
  corrupt memory silently — the exact failure this shim exists to prevent.
- **Fail-safe.** If the host is stripped or a symbol is missing, the module
  refuses to load instead of calling through a null pointer. REAPER stays up
  and `reaper_web_server.lua` prints its "use the file bridge" guidance.

### `lua_settable`

Not resolvable: REAPER's own code never calls it, so the linker dead-stripped
it. The shim maps it to `lua_rawset`. Every LuaSocket call site targets a plain
table it created itself with `lua_newtable` and never gave a metatable —
upstream already uses `lua_rawset` on that same module table in `base_open()`
and `select_open()` — so the two are equivalent there.

## Regenerating the header

`reaper_lua_shim.h` is generated from the symbols LuaSocket actually
references. After a LuaSocket version bump:

```sh
# compile the sources once, list what they leave undefined, regenerate
nm -u build/obj/*.o | grep -oE '_lua[A-Za-z_]+' | sed 's/^_//' | sort -u > /tmp/lua_syms.txt
python3 gen_shim_header.py /tmp/lua_syms.txt reaper_lua_shim.h
```

If a newly referenced symbol is missing from REAPER, the build fails at the
undefined-symbol gate rather than at runtime.

## Limitations

- macOS only. Windows and Linux need a different symbol-table walk.
- Unsupported by Cockos, and depends on REAPER shipping unstripped. Resolution
  is by symbol name, which is stable, so routine updates should be fine; a
  stripped build degrades to the file bridge rather than breaking.
- The bundle is unsigned. Building locally avoids Gatekeeper entirely.

## Verified

Built universal (arm64 + x86_64) against LuaSocket 3.1.0, loaded into REAPER
7.x on macOS 26 (arm64). The HTTP bridge serves requests, and responses well
past the 40-byte threshold arrive byte-exact — a 4095-character track name
round-trips intact in a 4168-byte response.

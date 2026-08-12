/*
 * reaper_lua_shim.c -- resolve REAPER's Lua C API at module load.
 *
 * REAPER links Lua 5.4 statically and does not export its symbols, so the
 * dynamic linker cannot bind them.  They are still present with real addresses
 * in the (unstripped) binary, so we read the host executable's own Mach-O
 * symbol table and take the addresses from there.  LuaSocket then calls
 * straight into REAPER's runtime -- one Lua state, one string table, no
 * embedded second copy to misread REAPER's strings.
 *
 * Nothing here is written to the host process: the symbol table is mapped
 * read-only as part of __LINKEDIT and only read.
 */

#define REAPER_LUA_SHIM_IMPL
#include "reaper_lua_shim.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

/* Storage for the resolved entry points. */
#define REAPER_LUA_SHIM_DEFINE(name) __typeof__(name) *reaper_p_##name = NULL;
REAPER_LUA_SHIM_SYMBOLS(REAPER_LUA_SHIM_DEFINE)
#undef REAPER_LUA_SHIM_DEFINE

/* Name -> slot, so one pass over the symbol table fills everything. */
typedef struct {
    const char *name;
    void **slot;
} shim_entry;

#define REAPER_LUA_SHIM_ENTRY(name) { #name, (void **)&reaper_p_##name },
static shim_entry shim_table[] = {
    REAPER_LUA_SHIM_SYMBOLS(REAPER_LUA_SHIM_ENTRY)
};
#undef REAPER_LUA_SHIM_ENTRY

#define SHIM_COUNT ((int)(sizeof(shim_table) / sizeof(shim_table[0])))

/* Locate the main executable (REAPER itself) and its ASLR slide. */
static const struct mach_header_64 *shim_host_image(intptr_t *slide_out)
{
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *h =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (h && h->magic == MH_MAGIC_64 && h->filetype == MH_EXECUTE) {
            *slide_out = _dyld_get_image_vmaddr_slide(i);
            return h;
        }
    }
    return NULL;
}

/*
 * Walk the host's symbol table once, filling every slot whose name matches.
 * Returns the number of symbols resolved.
 */
static int shim_resolve_all(void)
{
    intptr_t slide = 0;
    const struct mach_header_64 *hdr = shim_host_image(&slide);
    if (!hdr) return 0;

    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;

    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)hdr + sizeof(*hdr));
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    /* A stripped binary has no LC_SYMTAB worth reading -- bail out cleanly. */
    if (!symtab || !linkedit || symtab->nsyms == 0) return 0;

    /* symoff/stroff are file offsets; __LINKEDIT's vmaddr/fileoff pair rebases
     * them into the loaded image. */
    uintptr_t base = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr
                   - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);

    int found = 0;
    for (uint32_t i = 0; i < symtab->nsyms && found < SHIM_COUNT; i++) {
        uint32_t strx = syms[i].n_un.n_strx;
        if (strx == 0 || strx >= symtab->strsize) continue;
        if ((syms[i].n_type & N_STAB) != 0) continue;          /* debug entry */
        if ((syms[i].n_type & N_TYPE) != N_SECT) continue;     /* not defined here */
        if (syms[i].n_value == 0) continue;

        const char *sname = strs + strx;
        if (sname[0] != '_') continue;                          /* C symbols are _name */
        sname++;
        if (sname[0] != 'l') continue;                          /* cheap prefilter */

        for (int e = 0; e < SHIM_COUNT; e++) {
            if (*shim_table[e].slot) continue;
            if (strcmp(shim_table[e].name, sname) != 0) continue;
            *shim_table[e].slot = (void *)((uintptr_t)syms[i].n_value + (uintptr_t)slide);
            found++;
            break;
        }
    }
    return found;
}

/*
 * Confirm the host's Lua really has the ABI our headers were compiled against.
 * Mismatched lua_Number/lua_Integer widths or a different LUAL_BUFFERSIZE
 * would corrupt memory silently, which is exactly the failure mode this whole
 * shim exists to avoid.
 */
static int shim_check_abi(lua_State *L)
{
    luaL_Buffer b;

    /* Raises a Lua error if the version or the numeric sizes disagree. */
    reaper_p_luaL_checkversion_(L, LUA_VERSION_NUM, LUAL_NUMSIZES);

    /* luaL_buffinit only fills the header fields and sets size to the host's
     * LUAL_BUFFERSIZE; it touches no Lua stack slot, so this is safe to run
     * and discard. */
    reaper_p_luaL_buffinit(L, &b);
    if (b.size != (size_t)LUAL_BUFFERSIZE) return 0;

    return 1;
}

int reaper_lua_shim_init(lua_State *L)
{
    static int ready = 0;
    if (ready) return 1;

    if (shim_resolve_all() != SHIM_COUNT) return 0;
    if (!shim_check_abi(L)) return 0;

    ready = 1;
    return 1;
}

void reaper_shim_lua_settable(lua_State *L, int idx)
{
    /* See the header: every LuaSocket call site targets a metatable-free table
     * it created itself, so a raw set matches lua_settable exactly. */
    reaper_p_lua_rawset(L, idx);
}

/* ------------------------------------------------------------------------ */
/* Entry points.  Lua calls these; they resolve, then hand off to LuaSocket.  */
/*                                                                            */
/* This file is compiled once per module -- each bundle links only its own    */
/* entry point, so socket/core.so does not end up referencing mime's.         */
/* ------------------------------------------------------------------------ */

static int shim_unavailable(lua_State *L)
{
    static const char *msg =
        "LuaSocket shim: could not resolve Lua's C API inside REAPER "
        "(host binary stripped, or an incompatible REAPER build). "
        "Use the file bridge instead.";

    /* Report properly if we got far enough to have the two calls we need. */
    if (reaper_p_lua_pushstring && reaper_p_lua_error) {
        reaper_p_lua_pushstring(L, msg);
        reaper_p_lua_error(L);  /* does not return */
    }
    return 0;
}

#if defined(REAPER_SHIM_ENTRY_SOCKET)
int reaper_ls_luaopen_socket_core(lua_State *L);

int luaopen_socket_core(lua_State *L)
{
    if (!reaper_lua_shim_init(L)) return shim_unavailable(L);
    return reaper_ls_luaopen_socket_core(L);
}
#elif defined(REAPER_SHIM_ENTRY_MIME)
int reaper_ls_luaopen_mime_core(lua_State *L);

int luaopen_mime_core(lua_State *L)
{
    if (!reaper_lua_shim_init(L)) return shim_unavailable(L);
    return reaper_ls_luaopen_mime_core(L);
}
#else
#error "define REAPER_SHIM_ENTRY_SOCKET or REAPER_SHIM_ENTRY_MIME"
#endif

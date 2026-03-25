vcpkg_from_gitlab(
    GITLAB_URL https://gitlab.freedesktop.org/
    OUT_SOURCE_PATH SOURCE_PATH
    REPO slirp/libslirp
    REF "v${VERSION}"
    SHA512 cdb66f6280a9982de3c32269aee352bdf225db918590255abaed9bcd0aee4e996d2d8c2c3f62473f57485603ec29fd35723b0649d3ec3c41cc28b22ce913f63b
    HEAD_REF master
)

if(VCPKG_TARGET_IS_IOS)
    set(x1box_libslirp_meson "${SOURCE_PATH}/meson.build")
    set(x1box_libslirp_slirp_c "${SOURCE_PATH}/src/slirp.c")
    file(READ "${x1box_libslirp_meson}" x1box_libslirp_meson_raw)
    set(x1box_pingtest_start "pingtest = executable('pingtest', 'test/pingtest.c',")
    set(x1box_ncsi_end "test('ncsi', ncsitest)")

    if(x1box_libslirp_meson_raw MATCHES "if host_system != 'ios'")
        message(STATUS "libslirp iOS test binaries already disabled")
    else()
        if(NOT x1box_libslirp_meson_raw MATCHES "pingtest = executable\\('pingtest', 'test/pingtest\\.c',")
            message(FATAL_ERROR "Failed to locate libslirp pingtest block for iOS guard insertion")
        endif()
        if(NOT x1box_libslirp_meson_raw MATCHES "test\\('ncsi', ncsitest\\)")
            message(FATAL_ERROR "Failed to locate libslirp ncsi test terminator for iOS guard insertion")
        endif()

        string(REPLACE "${x1box_pingtest_start}" "if host_system != 'ios'\n${x1box_pingtest_start}" x1box_libslirp_meson_raw "${x1box_libslirp_meson_raw}")
        string(REPLACE "${x1box_ncsi_end}" "${x1box_ncsi_end}\nendif" x1box_libslirp_meson_raw "${x1box_libslirp_meson_raw}")
        file(WRITE "${x1box_libslirp_meson}" "${x1box_libslirp_meson_raw}")
    endif()

    file(READ "${x1box_libslirp_slirp_c}" x1box_libslirp_slirp_c_raw)
    if(x1box_libslirp_slirp_c_raw MATCHES "x1box_bind_resolver_symbols")
        message(STATUS "libslirp iOS resolver shim already applied")
    else()
        set(x1box_resolv_anchor [=[#include <resolv.h>

static int get_dns_addr_cached]=])
        set(x1box_resolv_replacement [=[#include <resolv.h>
#include <dlfcn.h>

typedef int (*x1box_res_ninit_fn)(struct __res_state *);
typedef int (*x1box_res_getservers_fn)(const struct __res_state *,
                                       union res_sockaddr_union *, int);
typedef void (*x1box_res_ndestroy_fn)(struct __res_state *);

static x1box_res_ninit_fn x1box_res_ninit_ptr;
static x1box_res_getservers_fn x1box_res_getservers_ptr;
static x1box_res_ndestroy_fn x1box_res_ndestroy_ptr;

static int x1box_bind_resolver_symbols(void)
{
    static int loaded;
    static int available;
    static void *resolver_handle;
    void *sym_handle;

    if (loaded) {
        return available;
    }

    loaded = 1;
    resolver_handle = dlopen("/usr/lib/libresolv.9.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!resolver_handle) {
        resolver_handle = dlopen("/usr/lib/libresolv.dylib", RTLD_LAZY | RTLD_LOCAL);
    }

    sym_handle = resolver_handle ? resolver_handle : RTLD_DEFAULT;

    x1box_res_ninit_ptr = (x1box_res_ninit_fn)dlsym(sym_handle, "res_9_ninit");
    if (!x1box_res_ninit_ptr) {
        x1box_res_ninit_ptr = (x1box_res_ninit_fn)dlsym(sym_handle, "res_ninit");
    }

    x1box_res_getservers_ptr = (x1box_res_getservers_fn)dlsym(sym_handle, "res_9_getservers");
    if (!x1box_res_getservers_ptr) {
        x1box_res_getservers_ptr = (x1box_res_getservers_fn)dlsym(sym_handle, "res_getservers");
    }

    x1box_res_ndestroy_ptr = (x1box_res_ndestroy_fn)dlsym(sym_handle, "res_9_ndestroy");
    if (!x1box_res_ndestroy_ptr) {
        x1box_res_ndestroy_ptr = (x1box_res_ndestroy_fn)dlsym(sym_handle, "res_ndestroy");
    }

    available = x1box_res_ninit_ptr && x1box_res_getservers_ptr &&
                x1box_res_ndestroy_ptr;
    if (!available) {
        g_warning_once("libslirp could not bind Apple resolver symbols; DNS forwarding will stay disabled on this host");
    }

    return available;
}

static int get_dns_addr_cached]=])
        set(x1box_resolv_init_old [=[    if (res_ninit(&state) != 0) {
        return -1;
    }

    count = res_getservers(&state, servers, NI_MAXSERV);]=])
        set(x1box_resolv_init_new [=[    if (!x1box_bind_resolver_symbols()) {
        return -1;
    }

    if (x1box_res_ninit_ptr(&state) != 0) {
        return -1;
    }

    count = x1box_res_getservers_ptr(&state, servers, NI_MAXSERV);]=])

        if(NOT x1box_libslirp_slirp_c_raw MATCHES "#include <resolv.h>")
            message(FATAL_ERROR "Failed to locate libslirp Apple resolver include block for iOS shim insertion")
        endif()
        if(NOT x1box_libslirp_slirp_c_raw MATCHES "if \\(res_ninit\\(&state\\) != 0\\)")
            message(FATAL_ERROR "Failed to locate libslirp Apple resolver init block for iOS shim insertion")
        endif()
        if(NOT x1box_libslirp_slirp_c_raw MATCHES "res_ndestroy\\(&state\\);")
            message(FATAL_ERROR "Failed to locate libslirp Apple resolver teardown block for iOS shim insertion")
        endif()

        string(REPLACE "${x1box_resolv_anchor}" "${x1box_resolv_replacement}" x1box_libslirp_slirp_c_raw "${x1box_libslirp_slirp_c_raw}")
        string(REPLACE "${x1box_resolv_init_old}" "${x1box_resolv_init_new}" x1box_libslirp_slirp_c_raw "${x1box_libslirp_slirp_c_raw}")
        string(REPLACE "    res_ndestroy(&state);" "    x1box_res_ndestroy_ptr(&state);" x1box_libslirp_slirp_c_raw "${x1box_libslirp_slirp_c_raw}")
        file(WRITE "${x1box_libslirp_slirp_c}" "${x1box_libslirp_slirp_c_raw}")
    endif()
endif()

if(VCPKG_HOST_IS_WINDOWS)
    vcpkg_acquire_msys(MSYS_ROOT)
    vcpkg_add_to_path("${MSYS_ROOT}/usr/bin")
endif()

vcpkg_configure_meson(
    SOURCE_PATH "${SOURCE_PATH}"
)

vcpkg_install_meson(ADD_BIN_TO_PATH)

vcpkg_fixup_pkgconfig()

vcpkg_copy_pdbs()

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYRIGHT")

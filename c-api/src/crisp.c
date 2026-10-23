/*
 * crisp.c -- the Crisp compile API client (c-api/include/crisp.h).            Endeavour 190, S3.
 *
 * A thin library with no Lisp and no LLVM in the caller's process (A1).  Compiles are done by
 * `crisp-compile --serve` helper processes, spoken to over the framing documented in src/api.lisp
 * ("The compile server"):  a record is  <tag> SP <length> LF <length bytes> LF.
 *
 * Helper processes live in a small idle POOL shared by every context: a compile takes one (or
 * starts one), uses it, and gives it back.  A helper whose stream breaks is killed, never reused.
 *
 * Finding the compiler, first match wins:
 *   1. $CRISP_COMPILE_EXE                       -- the full path of crisp-compile(.exe)
 *   2. $CRISP_HOME/bin/crisp-compile(.exe)
 *   3. crisp-compile(.exe) next to THIS library  -- the normal install: everything in <root>/bin/
 * The helper runs with its working directory set to the PARENT of the exe's directory (<root>),
 * because crisp-compile finds bin/LLVM-C.dll and its LLVM tools relative to it (F2).
 */
#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  define _GNU_SOURCE
#  include <dlfcn.h>
#  include <errno.h>
#  include <fcntl.h>
#  include <pthread.h>
#  include <signal.h>
#  include <sys/socket.h>
#  include <sys/types.h>
#  include <sys/wait.h>
#  include <time.h>
#  include <unistd.h>
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CRISP_BUILDING_LIBRARY 1
#include "crisp.h"

#define CRISP_PROTOCOL_HELLO "crisp-compile-server 1"
#define CRISP_POOL_MAX_IDLE  4

/* ============================================================================================== */
/* Small utilities                                                                                 */
/* ============================================================================================== */

static char* crisp_strdup_n(const char* s, size_t n)
{
    char* d = (char*)malloc(n + 1);
    if (!d) return NULL;
    if (n) memcpy(d, s, n);
    d[n] = '\0';
    return d;
}

static char* crisp_strdup(const char* s) { return s ? crisp_strdup_n(s, strlen(s)) : NULL; }

/* Grows *ARR (of ELEM bytes each) so index *N is valid; returns a pointer to the new zeroed slot. */
static void* crisp_push(void** arr, size_t* n, size_t* cap, size_t elem)
{
    if (*n == *cap) {
        size_t nc = *cap ? *cap * 2 : 8;
        void* na = realloc(*arr, nc * elem);
        if (!na) return NULL;
        *arr = na;
        *cap = nc;
    }
    {
        void* slot = (char*)*arr + (*n) * elem;
        memset(slot, 0, elem);
        (*n)++;
        return slot;
    }
}

#define CRISP_PUSH(arr, n, cap) crisp_push((void**)&(arr), &(n), &(cap), sizeof(*(arr)))

/* ============================================================================================== */
/* Results                                                                                         */
/* ============================================================================================== */

typedef struct { crisp_role role; uint32_t axis; size_t slot; } crisp_role_entry;

typedef struct {
    char* name;
    crisp_param_kind kind;
    crisp_direction direction;
    crisp_type element_type;
    uint32_t rank;
    crisp_layout layout;
    crisp_address_space address_space;
    char* adjoint_of;
    crisp_purpose purpose;
    int zero_before_launch;
    /* scratch size rule (item 2): elements per axis, or a launch-relative rule resolved by the
       launch object */
    uint64_t size_elements[8]; size_t n_size_elements;
    char* size_rule;
    crisp_role_entry* roles; size_t n_roles, cap_roles;
} crisp_param_rec;

typedef struct { crisp_type type; size_t size; crisp_address_space address_space; } crisp_slot_rec;

/* A number in a geometry declaration: a literal, a parameter's value, or a name that is no
   parameter (kept for the error message). */
typedef struct {
    int kind;                /* 0 literal, 1 parameter, 2 unknown name */
    uint64_t value;
    size_t param;
    char name[64];
} crisp_geo_ref;

typedef struct {
    uint32_t local[2];                       /* local-size :set-to, else 1 1 */
    int has_dispatch;                        /* global-size or num-groups declared */
    char strategy[24];                       /* "" when none */
    crisp_geo_ref set_to[3];  size_t n_set_to;
    int derive_kind;                         /* 0 none, 1 tensor, 2 scalars */
    crisp_geo_ref derive[3];  size_t n_derive;
    uint64_t tile[3];         size_t n_tile;
    int has_occupancy;
    double occupancy;
    uint32_t warp_size;                      /* from the hardware profile; 0 = none */
    uint32_t cluster[3];                     /* CUDA thread-block cluster; 0 0 0 = none */
    int cluster_reach;                       /* multicast / cluster barrier: padding unsafe */
} crisp_geometry;

typedef struct {
    char* name;
    char* grad_of;
    crisp_slot_rec* slots;   size_t n_slots, cap_slots;
    crisp_param_rec* params; size_t n_params, cap_params;
    crisp_geometry geo;
} crisp_kernel_rec;

typedef struct {
    unsigned char* data; size_t size;          /* data is always NUL-terminated (not counted) */
    crisp_kernel_rec* kernels; size_t n_kernels, cap_kernels;
} crisp_module_rec;

typedef struct {
    crisp_severity severity;
    char* message;
    char* file;
    uint32_t line, column;
} crisp_diag_rec;

struct crisp_context {
    char* target;
    char** flags; size_t n_flags;
    char** source_texts; char** source_names; size_t n_sources, cap_sources;
    /* results of the last compile */
    crisp_module_rec* modules; size_t n_modules, cap_modules;
    crisp_diag_rec* diags; size_t n_diags, cap_diags;
    char* diagnostics_text;
};

static void crisp_free_results(crisp_context* c)
{
    size_t m, k, p, d;
    for (m = 0; m < c->n_modules; m++) {
        crisp_module_rec* mod = &c->modules[m];
        for (k = 0; k < mod->n_kernels; k++) {
            crisp_kernel_rec* ker = &mod->kernels[k];
            for (p = 0; p < ker->n_params; p++) {
                free(ker->params[p].name);
                free(ker->params[p].adjoint_of);
                free(ker->params[p].size_rule);
                free(ker->params[p].roles);
            }
            free(ker->params);
            free(ker->slots);
            free(ker->name);
            free(ker->grad_of);
        }
        free(mod->kernels);
        free(mod->data);
    }
    free(c->modules);
    c->modules = NULL; c->n_modules = c->cap_modules = 0;
    for (d = 0; d < c->n_diags; d++) { free(c->diags[d].message); free(c->diags[d].file); }
    free(c->diags);
    c->diags = NULL; c->n_diags = c->cap_diags = 0;
    free(c->diagnostics_text);
    c->diagnostics_text = NULL;
}

/* Adds a diagnostic made on THIS side (no compiler involved). */
static void crisp_add_local_diag(crisp_context* c, crisp_severity sev, const char* fmt, const char* arg)
{
    char buf[1024];
    crisp_diag_rec* d = (crisp_diag_rec*)CRISP_PUSH(c->diags, c->n_diags, c->cap_diags);
    if (!d) return;
    snprintf(buf, sizeof buf, fmt, arg ? arg : "");
    d->severity = sev;
    d->message = crisp_strdup(buf);
}

/* ============================================================================================== */
/* The helper process                                                                              */
/* ============================================================================================== */

typedef struct crisp_server {
#if defined(_WIN32)
    HANDLE process, to_child, from_child;
#else
    pid_t pid;
    int fd;              /* our end of the socketpair: we send requests and read responses on it */
#endif
    unsigned char rbuf[65536];
    size_t rpos, rlen;
} crisp_server;

static int crisp_server_write(crisp_server* s, const void* data, size_t n)
{
    const char* p = (const char*)data;
    while (n > 0) {
#if defined(_WIN32)
        DWORD wrote = 0;
        DWORD chunk = n > 0x40000000u ? 0x40000000u : (DWORD)n;
        if (!WriteFile(s->to_child, p, chunk, &wrote, NULL) || wrote == 0) return 0;
#else
        /* MSG_NOSIGNAL: a dead helper must not raise SIGPIPE in the caller's process */
        ssize_t wrote = send(s->fd, p, n, MSG_NOSIGNAL);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) return 0;
#endif
        p += wrote;
        n -= (size_t)wrote;
    }
    return 1;
}

/* Refills the read buffer; 0 on end of file or error. */
static int crisp_server_fill(crisp_server* s)
{
#if defined(_WIN32)
    DWORD got = 0;
    if (!ReadFile(s->from_child, s->rbuf, (DWORD)sizeof s->rbuf, &got, NULL) || got == 0) return 0;
#else
    ssize_t got;
    do { got = recv(s->fd, s->rbuf, sizeof s->rbuf, 0); } while (got < 0 && errno == EINTR);
    if (got <= 0) return 0;
#endif
    s->rpos = 0;
    s->rlen = (size_t)got;
    return 1;
}

static int crisp_server_read_byte(crisp_server* s, unsigned char* out)
{
    if (s->rpos == s->rlen && !crisp_server_fill(s)) return 0;
    *out = s->rbuf[s->rpos++];
    return 1;
}

static int crisp_server_read_exact(crisp_server* s, unsigned char* dst, size_t n)
{
    while (n > 0) {
        size_t avail;
        if (s->rpos == s->rlen && !crisp_server_fill(s)) return 0;
        avail = s->rlen - s->rpos;
        if (avail > n) avail = n;
        memcpy(dst, s->rbuf + s->rpos, avail);
        s->rpos += avail;
        dst += avail;
        n -= avail;
    }
    return 1;
}

/* One record: TAG (NUL-terminated, at most 63 chars) and a malloc'ed PAYLOAD (NUL-terminated,
   *LEN bytes not counting the NUL).  0 on end of file or a malformed record. */
static int crisp_read_record(crisp_server* s, char tag[64], unsigned char** payload, size_t* len)
{
    char header[128];
    size_t h = 0, n = 0;
    unsigned char b, nl;
    char* space;
    for (;;) {
        if (!crisp_server_read_byte(s, &b)) return 0;
        if (b == '\n') break;
        if (h + 1 >= sizeof header) return 0;
        header[h++] = (char)b;
    }
    header[h] = '\0';
    space = strchr(header, ' ');
    if (!space || (size_t)(space - header) >= 64) return 0;
    memcpy(tag, header, (size_t)(space - header));
    tag[space - header] = '\0';
    {
        const char* q = space + 1;
        if (!*q) return 0;
        for (; *q; q++) {
            if (*q < '0' || *q > '9') return 0;
            n = n * 10 + (size_t)(*q - '0');
        }
    }
    *payload = (unsigned char*)malloc(n + 1);
    if (!*payload) return 0;
    if (!crisp_server_read_exact(s, *payload, n) || !crisp_server_read_byte(s, &nl) || nl != '\n') {
        free(*payload);
        *payload = NULL;
        return 0;
    }
    (*payload)[n] = '\0';
    *len = n;
    return 1;
}

static int crisp_write_record(crisp_server* s, const char* tag, const void* data, size_t n)
{
    char header[96];
    int h = snprintf(header, sizeof header, "%s %lu\n", tag, (unsigned long)n);
    return crisp_server_write(s, header, (size_t)h) && crisp_server_write(s, data, n) && crisp_server_write(s, "\n", 1);
}

static int crisp_write_text(crisp_server* s, const char* tag, const char* text)
{
    return crisp_write_record(s, tag, text, strlen(text));
}

/* ---- locating crisp-compile ---------------------------------------------------------------- */

#if defined(_WIN32)
#  define CRISP_EXE_NAME "crisp-compile.exe"
#  define CRISP_SEP '\\'
#else
#  define CRISP_EXE_NAME "crisp-compile"
#  define CRISP_SEP '/'
#endif

static int crisp_is_sep(char ch) { return ch == '/' || ch == '\\'; }

/* Any object inside this library: its address tells the loader which file the library is
   (an object, not a function -- ISO C forbids converting a function pointer to void*). */
static const char crisp_self_anchor = 0;

/* Writes the compiler's path to EXE and its working directory (<root>) to ROOT.  0 if not found. */
static int crisp_locate_compiler(char* exe, size_t exe_cap, char* root, size_t root_cap)
{
    const char* env_exe = getenv("CRISP_COMPILE_EXE");
    const char* env_home = getenv("CRISP_HOME");
    char dir[4096];
    size_t len;
    if (env_exe && *env_exe) {
        snprintf(exe, exe_cap, "%s", env_exe);
    } else if (env_home && *env_home) {
        snprintf(exe, exe_cap, "%s%cbin%c%s", env_home, CRISP_SEP, CRISP_SEP, CRISP_EXE_NAME);
    } else {
#if defined(_WIN32)
        HMODULE self = NULL;
        DWORD n;
        if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                (LPCSTR)&crisp_self_anchor, &self)) return 0;
        n = GetModuleFileNameA(self, dir, (DWORD)sizeof dir);
        if (n == 0 || n >= sizeof dir) return 0;
#else
        Dl_info info;
        if (!dladdr((const void*)&crisp_self_anchor, &info) || !info.dli_fname) return 0;
        snprintf(dir, sizeof dir, "%s", info.dli_fname);
#endif
        len = strlen(dir);
        while (len > 0 && !crisp_is_sep(dir[len - 1])) len--;   /* strip the library's file name */
        dir[len] = '\0';
        snprintf(exe, exe_cap, "%s%s", dir, CRISP_EXE_NAME);
    }
    /* <root> = the parent of the exe's directory */
    snprintf(root, root_cap, "%s", exe);
    len = strlen(root);
    while (len > 0 && !crisp_is_sep(root[len - 1])) len--;      /* -> <root>/bin/   */
    if (len > 0) len--;                                          /* -> <root>/bin    */
    while (len > 0 && !crisp_is_sep(root[len - 1])) len--;      /* -> <root>/       */
    if (len == 0) { snprintf(root, root_cap, "."); }
    else root[len] = '\0';
    return 1;
}

/* ---- starting and stopping ------------------------------------------------------------------ */

static void crisp_server_kill(crisp_server* s)
{
    if (!s) return;
#if defined(_WIN32)
    if (s->to_child) CloseHandle(s->to_child);           /* EOF on its stdin: it exits by itself */
    if (s->from_child) CloseHandle(s->from_child);
    if (s->process) {
        if (WaitForSingleObject(s->process, 2000) != WAIT_OBJECT_0) TerminateProcess(s->process, 1);
        CloseHandle(s->process);
    }
#else
    if (s->fd >= 0) close(s->fd);                         /* EOF on its stdin: it exits by itself */
    if (s->pid > 0) {
        int i, status;
        for (i = 0; i < 200; i++) {                       /* up to ~2 s, then insist */
            struct timespec ts = { 0, 10 * 1000 * 1000 };
            if (waitpid(s->pid, &status, WNOHANG) != 0) { s->pid = 0; break; }
            nanosleep(&ts, NULL);
        }
        if (s->pid > 0) { kill(s->pid, SIGKILL); waitpid(s->pid, &status, 0); }
    }
#endif
    free(s);
}

/* Starts a helper and checks its hello.  NULL on failure, with the reason in WHY. */
static crisp_server* crisp_server_start(char* why, size_t why_cap)
{
    char exe[4096], root[4096];
    crisp_server* s;
    char tag[64];
    unsigned char* hello = NULL;
    size_t hello_len = 0;

    if (!crisp_locate_compiler(exe, sizeof exe, root, sizeof root)) {
        snprintf(why, why_cap, "cannot locate crisp-compile (set CRISP_HOME or CRISP_COMPILE_EXE)");
        return NULL;
    }
    s = (crisp_server*)calloc(1, sizeof *s);
    if (!s) { snprintf(why, why_cap, "out of memory"); return NULL; }

#if defined(_WIN32)
    {
        SECURITY_ATTRIBUTES sa;
        HANDLE child_in_r = NULL, child_out_w = NULL, nul = INVALID_HANDLE_VALUE;
        STARTUPINFOA si;
        PROCESS_INFORMATION pi;
        char cmd[4200];
        sa.nLength = sizeof sa; sa.lpSecurityDescriptor = NULL; sa.bInheritHandle = TRUE;
        if (!CreatePipe(&child_in_r, &s->to_child, &sa, 0) || !CreatePipe(&s->from_child, &child_out_w, &sa, 0)) {
            snprintf(why, why_cap, "cannot create pipes (error %lu)", (unsigned long)GetLastError());
            if (child_in_r) CloseHandle(child_in_r);
            crisp_server_kill(s);
            return NULL;
        }
        /* our ends must not leak into the child (or into anything else the caller starts) */
        SetHandleInformation(s->to_child, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(s->from_child, HANDLE_FLAG_INHERIT, 0);
        nul = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
        ZeroMemory(&si, sizeof si);
        si.cb = sizeof si;
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = child_in_r;
        si.hStdOutput = child_out_w;
        si.hStdError = nul;                               /* never a pipe nobody drains */
        snprintf(cmd, sizeof cmd, "\"%s\" --serve", exe);
        if (!CreateProcessA(exe, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, root, &si, &pi)) {
            snprintf(why, why_cap, "cannot start %.900s (error %lu)", exe, (unsigned long)GetLastError());
            CloseHandle(child_in_r); CloseHandle(child_out_w);
            if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
            crisp_server_kill(s);
            return NULL;
        }
        CloseHandle(pi.hThread);
        s->process = pi.hProcess;
        CloseHandle(child_in_r); CloseHandle(child_out_w);
        if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    }
#else
    {
        int sv[2];
        pid_t pid;
        if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) {
            snprintf(why, why_cap, "cannot create a socketpair (%s)", strerror(errno));
            free(s);
            return NULL;
        }
        s->fd = sv[0];
        pid = fork();
        if (pid < 0) {
            snprintf(why, why_cap, "cannot fork (%s)", strerror(errno));
            close(sv[0]); close(sv[1]);
            free(s);
            return NULL;
        }
        if (pid == 0) {                                   /* child: async-signal-safe calls only */
            int devnull = open("/dev/null", O_WRONLY);
            dup2(sv[1], 0);
            dup2(sv[1], 1);
            if (devnull >= 0) dup2(devnull, 2);
            if (chdir(root) != 0) _exit(126);
            execl(exe, exe, "--serve", (char*)NULL);
            _exit(127);
        }
        close(sv[1]);
        s->pid = pid;
    }
#endif

    if (!crisp_read_record(s, tag, &hello, &hello_len) || strcmp(tag, "hello") != 0
        || strcmp((const char*)hello, CRISP_PROTOCOL_HELLO) != 0) {
        snprintf(why, why_cap, "%.900s did not answer as a compile server (expected \"%s\", got \"%.100s\")",
                 exe, CRISP_PROTOCOL_HELLO, hello ? (const char*)hello : "nothing");
        free(hello);
        crisp_server_kill(s);
        return NULL;
    }
    free(hello);
    return s;
}

/* ---- the pool ------------------------------------------------------------------------------- */

#if defined(_WIN32)
static SRWLOCK crisp_pool_lock = SRWLOCK_INIT;
#  define CRISP_LOCK()   AcquireSRWLockExclusive(&crisp_pool_lock)
#  define CRISP_UNLOCK() ReleaseSRWLockExclusive(&crisp_pool_lock)
#else
static pthread_mutex_t crisp_pool_lock = PTHREAD_MUTEX_INITIALIZER;
#  define CRISP_LOCK()   pthread_mutex_lock(&crisp_pool_lock)
#  define CRISP_UNLOCK() pthread_mutex_unlock(&crisp_pool_lock)
#endif

static crisp_server* crisp_pool_idle[CRISP_POOL_MAX_IDLE];
static size_t crisp_pool_n_idle = 0;

static crisp_server* crisp_pool_take(char* why, size_t why_cap)
{
    crisp_server* s = NULL;
    CRISP_LOCK();
    if (crisp_pool_n_idle > 0) s = crisp_pool_idle[--crisp_pool_n_idle];
    CRISP_UNLOCK();
    return s ? s : crisp_server_start(why, why_cap);    /* start OUTSIDE the lock: it is slow */
}

static void crisp_pool_give_back(crisp_server* s)
{
    int kept = 0;
    CRISP_LOCK();
    if (crisp_pool_n_idle < CRISP_POOL_MAX_IDLE) { crisp_pool_idle[crisp_pool_n_idle++] = s; kept = 1; }
    CRISP_UNLOCK();
    if (!kept) crisp_server_kill(s);
}

CRISP_API void crisp_shutdown(void)
{
    crisp_server* doomed[CRISP_POOL_MAX_IDLE];
    size_t n, i;
    CRISP_LOCK();
    n = crisp_pool_n_idle;
    for (i = 0; i < n; i++) doomed[i] = crisp_pool_idle[i];
    crisp_pool_n_idle = 0;
    CRISP_UNLOCK();
    for (i = 0; i < n; i++) crisp_server_kill(doomed[i]);
}

/* ============================================================================================== */
/* Enumerations from the wire                                                                      */
/* ============================================================================================== */

typedef struct { const char* name; int value; } crisp_name_value;

static int crisp_lookup(const crisp_name_value* table, const char* name)
{
    for (; table->name; table++) if (strcmp(table->name, name) == 0) return table->value;
    return 0;                                             /* every enum's 0 is its INVALID */
}

static const crisp_name_value crisp_types[] = {
    { "char", CRISP_TYPE_CHAR }, { "uchar", CRISP_TYPE_UCHAR }, { "short", CRISP_TYPE_SHORT },
    { "ushort", CRISP_TYPE_USHORT }, { "int", CRISP_TYPE_INT }, { "uint", CRISP_TYPE_UINT },
    { "long", CRISP_TYPE_LONG }, { "ulong", CRISP_TYPE_ULONG }, { "half", CRISP_TYPE_HALF },
    { "bfloat16", CRISP_TYPE_BFLOAT16 }, { "float", CRISP_TYPE_FLOAT }, { "double", CRISP_TYPE_DOUBLE },
    { "pointer", CRISP_TYPE_POINTER }, { "aggregate", CRISP_TYPE_AGGREGATE }, { NULL, 0 } };
static const crisp_name_value crisp_spaces[] = {
    { "global", CRISP_ADDRESS_SPACE_GLOBAL }, { "constant", CRISP_ADDRESS_SPACE_CONSTANT },
    { "local", CRISP_ADDRESS_SPACE_LOCAL }, { NULL, 0 } };
static const crisp_name_value crisp_kinds[] = {
    { "scalar", CRISP_PARAM_SCALAR }, { "cell", CRISP_PARAM_CELL }, { "tensor", CRISP_PARAM_TENSOR },
    { "record", CRISP_PARAM_RECORD }, { NULL, 0 } };
static const crisp_name_value crisp_directions[] = {
    { "in", CRISP_DIRECTION_IN }, { "out", CRISP_DIRECTION_OUT }, { NULL, 0 } };
static const crisp_name_value crisp_layouts[] = {
    { "compact", CRISP_LAYOUT_COMPACT }, { "compact-offset", CRISP_LAYOUT_COMPACT_OFFSET },
    { "strided", CRISP_LAYOUT_STRIDED }, { NULL, 0 } };
static const crisp_name_value crisp_roles[] = {
    { "value", CRISP_ROLE_VALUE }, { "pointer", CRISP_ROLE_POINTER }, { "byte-size", CRISP_ROLE_BYTE_SIZE },
    { "offset", CRISP_ROLE_OFFSET }, { "stride", CRISP_ROLE_STRIDE }, { "extent", CRISP_ROLE_EXTENT },
    { "length", CRISP_ROLE_LENGTH }, { "field", CRISP_ROLE_FIELD }, { NULL, 0 } };
static const crisp_name_value crisp_purposes[] = {
    { "declared", CRISP_PURPOSE_DECLARED }, { "scratch", CRISP_PURPOSE_SCRATCH },
    { "debug-log", CRISP_PURPOSE_DEBUG_LOG }, { "tensor-map", CRISP_PURPOSE_TENSOR_MAP }, { NULL, 0 } };
static const crisp_name_value crisp_severities[] = {
    { "error", CRISP_SEVERITY_ERROR }, { "warning", CRISP_SEVERITY_WARNING }, { "note", CRISP_SEVERITY_NOTE },
    { NULL, 0 } };
static const crisp_name_value crisp_statuses[] = {
    { "ok", CRISP_OK }, { "compile-error", CRISP_ERROR_COMPILE },
    { "invalid-argument", CRISP_ERROR_INVALID_ARGUMENT }, { "internal-error", CRISP_ERROR_INTERNAL },
    { NULL, 0 } };

/* ============================================================================================== */
/* One request / response                                                                          */
/* ============================================================================================== */

/* "p3" -> parameter 3, "?width" -> unknown name, "256" -> literal. */
static void crisp_parse_geo_ref(const char* tok, size_t len, crisp_geo_ref* out)
{
    char buf[80];
    if (len >= sizeof buf) len = sizeof buf - 1;
    memcpy(buf, tok, len);
    buf[len] = '\0';
    memset(out, 0, sizeof *out);
    if (buf[0] == 'p') { out->kind = 1; out->param = (size_t)strtoull(buf + 1, NULL, 10); }
    else if (buf[0] == '?') { out->kind = 2; snprintf(out->name, sizeof out->name, "%.63s", buf + 1); }
    else { out->kind = 0; out->value = (uint64_t)strtoull(buf, NULL, 10); }
}

/* Splits T on spaces into up to MAX refs; returns the count.  SKIP_FIRST drops a leading word. */
static size_t crisp_parse_geo_refs(const char* t, crisp_geo_ref* out, size_t max, int skip_first)
{
    size_t n = 0;
    while (*t) {
        const char* end;
        while (*t == ' ') t++;
        if (!*t) break;
        end = t;
        while (*end && *end != ' ') end++;
        if (skip_first) skip_first = 0;
        else if (n < max) crisp_parse_geo_ref(t, (size_t)(end - t), &out[n++]);
        t = end;
    }
    return n;
}

/* Reads one response into C.  Returns 1 and sets *STATUS, or 0 if the stream broke. */
static int crisp_read_response(crisp_server* s, crisp_context* c, crisp_status* status)
{
    char tag[64];
    unsigned char* p = NULL;
    size_t n = 0;
    crisp_module_rec* mod = NULL;
    crisp_kernel_rec* ker = NULL;
    crisp_slot_rec* slot = NULL;
    crisp_param_rec* par = NULL;
    crisp_diag_rec* dia = NULL;
    int saw_status = 0;

    for (;;) {
        const char* t;
        if (!crisp_read_record(s, tag, &p, &n)) return 0;
        t = (const char*)p;
        if (strcmp(tag, "end") == 0) { free(p); break; }
        else if (strcmp(tag, "status") == 0) {
            *status = (crisp_status)crisp_lookup(crisp_statuses, t);
            if (*status == CRISP_OK && strcmp(t, "ok") != 0) *status = CRISP_ERROR_INTERNAL;
            saw_status = 1;
        }
        else if (strcmp(tag, "diag") == 0)          { dia = (crisp_diag_rec*)CRISP_PUSH(c->diags, c->n_diags, c->cap_diags); }
        else if (dia && strcmp(tag, "diag.severity") == 0) dia->severity = (crisp_severity)crisp_lookup(crisp_severities, t);
        else if (dia && strcmp(tag, "diag.message") == 0)  { free(dia->message); dia->message = (char*)p; p = NULL; }
        else if (dia && strcmp(tag, "diag.file") == 0)     { free(dia->file); dia->file = (char*)p; p = NULL; }
        else if (dia && strcmp(tag, "diag.line") == 0)     dia->line = (uint32_t)strtoul(t, NULL, 10);
        else if (dia && strcmp(tag, "diag.column") == 0)   dia->column = (uint32_t)strtoul(t, NULL, 10);
        else if (strcmp(tag, "module") == 0)        { mod = (crisp_module_rec*)CRISP_PUSH(c->modules, c->n_modules, c->cap_modules); ker = NULL; }
        else if (mod && strcmp(tag, "module.binary") == 0) { free(mod->data); mod->data = p; mod->size = n; p = NULL; }
        else if (mod && strcmp(tag, "kernel") == 0) {
            ker = (crisp_kernel_rec*)CRISP_PUSH(mod->kernels, mod->n_kernels, mod->cap_kernels);
            slot = NULL; par = NULL;
            if (ker) { ker->geo.local[0] = 1; ker->geo.local[1] = 1; }
        }
        else if (ker && strcmp(tag, "kernel.name") == 0)    { free(ker->name); ker->name = (char*)p; p = NULL; }
        else if (ker && strcmp(tag, "kernel.grad-of") == 0) { free(ker->grad_of); ker->grad_of = (char*)p; p = NULL; }
        else if (ker && strcmp(tag, "kernel.local") == 0) {
            unsigned long x = 1, y = 1;
            if (sscanf(t, "%lu %lu", &x, &y) >= 1) { ker->geo.local[0] = (uint32_t)x; ker->geo.local[1] = (uint32_t)y; }
        }
        else if (ker && strcmp(tag, "kernel.dispatch") == 0)  ker->geo.has_dispatch = 1;
        else if (ker && strcmp(tag, "kernel.strategy") == 0)  snprintf(ker->geo.strategy, sizeof ker->geo.strategy, "%s", t);
        else if (ker && strcmp(tag, "kernel.set-to") == 0)    ker->geo.n_set_to = crisp_parse_geo_refs(t, ker->geo.set_to, 3, 0);
        else if (ker && strcmp(tag, "kernel.derive") == 0) {
            ker->geo.derive_kind = strncmp(t, "tensor", 6) == 0 ? 1 : 2;
            ker->geo.n_derive = crisp_parse_geo_refs(t, ker->geo.derive, 3, 1);
        }
        else if (ker && strcmp(tag, "kernel.tile-shape") == 0) {
            crisp_geo_ref r[3];
            size_t i, n = crisp_parse_geo_refs(t, r, 3, 0);
            for (i = 0; i < n; i++) ker->geo.tile[i] = r[i].value;
            ker->geo.n_tile = n;
        }
        else if (ker && strcmp(tag, "kernel.occupancy") == 0) { ker->geo.has_occupancy = 1; ker->geo.occupancy = strtod(t, NULL); }
        else if (ker && strcmp(tag, "kernel.warp-size") == 0)  ker->geo.warp_size = (uint32_t)strtoul(t, NULL, 10);
        else if (ker && strcmp(tag, "kernel.cluster") == 0) {
            unsigned long x = 1, y = 1, z = 1;
            int n = sscanf(t, "%lu %lu %lu", &x, &y, &z);
            if (n >= 1) { ker->geo.cluster[0] = (uint32_t)x; ker->geo.cluster[1] = n >= 2 ? (uint32_t)y : 1; ker->geo.cluster[2] = n >= 3 ? (uint32_t)z : 1; }
        }
        else if (ker && strcmp(tag, "kernel.cluster-reach") == 0) ker->geo.cluster_reach = 1;
        else if (ker && strcmp(tag, "slot") == 0)   { slot = (crisp_slot_rec*)CRISP_PUSH(ker->slots, ker->n_slots, ker->cap_slots); }
        else if (slot && strcmp(tag, "slot.type") == 0)          slot->type = (crisp_type)crisp_lookup(crisp_types, t);
        else if (slot && strcmp(tag, "slot.size") == 0)          slot->size = (size_t)strtoul(t, NULL, 10);
        else if (slot && strcmp(tag, "slot.address-space") == 0) slot->address_space = (crisp_address_space)crisp_lookup(crisp_spaces, t);
        else if (ker && strcmp(tag, "param") == 0)  { par = (crisp_param_rec*)CRISP_PUSH(ker->params, ker->n_params, ker->cap_params); }
        else if (par && strcmp(tag, "param.name") == 0)          { free(par->name); par->name = (char*)p; p = NULL; }
        else if (par && strcmp(tag, "param.kind") == 0)          par->kind = (crisp_param_kind)crisp_lookup(crisp_kinds, t);
        else if (par && strcmp(tag, "param.direction") == 0)     par->direction = (crisp_direction)crisp_lookup(crisp_directions, t);
        else if (par && strcmp(tag, "param.element-type") == 0)  par->element_type = (crisp_type)crisp_lookup(crisp_types, t);
        else if (par && strcmp(tag, "param.rank") == 0)          par->rank = (uint32_t)strtoul(t, NULL, 10);
        else if (par && strcmp(tag, "param.layout") == 0)        par->layout = (crisp_layout)crisp_lookup(crisp_layouts, t);
        else if (par && strcmp(tag, "param.address-space") == 0) par->address_space = (crisp_address_space)crisp_lookup(crisp_spaces, t);
        else if (par && strcmp(tag, "param.adjoint-of") == 0)    { free(par->adjoint_of); par->adjoint_of = (char*)p; p = NULL; }
        else if (par && strcmp(tag, "param.purpose") == 0)       par->purpose = (crisp_purpose)crisp_lookup(crisp_purposes, t);
        else if (par && strcmp(tag, "param.zero-before-launch") == 0) par->zero_before_launch = (t[0] == '1');
        else if (par && strcmp(tag, "param.size") == 0) {
            if (strncmp(t, "elements", 8) == 0) {
                const char* q = t + 8;
                char* end;
                par->n_size_elements = 0;
                while (par->n_size_elements < 8) {
                    unsigned long long v = strtoull(q, &end, 10);
                    if (end == q) break;
                    par->size_elements[par->n_size_elements++] = (uint64_t)v;
                    q = end;
                }
            } else if (strncmp(t, "rule ", 5) == 0) {
                free(par->size_rule);
                par->size_rule = crisp_strdup(t + 5);
            }
        }
        else if (par && strcmp(tag, "role") == 0) {
            char role_name[32];
            unsigned long axis = 0, slot_ix = 0;
            if (sscanf(t, "%31s %lu %lu", role_name, &axis, &slot_ix) == 3) {
                crisp_role_entry* r = (crisp_role_entry*)CRISP_PUSH(par->roles, par->n_roles, par->cap_roles);
                if (r) { r->role = (crisp_role)crisp_lookup(crisp_roles, role_name); r->axis = (uint32_t)axis; r->slot = (size_t)slot_ix; }
            }
        }
        /* anything else: a newer server's field this client does not know -- skipped */
        free(p);
        p = NULL;
    }
    if (!saw_status) *status = CRISP_ERROR_INTERNAL;
    return 1;
}

static int crisp_send_request(crisp_server* s, const crisp_context* c)
{
    size_t i;
    if (!crisp_write_text(s, "target", c->target)) return 0;
    for (i = 0; i < c->n_flags; i++) if (!crisp_write_text(s, "flag", c->flags[i])) return 0;
    for (i = 0; i < c->n_sources; i++) {
        if (c->source_names[i] && !crisp_write_text(s, "source-name", c->source_names[i])) return 0;
        if (!crisp_write_text(s, "source", c->source_texts[i])) return 0;
    }
    return crisp_write_record(s, "end", "", 0);
}

static void crisp_build_diagnostics_text(crisp_context* c)
{
    size_t i, total = 1;
    char* out;
    for (i = 0; i < c->n_diags; i++)
        total += 64 + (c->diags[i].file ? strlen(c->diags[i].file) : 0) + (c->diags[i].message ? strlen(c->diags[i].message) : 0);
    out = (char*)malloc(total);
    if (!out) return;
    out[0] = '\0';
    for (i = 0; i < c->n_diags; i++) {
        const crisp_diag_rec* d = &c->diags[i];
        const char* sev = d->severity == CRISP_SEVERITY_ERROR ? "error"
                        : d->severity == CRISP_SEVERITY_WARNING ? "warning" : "note";
        size_t used = strlen(out);
        if (d->file)
            snprintf(out + used, total - used, "%s: %s: %s\n", d->file, sev, d->message ? d->message : "");
        else
            snprintf(out + used, total - used, "%s: %s\n", sev, d->message ? d->message : "");
    }
    c->diagnostics_text = out;
}

/* ============================================================================================== */
/* The public API                                                                                  */
/* ============================================================================================== */

CRISP_API uint32_t crisp_api_version(void)
{
    return ((uint32_t)CRISP_API_VERSION_MAJOR << 16) | (uint32_t)CRISP_API_VERSION_MINOR;
}

CRISP_API const char* crisp_status_string(crisp_status status)
{
    switch (status) {
    case CRISP_OK:                     return "success";
    case CRISP_ERROR_COMPILE:          return "the source did not compile";
    case CRISP_ERROR_INVALID_ARGUMENT: return "invalid argument";
    case CRISP_ERROR_NO_RESULT:        return "no result: nothing has compiled successfully";
    case CRISP_ERROR_IO:               return "the file could not be read";
    case CRISP_ERROR_COMPILER_PROCESS: return "the compiler process could not start, or died";
    case CRISP_ERROR_OUT_OF_MEMORY:    return "out of memory";
    case CRISP_ERROR_INTERNAL:         return "internal error in Crisp";
    }
    return "unknown status";
}

CRISP_API crisp_status crisp_context_create(const char* target, crisp_context** out_context)
{
    crisp_context* c;
    if (!out_context) return CRISP_ERROR_INVALID_ARGUMENT;
    *out_context = NULL;
    if (!target || (strcmp(target, "spv") != 0 && strcmp(target, "spirv") != 0 && strcmp(target, "ptx") != 0))
        return CRISP_ERROR_INVALID_ARGUMENT;
    c = (crisp_context*)calloc(1, sizeof *c);
    if (!c) return CRISP_ERROR_OUT_OF_MEMORY;
    c->target = crisp_strdup(target);
    if (!c->target) { free(c); return CRISP_ERROR_OUT_OF_MEMORY; }
    *out_context = c;
    return CRISP_OK;
}

static void crisp_free_flags(crisp_context* c)
{
    size_t i;
    for (i = 0; i < c->n_flags; i++) free(c->flags[i]);
    free(c->flags);
    c->flags = NULL;
    c->n_flags = 0;
}

static void crisp_free_sources(crisp_context* c)
{
    size_t i;
    for (i = 0; i < c->n_sources; i++) { free(c->source_texts[i]); free(c->source_names[i]); }
    free(c->source_texts); free(c->source_names);
    c->source_texts = c->source_names = NULL;
    c->n_sources = c->cap_sources = 0;
}

CRISP_API void crisp_context_destroy(crisp_context* context)
{
    if (!context) return;
    crisp_free_results(context);
    crisp_free_flags(context);
    crisp_free_sources(context);
    free(context->target);
    free(context);
}

CRISP_API crisp_status crisp_set_flags(crisp_context* context, const char* const* flags, size_t count)
{
    char** copy = NULL;
    size_t i;
    if (!context || (count > 0 && !flags)) return CRISP_ERROR_INVALID_ARGUMENT;
    for (i = 0; i < count; i++) if (!flags[i]) return CRISP_ERROR_INVALID_ARGUMENT;
    if (count > 0) {
        copy = (char**)calloc(count, sizeof *copy);
        if (!copy) return CRISP_ERROR_OUT_OF_MEMORY;
        for (i = 0; i < count; i++) {
            copy[i] = crisp_strdup(flags[i]);
            if (!copy[i]) {
                while (i > 0) free(copy[--i]);
                free(copy);
                return CRISP_ERROR_OUT_OF_MEMORY;
            }
        }
    }
    crisp_free_flags(context);
    context->flags = copy;
    context->n_flags = count;
    return CRISP_OK;
}

static crisp_status crisp_add_source_owned(crisp_context* c, char* text, char* name)
{
    if (c->n_sources == c->cap_sources) {
        size_t nc = c->cap_sources ? c->cap_sources * 2 : 4;
        char** nt = (char**)realloc(c->source_texts, nc * sizeof *nt);
        char** nn;
        if (!nt) { free(text); free(name); return CRISP_ERROR_OUT_OF_MEMORY; }
        c->source_texts = nt;
        nn = (char**)realloc(c->source_names, nc * sizeof *nn);
        if (!nn) { free(text); free(name); return CRISP_ERROR_OUT_OF_MEMORY; }
        c->source_names = nn;
        c->cap_sources = nc;
    }
    c->source_texts[c->n_sources] = text;
    c->source_names[c->n_sources] = name;
    c->n_sources++;
    return CRISP_OK;
}

CRISP_API crisp_status crisp_add_source(crisp_context* context, const char* source, const char* virtual_name)
{
    char* text;
    char* name = NULL;
    if (!context || !source) return CRISP_ERROR_INVALID_ARGUMENT;
    text = crisp_strdup(source);
    if (!text) return CRISP_ERROR_OUT_OF_MEMORY;
    if (virtual_name) {
        name = crisp_strdup(virtual_name);
        if (!name) { free(text); return CRISP_ERROR_OUT_OF_MEMORY; }
    }
    return crisp_add_source_owned(context, text, name);
}

CRISP_API crisp_status crisp_add_source_file(crisp_context* context, const char* path)
{
    FILE* f;
    long size;
    char* text;
    char* name;
    if (!context || !path) return CRISP_ERROR_INVALID_ARGUMENT;
    f = fopen(path, "rb");
    if (!f) return CRISP_ERROR_IO;
    if (fseek(f, 0, SEEK_END) != 0 || (size = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return CRISP_ERROR_IO; }
    text = (char*)malloc((size_t)size + 1);
    if (!text) { fclose(f); return CRISP_ERROR_OUT_OF_MEMORY; }
    if (fread(text, 1, (size_t)size, f) != (size_t)size) { free(text); fclose(f); return CRISP_ERROR_IO; }
    fclose(f);
    text[size] = '\0';
    name = crisp_strdup(path);
    if (!name) { free(text); return CRISP_ERROR_OUT_OF_MEMORY; }
    return crisp_add_source_owned(context, text, name);
}

CRISP_API crisp_status crisp_clear_sources(crisp_context* context)
{
    if (!context) return CRISP_ERROR_INVALID_ARGUMENT;
    crisp_free_sources(context);
    crisp_free_results(context);
    return CRISP_OK;
}

CRISP_API crisp_status crisp_compile(crisp_context* context)
{
    crisp_server* s;
    char why[1200];
    crisp_status status = CRISP_ERROR_INTERNAL;
    if (!context) return CRISP_ERROR_INVALID_ARGUMENT;
    crisp_free_results(context);
    if (context->n_sources == 0) {
        crisp_add_local_diag(context, CRISP_SEVERITY_ERROR, "no sources to compile%s", "");
        crisp_build_diagnostics_text(context);
        return CRISP_ERROR_INVALID_ARGUMENT;
    }
    why[0] = '\0';
    s = crisp_pool_take(why, sizeof why);
    if (!s) {
        crisp_add_local_diag(context, CRISP_SEVERITY_ERROR, "%s", why);
        crisp_build_diagnostics_text(context);
        return CRISP_ERROR_COMPILER_PROCESS;
    }
    if (!crisp_send_request(s, context) || !crisp_read_response(s, context, &status)) {
        crisp_server_kill(s);                             /* out of sync or dead: never reuse it */
        crisp_free_results(context);
        crisp_add_local_diag(context, CRISP_SEVERITY_ERROR, "the compiler process stopped answering%s", "");
        crisp_build_diagnostics_text(context);
        return CRISP_ERROR_COMPILER_PROCESS;
    }
    crisp_pool_give_back(s);
    if (status != CRISP_OK) {                             /* no modules on failure, whatever arrived */
        crisp_diag_rec* keep = context->diags;
        size_t nd = context->n_diags, cd = context->cap_diags;
        context->diags = NULL; context->n_diags = context->cap_diags = 0;
        crisp_free_results(context);
        context->diags = keep; context->n_diags = nd; context->cap_diags = cd;
    }
    /* binaries are NUL-terminated for PTX convenience: module.binary payloads already are */
    crisp_build_diagnostics_text(context);
    return status;
}

/* ---- diagnostics --------------------------------------------------------------------------- */

static const crisp_diag_rec* crisp_diag_at(const crisp_context* c, size_t i)
{
    return (c && i < c->n_diags) ? &c->diags[i] : NULL;
}

CRISP_API size_t crisp_diagnostic_count(const crisp_context* context) { return context ? context->n_diags : 0; }
CRISP_API crisp_severity crisp_diagnostic_severity(const crisp_context* context, size_t index)
{ const crisp_diag_rec* d = crisp_diag_at(context, index); return d ? d->severity : CRISP_SEVERITY_INVALID; }
CRISP_API const char* crisp_diagnostic_message(const crisp_context* context, size_t index)
{ const crisp_diag_rec* d = crisp_diag_at(context, index); return d ? d->message : NULL; }
CRISP_API const char* crisp_diagnostic_file(const crisp_context* context, size_t index)
{ const crisp_diag_rec* d = crisp_diag_at(context, index); return d ? d->file : NULL; }
CRISP_API uint32_t crisp_diagnostic_line(const crisp_context* context, size_t index)
{ const crisp_diag_rec* d = crisp_diag_at(context, index); return d ? d->line : 0; }
CRISP_API uint32_t crisp_diagnostic_column(const crisp_context* context, size_t index)
{ const crisp_diag_rec* d = crisp_diag_at(context, index); return d ? d->column : 0; }
CRISP_API const char* crisp_diagnostics_text(const crisp_context* context)
{ return (context && context->diagnostics_text) ? context->diagnostics_text : ""; }

/* ---- modules, kernels, slots, params --------------------------------------------------------- */

static const crisp_module_rec* crisp_module_at(const crisp_context* c, size_t m)
{ return (c && m < c->n_modules) ? &c->modules[m] : NULL; }
static const crisp_kernel_rec* crisp_kernel_at(const crisp_context* c, size_t m, size_t k)
{ const crisp_module_rec* mod = crisp_module_at(c, m); return (mod && k < mod->n_kernels) ? &mod->kernels[k] : NULL; }
static const crisp_slot_rec* crisp_slot_at(const crisp_context* c, size_t m, size_t k, size_t s)
{ const crisp_kernel_rec* ker = crisp_kernel_at(c, m, k); return (ker && s < ker->n_slots) ? &ker->slots[s] : NULL; }
static const crisp_param_rec* crisp_param_at(const crisp_context* c, size_t m, size_t k, size_t p)
{ const crisp_kernel_rec* ker = crisp_kernel_at(c, m, k); return (ker && p < ker->n_params) ? &ker->params[p] : NULL; }

CRISP_API size_t crisp_module_count(const crisp_context* context) { return context ? context->n_modules : 0; }

CRISP_API crisp_status crisp_module_binary(const crisp_context* context, size_t module,
                                           const void** out_data, size_t* out_size)
{
    const crisp_module_rec* mod;
    if (!context || !out_data || !out_size) return CRISP_ERROR_INVALID_ARGUMENT;
    if (context->n_modules == 0) return CRISP_ERROR_NO_RESULT;
    mod = crisp_module_at(context, module);
    if (!mod || !mod->data) return CRISP_ERROR_INVALID_ARGUMENT;
    *out_data = mod->data;
    *out_size = mod->size;
    return CRISP_OK;
}

CRISP_API size_t crisp_kernel_count(const crisp_context* context, size_t module)
{ const crisp_module_rec* mod = crisp_module_at(context, module); return mod ? mod->n_kernels : 0; }
CRISP_API const char* crisp_kernel_name(const crisp_context* context, size_t module, size_t kernel)
{ const crisp_kernel_rec* k = crisp_kernel_at(context, module, kernel); return k ? k->name : NULL; }
CRISP_API const char* crisp_kernel_grad_of(const crisp_context* context, size_t module, size_t kernel)
{ const crisp_kernel_rec* k = crisp_kernel_at(context, module, kernel); return k ? k->grad_of : NULL; }

CRISP_API size_t crisp_slot_count(const crisp_context* context, size_t module, size_t kernel)
{ const crisp_kernel_rec* k = crisp_kernel_at(context, module, kernel); return k ? k->n_slots : 0; }
CRISP_API crisp_type crisp_slot_type(const crisp_context* context, size_t module, size_t kernel, size_t slot)
{ const crisp_slot_rec* s = crisp_slot_at(context, module, kernel, slot); return s ? s->type : CRISP_TYPE_INVALID; }
CRISP_API size_t crisp_slot_size(const crisp_context* context, size_t module, size_t kernel, size_t slot)
{ const crisp_slot_rec* s = crisp_slot_at(context, module, kernel, slot); return s ? s->size : 0; }
CRISP_API crisp_address_space crisp_slot_address_space(const crisp_context* context, size_t module, size_t kernel, size_t slot)
{ const crisp_slot_rec* s = crisp_slot_at(context, module, kernel, slot); return s ? s->address_space : CRISP_ADDRESS_SPACE_INVALID; }

CRISP_API size_t crisp_param_count(const crisp_context* context, size_t module, size_t kernel)
{ const crisp_kernel_rec* k = crisp_kernel_at(context, module, kernel); return k ? k->n_params : 0; }
CRISP_API crisp_purpose crisp_param_purpose(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->purpose : CRISP_PURPOSE_INVALID; }
CRISP_API int crisp_param_zero_before_launch(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->zero_before_launch : 0; }
CRISP_API const char* crisp_param_name(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->name : NULL; }
CRISP_API crisp_param_kind crisp_param_kind_of(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->kind : CRISP_PARAM_INVALID; }
CRISP_API crisp_direction crisp_param_direction(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->direction : CRISP_DIRECTION_INVALID; }
CRISP_API crisp_type crisp_param_element_type(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->element_type : CRISP_TYPE_INVALID; }
CRISP_API uint32_t crisp_param_rank(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->rank : 0; }
CRISP_API crisp_layout crisp_param_layout(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->layout : CRISP_LAYOUT_INVALID; }
CRISP_API crisp_address_space crisp_param_address_space(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->address_space : CRISP_ADDRESS_SPACE_INVALID; }
CRISP_API const char* crisp_param_adjoint_of(const crisp_context* context, size_t module, size_t kernel, size_t param)
{ const crisp_param_rec* p = crisp_param_at(context, module, kernel, param); return p ? p->adjoint_of : NULL; }

CRISP_API size_t crisp_param_slot(const crisp_context* context, size_t module, size_t kernel, size_t param,
                                  crisp_role role, uint32_t axis)
{
    const crisp_param_rec* p = crisp_param_at(context, module, kernel, param);
    size_t i;
    if (!p) return CRISP_NO_SLOT;
    for (i = 0; i < p->n_roles; i++)
        if (p->roles[i].role == role && p->roles[i].axis == axis) return p->roles[i].slot;
    return CRISP_NO_SLOT;
}

/* ============================================================================================== */
/* Launching (item 2, step 2): geometry + scratch sizes                                             */
/*                                                                                                 */
/* A C port of the L0 hoister's dispatch rules (src/hoist-l0/main.lisp %l0-emit-dispatch,          */
/* %l0-emit-group-count, %l0-emit-tile-grid-group-count; scratch: %l0-scratch-symbolic-expr and    */
/* the deferred :match-num-workgroups block).  The dogfood launcher (--hoist-kernel=source) checks */
/* this against the hoister's own numbers on every L0 metal spec, so keep the two in step.         */
/* ============================================================================================== */

#define CRISP_MAX_AXES 8

struct crisp_launch {
    const crisp_kernel_rec* ker;
    int is_ptx;
    /* inputs, per parameter */
    uint64_t (*extents)[CRISP_MAX_AXES];
    unsigned char (*extent_set)[CRISP_MAX_AXES];
    uint64_t* scalars;
    unsigned char* scalar_set;
    uint64_t resident_groups; int has_resident;
    uint32_t warp_size;                      /* 0: the profile's, else 32 */
    uint32_t max_groups[3]; int has_max;
    /* results */
    uint32_t groups[3];
    uint64_t* param_bytes;
    uint64_t* shared_offset;                 /* PTX local scratch: byte offset in the shared block */
    uint64_t shared_bytes;
    int computed;
    char message[512];
};

CRISP_API void crisp_launch_destroy(crisp_launch* launch)
{
    if (!launch) return;
    free(launch->extents);
    free(launch->extent_set);
    free(launch->scalars);
    free(launch->scalar_set);
    free(launch->param_bytes);
    free(launch->shared_offset);
    free(launch);
}

CRISP_API crisp_status crisp_launch_create(const crisp_context* context, size_t module, size_t kernel,
                                           crisp_launch** out_launch)
{
    const crisp_kernel_rec* k;
    crisp_launch* L;
    size_t n;
    if (!out_launch) return CRISP_ERROR_INVALID_ARGUMENT;
    *out_launch = NULL;
    if (!context) return CRISP_ERROR_INVALID_ARGUMENT;
    if (context->n_modules == 0) return CRISP_ERROR_NO_RESULT;
    k = crisp_kernel_at(context, module, kernel);
    if (!k) return CRISP_ERROR_INVALID_ARGUMENT;
    L = (crisp_launch*)calloc(1, sizeof *L);
    if (!L) return CRISP_ERROR_OUT_OF_MEMORY;
    n = k->n_params ? k->n_params : 1;
    L->ker = k;
    L->is_ptx = strcmp(context->target, "ptx") == 0;
    L->extents = calloc(n, sizeof *L->extents);
    L->extent_set = calloc(n, sizeof *L->extent_set);
    L->scalars = (uint64_t*)calloc(n, sizeof *L->scalars);
    L->scalar_set = (unsigned char*)calloc(n, 1);
    L->param_bytes = (uint64_t*)calloc(n, sizeof *L->param_bytes);
    L->shared_offset = (uint64_t*)calloc(n, sizeof *L->shared_offset);
    if (!L->extents || !L->extent_set || !L->scalars || !L->scalar_set || !L->param_bytes || !L->shared_offset) {
        crisp_launch_destroy(L);
        return CRISP_ERROR_OUT_OF_MEMORY;
    }
    L->groups[0] = L->groups[1] = L->groups[2] = 1;
    *out_launch = L;
    return CRISP_OK;
}

CRISP_API crisp_status crisp_launch_set_extent(crisp_launch* launch, size_t param, uint32_t axis, uint64_t extent)
{
    if (!launch || param >= launch->ker->n_params || axis >= CRISP_MAX_AXES) return CRISP_ERROR_INVALID_ARGUMENT;
    launch->extents[param][axis] = extent;
    launch->extent_set[param][axis] = 1;
    launch->computed = 0;
    return CRISP_OK;
}

CRISP_API crisp_status crisp_launch_set_scalar(crisp_launch* launch, size_t param, uint64_t value)
{
    if (!launch || param >= launch->ker->n_params) return CRISP_ERROR_INVALID_ARGUMENT;
    launch->scalars[param] = value;
    launch->scalar_set[param] = 1;
    launch->computed = 0;
    return CRISP_OK;
}

CRISP_API crisp_status crisp_launch_set_resident_groups(crisp_launch* launch, uint64_t groups)
{
    if (!launch) return CRISP_ERROR_INVALID_ARGUMENT;
    launch->resident_groups = groups;
    launch->has_resident = 1;
    launch->computed = 0;
    return CRISP_OK;
}

CRISP_API crisp_status crisp_launch_set_warp_size(crisp_launch* launch, uint32_t lanes)
{
    if (!launch || lanes == 0) return CRISP_ERROR_INVALID_ARGUMENT;
    launch->warp_size = lanes;
    launch->computed = 0;
    return CRISP_OK;
}

CRISP_API crisp_status crisp_launch_set_max_group_count(crisp_launch* launch, uint32_t x, uint32_t y, uint32_t z)
{
    if (!launch) return CRISP_ERROR_INVALID_ARGUMENT;
    launch->max_groups[0] = x; launch->max_groups[1] = y; launch->max_groups[2] = z;
    launch->has_max = 1;
    launch->computed = 0;
    return CRISP_OK;
}

static uint64_t crisp_ceil_div(uint64_t a, uint64_t b) { return b > 1 ? (a + b - 1) / b : a; }

static const char* crisp_param_label(const crisp_launch* L, size_t p)
{
    return (p < L->ker->n_params && L->ker->params[p].name) ? L->ker->params[p].name : "?";
}

/* The value a geometry reference stands for.  0 (and a message) when it cannot be had. */
static int crisp_geo_value(crisp_launch* L, const crisp_geo_ref* r, uint64_t* out)
{
    if (r->kind == 0) { *out = r->value; return 1; }
    if (r->kind == 2) {
        snprintf(L->message, sizeof L->message,
                 "the kernel geometry names '%s', which is not one of its parameters", r->name);
        return 0;
    }
    if (r->param >= L->ker->n_params || !L->scalar_set[r->param]) {
        snprintf(L->message, sizeof L->message,
                 "the kernel geometry needs the value of scalar parameter '%s' (crisp_launch_set_scalar)",
                 crisp_param_label(L, r->param));
        return 0;
    }
    *out = L->scalars[r->param];
    return 1;
}

/* A tensor parameter's extent on AXIS. */
static int crisp_geo_extent(crisp_launch* L, size_t p, uint32_t axis, uint64_t* out)
{
    if (p >= L->ker->n_params || axis >= CRISP_MAX_AXES || !L->extent_set[p][axis]) {
        snprintf(L->message, sizeof L->message,
                 "the kernel geometry needs extent %u of tensor parameter '%s' (crisp_launch_set_extent)",
                 (unsigned)axis, crisp_param_label(L, p));
        return 0;
    }
    *out = L->extents[p][axis];
    return 1;
}

/* A tensor parameter's length: the product of its extents over its rank. */
static int crisp_geo_length(crisp_launch* L, size_t p, uint64_t* out)
{
    uint32_t rank, a;
    uint64_t len = 1, e;
    if (p >= L->ker->n_params) return crisp_geo_extent(L, p, 0, out);
    rank = L->ker->params[p].rank ? L->ker->params[p].rank : 1;
    for (a = 0; a < rank; a++) {
        if (!crisp_geo_extent(L, p, a, &e)) return 0;
        len *= e;
    }
    *out = len;
    return 1;
}

static uint32_t crisp_u32(uint64_t v) { return v > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)v; }

static size_t crisp_type_bytes(crisp_type t)
{
    switch (t) {
    case CRISP_TYPE_CHAR: case CRISP_TYPE_UCHAR: return 1;
    case CRISP_TYPE_SHORT: case CRISP_TYPE_USHORT: case CRISP_TYPE_HALF: case CRISP_TYPE_BFLOAT16: return 2;
    case CRISP_TYPE_INT: case CRISP_TYPE_UINT: case CRISP_TYPE_FLOAT: return 4;
    case CRISP_TYPE_LONG: case CRISP_TYPE_ULONG: case CRISP_TYPE_DOUBLE: case CRISP_TYPE_POINTER: return 8;
    default: return 0;
    }
}

/* The group counts -- %l0-emit-group-count (SPIR-V) and %emit-launch-base (PTX, hoist-cuda), branch
   for branch.  The two hoisters agree except where marked PTX: CUDA sizes at most TWO axes from a
   :set-to list / scalar :derive-from / scalar :exact (gridZ = 1), and has no :interleaved special
   case (it takes the ordinary rules). */
static int crisp_compute_groups(crisp_launch* L)
{
    const crisp_geometry* g = &L->ker->geo;
    const char* s = g->strategy;
    int strided = strcmp(s, "strided") == 0, exact = strcmp(s, "exact") == 0;
    int interleaved = strcmp(s, "interleaved") == 0 && !L->is_ptx;   /* PTX: ordinary rules */
    int one_thread_per = strcmp(s, "one-thread-per") == 0;
    size_t max_axes = L->is_ptx ? 2 : 3;                               /* PTX: gridZ stays 1 */
    uint64_t lx = g->local[0], ly = g->local[1], v;
    uint32_t* G = L->groups;
    G[0] = G[1] = G[2] = 1;

    if (g->n_tile && g->derive_kind && (strided || exact)) {
        /* the rank-N tile grid: axis k <- dimension k of the derive source (Endeavor 143) */
        size_t rank = g->n_tile < 3 ? g->n_tile : 3, k;
        for (k = 0; k < rank; k++) {
            uint64_t tk = g->tile[k] ? g->tile[k] : 1, src = 0;
            int have = 0;
            if (g->derive_kind == 1) {
                if (g->n_derive < 1 || g->derive[0].kind != 1) {   /* names no tensor parameter */
                    if (g->n_derive > 0 && g->derive[0].kind == 2) (void)crisp_geo_value(L, &g->derive[0], &src);
                    else snprintf(L->message, sizeof L->message, "the kernel geometry derives from no tensor parameter");
                    return 0;
                }
                if (!crisp_geo_extent(L, g->derive[0].param, (uint32_t)k, &src)) return 0;
                have = 1;
            } else if (k < g->n_derive) {
                if (!crisp_geo_value(L, &g->derive[k], &src)) return 0;
                have = 1;
            }
            if (have) {
                uint64_t n = (src + tk - 1) / tk;
                G[k] = crisp_u32(n < 1 ? 1 : n);
                if (L->has_max && L->max_groups[k] && G[k] > L->max_groups[k]) {
                    if (!strided) {
                        snprintf(L->message, sizeof L->message,
                                 "axis %u needs %u groups, over the device limit %u; :strategy :exact has no "
                                 "stride loop, so clamping would skip tiles (use :strided for a problem this large)",
                                 (unsigned)k, G[k], L->max_groups[k]);
                        return 0;
                    }
                    G[k] = L->max_groups[k];   /* safe: the tile-stride loop covers the rest */
                }
            }
        }
        return 1;
    }
    if (strided) {
        double ratio = g->has_occupancy ? g->occupancy : 1.0;
        uint64_t n;
        if (!L->has_resident) {
            snprintf(L->message, sizeof L->message,
                     ":strategy :strided sizes the grid by occupancy: set how many groups can be resident "
                     "(crisp_launch_set_resident_groups)");
            return 0;
        }
        n = (uint64_t)((double)L->resident_groups * ratio);
        G[0] = crisp_u32(n < 1 ? 1 : n);
        return 1;
    }
    if (interleaved || !g->has_dispatch) return 1;
    if (exact && g->derive_kind == 1) {
        uint64_t tx = g->n_tile ? (g->tile[0] ? g->tile[0] : 1) : lx;
        if (!crisp_geo_length(L, g->derive[0].param, &v)) return 0;
        G[0] = crisp_u32(crisp_ceil_div(v, tx));
        return 1;
    }
    if (exact) {
        uint64_t tx = g->n_tile ? (g->tile[0] ? g->tile[0] : 1) : lx;
        uint64_t ty = g->n_tile ? (g->n_tile > 1 && g->tile[1] ? g->tile[1] : 1) : (ly > 1 ? ly : 1);
        if (g->derive_kind == 2 && g->n_derive > 0) { if (!crisp_geo_value(L, &g->derive[0], &v)) return 0; G[0] = crisp_u32(crisp_ceil_div(v, tx)); }
        if (g->derive_kind == 2 && g->n_derive > 1) { if (!crisp_geo_value(L, &g->derive[1], &v)) return 0; G[1] = crisp_u32(crisp_ceil_div(v, ty)); }
        if (g->derive_kind == 2 && g->n_derive > 2 && max_axes > 2) { if (!crisp_geo_value(L, &g->derive[2], &v)) return 0; G[2] = crisp_u32(v); }
        return 1;
    }
    if (one_thread_per && g->derive_kind == 1) {
        if (!crisp_geo_length(L, g->derive[0].param, &v)) return 0;
        G[0] = crisp_u32(crisp_ceil_div(v, lx));
        return 1;
    }
    {
        /* a fixed :set-to (one number or a list), or :derive-from scalars: one value per axis */
        const crisp_geo_ref* dims = g->n_set_to ? g->set_to : g->derive;
        size_t nd = g->n_set_to ? g->n_set_to : (g->derive_kind == 2 ? g->n_derive : 0);
        uint64_t div[3];
        size_t k;
        div[0] = lx; div[1] = ly > 1 ? ly : 1; div[2] = 1;
        if (!g->n_set_to && g->derive_kind == 1) {          /* a tensor with no strategy: its length */
            if (!crisp_geo_length(L, g->derive[0].param, &v)) return 0;
            G[0] = crisp_u32(crisp_ceil_div(v, lx));
            return 1;
        }
        for (k = 0; k < nd && k < max_axes; k++) {
            if (!crisp_geo_value(L, &dims[k], &v)) return 0;
            G[k] = crisp_u32(crisp_ceil_div(v, div[k]));
        }
        return 1;
    }
}

/* PTX thread-block clusters (hoist-cuda %cuda-cluster-grid-fixup-string): the driver needs
   gridDim % clusterDim == 0 on every axis.  :strided pads UP (its tile-stride loop leaves surplus
   blocks nothing to claim); :exact, or a kernel using its cluster's reach (multicast / cluster
   barrier), refuses -- a padded block would have no tile, or be a peer that exits early. */
static int crisp_apply_cluster(crisp_launch* L)
{
    const crisp_geometry* g = &L->ker->geo;
    uint32_t* G = L->groups;
    int k, divisible = 1;
    if (!L->is_ptx || (uint64_t)g->cluster[0] * (g->cluster[1] ? g->cluster[1] : 1) * (g->cluster[2] ? g->cluster[2] : 1) <= 1)
        return 1;
    for (k = 0; k < 3; k++) {
        uint32_t c = g->cluster[k] ? g->cluster[k] : 1;
        if (G[k] % c) divisible = 0;
    }
    if (divisible) return 1;
    if (strcmp(g->strategy, "exact") == 0 || g->cluster_reach) {
        snprintf(L->message, sizeof L->message,
                 "grid (%u,%u,%u) is not divisible by the cluster (%u,%u,%u), and %s, so it cannot be padded",
                 G[0], G[1], G[2], g->cluster[0], g->cluster[1] ? g->cluster[1] : 1, g->cluster[2] ? g->cluster[2] : 1,
                 g->cluster_reach ? "the kernel multicasts or uses a cluster barrier (padded blocks would be peers that exit early)"
                                  : ":strategy :exact has no stride loop");
        return 0;
    }
    for (k = 0; k < 3; k++) {
        uint32_t c = g->cluster[k] ? g->cluster[k] : 1;
        G[k] = ((G[k] + c - 1) / c) * c;
    }
    return 1;
}

/* Scratch bytes per parameter -- %l0-scratch-symbolic-expr / %l0-scratch-dims, and the deferred
   :match-num-workgroups block (one element per group in the grid). */
static int crisp_compute_scratch(crisp_launch* L)
{
    const crisp_kernel_rec* k = L->ker;
    uint64_t wg = (uint64_t)k->geo.local[0] * (uint64_t)k->geo.local[1];
    uint64_t warp = L->warp_size ? L->warp_size : (k->geo.warp_size ? k->geo.warp_size : 32);
    size_t p;
    L->shared_bytes = 0;
    for (p = 0; p < k->n_params; p++) {
        const crisp_param_rec* par = &k->params[p];
        uint64_t count = 1;
        size_t i;
        L->param_bytes[p] = 0;
        if (par->purpose != CRISP_PURPOSE_SCRATCH) continue;
        if (par->size_rule) {
            if (strcmp(par->size_rule, "match-workgroup-size") == 0) count = wg;
            else if (strcmp(par->size_rule, "match-num-warps-per-workgroup") == 0) count = (wg + warp - 1) / warp;
            else if (strcmp(par->size_rule, "match-num-workgroups") == 0)
                count = (uint64_t)L->groups[0] * L->groups[1] * L->groups[2];
            else {
                snprintf(L->message, sizeof L->message,
                         "scratch parameter '%s' has a size rule this library cannot resolve: %s",
                         crisp_param_label(L, p), par->size_rule);
                return 0;
            }
        } else {
            for (i = 0; i < par->n_size_elements; i++) count *= par->size_elements[i];
        }
        L->param_bytes[p] = count * crisp_type_bytes(par->element_type);
    }
    if (L->is_ptx) {
        /* hoist-cuda %cuda-shared-layout: local scratch TENSORS packed from offset 0 in slot order,
           local scratch CELLS after them from the tensors' total rounded up to 8 (so an 8-byte cell
           is aligned); the block is every byte the kernel can address, padding included. */
        uint64_t tensor_bytes = 0, cell_base, cell_off;
        int any_cell = 0;
        for (p = 0; p < k->n_params; p++) {
            const crisp_param_rec* par = &k->params[p];
            L->shared_offset[p] = (uint64_t)-1;
            if (par->purpose != CRISP_PURPOSE_SCRATCH || par->address_space != CRISP_ADDRESS_SPACE_LOCAL) continue;
            if (par->kind == CRISP_PARAM_TENSOR) { L->shared_offset[p] = tensor_bytes; tensor_bytes += L->param_bytes[p]; }
            else any_cell = 1;
        }
        cell_base = (tensor_bytes + 7) / 8 * 8;
        cell_off = cell_base;
        for (p = 0; p < k->n_params; p++) {
            const crisp_param_rec* par = &k->params[p];
            if (par->purpose != CRISP_PURPOSE_SCRATCH || par->address_space != CRISP_ADDRESS_SPACE_LOCAL) continue;
            if (par->kind != CRISP_PARAM_TENSOR) { L->shared_offset[p] = cell_off; cell_off += L->param_bytes[p]; }
        }
        L->shared_bytes = any_cell ? cell_off : tensor_bytes;
    }
    return 1;
}

CRISP_API crisp_status crisp_launch_compute(crisp_launch* launch)
{
    if (!launch) return CRISP_ERROR_INVALID_ARGUMENT;
    launch->message[0] = '\0';
    launch->computed = 0;
    if (!crisp_compute_groups(launch) || !crisp_apply_cluster(launch) || !crisp_compute_scratch(launch))
        return CRISP_ERROR_INVALID_ARGUMENT;
    launch->computed = 1;
    return CRISP_OK;
}

CRISP_API const char* crisp_launch_message(const crisp_launch* launch) { return launch ? launch->message : ""; }
CRISP_API int crisp_launch_declared(const crisp_launch* launch) { return launch ? launch->ker->geo.has_dispatch : 0; }

CRISP_API uint32_t crisp_launch_local_size(const crisp_launch* launch, uint32_t axis)
{
    if (!launch || axis > 2) return 0;
    return axis < 2 ? launch->ker->geo.local[axis] : 1;
}

CRISP_API uint32_t crisp_launch_group_count(const crisp_launch* launch, uint32_t axis)
{
    if (!launch || axis > 2 || !launch->computed) return 0;
    return launch->groups[axis];
}

CRISP_API uint64_t crisp_launch_param_bytes(const crisp_launch* launch, size_t param)
{
    if (!launch || !launch->computed || param >= launch->ker->n_params) return 0;
    return launch->param_bytes[param];
}

CRISP_API uint64_t crisp_launch_shared_bytes(const crisp_launch* launch)
{
    return (launch && launch->computed) ? launch->shared_bytes : 0;
}

CRISP_API uint64_t crisp_launch_param_shared_offset(const crisp_launch* launch, size_t param)
{
    if (!launch || !launch->computed || !launch->is_ptx || param >= launch->ker->n_params) return CRISP_NO_SHARED_OFFSET;
    return launch->shared_offset[param];
}

CRISP_API uint32_t crisp_launch_cluster_size(const crisp_launch* launch, uint32_t axis)
{
    uint32_t c;
    if (!launch || axis > 2) return 0;
    c = launch->ker->geo.cluster[axis];
    return c ? c : 1;
}

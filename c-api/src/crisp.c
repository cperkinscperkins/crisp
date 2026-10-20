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
    crisp_role_entry* roles; size_t n_roles, cap_roles;
} crisp_param_rec;

typedef struct { crisp_type type; size_t size; crisp_address_space address_space; } crisp_slot_rec;

typedef struct {
    char* name;
    char* grad_of;
    crisp_slot_rec* slots;   size_t n_slots, cap_slots;
    crisp_param_rec* params; size_t n_params, cap_params;
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
    { "pointer", CRISP_TYPE_POINTER }, { NULL, 0 } };
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
        else if (mod && strcmp(tag, "kernel") == 0) { ker = (crisp_kernel_rec*)CRISP_PUSH(mod->kernels, mod->n_kernels, mod->cap_kernels); slot = NULL; par = NULL; }
        else if (ker && strcmp(tag, "kernel.name") == 0)    { free(ker->name); ker->name = (char*)p; p = NULL; }
        else if (ker && strcmp(tag, "kernel.grad-of") == 0) { free(ker->grad_of); ker->grad_of = (char*)p; p = NULL; }
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

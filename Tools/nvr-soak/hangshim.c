/* hangshim: makes file operations under one folder hang, like a drive that stopped answering (a USB disk that spun down for good, an
 * unplugged network volume). It is a userspace fault injector for tests: nothing in the kernel or the file system is touched, so it is
 * safe on a developer's Mac and in a container, and it is undone by removing one file.
 *
 * Environment (read once, at load):
 *   CB_HANG_ROOT         absolute path of the folder to affect, no trailing slash. Everything below it is affected.
 *   CB_HANG_FLAG         path of the flag file. While it EXISTS, a call that touches ROOT (by path, or by a descriptor opened under
 *                        it) waits in 50 ms steps until the file is removed.
 *   CB_HANG_LOG          optional: appends "<seconds since load> blocked <function>" the first time each function blocks, so a test can
 *                        prove that the shim really intercepted something (a positive control).
 *   CB_HANG_MAX_SECONDS  optional, default 900: one call waits at most this long, so a forgotten flag cannot wedge a process.
 *
 * macOS:  cc -O2 -Wall -dynamiclib -o hangshim.dylib hangshim.c      run with DYLD_INSERT_LIBRARIES=$PWD/hangshim.dylib
 * Linux:  cc -O2 -Wall -D_GNU_SOURCE -shared -fPIC -o hangshim.so hangshim.c -ldl      run with LD_PRELOAD=$PWD/hangshim.so
 *
 * Limits: only calls made through the C library's exported functions are seen (Swift Foundation's file calls are; a call made inside the
 * C library itself, or by a statically linked binary, is not). A symlinked ROOT must be given by the spelling the program uses; the
 * "/private" prefix macOS adds to /tmp, /var and /etc is accepted either way.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#else
#include <dlfcn.h>
#include <sys/vfs.h>
#endif

#define MAX_FD 65536
static unsigned char marked[MAX_FD];       /* descriptors opened under ROOT */
static char root[PATH_MAX], root_alt[PATH_MAX], flag_path[PATH_MAX], log_path[PATH_MAX];
static size_t root_length, root_alt_length;
static double max_seconds = 900;
static double loaded_at;

static double now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

#ifdef __APPLE__
#define REAL(name) name
#define EXPORT(name) hs_##name
#define DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *new_fn; const void *old_fn; } interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee };
#else
/* The C library may call our functions before any constructor of ours ran, so the real function is looked up on first use. */
#define REAL(name) (real_##name ? real_##name : (real_##name = (__typeof__(name) *)dlsym(RTLD_NEXT, #name)))
#define EXPORT(name) name
#define DECLARE_REAL(name) static __typeof__(name) *real_##name
#endif

#ifndef __APPLE__
DECLARE_REAL(open); DECLARE_REAL(open64); DECLARE_REAL(openat); DECLARE_REAL(openat64); DECLARE_REAL(creat); DECLARE_REAL(mkdir);
DECLARE_REAL(mkdirat); DECLARE_REAL(rename); DECLARE_REAL(unlink); DECLARE_REAL(unlinkat); DECLARE_REAL(rmdir); DECLARE_REAL(stat);
DECLARE_REAL(stat64); DECLARE_REAL(lstat); DECLARE_REAL(lstat64); DECLARE_REAL(fstatat); DECLARE_REAL(access); DECLARE_REAL(statvfs);
DECLARE_REAL(statvfs64); DECLARE_REAL(statfs); DECLARE_REAL(statfs64); DECLARE_REAL(opendir); DECLARE_REAL(truncate); DECLARE_REAL(readdir);
DECLARE_REAL(write); DECLARE_REAL(pwrite); DECLARE_REAL(pwrite64); DECLARE_REAL(read); DECLARE_REAL(pread); DECLARE_REAL(pread64);
DECLARE_REAL(fsync); DECLARE_REAL(fdatasync); DECLARE_REAL(ftruncate); DECLARE_REAL(fstat); DECLARE_REAL(close); DECLARE_REAL(dup);
DECLARE_REAL(dup2);
static __typeof__(fcntl) *real_fcntl;
#endif

static int in_root(const char *path) {
    if (!path || root_length == 0 || path[0] != '/') return 0;
    if (strncmp(path, root, root_length) == 0 && (path[root_length] == '/' || path[root_length] == '\0')) return 1;
    if (root_alt_length && strncmp(path, root_alt, root_alt_length) == 0 && (path[root_alt_length] == '/' || path[root_alt_length] == '\0')) return 1;
    return 0;
}
static int fd_in_root(int fd) { return fd >= 0 && fd < MAX_FD && marked[fd]; }
/* A relative path is under ROOT when it is looked up from a directory descriptor that is. */
static int under_dir(int dirfd, const char *path) { return path && path[0] != '/' && fd_in_root(dirfd); }
static int dir_descriptor(DIR *d) { return d ? dirfd(d) : -1; }
static void mark(int fd, int value) { if (fd >= 0 && fd < MAX_FD) marked[fd] = (unsigned char)value; }

static const char *announced_names[32];
static void note_blocked(const char *what) {
    if (log_path[0] == 0) return;
    int i = 0;
    for (; i < 32 && announced_names[i]; i++) if (strcmp(announced_names[i], what) == 0) return;
    if (i == 32) return;
    announced_names[i] = what;   /* `what` is always a string literal */
    FILE *f = fopen(log_path, "a");   /* fopen is not wrapped: its path is outside ROOT */
    if (f) { fprintf(f, "%.3f blocked %s\n", now_seconds() - loaded_at, what); fclose(f); }
}

/* Waits while the flag file exists, at most max_seconds for this call. The limit is per call and not a total over all threads: a daemon with a dozen
 * threads in file calls would otherwise use up a shared budget a dozen times as fast as the clock runs, and the "hung" drive would answer again long
 * before the flag was removed (measured: a 150 s hang that ended after about 85 s with CB_HANG_MAX_SECONDS=600). */
static void wait_if_hung(const char *what) {
    if (flag_path[0] == 0) return;
    int announced = 0;
    double waited = 0;
    for (;;) {
        if (REAL(access)(flag_path, F_OK) != 0) return;
        if (waited >= max_seconds) return;
        if (!announced) { note_blocked(what); announced = 1; }
        usleep(50000);
        waited += 0.05;
    }
}
static void gate_path(const char *what, const char *path) { if (in_root(path)) wait_if_hung(what); }
static void gate_fd(const char *what, int fd) { if (fd_in_root(fd)) wait_if_hung(what); }

__attribute__((constructor)) static void hs_init(void) {
    const char *r = getenv("CB_HANG_ROOT"), *f = getenv("CB_HANG_FLAG"), *l = getenv("CB_HANG_LOG"), *m = getenv("CB_HANG_MAX_SECONDS");
    loaded_at = now_seconds();
    if (r && r[0] == '/' && strlen(r) < sizeof root) {
        strcpy(root, r);
        root_length = strlen(root);
        while (root_length > 1 && root[root_length - 1] == '/') root[--root_length] = 0;
        if (strncmp(root, "/private/", 9) == 0) { strcpy(root_alt, root + 8); root_alt_length = strlen(root_alt); }
    }
    if (f && strlen(f) < sizeof flag_path) strcpy(flag_path, f);
    if (l && strlen(l) < sizeof log_path) strcpy(log_path, l);
    if (m && atof(m) > 0) max_seconds = atof(m);
}

/* ---- open family: wait, call, mark the descriptor ------------------------------------------------------------------------------- */
static int opened(int fd, int under) { if (fd >= 0) mark(fd, under); return fd; }

int EXPORT(open)(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int under = in_root(path);
    if (under) wait_if_hung("open");
    return opened(REAL(open)(path, flags, mode), under);
}
int EXPORT(openat)(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int under = in_root(path) || under_dir(dirfd, path);
    if (under) wait_if_hung("openat");
    return opened(REAL(openat)(dirfd, path, flags, mode), under);
}
#ifndef __APPLE__
int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int under = in_root(path);
    if (under) wait_if_hung("open");
    return opened(REAL(open64)(path, flags, mode), under);
}
int openat64(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int under = in_root(path) || under_dir(dirfd, path);
    if (under) wait_if_hung("openat");
    return opened(REAL(openat64)(dirfd, path, flags, mode), under);
}
int creat(const char *path, mode_t mode) {
    int under = in_root(path);
    if (under) wait_if_hung("open");
    return opened(REAL(creat)(path, mode), under);
}
#endif
DIR *EXPORT(opendir)(const char *path) {
    gate_path("opendir", path);
    DIR *d = REAL(opendir)(path);
    if (d && in_root(path)) mark(dir_descriptor(d), 1);
    return d;
}
struct dirent *EXPORT(readdir)(DIR *d) { gate_fd("readdir", dir_descriptor(d)); return REAL(readdir)(d); }

/* ---- path calls ------------------------------------------------------------------------------------------------------------------ */
int EXPORT(mkdir)(const char *p, mode_t m) { gate_path("mkdir", p); return REAL(mkdir)(p, m); }
int EXPORT(mkdirat)(int d, const char *p, mode_t m) { if (in_root(p) || under_dir(d, p)) wait_if_hung("mkdir"); return REAL(mkdirat)(d, p, m); }
int EXPORT(rename)(const char *a, const char *b) { if (in_root(a) || in_root(b)) wait_if_hung("rename"); return REAL(rename)(a, b); }
int EXPORT(unlink)(const char *p) { gate_path("unlink", p); return REAL(unlink)(p); }
int EXPORT(unlinkat)(int d, const char *p, int f) { if (in_root(p) || under_dir(d, p)) wait_if_hung("unlink"); return REAL(unlinkat)(d, p, f); }
int EXPORT(rmdir)(const char *p) { gate_path("rmdir", p); return REAL(rmdir)(p); }
int EXPORT(stat)(const char *p, struct stat *s) { gate_path("stat", p); return REAL(stat)(p, s); }
int EXPORT(lstat)(const char *p, struct stat *s) { gate_path("stat", p); return REAL(lstat)(p, s); }
int EXPORT(fstatat)(int d, const char *p, struct stat *s, int f) { if (in_root(p) || under_dir(d, p)) wait_if_hung("stat"); return REAL(fstatat)(d, p, s, f); }
int EXPORT(access)(const char *p, int m) { gate_path("access", p); return REAL(access)(p, m); }
int EXPORT(statvfs)(const char *p, struct statvfs *s) { gate_path("statvfs", p); return REAL(statvfs)(p, s); }
int EXPORT(statfs)(const char *p, struct statfs *s) { gate_path("statfs", p); return REAL(statfs)(p, s); }
int EXPORT(truncate)(const char *p, off_t l) { gate_path("truncate", p); return REAL(truncate)(p, l); }
#ifndef __APPLE__
int stat64(const char *p, struct stat64 *s) { gate_path("stat", p); return REAL(stat64)(p, s); }
int lstat64(const char *p, struct stat64 *s) { gate_path("stat", p); return REAL(lstat64)(p, s); }
int statvfs64(const char *p, struct statvfs64 *s) { gate_path("statvfs", p); return REAL(statvfs64)(p, s); }
int statfs64(const char *p, struct statfs64 *s) { gate_path("statfs", p); return REAL(statfs64)(p, s); }
#endif

/* ---- descriptor calls ------------------------------------------------------------------------------------------------------------ */
ssize_t EXPORT(write)(int fd, const void *b, size_t n) { gate_fd("write", fd); return REAL(write)(fd, b, n); }
ssize_t EXPORT(pwrite)(int fd, const void *b, size_t n, off_t o) { gate_fd("write", fd); return REAL(pwrite)(fd, b, n, o); }
ssize_t EXPORT(read)(int fd, void *b, size_t n) { gate_fd("read", fd); return REAL(read)(fd, b, n); }
ssize_t EXPORT(pread)(int fd, void *b, size_t n, off_t o) { gate_fd("read", fd); return REAL(pread)(fd, b, n, o); }
int EXPORT(fsync)(int fd) { gate_fd("fsync", fd); return REAL(fsync)(fd); }
int EXPORT(ftruncate)(int fd, off_t l) { gate_fd("ftruncate", fd); return REAL(ftruncate)(fd, l); }
int EXPORT(fstat)(int fd, struct stat *s) { gate_fd("fstat", fd); return REAL(fstat)(fd, s); }
int EXPORT(fcntl)(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
#ifdef F_FULLFSYNC
    if (cmd == F_FULLFSYNC) gate_fd("fsync", fd);
#endif
    return REAL(fcntl)(fd, cmd, arg);
}
int EXPORT(close)(int fd) { mark(fd, 0); return REAL(close)(fd); }
int EXPORT(dup)(int fd) { int n = REAL(dup)(fd); if (n >= 0) mark(n, fd_in_root(fd)); return n; }
int EXPORT(dup2)(int fd, int to) { int n = REAL(dup2)(fd, to); if (n >= 0) mark(n, fd_in_root(fd)); return n; }
#ifndef __APPLE__
ssize_t pwrite64(int fd, const void *b, size_t n, off64_t o) { gate_fd("write", fd); return REAL(pwrite64)(fd, b, n, o); }
ssize_t pread64(int fd, void *b, size_t n, off64_t o) { gate_fd("read", fd); return REAL(pread64)(fd, b, n, o); }
int fdatasync(int fd) { gate_fd("fsync", fd); return REAL(fdatasync)(fd); }
#endif

#ifdef __APPLE__
DYLD_INTERPOSE(hs_open, open) DYLD_INTERPOSE(hs_openat, openat) DYLD_INTERPOSE(hs_opendir, opendir) DYLD_INTERPOSE(hs_readdir, readdir)
DYLD_INTERPOSE(hs_mkdir, mkdir) DYLD_INTERPOSE(hs_mkdirat, mkdirat) DYLD_INTERPOSE(hs_rename, rename) DYLD_INTERPOSE(hs_unlink, unlink)
DYLD_INTERPOSE(hs_unlinkat, unlinkat) DYLD_INTERPOSE(hs_rmdir, rmdir) DYLD_INTERPOSE(hs_stat, stat) DYLD_INTERPOSE(hs_lstat, lstat)
DYLD_INTERPOSE(hs_fstatat, fstatat) DYLD_INTERPOSE(hs_access, access) DYLD_INTERPOSE(hs_statvfs, statvfs) DYLD_INTERPOSE(hs_statfs, statfs)
DYLD_INTERPOSE(hs_truncate, truncate) DYLD_INTERPOSE(hs_write, write) DYLD_INTERPOSE(hs_pwrite, pwrite) DYLD_INTERPOSE(hs_read, read)
DYLD_INTERPOSE(hs_pread, pread) DYLD_INTERPOSE(hs_fsync, fsync) DYLD_INTERPOSE(hs_ftruncate, ftruncate) DYLD_INTERPOSE(hs_fstat, fstat)
DYLD_INTERPOSE(hs_fcntl, fcntl) DYLD_INTERPOSE(hs_close, close) DYLD_INTERPOSE(hs_dup, dup) DYLD_INTERPOSE(hs_dup2, dup2)
#endif

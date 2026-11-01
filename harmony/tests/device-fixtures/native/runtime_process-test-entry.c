/* 每次启动在独立正式子进程运行一次 Node，参数为 dsh|安装目录|数据目录。 */
#define _GNU_SOURCE
#include <AbilityKit/native_child_process.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "argument_storage.h"

static int absolute(const char *value) {
    return value && value[0] == '/' && !strstr(value, "..") && !strchr(value, '|');
}
static int join(char *out, size_t size, const char *base, const char *leaf) {
    int n = snprintf(out, size, "%s/%s", base, leaf);
    return n > 0 && (size_t)n < size;
}
static void report(const char *file, const char *phase, int code) {
    char text[128];
    int n = snprintf(text, sizeof(text), "{\"phase\":\"%s\",\"code\":%d}\n", phase, code);
    int fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { (void)write(fd, text, (size_t)n); close(fd); }
}
__attribute__((visibility("default")))
void ProbeDsh(NativeChildProcess_Args args) {
    if (!args.entryParams || strlen(args.entryParams) >= 4096) return;
    char input[4096];
    strcpy(input, args.entryParams);
    char *cursor = input;
    char *phase = strsep(&cursor, "|");
    char *installed = strsep(&cursor, "|");
    char *data = strsep(&cursor, "|");
    char *generation = cursor ? strsep(&cursor, "|") : NULL;
    const int tools_probe = cursor != NULL;
    if (strcmp(phase, "dsh") || !absolute(installed) || !absolute(data) ||
        (generation && (!*generation || strlen(generation) > 80)) ||
        (tools_probe && strcmp(cursor, "real-tools-probe-v1"))) return;
    if (tools_probe) {
        const char *leaf = strrchr(data, '/');
        if (!leaf || strncmp(leaf + 1, "engine-tools-probe-", 19) != 0) return;
        const char *number = leaf + 20;
        if (!*number || strspn(number, "0123456789") != strlen(number)) return;
    }
    if (generation) for (const char *p = generation; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '-')) return;
    char state[2048], result[2048], script[2048], home[2048], temp[2048];
    if (!join(state, sizeof(state), installed, "reports/dsh/native.json") ||
        !join(result, sizeof(result), installed, "reports/dsh/result.json") ||
        !join(script, sizeof(script), installed, "transport/run-loopback-smoke.mjs") ||
        !join(home, sizeof(home), data, "home") || !join(temp, sizeof(temp), data, "tmp")) return;
    int broker_fd = -1, broker_original = -1;
    for (NativeChildProcess_Fd *item = args.fdList.head; item; item = item->next) {
        if (item->fdName && strcmp(item->fdName, "dshBroker") == 0) {
            if (broker_original >= 0 || item->fd < 0) { report(state, "BROKER_FD_FAILED", 1); return; }
            broker_original = item->fd;
        }
    }
    if ((generation != NULL) != (broker_original >= 0)) { report(state, "BROKER_FD_FAILED", 2); return; }
    if (broker_original >= 0) {
        broker_fd = fcntl(broker_original, F_DUPFD_CLOEXEC, 64);
        if (broker_fd < 0) { report(state, "BROKER_FD_FAILED", 3); return; }
        if (broker_original > STDERR_FILENO) close(broker_original);
    }
    int devnull = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (devnull < 0) { report(state, "REDIRECT_FAILED", 1); return; }
    if (dup2(devnull, STDOUT_FILENO) < 0 || dup2(devnull, STDERR_FILENO) < 0) {
        close(devnull); report(state, "REDIRECT_FAILED", 2); return;
    }
    if (devnull > STDERR_FILENO) close(devnull);
    int hold[2];
    if (pipe(hold) != 0) { report(state, "STDIN_FAILED", 1); return; }
    if (dup2(hold[0], STDIN_FILENO) < 0) { close(hold[0]); close(hold[1]); return; }
    close(hold[0]); /* 保持写端打开，CLI 不会因为 stdin EOF 自行退出。 */
    mkdir(data, 0700); mkdir(home, 0700); mkdir(temp, 0700);
    clearenv();
    if (tools_probe) setenv("DSH_HARMONY_REAL_TOOLS_PROBE", "1", 1);
    if (broker_fd >= 0) {
        char number[24]; snprintf(number, sizeof(number), "%d", broker_fd);
        setenv("DSH_HARMONY_BROKER_FD", number, 1);
        setenv("DSH_HARMONY_BROKER_GENERATION", generation, 1);
    }
    setenv("HOME", home, 1); setenv("TMPDIR", temp, 1);
    setenv("UV_USE_IO_URING", "0", 1); setenv("NO_COLOR", "1", 1);
    setenv("NARB_DISABLE_NATIVE_CACHE", "1", 1);
    Dl_info info;
    char libraries[2048];
    if (!dladdr((void *)ProbeDsh, &info) || !info.dli_fname || strlen(info.dli_fname) >= sizeof(libraries)) return;
    strcpy(libraries, info.dli_fname);
    char *slash = strrchr(libraries, '/');
    if (!slash) return;
    *slash = '\0';
    setenv("DSH_HARMONY_NATIVE_LIBRARY_DIR", libraries, 1);
    void *node = dlopen("libnode.so", RTLD_NOW | RTLD_GLOBAL);
    if (!node) { report(state, "NODE_LOAD_FAILED", 1); return; }
    /* 仅记录符号地址是否一致，不输出本机路径或运行时地址。 */
    char binding[2048];
    if (join(binding, sizeof(binding), installed, "reports/dsh/binding.json")) {
        void *global_uv = dlsym(RTLD_DEFAULT, "uv_default_loop");
        void *node_uv = dlsym(node, "uv_default_loop");
        int fd = open(binding, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            const char *value = global_uv == node_uv ? "{\"uvSymbolMatches\":true}" : "{\"uvSymbolMatches\":false}";
            (void)write(fd, value, strlen(value)); close(fd);
        }
    }
    int (*start)(int, char **) = (int (*)(int, char **))dlsym(node, "_ZN4node5StartEiPPc");
    if (!start) { report(state, "NODE_LOAD_FAILED", 2); return; }
    char *argv[9] = { "node", "--jitless", "--wasm-jitless", script, installed, data, result, "38081", NULL };
    char storage[8192];
    if (!dsh_pack_arguments(8, argv, 9, storage, sizeof(storage))) return;
    report(state, "BEFORE_NODE_START", 0);
    int code = start(8, argv);
    report(state, "NODE_RETURNED", code);
    /* Node 已退出即结束子进程；不能用 pause 冒充仍在运行的服务。 */
}

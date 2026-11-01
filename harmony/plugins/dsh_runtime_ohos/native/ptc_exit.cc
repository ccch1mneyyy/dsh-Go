#include <node.h>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdio>
namespace {
int status_fd = -1;
void (*shutdown_io)() = nullptr;
std::atomic<bool> reported{false};
// 固定16字节记录，不与stdout或不可信PTC控制消息混用。
void report(int code, uint32_t source) {
  if (status_fd < 0 || reported.exchange(true)) return;
  const uint32_t record[4] = {0x44534858u, 1u, source, static_cast<uint32_t>(code)};
  ssize_t result;
  do { result = write(status_fd, record, sizeof(record)); } while (result < 0 && errno == EINTR);
  // 写入失败由父端缺少完整记录判失败，不能伪造exit0。
}
}
extern "C" __attribute__((visibility("default"))) int DshConfigureExitObserver(int fd) {
  if (status_fd >= 0 || fd < 0) return -1;
  status_fd = fcntl(fd, F_DUPFD_CLOEXEC, 64);
  return status_fd < 0 ? -1 : 0;
}
extern "C" __attribute__((visibility("default"))) void DshObserveNodeReturn(int code) { report(code, 2); }
NODE_MODULE_INIT() {
  (void)exports; (void)module;
#ifdef EXIT_OBSERVER_LOCAL_TEST
  // 仅本地固定fixture使用环境传FD；产品入口由C函数设置，不导出JS方法。
  const char* text = std::getenv("DSH_FIXED_EXIT_FD");
  if (text) { DshConfigureExitObserver(std::atoi(text)); unsetenv("DSH_FIXED_EXIT_FD"); }
#endif
#ifndef EXIT_OBSERVER_LOCAL_TEST
  // 入口库为RTLD_LOCAL，不能依赖全局符号表；只查同目录已加载的固定签名库。
  Dl_info self{};
  char launcher[2048]{};
  void* entry = nullptr;
  if (dladdr(reinterpret_cast<void*>(DshConfigureExitObserver), &self) && self.dli_fname) {
    const char* slash = std::strrchr(self.dli_fname, '/');
    if (slash) {
      const size_t prefix = static_cast<size_t>(slash - self.dli_fname) + 1;
      constexpr char name[] = "libdsh_ptc_child.so";
      if (prefix + sizeof(name) <= sizeof(launcher)) {
        std::memcpy(launcher, self.dli_fname, prefix);
        std::memcpy(launcher + prefix, name, sizeof(name));
        entry = dlopen(launcher, RTLD_NOW | RTLD_NOLOAD);
      }
    }
  }
  auto get_fd = entry ? reinterpret_cast<int (*)()>(dlsym(entry, "DshTaskStatusFd")) : nullptr;
  if (status_fd < 0 && get_fd) DshConfigureExitObserver(get_fd());
  if (entry) { shutdown_io = reinterpret_cast<void (*)()>(dlsym(entry, "DshTaskShutdownIo")); dlclose(entry); }
#endif
  node::Environment* env = node::GetCurrentEnvironment(context);
  if (!env || status_fd < 0) {
    context->GetIsolate()->ThrowException(v8::Exception::Error(v8::String::NewFromUtf8Literal(context->GetIsolate(), "EXIT_OBSERVER_NOT_CONFIGURED")));
    return;
  }
  node::SetProcessExitHandler(env, [](node::Environment* current, int code) {
    report(code, 1);
    if (shutdown_io) shutdown_io();
    node::DefaultProcessExitHandler(current, code);
  });
}

#include <node.h>
#include <string>
#include <vector>
/* 官方嵌入API保留真实stdio，仅跳过不适用于独立UID继承socket的元数据初始化。 */
extern "C" __attribute__((visibility("default"))) int DshPtcRunEmbedded(
    int argc, char** argv, const char* script) {
  if (argc < 1 || !argv || !script) return 85;
  std::vector<std::string> args(argv, argv + argc);
  auto initialized = node::InitializeOncePerProcess(args, {
      node::ProcessInitializationFlags::kNoStdioInitialization,
      node::ProcessInitializationFlags::kDisableNodeOptionsEnv});
  if (initialized->early_return()) return initialized->exit_code();
  int code = 1;
  {
    std::vector<std::string> errors;
    auto setup = node::CommonEnvironmentSetup::Create(
        initialized->platform(), &errors, initialized->args(), initialized->exec_args());
    if (setup) {
      v8::Isolate* isolate = setup->isolate();
      v8::Locker locker(isolate);
      v8::Isolate::Scope isolate_scope(isolate);
      v8::HandleScope handles(isolate);
      v8::Context::Scope context_scope(setup->context());
      if (!node::LoadEnvironment(setup->env(), script).IsEmpty()) {
        code = node::SpinEventLoop(setup->env()).FromMaybe(1);
      }
      node::Stop(setup->env());
    }
  }
  node::TearDownOncePerProcess();
  return code;
}

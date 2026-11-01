#include "publication_binding.h"

#include <node.h>
#include <node_api.h>
#include <uv.h>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <linux/fs.h>
#include <string>
#include <sys/syscall.h>
#include <unistd.h>
#include <vector>

namespace {

bool ReadPath(napi_env env, napi_value value, std::string* path) {
  napi_valuetype type;
  if (napi_typeof(env, value, &type) != napi_ok) return false;
  if (type != napi_string) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Paths must be strings");
    return false;
  }
  size_t length;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
  std::vector<char> bytes(length + 1);
  if (napi_get_value_string_utf8(env, value, bytes.data(), bytes.size(), &length) != napi_ok) return false;
  if (std::memchr(bytes.data(), '\0', length) != nullptr) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "Paths must not contain NUL");
    return false;
  }
  path->assign(bytes.data(), length);
  return true;
}

napi_value RenameNoReplace(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) return nullptr;
  if (argc < 2) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Two path strings are required");
    return nullptr;
  }
  std::string source, destination;
  if (!ReadPath(env, argv[0], &source) || !ReadPath(env, argv[1], &destination)) return nullptr;

#ifdef SYS_renameat2
  const long rename_result = syscall(SYS_renameat2, AT_FDCWD, source.c_str(),
                              AT_FDCWD, destination.c_str(), RENAME_NOREPLACE);
  const int error_number = rename_result == 0 ? 0 : errno;
#else
  const int error_number = ENOSYS;
#endif
  if (error_number != 0) {
    const int uv_error = uv_translate_sys_error(error_number);
    napi_value message, code, error, number, operation;
    if (napi_create_string_utf8(env, "renameat2(RENAME_NOREPLACE) failed", NAPI_AUTO_LENGTH, &message) != napi_ok ||
        napi_create_string_utf8(env, uv_err_name(uv_error), NAPI_AUTO_LENGTH, &code) != napi_ok ||
        napi_create_error(env, code, message, &error) != napi_ok ||
        napi_create_int32(env, -error_number, &number) != napi_ok ||
        napi_set_named_property(env, error, "errno", number) != napi_ok ||
        napi_create_string_utf8(env, "renameat2", NAPI_AUTO_LENGTH, &operation) != napi_ok ||
        napi_set_named_property(env, error, "syscall", operation) != napi_ok) return nullptr;
    napi_throw(env, error);
    return nullptr;
  }
  napi_value result;
  if (napi_get_undefined(env, &result) != napi_ok) return nullptr;
  return result;
}

napi_value Initialize(napi_env env, napi_value exports) {
  const napi_node_version* version;
  if (napi_get_node_version(env, &version) != napi_ok) return nullptr;
  if (version->major != 24 || version->minor != 22 || version->patch != 1) {
    napi_throw_error(env, "ERR_OHOS_NATIVE_NODE_VERSION", "Publication binding requires Node 24.22.1");
    return nullptr;
  }
  napi_value function;
  if (napi_create_function(env, "renameNoReplace", NAPI_AUTO_LENGTH, RenameNoReplace,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "renameNoReplace", function) != napi_ok) return nullptr;
  return exports;
}

// Node 24.22.1's pre-Start registration puts this descriptor in the linked list.
// NAPI_MODULE_X ignores its flags argument and is not a substitute for this call.
// Registration uses the default Node-API version (8), matching our test build.
napi_module publication_module = {
    NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
    "runtime/ohos/host/publication_binding.cc", Initialize,
    "dsh_ohos_publication", nullptr, {nullptr, nullptr, nullptr, nullptr}};

}  // namespace

void RegisterPublicationBinding() {
  napi_module_register(&publication_module);
}

#ifdef DSH_PUBLICATION_TEST_ADDON
NAPI_MODULE(dsh_ohos_publication, Initialize)
#endif

#ifdef DSH_PUBLICATION_TEST_PRELOAD
__attribute__((constructor)) static void TestPreStartRegistration() {
  RegisterPublicationBinding();
}
#endif

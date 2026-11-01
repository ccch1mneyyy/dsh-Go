#define _GNU_SOURCE
#include <node_api.h>
#include <uv.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

/* 同目录排他发布：成功消费源文件，冲突保留源与目标，不回退为覆盖重命名。 */
static int read_path(napi_env env, napi_value value, char *path) {
    size_t length = 0, copied = 0;
    if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) {
        napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "发布路径必须是字符串");
        return 0;
    }
    if (!length || length >= PATH_MAX) {
        napi_throw_range_error(env, "ERR_INVALID_ARG_VALUE", "发布路径长度无效");
        return 0;
    }
    if (napi_get_value_string_utf8(env, value, path, PATH_MAX, &copied) != napi_ok) return 0;
    if (copied != length || strlen(path) != length || path[0] != '/') {
        napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "发布路径必须是无空字符的绝对路径");
        return 0;
    }
    return 1;
}
static napi_value publish(napi_env env, napi_callback_info info) {
    size_t count = 2;
    napi_value args[2], result;
    if (napi_get_cb_info(env, info, &count, args, NULL, NULL) != napi_ok) return NULL;
    if (count != 2) {
        napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "排他发布需要源和目标路径");
        return NULL;
    }
    char source[PATH_MAX], target[PATH_MAX];
    if (!read_path(env, args[0], source) || !read_path(env, args[1], target)) return NULL;
    if (renameat2(AT_FDCWD, source, AT_FDCWD, target, RENAME_NOREPLACE) != 0) {
        int error_number = uv_translate_sys_error(errno);
        napi_value code, message, error, number, syscall;
        if (napi_create_string_utf8(env, uv_err_name(error_number), NAPI_AUTO_LENGTH, &code) != napi_ok ||
            napi_create_string_utf8(env, "排他发布失败", NAPI_AUTO_LENGTH, &message) != napi_ok ||
            napi_create_error(env, code, message, &error) != napi_ok ||
            napi_create_int32(env, error_number, &number) != napi_ok ||
            napi_set_named_property(env, error, "errno", number) != napi_ok ||
            napi_create_string_utf8(env, "renameat2", NAPI_AUTO_LENGTH, &syscall) != napi_ok ||
            napi_set_named_property(env, error, "syscall", syscall) != napi_ok) return NULL;
        napi_throw(env, error);
        return NULL;
    }
    if (napi_get_undefined(env, &result) != napi_ok) return NULL;
    return result;
}
static napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor property = {"publishNoReplaceSync", NULL, publish, NULL, NULL, NULL, napi_default, NULL};
    if (napi_define_properties(env, exports, 1, &property) != napi_ok) return NULL;
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)

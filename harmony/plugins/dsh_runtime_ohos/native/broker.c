#define _GNU_SOURCE
#include <napi/native_api.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* 每个引擎代次持有独立连接；子端只传给主引擎，不授予执行任务。 */
static int host_fd = -1, child_fd = -1;
static int32_t generation;
static napi_value integer(napi_env env, int32_t value) {
    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}
static void property(napi_env env, napi_value object, const char *name, int32_t value) {
    napi_set_named_property(env, object, name, integer(env, value));
}
static int32_t handle(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value input;
    int32_t value = -1;
    if (napi_get_cb_info(env, info, &count, &input, NULL, NULL) == napi_ok && count == 1)
        napi_get_value_int32(env, input, &value);
    return value;
}
static napi_value create(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result;
    napi_create_object(env, &result);
    if (host_fd >= 0 || child_fd >= 0 || generation == INT32_MAX) {
        property(env, result, "error", EBUSY);
        return result;
    }
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0) {
        property(env, result, "error", errno);
        return result;
    }
    if (fcntl(pair[0], F_SETFL, O_NONBLOCK) != 0) {
        int saved = errno;
        close(pair[0]); close(pair[1]);
        property(env, result, "error", saved);
        return result;
    }
    host_fd = pair[0]; child_fd = pair[1]; ++generation;
    property(env, result, "handle", generation);
    property(env, result, "fd", child_fd);
    property(env, result, "error", 0);
    return result;
}
static napi_value attached(napi_env env, napi_callback_info info) {
    if (handle(env, info) != generation || host_fd < 0) return integer(env, -EINVAL);
    if (child_fd >= 0) { close(child_fd); child_fd = -1; }
    return integer(env, 0);
}
static napi_value read_bytes(napi_env env, napi_callback_info info) {
    napi_value result, buffer, bytes;
    napi_create_object(env, &result);
    unsigned char data[65536];
    ssize_t count = -1;
    int error = 0;
    if (handle(env, info) != generation || host_fd < 0) error = EINVAL;
    else {
        count = read(host_fd, data, sizeof(data));
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) error = errno;
    }
    size_t length = count > 0 ? (size_t)count : 0;
    void *destination;
    napi_create_arraybuffer(env, length, &destination, &buffer);
    if (length) memcpy(destination, data, length);
    napi_create_typedarray(env, napi_uint8_array, length, buffer, 0, &bytes);
    napi_set_named_property(env, result, "bytes", bytes);
    property(env, result, "eof", count == 0);
    property(env, result, "error", error);
    return result;
}
static napi_value write_bytes(napi_env env, napi_callback_info info) {
    napi_value args[2], buffer;
    size_t count = 2, length = 0, offset;
    napi_typedarray_type type;
    void *data;
    int32_t id = -1;
    if (napi_get_cb_info(env, info, &count, args, NULL, NULL) != napi_ok || count != 2 ||
        napi_get_value_int32(env, args[0], &id) != napi_ok || id != generation || host_fd < 0 ||
        napi_get_typedarray_info(env, args[1], &type, &length, &data, &buffer, &offset) != napi_ok ||
        type != napi_uint8_array || length > 65536) return integer(env, -EINVAL);
    ssize_t sent = send(host_fd, data, length, MSG_NOSIGNAL);
    if (sent >= 0) return integer(env, (int32_t)sent);
    return integer(env, errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -errno);
}
static napi_value close_pair(napi_env env, napi_callback_info info) {
    if (handle(env, info) != generation) return integer(env, -EINVAL);
    if (host_fd >= 0) close(host_fd);
    if (child_fd >= 0) close(child_fd);
    host_fd = child_fd = -1;
    return integer(env, 0);
}
static napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor methods[] = {
        {"create",0,create,0,0,0,napi_default,0},
        {"attached",0,attached,0,0,0,napi_default,0},
        {"read",0,read_bytes,0,0,0,napi_default,0},
        {"write",0,write_bytes,0,0,0,napi_default,0},
        {"close",0,close_pair,0,0,0,napi_default,0}
    };
    napi_define_properties(env, exports, 5, methods);
    return exports;
}
static napi_module module = {.nm_version=1,.nm_register_func=init,.nm_modname="dsh_broker"};
__attribute__((constructor)) static void register_module(void) { napi_module_register(&module); }

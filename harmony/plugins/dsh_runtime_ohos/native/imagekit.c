/* 候选：仅内存图像，不接受文件路径；Node NAPI异步工作中调用系统ImageKit。 */
#include <node_api.h>
/* 图像头包含ArkTS NAPI头，但本库所有NAPI符号必须来自libnode。 */
#define FOUNDATION_ACE_NAPI_INTERFACES_KITS_NAPI_NATIVE_API_H
#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/image_packer_native.h>
#include <native_color_space_manager/native_color_space_manager.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    napi_async_work work; napi_deferred deferred;
    uint8_t *input, *output; size_t input_size, output_size;
    uint32_t width, height, frames, max_pixels, max_dimension, orientation, out_width, out_height, quality;
    int encode, transparent, native_code; uint32_t stage, native_flags, native_value; const char *error; char mime[16];
} Job;
static atomic_uint pending = 0;
static const size_t MAX_INPUT = 20U * 1024U * 1024U, MAX_OUTPUT = 32U * 1024U * 1024U;
#define OK(call) do { Image_ErrorCode code = (call); if (code != IMAGE_SUCCESS) { job->native_code = (int)code; job->error = "IMAGE_BACKEND_FAILED"; goto done; } } while (0)
/* 仅用于诊断：负数或超界枚举/尺寸统一用有界哨兵，不返回图像或地址。 */
static uint32_t diagnostic_value(int64_t value) {
    return value >= 0 && value < 1048575 ? (uint32_t)value : 1048575;
}
#define DIAG(flag, value) do { if (!job->native_flags) job->native_value = diagnostic_value(value); job->native_flags |= (flag); } while (0)

static void execute(napi_env env, void *data) {
    (void)env; Job *job = data;
    OH_ImageSourceNative *source = NULL; OH_ImageSource_Info *source_info = NULL;
    OH_DecodingOptions *decode = NULL; OH_PixelmapNative *pixels = NULL, *oriented = NULL, *scaled = NULL;
    OH_Pixelmap_ImageInfo *info = NULL; OH_Pixelmap_InitializationOptions *initial = NULL;
    OH_ImagePackerNative *packer = NULL; OH_PackingOptions *packing = NULL;
    OH_NativeColorSpaceManager *space = NULL, *created_space = NULL, *scaled_space = NULL;
    uint8_t *raw = NULL, *turned = NULL; uint32_t width = 0, height = 0, frames = 0, stride = 0;
    int32_t format = 0, alpha = 0; bool hdr = false;
    job->stage = 1; OK(OH_ImageSourceNative_CreateFromData(job->input, job->input_size, &source));
    job->stage = 2;
    OK(OH_ImageSourceInfo_Create(&source_info));
    OK(OH_ImageSourceNative_GetImageInfo(source, 0, source_info));
    OK(OH_ImageSourceInfo_GetWidth(source_info, &width)); OK(OH_ImageSourceInfo_GetHeight(source_info, &height));
    OK(OH_ImageSourceNative_GetFrameCount(source, &frames));
    if (width != job->width || height != job->height || frames != job->frames) { job->error = "IMAGE_BACKEND_MISMATCH"; goto done; }
    if ((uint64_t)width * height > job->max_pixels) { job->error = "IMAGE_TOO_MANY_PIXELS"; goto done; }
    if (width > job->max_dimension || height > job->max_dimension) { job->error = "IMAGE_DIMENSION_TOO_LARGE"; goto done; }
    job->stage = 3; OK(OH_DecodingOptions_Create(&decode)); OK(OH_DecodingOptions_SetIndex(decode, 0));
    OK(OH_DecodingOptions_SetPixelFormat(decode, PIXEL_FORMAT_RGBA_8888));
    OK(OH_DecodingOptions_SetDesiredColorSpace(decode, SRGB));
    OK(OH_DecodingOptions_SetDesiredDynamicRange(decode, IMAGE_DYNAMIC_RANGE_SDR));
    job->stage = 4; OK(OH_ImageSourceNative_CreatePixelmapUsingAllocator(source, decode, IMAGE_ALLOCATOR_TYPE_SHARE_MEMORY, &pixels));
    job->stage = 5;
    OK(OH_PixelmapImageInfo_Create(&info)); OK(OH_PixelmapNative_GetImageInfo(pixels, info));
    uint32_t decoded_width = 0, decoded_height = 0;
    OK(OH_PixelmapImageInfo_GetWidth(info, &decoded_width)); OK(OH_PixelmapImageInfo_GetHeight(info, &decoded_height));
    OK(OH_PixelmapImageInfo_GetPixelFormat(info, &format)); OK(OH_PixelmapImageInfo_GetAlphaMode(info, &alpha));
    OK(OH_PixelmapImageInfo_GetDynamicRange(info, &hdr)); OK(OH_PixelmapImageInfo_GetRowStride(info, &stride));
    job->stage = 6; OK(OH_PixelmapNative_GetColorSpaceNative(pixels, &space));
    int color_name = space ? OH_NativeColorSpaceManager_GetColorSpaceName(space) : 0;
    /* 与原guard逐项相同；位1/2/4/8/16/32仅标识失败，不放宽条件。 */
    if (decoded_width != width || decoded_height != height) DIAG(1, decoded_width != width ? decoded_width : decoded_height);
    if (format != PIXEL_FORMAT_RGBA_8888) DIAG(2, format);
    if (hdr) DIAG(4, 1);
    if (!space || color_name != SRGB) DIAG(8, color_name);
    if (alpha != PIXELMAP_ALPHA_TYPE_OPAQUE && alpha != PIXELMAP_ALPHA_TYPE_PREMULTIPLIED && alpha != PIXELMAP_ALPHA_TYPE_UNPREMULTIPLIED) DIAG(16, alpha);
    if (stride < (uint64_t)width * 4 || stride > (uint64_t)width * 4 + 65536) DIAG(32, stride);
    if (job->native_flags) { job->error = "IMAGE_BACKEND_MISMATCH"; goto done; }
    size_t raw_size = (size_t)stride * height;
    if (raw_size > 320U * 1024U * 1024U) { job->error = "IMAGE_TOO_MANY_PIXELS"; goto done; }
    job->stage = 7; raw = malloc(raw_size); if (!raw) { job->error = "IMAGE_ALLOCATION_FAILED"; goto done; }
    OK(OH_PixelmapNative_ReadPixels(pixels, raw, &raw_size));
    if (raw_size != (size_t)stride * height) { job->error = "IMAGE_BACKEND_MISMATCH"; goto done; }
    for (uint32_t y = 0; y < height; y++) for (uint32_t x = 0; x < width; x++) if (raw[(size_t)y * stride + x * 4 + 3] != 255) job->transparent = 1;
    if (!job->encode) goto done;
    /* 方向用整数RGBA坐标映射，避免依赖系统旋转角度方向或自动方向的隐含行为。 */
    job->stage = 8; uint32_t ow = job->orientation >= 5 ? height : width, oh = job->orientation >= 5 ? width : height;
    if (job->out_width > ow || job->out_height > oh) { job->error = "IMAGE_BACKEND_MISMATCH"; goto done; }
    turned = malloc((size_t)ow * oh * 4); if (!turned) { job->error = "IMAGE_ALLOCATION_FAILED"; goto done; }
    for (uint32_t y = 0; y < height; y++) for (uint32_t x = 0; x < width; x++) {
        uint32_t dx = x, dy = y;
        switch (job->orientation) {
            case 2: dx = width - 1 - x; break;
            case 3: dx = width - 1 - x; dy = height - 1 - y; break;
            case 4: dy = height - 1 - y; break;
            case 5: dx = y; dy = x; break;
            case 6: dx = height - 1 - y; dy = x; break;
            case 7: dx = height - 1 - y; dy = width - 1 - x; break;
            case 8: dx = y; dy = width - 1 - x; break;
            default: break;
        }
        memcpy(turned + ((size_t)dy * ow + dx) * 4, raw + (size_t)y * stride + x * 4, 4);
    }
    job->stage = 9; OK(OH_PixelmapInitializationOptions_Create(&initial));
    OK(OH_PixelmapInitializationOptions_SetWidth(initial, ow)); OK(OH_PixelmapInitializationOptions_SetHeight(initial, oh));
    OK(OH_PixelmapInitializationOptions_SetPixelFormat(initial, PIXEL_FORMAT_RGBA_8888));
    OK(OH_PixelmapInitializationOptions_SetSrcPixelFormat(initial, PIXEL_FORMAT_RGBA_8888));
    OK(OH_PixelmapInitializationOptions_SetAlphaType(initial, alpha));
    OK(OH_PixelmapInitializationOptions_SetRowStride(initial, ow * 4));
    OK(OH_PixelmapNative_CreatePixelmap(turned, (size_t)ow * oh * 4, initial, &oriented));
    created_space = OH_NativeColorSpaceManager_CreateFromName(SRGB);
    if (!created_space) { job->error = "IMAGE_BACKEND_FAILED"; goto done; }
    OK(OH_PixelmapNative_SetColorSpaceNative(oriented, created_space));
    job->stage = 10; OK(OH_PixelmapNative_CreateScaledPixelMapWithAntiAliasing(oriented, &scaled,
        (float)job->out_width / ow, (float)job->out_height / oh, OH_PixelmapNative_AntiAliasing_HIGH));
    OK(OH_PixelmapNative_GetImageInfo(scaled, info));
    OK(OH_PixelmapImageInfo_GetWidth(info, &decoded_width)); OK(OH_PixelmapImageInfo_GetHeight(info, &decoded_height));
    if (decoded_width != job->out_width || decoded_height != job->out_height) { job->error = "IMAGE_BACKEND_MISMATCH"; goto done; }
    /* 清理新编码输出ICC之前，必须核实缩放后实际像素仍为RGBA8/SDR/SRGB。 */
    OK(OH_PixelmapImageInfo_GetPixelFormat(info, &format)); OK(OH_PixelmapImageInfo_GetDynamicRange(info, &hdr));
    OK(OH_PixelmapImageInfo_GetAlphaMode(info, &alpha)); OK(OH_PixelmapNative_GetColorSpaceNative(scaled, &scaled_space));
    if (format != PIXEL_FORMAT_RGBA_8888 || hdr || !scaled_space || OH_NativeColorSpaceManager_GetColorSpaceName(scaled_space) != SRGB ||
        (alpha != PIXELMAP_ALPHA_TYPE_OPAQUE && alpha != PIXELMAP_ALPHA_TYPE_PREMULTIPLIED && alpha != PIXELMAP_ALPHA_TYPE_UNPREMULTIPLIED)) { job->error = "IMAGE_BACKEND_MISMATCH"; goto done; }
    job->stage = 11; OK(OH_ImagePackerNative_Create(&packer)); OK(OH_PackingOptions_Create(&packing));
    Image_MimeType mime = { job->mime, strlen(job->mime) };
    OK(OH_PackingOptions_SetMimeType(packing, &mime)); OK(OH_PackingOptions_SetQuality(packing, job->quality));
    OK(OH_PackingOptions_SetNeedsPackProperties(packing, false));
    OK(OH_PackingOptions_SetDesiredDynamicRange(packing, IMAGE_PACKER_DYNAMIC_RANGE_SDR));
    job->output = malloc(MAX_OUTPUT); job->output_size = MAX_OUTPUT;
    if (!job->output) { job->error = "IMAGE_ALLOCATION_FAILED"; goto done; }
    job->stage = 12; OK(OH_ImagePackerNative_PackToDataFromPixelmap(packer, packing, scaled, job->output, &job->output_size));
    if (!job->output_size || job->output_size > MAX_OUTPUT) job->error = "IMAGE_BACKEND_MISMATCH";
done:
    if (scaled_space) OH_NativeColorSpaceManager_Destroy(scaled_space);
    if (packing) OH_PackingOptions_Release(packing);
    if (packer) OH_ImagePackerNative_Release(packer);
    if (scaled) OH_PixelmapNative_Release(scaled);
    if (oriented) OH_PixelmapNative_Release(oriented);
    if (created_space) OH_NativeColorSpaceManager_Destroy(created_space);
    if (space) OH_NativeColorSpaceManager_Destroy(space);
    if (initial) OH_PixelmapInitializationOptions_Release(initial);
    if (info) OH_PixelmapImageInfo_Release(info);
    if (pixels) OH_PixelmapNative_Release(pixels);
    if (decode) OH_DecodingOptions_Release(decode);
    if (source_info) OH_ImageSourceInfo_Release(source_info);
    if (source) OH_ImageSourceNative_Release(source);
    free(raw); free(turned);
}
static napi_value error_value(napi_env env, const char *code) {
    napi_value key, message, error;
    napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &key);
    napi_create_string_utf8(env, "图像候选处理失败", NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, key, message, &error); return error;
}
static void set_uint(napi_env env, napi_value object, const char *key, uint32_t value) {
    napi_value number; napi_create_uint32(env, value, &number); napi_set_named_property(env, object, key, number);
}
static void complete(napi_env env, napi_status status, void *data) {
    Job *job = data; napi_value result, bytes, boolean;
    if (status != napi_ok && !job->error) job->error = "IMAGE_BACKEND_FAILED";
    if (job->error) {
        napi_value error = error_value(env, job->error);
        set_uint(env, error, "nativeStage", job->stage); set_uint(env, error, "nativeCode", (uint32_t)job->native_code);
        set_uint(env, error, "nativeFlags", job->native_flags); set_uint(env, error, "nativeValue", job->native_value);
        napi_reject_deferred(env, job->deferred, error);
    }
    else {
        napi_create_object(env, &result); set_uint(env, result, "width", job->encode ? job->out_width : job->width);
        set_uint(env, result, "height", job->encode ? job->out_height : job->height);
        napi_get_boolean(env, job->transparent != 0, &boolean); napi_set_named_property(env, result, "transparent", boolean);
        napi_status copied = napi_ok;
        if (job->encode) { copied = napi_create_buffer_copy(env, job->output_size, job->output, NULL, &bytes); if (copied == napi_ok) napi_set_named_property(env, result, "data", bytes); }
        if (copied == napi_ok) napi_resolve_deferred(env, job->deferred, result);
        else napi_reject_deferred(env, job->deferred, error_value(env, "IMAGE_ALLOCATION_FAILED"));
    }
    napi_delete_async_work(env, job->work); free(job->input); free(job->output); free(job); atomic_fetch_sub(&pending, 1);
}
static int get_uint(napi_env env, napi_value options, const char *key, uint32_t *out) {
    napi_value value; double number;
    return napi_get_named_property(env, options, key, &value) == napi_ok && napi_get_value_double(env, value, &number) == napi_ok &&
        number >= 1 && number <= UINT32_MAX && number == (uint32_t)number && ((*out = (uint32_t)number), 1);
}
static napi_value run(napi_env env, napi_callback_info info) {
    napi_value args[2], promise, resource, value; size_t count = 2; bool buffer = false; void *input; size_t size;
    if (napi_get_cb_info(env, info, &count, args, NULL, NULL) != napi_ok || count != 2 ||
        napi_is_buffer(env, args[0], &buffer) != napi_ok || !buffer || napi_get_buffer_info(env, args[0], &input, &size) != napi_ok || !size || size > MAX_INPUT) {
        napi_throw(env, error_value(env, "INVALID_IMAGE")); return NULL;
    }
    Job *job = calloc(1, sizeof(*job)); if (!job) { napi_throw(env, error_value(env, "IMAGE_ALLOCATION_FAILED")); return NULL; }
    int valid = get_uint(env, args[1], "width", &job->width) && get_uint(env, args[1], "height", &job->height) &&
        get_uint(env, args[1], "frames", &job->frames) && get_uint(env, args[1], "maxPixels", &job->max_pixels) &&
        get_uint(env, args[1], "maxDimension", &job->max_dimension) && get_uint(env, args[1], "orientation", &job->orientation);
    bool encode = false;
    valid = valid && napi_get_named_property(env, args[1], "encode", &value) == napi_ok && napi_get_value_bool(env, value, &encode) == napi_ok;
    job->encode = encode;
    if (encode) {
        size_t copied = 0;
        valid = valid && get_uint(env, args[1], "outWidth", &job->out_width) && get_uint(env, args[1], "outHeight", &job->out_height) &&
            get_uint(env, args[1], "quality", &job->quality) && job->quality <= 100 &&
            napi_get_named_property(env, args[1], "mediaType", &value) == napi_ok &&
            napi_get_value_string_utf8(env, value, job->mime, sizeof(job->mime), &copied) == napi_ok &&
            copied == strlen(job->mime) && (!strcmp(job->mime, "image/jpeg") || !strcmp(job->mime, "image/webp"));
    }
    if (!valid || job->orientation > 8 || job->max_pixels > 64000000 || job->max_dimension > 8192 ||
        job->width > 8192 || job->height > 8192 || job->frames > 10000 || (uint64_t)job->width * job->height > 64000000) {
        free(job); napi_throw(env, error_value(env, "INVALID_IMAGE")); return NULL;
    }
    if (atomic_fetch_add(&pending, 1) >= 2) { atomic_fetch_sub(&pending, 1); free(job); napi_throw(env, error_value(env, "IMAGE_BACKEND_BUSY")); return NULL; }
    job->input = malloc(size); job->input_size = size;
    if (!job->input) { atomic_fetch_sub(&pending, 1); free(job); napi_throw(env, error_value(env, "IMAGE_ALLOCATION_FAILED")); return NULL; }
    memcpy(job->input, input, size);
    napi_create_promise(env, &job->deferred, &promise); napi_create_string_utf8(env, "dsh-imagekit-candidate", NAPI_AUTO_LENGTH, &resource);
    if (napi_create_async_work(env, NULL, resource, execute, complete, job, &job->work) != napi_ok || napi_queue_async_work(env, job->work) != napi_ok) {
        napi_reject_deferred(env, job->deferred, error_value(env, "IMAGE_BACKEND_FAILED"));
        if (job->work) napi_delete_async_work(env, job->work);
        free(job->input); free(job); atomic_fetch_sub(&pending, 1);
    }
    return promise;
}
static napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor method = { "run", NULL, run, NULL, NULL, NULL, napi_default, NULL };
    napi_define_properties(env, exports, 1, &method); return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)

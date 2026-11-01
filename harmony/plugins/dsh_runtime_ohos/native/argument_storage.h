/* 连续、可写且有界的参数区，贯穿node::Start，避免libuv写入只读字面量。 */
#ifndef DSH_ARGUMENT_STORAGE_H
#define DSH_ARGUMENT_STORAGE_H
#include <stddef.h>
#include <string.h>
static inline int dsh_pack_arguments(int argc, char **argv, size_t capacity,
                                    char *storage, size_t storage_size) {
    if (argc <= 0 || (size_t)argc >= capacity) return 0;
    size_t used = 0;
    for (int index = 0; index < argc; index++) {
        if (!argv[index]) return 0;
        size_t length = strlen(argv[index]) + 1;
        if (length > storage_size - used) return 0;
        memcpy(storage + used, argv[index], length);
        argv[index] = storage + used;
        used += length;
    }
    argv[argc] = NULL;
    return 1;
}
#endif

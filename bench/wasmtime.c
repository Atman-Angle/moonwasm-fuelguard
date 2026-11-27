#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wasmtime.h>

typedef struct {
    uint8_t *data;
    size_t length;
    size_t capacity;
} buffer_t;

typedef struct {
    wasmtime_store_t *store;
    wasmtime_context_t *context;
    wasmtime_func_t entry;
    buffer_t output;
} instance_t;

typedef struct {
    bool hot;
    bool wasi;
    bool has_entry;
    bool has_result;
    int batch;
    const char *entry;
    int32_t result;
    wasm_byte_vec_t expected;
} options_t;

static void fail(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(1);
}

static void check(wasmtime_error_t *err, wasm_trap_t *trap) {
    if (err == NULL && trap == NULL) {
        return;
    }
    wasm_name_t message;
    if (err) {
        wasmtime_error_message(err, &message);
    } else {
        wasm_trap_message(trap, &message);
    }
    fwrite(message.data, 1, message.size, stderr);
    fail("\nWasmtime error or trap");
}

static uint64_t now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0) {
        fail("clock_gettime");
    }
    return (uint64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static wasm_byte_vec_t read_bytes(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL || fseek(file, 0, SEEK_END) < 0) {
        fail(path);
    }
    long size = ftell(file);
    if (size < 0 || fseek(file, 0, SEEK_SET) < 0) {
        fail(path);
    }
    wasm_byte_vec_t bytes;
    wasm_byte_vec_new_uninitialized(&bytes, (size_t)size);
    if (fread(bytes.data, 1, size, file) != (size_t)size || fclose(file) != 0) {
        fail(path);
    }
    return bytes;
}

static ptrdiff_t capture(void *env, const unsigned char *bytes, size_t length) {
    buffer_t *output = env;
    size_t required = output->length + length;
    if (required > output->capacity) {
        output->capacity = required * 2;
        output->data = realloc(output->data, output->capacity);
        if (output->data == NULL) {
            fail("cannot grow WASI stdout buffer");
        }
    }
    if (length > 0) {
        memcpy(output->data + output->length, bytes, length);
        output->length = required;
    }
    return (ptrdiff_t)length;
}

static void instantiate(instance_t *instance, wasm_engine_t *engine,
                        wasmtime_linker_t *linker, wasmtime_module_t *module,
                        const options_t *opts) {
    *instance = (instance_t){0};
    instance->store = wasmtime_store_new(engine, NULL, NULL);
    instance->context = wasmtime_store_context(instance->store);
    if (opts->wasi) {
        wasi_config_t *wasi = wasi_config_new();
        wasi_config_set_stdout_custom(wasi, capture, &instance->output, NULL);
        check(wasmtime_context_set_wasi(instance->context, wasi), NULL);
    }
    wasmtime_instance_t guest;
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *err = wasmtime_linker_instantiate(
        linker, instance->context, module, &guest, &trap);
    check(err, trap);
    if (opts->has_entry) {
        wasmtime_extern_t entry;
        if (!wasmtime_instance_export_get(instance->context, &guest, opts->entry,
                                          strlen(opts->entry), &entry)
            || entry.kind != WASMTIME_EXTERN_FUNC) {
            fail("missing requested function");
        }
        instance->entry = entry.of.func;
        wasmtime_extern_delete(&entry);
    }
}

static void invoke(const instance_t *instance, const options_t *opts) {
    if (!opts->has_entry) {
        return;
    }
    wasmtime_val_t result;
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *err = wasmtime_func_call(
        instance->context, &instance->entry, NULL, 0, &result, opts->has_result, &trap);
    check(err, trap);
    if (opts->has_result && (result.kind != WASMTIME_I32 || result.of.i32 != opts->result)) {
        fail("unexpected Wasmtime scalar result");
    }
}

static void verify_stdout(instance_t *instance, const wasm_byte_vec_t *expected, int count) {
    if (instance->output.length != expected->size * count) {
        fail("unexpected Wasmtime stdout length");
    }
    if (expected->size) {
        for (int i = 0; i < count; i++) {
            if (memcmp(instance->output.data + i * expected->size, expected->data, expected->size)) {
                fail("unexpected Wasmtime stdout");
            }
        }
    }
    instance->output.length = 0;
}

static void close_instance(instance_t *instance) {
    wasmtime_store_delete(instance->store);
    free(instance->output.data);
}

int main(int argc, char **argv) {
    enum { module_arg = 8, max_variants = 9 };
    if (argc < module_arg + 3 || argc > module_arg + max_variants) {
        fail("expected SCHEDULE WINDOW BATCH WASI ENTRY RETURN STDOUT and 3 to 9 modules");
    }
    const size_t variants = (size_t)(argc - module_arg);
    wasm_byte_vec_t schedule = read_bytes(argv[1]);
    options_t opts = {
        .hot = strcmp(argv[2], "hot") == 0,
        .wasi = strcmp(argv[4], "1") == 0,
        .has_entry = strcmp(argv[5], "-") != 0,
        .has_result = strcmp(argv[6], "-") != 0,
        .batch = atoi(argv[3]),
        .entry = argv[5],
        .result = (int32_t)strtol(argv[6], NULL, 10),
        .expected = read_bytes(argv[7]),
    };
    if (opts.batch <= 0 || (opts.hot && !opts.has_entry)) {
        fail("invalid batch or hot entry");
    }
    wasm_config_t *config = wasm_config_new();
    wasmtime_config_consume_fuel_set(config, false);
    wasmtime_config_epoch_interruption_set(config, false);
    wasmtime_config_parallel_compilation_set(config, false);
    wasmtime_config_max_wasm_stack_set(config, 524288);
    wasm_engine_t *engine = wasm_engine_new_with_config(config);
    wasmtime_linker_t *linker = wasmtime_linker_new(engine);
    if (opts.wasi) {
        check(wasmtime_linker_define_wasi(linker), NULL);
    }

    wasmtime_module_t *modules[max_variants];
    instance_t hot[max_variants];
    for (size_t index = 0; index < variants; index++) {
        uint64_t load = now();
        wasm_byte_vec_t bytes = read_bytes(argv[module_arg + index]);
        uint64_t compile = now();
        check(wasmtime_module_new(engine, (const uint8_t *)bytes.data, bytes.size, &modules[index]), NULL);
        uint64_t ready = now();
        wasm_byte_vec_delete(&bytes);
        printf("compile %" PRIu64 " %" PRIu64 " 0\n", compile - load, ready - compile);
    }
    if (opts.hot) {
        const wasm_byte_vec_t empty = {0};
        for (size_t index = 0; index < variants; index++) {
            instantiate(&hot[index], engine, linker, modules[index], &opts);
            verify_stdout(&hot[index], &empty, 1);
        }
    }
    for (size_t row = 0; row < schedule.size; row++) {
        unsigned int index = (uint8_t)schedule.data[row];
        if (index >= variants) {
            fail("invalid schedule variant");
        }
        uint64_t setup = 0;
        uint64_t execution = 0;
        if (opts.hot) {
            uint64_t start = now();
            for (int i = 0; i < opts.batch; i++) {
                invoke(&hot[index], &opts);
            }
            execution = now() - start;
            verify_stdout(&hot[index], &opts.expected, opts.batch);
        } else {
            for (int i = 0; i < opts.batch; i++) {
                instance_t instance;
                uint64_t start = now();
                instantiate(&instance, engine, linker, modules[index], &opts);
                uint64_t ready = now();
                invoke(&instance, &opts);
                uint64_t finished = now();
                setup += ready - start;
                execution += finished - ready;
                verify_stdout(&instance, &opts.expected, 1);
                close_instance(&instance);
            }
        }
        printf("sample %u %" PRIu64 " %" PRIu64 "\n", index, setup, execution);
    }
    for (size_t index = 0; index < variants; index++) {
        if (opts.hot) {
            close_instance(&hot[index]);
        }
        wasmtime_module_delete(modules[index]);
    }
    wasmtime_linker_delete(linker);
    wasm_engine_delete(engine);
    wasm_byte_vec_delete(&schedule);
    wasm_byte_vec_delete(&opts.expected);
}

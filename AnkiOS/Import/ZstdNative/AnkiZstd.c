#include "AnkiZstd.h"

#include "zstd.h"

#include <stdio.h>
#include <stdlib.h>

int ankios_zstd_compress_file(const char *source_path, const char *destination_path) {
    FILE *source = fopen(source_path, "rb");
    if (!source) return 1;
    FILE *destination = fopen(destination_path, "wb");
    if (!destination) {
        fclose(source);
        return 1;
    }

    ZSTD_CStream *stream = ZSTD_createCStream();
    if (!stream || ZSTD_isError(ZSTD_initCStream(stream, 3))) {
        if (stream) ZSTD_freeCStream(stream);
        fclose(source);
        fclose(destination);
        return 1;
    }

    char input_buffer[131072];
    char output_buffer[131072];
    int failed = 0;
    size_t bytes_read = 0;
    while ((bytes_read = fread(input_buffer, 1, sizeof(input_buffer), source)) > 0) {
        ZSTD_inBuffer input = { input_buffer, bytes_read, 0 };
        while (input.pos < input.size) {
            ZSTD_outBuffer output = { output_buffer, sizeof(output_buffer), 0 };
            size_t result = ZSTD_compressStream2(stream, &output, &input, ZSTD_e_continue);
            if (ZSTD_isError(result) || fwrite(output_buffer, 1, output.pos, destination) != output.pos) {
                failed = 1;
                break;
            }
        }
        if (failed) break;
    }
    if (ferror(source)) failed = 1;

    if (!failed) {
        size_t remaining;
        do {
            ZSTD_inBuffer input = { NULL, 0, 0 };
            ZSTD_outBuffer output = { output_buffer, sizeof(output_buffer), 0 };
            remaining = ZSTD_compressStream2(stream, &output, &input, ZSTD_e_end);
            if (ZSTD_isError(remaining) || fwrite(output_buffer, 1, output.pos, destination) != output.pos) {
                failed = 1;
                break;
            }
        } while (remaining != 0);
    }

    ZSTD_freeCStream(stream);
    if (fclose(source) != 0) failed = 1;
    if (fclose(destination) != 0) failed = 1;
    return failed;
}

int ankios_zstd_compress_data(const void *source, size_t source_size, void **destination, size_t *destination_size) {
    static const char empty_source = 0;
    if (!source) source = &empty_source;
    size_t capacity = ZSTD_compressBound(source_size);
    void *buffer = malloc(capacity);
    if (!buffer) return 1;
    size_t result = ZSTD_compress(buffer, capacity, source, source_size, 3);
    if (ZSTD_isError(result)) {
        free(buffer);
        return 1;
    }
    *destination = buffer;
    *destination_size = result;
    return 0;
}

int ankios_zstd_decompress_data(const void *source, size_t source_size, void **destination, size_t *destination_size) {
    if (!source || source_size == 0) return 1;
    ZSTD_DStream *stream = ZSTD_createDStream();
    if (!stream || ZSTD_isError(ZSTD_initDStream(stream))) {
        if (stream) ZSTD_freeDStream(stream);
        return 1;
    }

    size_t capacity = 65536;
    size_t produced = 0;
    void *buffer = malloc(capacity);
    if (!buffer) {
        ZSTD_freeDStream(stream);
        return 1;
    }

    ZSTD_inBuffer input = { source, source_size, 0 };
    size_t remaining = 1;
    int failed = 0;
    while (input.pos < input.size || remaining != 0) {
        if (produced == capacity) {
            size_t next_capacity = capacity * 2;
            if (next_capacity < capacity) {
                failed = 1;
                break;
            }
            void *next_buffer = realloc(buffer, next_capacity);
            if (!next_buffer) {
                failed = 1;
                break;
            }
            buffer = next_buffer;
            capacity = next_capacity;
        }

        size_t previous_input = input.pos;
        ZSTD_outBuffer output = { (char *)buffer + produced, capacity - produced, 0 };
        remaining = ZSTD_decompressStream(stream, &output, &input);
        produced += output.pos;
        if (ZSTD_isError(remaining)) {
            failed = 1;
            break;
        }
        if (remaining != 0 && input.pos == input.size && input.pos == previous_input && output.pos == 0) {
            failed = 1;
            break;
        }
    }

    ZSTD_freeDStream(stream);
    if (failed) {
        free(buffer);
        return 1;
    }
    *destination = buffer;
    *destination_size = produced;
    return 0;
}

void ankios_zstd_free(void *buffer) {
    free(buffer);
}

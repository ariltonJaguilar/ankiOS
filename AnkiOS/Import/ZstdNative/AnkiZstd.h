#ifndef AnkiZstd_h
#define AnkiZstd_h

#include <stddef.h>

int ankios_zstd_compress_file(const char *source_path, const char *destination_path);
int ankios_zstd_compress_data(const void *source, size_t source_size, void **destination, size_t *destination_size);
int ankios_zstd_decompress_data(const void *source, size_t source_size, void **destination, size_t *destination_size);
void ankios_zstd_free(void *buffer);

#endif

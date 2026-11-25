#include <stddef.h>
#include <stdint.h>

enum {
    pe_ok, pe_spawn_failed, pe_timeout, pe_output_limit, pe_io_failed, pe_isolation_failed
};

typedef struct {
    int result;
    int status;
    size_t output_length;
    size_t error_length;
} pe_result;

int pe_isolation_probe(const char *launcher, const char *directory, int omit_symbols);
pe_result pe_run(const char *launcher, const char *executable, const char *directory,
    const uint8_t *input, size_t input_length, uint8_t *output, size_t output_capacity,
    uint8_t *errors, size_t error_capacity, int timeout_ms, int isolated);

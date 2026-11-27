#include <stdint.h>
#include <stdlib.h>
#include <time.h>

int64_t fuelguard_bench_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        abort();
    }
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

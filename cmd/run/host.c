#define _POSIX_C_SOURCE 200809L
#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__linux__) && defined(__x86_64__)
#include <signal.h>
#include <sys/resource.h>

static volatile sig_atomic_t cancelled;

static void request_cancel(int sig) {
    (void)sig;
    cancelled = 1;
}
#endif

MOONBIT_FFI_EXPORT int32_t fuelguard_run_environment(void) {
#if defined(__linux__) && defined(__x86_64__)
    struct rlimit limit;
    if (getrlimit(RLIMIT_STACK, &limit) != 0)
        return 2;
    return limit.rlim_cur >= 8 * 1024 * 1024 ? 0 : 3;
#else
    return 1;
#endif
}

MOONBIT_FFI_EXPORT int32_t fuelguard_run_install_cancel(void) {
#if defined(__linux__) && defined(__x86_64__)
    struct sigaction action = {0};
    action.sa_handler = request_cancel;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGINT, &action, NULL) == 0 &&
           sigaction(SIGTERM, &action, NULL) == 0;
#else
    return 0;
#endif
}

MOONBIT_FFI_EXPORT int32_t fuelguard_run_cancelled(void) {
#if defined(__linux__) && defined(__x86_64__)
    return cancelled != 0;
#else
    return 0;
#endif
}

MOONBIT_FFI_EXPORT void fuelguard_run_report(moonbit_bytes_t bytes) {
    fwrite(bytes, 1, Moonbit_array_length(bytes), stderr);
    fputc('\n', stderr);
}

MOONBIT_FFI_EXPORT void fuelguard_run_exit(int32_t status) {
    exit(status);
}

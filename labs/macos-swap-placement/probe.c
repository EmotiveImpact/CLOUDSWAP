/* Synthetic anonymous-memory workload, adapted from labs/linux-vm/probe.c.
 * Large allocations are restricted to the explicitly selected hosted CI lab.
 * No mount, swap, boot-policy or filesystem changes are made by this process. */
#include <errno.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define MIB (UINT64_C(1024) * 1024)
#define CHUNK (64 * MIB)
static uint64_t pattern(uint64_t offset) {
    uint64_t x = (offset + 1) * UINT64_C(0x9e3779b97f4a7c15);
    x ^= x >> 30; x *= UINT64_C(0xbf58476d1ce4e5b9);
    x ^= x >> 27; return x * UINT64_C(0x94d049bb133111eb);
}
static int environment(const char *name, const char *value) {
    const char *actual = getenv(name);
    return actual && strcmp(actual, value) == 0;
}
static int statistics(vm_statistics64_data_t *result) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    return host_statistics64(mach_host_self(), HOST_VM_INFO64,
                            (host_info64_t)result, &count) == KERN_SUCCESS;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    errno = 0; char *end;
    unsigned long long mib = strtoull(argv[1], &end, 10);
    if (errno || *end || !mib || mib > 12288) return 2;
    uint64_t length = mib * MIB;
    if (length > 64 * MIB) {
        uint64_t ram = 0; size_t size = sizeof(ram);
        if (!environment("GITHUB_ACTIONS", "true") ||
            !environment("RUNNER_ENVIRONMENT", "github-hosted") ||
            !environment("GITHUB_REPOSITORY", "EmotiveImpact/CLOUDSWAP") ||
            !environment("CLOUDSWAP_CI_PLACEMENT", "explicit-disposable-test") ||
            sysctlbyname("hw.memsize", &ram, &size, NULL, 0) ||
            ram <= 2 * 1024 * MIB || length > ram - 2 * 1024 * MIB ||
            length > (ram / 100) * 85) {
            fprintf(stderr, "Large workload refused outside bounded hosted CI lab\n");
            return 3;
        }
    }
    alarm(120);
    setvbuf(stdout, NULL, _IOLBF, 0);
    vm_statistics64_data_t before = {0}, ready = {0}, after = {0};
    int counters = statistics(&before);
    volatile uint64_t *data = mmap(NULL, (size_t)length, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (data == MAP_FAILED) return 4;
    uint64_t touched = 0;
    while (touched < length) {
        uint64_t next = touched + CHUNK;
        if (next > length) next = length;
        for (uint64_t i = touched / 8; i < next / 8; ++i) data[i] = pattern(i);
        touched = next;
        if (counters && !statistics(&ready)) counters = 0;
        printf("{\"event\":\"allocated\",\"bytes\":%llu}\n", (unsigned long long)touched);
        if (length > 64 * MIB && touched >= 256 * MIB && counters && ready.swapouts > before.swapouts) break;
        if (length > 64 * MIB && touched % (512 * MIB) == 0) usleep(100000);
    }
    printf("{\"event\":\"ready\",\"bytes\":%llu,\"counters_available\":%s,\"swapouts_delta\":%llu}\n",
           (unsigned long long)touched, counters ? "true" : "false",
           (unsigned long long)(counters ? ready.swapouts - before.swapouts : 0));
    char command[16];
    if (!fgets(command, sizeof(command), stdin) || strcmp(command, "verify\n")) return 5;
    if (counters && !statistics(&ready)) counters = 0;
    for (uint64_t i = 0; i < touched / 8; ++i) {
        if (data[i] != pattern(i)) {
            fprintf(stderr, "Synthetic data mismatch at byte %llu\n", (unsigned long long)(i * 8));
            return 6;
        }
    }
    if (counters && !statistics(&after)) counters = 0;
    printf("{\"event\":\"verified\",\"bytes\":%llu,\"counters_available\":%s,\"swapins_delta\":%llu}\n",
           (unsigned long long)touched, counters ? "true" : "false",
           (unsigned long long)(counters ? after.swapins - ready.swapins : 0));
    munmap((void *)data, (size_t)length);
    return 0;
}

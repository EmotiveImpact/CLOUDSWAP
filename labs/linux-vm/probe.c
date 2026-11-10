/* Guest-only workload. Verify every word after real Linux swap I/O. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static unsigned long vmstat(const char *wanted) {
    FILE *file = fopen("/proc/vmstat", "r");
    if (!file) return 0;
    char name[128];
    unsigned long value;
    while (fscanf(file, "%127s %lu", name, &value) == 2) {
        if (!strcmp(name, wanted)) {
            fclose(file);
            return value;
        }
    }
    fclose(file);
    return 0;
}

static uint64_t pattern(uint64_t offset) {
    uint64_t x = (offset + 1) * UINT64_C(0x9e3779b97f4a7c15);
    x ^= x >> 30;
    x *= UINT64_C(0xbf58476d1ce4e5b9);
    x ^= x >> 27;
    return x * UINT64_C(0x94d049bb133111eb);
}

int main(void) {
    const size_t length = 24 * 1024 * 1024;
    const size_t words = length / sizeof(uint64_t);
    int fd = open("/sys/fs/cgroup/probe/cgroup.procs", O_WRONLY);
    if (fd < 0 || write(fd, "0\n", 2) != 2) {
        perror("join probe cgroup");
        return 10;
    }
    close(fd);
    unsigned long out_before = vmstat("pswpout");
    volatile uint64_t *data = mmap(NULL, length, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        return 11;
    }
    for (size_t i = 0; i < words; i++) data[i] = pattern(i);
    unsigned long out_after = vmstat("pswpout");
    if (out_after <= out_before) {
        fprintf(stderr, "no guest page-out observed\n");
        return 12;
    }
    unsigned long in_before = vmstat("pswpin");
    printf("PAGEOUT_READY swapouts=%lu\n", out_after - out_before);
    fflush(stdout);
    char command[32];
    if (!fgets(command, sizeof command, stdin) || strcmp(command, "verify\n")) return 13;
    for (size_t i = 0; i < words; i++) {
        if (data[i] != pattern(i)) {
            fprintf(stderr, "DATA_MISMATCH offset=%zu\n", i * sizeof(uint64_t));
            return 14;
        }
    }
    unsigned long in_after = vmstat("pswpin");
    if (in_after <= in_before) return 15;
    printf("DATA_VERIFIED swapins=%lu bytes=%zu\n", in_after - in_before, length);
    return 0;
}

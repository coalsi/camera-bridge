/* notifylisten: stands in for systemd's notify socket (sd_notify(3)) so the daemon's READY=1 and WATCHDOG=1 can be recorded without systemd.
 *
 * Usage: notifylisten SOCKET_PATH OUTPUT_FILE
 *   Binds the unix datagram socket SOCKET_PATH (relative paths are fine: start the daemon in the same directory and give it the same
 *   NOTIFY_SOCKET) and appends one JSON line per datagram to OUTPUT_FILE:
 *   {"t": seconds since start (monotonic), "wall": unix seconds, "msg": "READY=1 | STATUS=..."}
 *   Newlines inside a datagram become " | ". Ends on SIGTERM or SIGINT, removing the socket.
 * Build: cc -O2 -Wall -o notifylisten notifylisten.c   (macOS and Linux)
 */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested = 0;
static void on_signal(int number) { (void)number; stop_requested = 1; }

static double seconds(clockid_t clock) {
    struct timespec now;
    clock_gettime(clock, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static void write_escaped(FILE *out, const char *text, size_t length) {
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c == '\n') fputs(" | ", out);
        else if (c == '"' || c == '\\') { fputc('\\', out); fputc(c, out); }
        else if (c < 0x20 || c == 0x7f) fprintf(out, "\\u%04x", c);
        else fputc(c, out);
    }
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: notifylisten SOCKET_PATH OUTPUT_FILE\n"); return 2; }
    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    if (strlen(argv[1]) >= sizeof address.sun_path) { fprintf(stderr, "notifylisten: the socket path is too long (%zu bytes at most)\n", sizeof address.sun_path - 1); return 2; }
    strcpy(address.sun_path, argv[1]);
    unlink(argv[1]);
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof address) != 0) { perror("notifylisten: bind"); return 1; }
    struct timeval timeout = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_signal;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    FILE *out = fopen(argv[2], "a");
    if (!out) { perror("notifylisten: output"); return 1; }
    setvbuf(out, NULL, _IOLBF, 0);
    double start = seconds(CLOCK_MONOTONIC);
    fprintf(out, "{\"t\": 0.000, \"wall\": %.3f, \"msg\": \"LISTENING\"}\n", seconds(CLOCK_REALTIME));
    char buffer[4096];
    while (!stop_requested) {
        ssize_t length = recv(fd, buffer, sizeof buffer, 0);
        if (length < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
            perror("notifylisten: recv");
            break;
        }
        fprintf(out, "{\"t\": %.3f, \"wall\": %.3f, \"msg\": \"", seconds(CLOCK_MONOTONIC) - start, seconds(CLOCK_REALTIME));
        write_escaped(out, buffer, (size_t)length);
        fputs("\"}\n", out);
    }
    fclose(out);
    close(fd);
    unlink(argv[1]);
    return 0;
}

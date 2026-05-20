#include "CMTermBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <util.h>
#include <sys/ioctl.h>
#include <libproc.h>

int mterm_spawn_shell(const char *shell_path,
                      const char *cwd,
                      unsigned short rows,
                      unsigned short cols,
                      pid_t *out_pid) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    // Build argv[0] as "-basename" to mark this as a login shell, matching the
    // convention used by login(1), Terminal.app, and ssh. zsh/bash/fish detect
    // the leading dash and source login profile files (.zshrc via oh-my-zsh,
    // .bash_profile, etc.).
    const char *base = strrchr(shell_path, '/');
    base = base ? base + 1 : shell_path;
    char argv0[256];
    snprintf(argv0, sizeof(argv0), "-%s", base);

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        if (cwd && *cwd) {
            // Best effort — if it fails we still exec the shell from whatever
            // CWD we got, rather than refusing to spawn.
            (void)chdir(cwd);
        }
        char *argv[] = { argv0, NULL };
        execvp(shell_path, argv);
        _exit(127);
    }
    if (out_pid) {
        *out_pid = pid;
    }
    return master;
}

int mterm_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int mterm_proc_name(pid_t pid, char *buf, int len) {
    if (!buf || len <= 0) return 0;
    buf[0] = '\0';
    int n = proc_name(pid, buf, (uint32_t)len);
    if (n <= 0) {
        buf[0] = '\0';
        return 0;
    }
    if (n >= len) n = len - 1;
    buf[n] = '\0';
    return n;
}

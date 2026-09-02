#include "CMTermBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <util.h>
#include <sys/ioctl.h>
#include <libproc.h>
#include <sys/sysctl.h>

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

pid_t mterm_foreground_pid(pid_t pgid) {
    if (pgid <= 0) return pgid;

    // KERN_PROC_PGRP hands back exactly the group we care about, so the walk
    // never has to look at the rest of the process table.
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PGRP, (int)pgid };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return pgid;

    // Processes can come and go between the sizing call and the read, so ask
    // for some slack and accept a short answer.
    len += 8 * sizeof(struct kinfo_proc);
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return pgid;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        return pgid;
    }

    int count = (int)(len / sizeof(struct kinfo_proc));
    pid_t best = pgid;
    int best_depth = 0;

    // Depth = hops from the group leader. The deepest process is the one doing
    // the work; ties go to the youngest, which is the one a wrapper started
    // last. Capped at `count` hops so a cycle can't spin.
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid == pgid) continue;
        // A zombie is the deepest thing in the group right up until its parent
        // reaps it, and it has no name left to report.
        if (procs[i].kp_proc.p_stat == SZOMB) continue;

        int depth = 0;
        pid_t walk = pid;
        while (walk != pgid && depth <= count) {
            pid_t parent = 0;
            for (int j = 0; j < count; j++) {
                if (procs[j].kp_proc.p_pid == walk) {
                    parent = procs[j].kp_eproc.e_ppid;
                    break;
                }
            }
            if (parent <= 0) { depth = -1; break; }   // parent left the group
            walk = parent;
            depth++;
        }
        if (depth <= 0 || walk != pgid) continue;     // not a descendant

        if (depth > best_depth || (depth == best_depth && pid > best)) {
            best = pid;
            best_depth = depth;
        }
    }

    free(procs);
    return best;
}

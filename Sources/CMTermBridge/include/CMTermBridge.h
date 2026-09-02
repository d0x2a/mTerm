#ifndef CMTERMBRIDGE_H
#define CMTERMBRIDGE_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forks a child via forkpty(3), applies `env` and `cwd` in the child, then
// execs `path` with `argv`. argv[0] is whatever the child should see as its
// name — a login shell is spawned by passing "-zsh" there, the convention
// login(1), Terminal.app and ssh use, with the real path in `path`. `env` is a
// NULL-terminated list of "KEY=VALUE" strings to set and bare "KEY" strings
// to unset, applied to the child only. Returns the master fd; the child PID
// is written to *out_pid on success. Returns -1 on failure (with errno set).
// Pass NULL for `cwd` to keep the parent's CWD and NULL for `env` to inherit
// the parent's environment unchanged.
int mterm_spawn(const char *path,
                char *const argv[],
                const char *cwd,
                char *const env[],
                unsigned short rows,
                unsigned short cols,
                pid_t *out_pid);

// Updates the PTY's window size via TIOCSWINSZ. Returns 0 on success.
int mterm_set_winsize(int fd, unsigned short rows, unsigned short cols);

// Writes the executable name of `pid` into `buf` (NUL-terminated), up to
// `len` bytes. Returns the number of bytes written (excluding the NUL), or
// 0 if the lookup failed (process exited, permission denied, etc).
int mterm_proc_name(pid_t pid, char *buf, int len);

// Resolves the process group `pgid` to the command actually running in it:
// the deepest descendant of the group leader that is still in the group.
// Wrappers keep the leadership and fork the real program (npm and node shims,
// `script`, `env`), so the leader's name is often not what the user thinks is
// running — codex's leader is the `node` wrapper that spawned the real binary.
// Returns `pgid` unchanged when the walk finds nothing better.
pid_t mterm_foreground_pid(pid_t pgid);

#ifdef __cplusplus
}
#endif

#endif

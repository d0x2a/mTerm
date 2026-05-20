#ifndef CMTERMBRIDGE_H
#define CMTERMBRIDGE_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forks a child via forkpty(3), optionally chdirs to `cwd` in the child, then
// execs the given shell as a login shell (argv[0] = "-basename"). Returns the
// master fd; the child PID is written to *out_pid on success. Returns -1 on
// failure (with errno set). Pass NULL for `cwd` to keep the parent's CWD.
int mterm_spawn_shell(const char *shell_path,
                      const char *cwd,
                      unsigned short rows,
                      unsigned short cols,
                      pid_t *out_pid);

// Updates the PTY's window size via TIOCSWINSZ. Returns 0 on success.
int mterm_set_winsize(int fd, unsigned short rows, unsigned short cols);

// Writes the executable name of `pid` into `buf` (NUL-terminated), up to
// `len` bytes. Returns the number of bytes written (excluding the NUL), or
// 0 if the lookup failed (process exited, permission denied, etc).
int mterm_proc_name(pid_t pid, char *buf, int len);

#ifdef __cplusplus
}
#endif

#endif

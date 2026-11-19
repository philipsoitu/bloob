/* Thin libc surface not covered by std.posix in Zig 0.17. */
#ifndef BLOOB_SYS_H
#define BLOOB_SYS_H
#define _GNU_SOURCE 1
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <sys/stat.h>
#include <time.h>
#include <pwd.h>
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#endif

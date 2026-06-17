# cx changes: add cwd + timeout to CxProcess (for Helios seed)

The seed daemon's `run` verb needs two things `CxProcess::run(const char *)`
doesn't have:

1. **cwd** so the agent can say "build in /export/dev/myproj" without
   prepending `cd /path && ` to every command
2. **timeout** so a hung command doesn't block the seed forever

This doc has the full source for each change. Existing signatures are
preserved; only additions and one tiny safety guard. Solaris 2.6 stays
clean: only POSIX features that g++ 2.95.3 + the Solaris 2.6 libc both
have. No `<chrono>`, no `posix_spawn`, no STL beyond what cx already
uses, no `nullptr`, no auto.

## Change 1: replace `cx/process/process.h`

Full file. The diff vs current: one new `run` overload, one new accessor
`wasTimedOut()`, one new private member `_killedByTimeout`. Constructor
init for the new member happens in process.cpp.

```cpp
//-------------------------------------------------------------------------------------------------
//
//  process.h
//  cx
//
//  Copyright 2022-2025 Todd Vernon. All rights reserved.
//  Licensed under the Apache License, Version 2.0
//  See LICENSE file for details.
//
//  process.h
//
//-------------------------------------------------------------------------------------------------

#ifndef _CxProcess_h_
#define _CxProcess_h_

#include <cx/base/string.h>

//-------------------------------------------------------------------------------------------------
// CxBuildError
//
// Holds parsed error information from a compiler output line.
//-------------------------------------------------------------------------------------------------
struct CxBuildError
{
    CxString filename;      // source file path
    int line;               // line number (1-based), 0 if not found
    int column;             // column number (1-based), 0 if not found
    CxString message;       // error/warning message
    int valid;              // 1 if successfully parsed, 0 otherwise

    CxBuildError() : line(0), column(0), valid(0) {}
};


//-------------------------------------------------------------------------------------------------
// CxProcess
//
// Run external commands and capture output.
//-------------------------------------------------------------------------------------------------
class CxProcess
{
public:
    CxProcess();
    ~CxProcess();

    //---------------------------------------------------------------------------------------------
    // Run a command and capture its output (stdout and stderr combined)
    // Returns 0 on success, -1 on failure to execute
    // Output is stored and accessible via getOutput()
    //---------------------------------------------------------------------------------------------
    int run(const char *command);
    int run(CxString command);

    //---------------------------------------------------------------------------------------------
    // Run with optional working directory and timeout.
    //
    //   cwd:        NULL = inherit caller's cwd, otherwise chdir() in child before exec.
    //   timeout_ms: 0 = no timeout (wait indefinitely).
    //               >0 = milliseconds before SIGTERM, then 1s grace, then SIGKILL the
    //                    process group. wasTimedOut() returns 1 in this case and
    //                    getExitCode() returns -1.
    //
    // Returns 0 if a child was spawned (use getExitCode() to learn the result);
    // -1 on inability to spawn (null/empty command, pipe failure, fork failure).
    //
    // The fast path (cwd == NULL && timeout_ms == 0) delegates to run(command)
    // unchanged, so existing behavior is preserved byte-for-byte.
    //---------------------------------------------------------------------------------------------
    int run(const char *command, const char *cwd, int timeout_ms);

    //---------------------------------------------------------------------------------------------
    // Get the captured output from the last run
    //---------------------------------------------------------------------------------------------
    CxString getOutput(void);

    //---------------------------------------------------------------------------------------------
    // Get the exit code from the last run
    //---------------------------------------------------------------------------------------------
    int getExitCode(void);

    //---------------------------------------------------------------------------------------------
    // 1 if the last run() was killed by the timeout, 0 otherwise.
    //---------------------------------------------------------------------------------------------
    int wasTimedOut(void);

    //---------------------------------------------------------------------------------------------
    // Parse a single line for build error pattern (file:line:col: or file:line:)
    // Recognizes common compiler output formats:
    //   - GCC/Clang: file.cpp:123:45: error: message
    //   - GCC/Clang: file.cpp:123: message
    //   - Generic:   file:123: message
    //---------------------------------------------------------------------------------------------
    static CxBuildError parseBuildError(CxString line);

private:
    CxString _output;
    int _exitCode;
    int _killedByTimeout;
};

#endif
```

## Change 2: replace `cx/process/process.cpp`

Full file. Adds the new overload, the `wasTimedOut()` accessor, the
constructor init for `_killedByTimeout`, and one one-line safety guard
(pclose returning -1) on the existing run path. All other methods are
preserved verbatim.

```cpp
//-------------------------------------------------------------------------------------------------
//
//  process.cpp
//  cx
//
//  Copyright 2022-2025 Todd Vernon. All rights reserved.
//  Licensed under the Apache License, Version 2.0
//  See LICENSE file for details.
//
//  process.cpp
//
//-------------------------------------------------------------------------------------------------

#include "process.h"
#include <stdio.h>
#include <stdlib.h>

#if defined(_LINUX_) || defined(_OSX_) || defined(_SUNOS_) || defined(_SOLARIS6_) || defined(_SOLARIS10_) || defined(_IRIX6_) || defined(_NETBSD_) || defined(_NEXT_)
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/select.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#endif

//-------------------------------------------------------------------------
// SunOS 4.x needs extern "C" declaration for pclose
//-------------------------------------------------------------------------
#if defined(_SUNOS_)
extern "C" {
int pclose(FILE *stream);
}
#endif


//-------------------------------------------------------------------------------------------------
// Constructor
//-------------------------------------------------------------------------------------------------
CxProcess::CxProcess()
    : _exitCode(-1), _killedByTimeout(0)
{
}


//-------------------------------------------------------------------------------------------------
// Destructor
//-------------------------------------------------------------------------------------------------
CxProcess::~CxProcess()
{
}


//-------------------------------------------------------------------------------------------------
// Run a command and capture output (popen-based; combined stdout+stderr).
//-------------------------------------------------------------------------------------------------
int
CxProcess::run(const char *command)
{
    _output = "";
    _exitCode = -1;
    _killedByTimeout = 0;

    if (command == NULL || command[0] == '\0') {
        return -1;
    }

    // Redirect stderr to stdout so we capture both
    CxString fullCommand = command;
    fullCommand += " 2>&1";

    FILE *pipe = popen(fullCommand.data(), "r");
    if (pipe == NULL) {
        return -1;
    }

    // Read output
    char buffer[4096];
    while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
        _output += buffer;
    }

    // Get exit status
    int status = pclose(pipe);
    if (status == -1) {
        // pclose's waitpid failed; WIFEXITED(-1) is undefined.
        _exitCode = -1;
        return 0;
    }
#if defined(_LINUX_) || defined(_OSX_) || defined(_SUNOS_) || defined(_SOLARIS6_) || defined(_SOLARIS10_) || defined(_IRIX6_) || defined(_NETBSD_) || defined(_NEXT_)
    if (WIFEXITED(status)) {
        _exitCode = WEXITSTATUS(status);
    } else {
        _exitCode = -1;
    }
#else
    _exitCode = status;
#endif

    return 0;
}


//-------------------------------------------------------------------------------------------------
// Run (CxString version)
//-------------------------------------------------------------------------------------------------
int
CxProcess::run(CxString command)
{
    return run(command.data());
}


//-------------------------------------------------------------------------------------------------
// Run with optional cwd and timeout.
//
// Implementation: fork + pipe + execl("/bin/sh", "sh", "-c", command).
// popen() can't do chdir-between-fork-and-exec or a clean timeout, so we
// do it ourselves. Parent loops on select() + waitpid(WNOHANG) on a 100ms
// poll cadence until child exits, the read end EOFs, or the deadline fires.
//-------------------------------------------------------------------------------------------------
int
CxProcess::run(const char *command, const char *cwd, int timeout_ms)
{
    _output = "";
    _exitCode = -1;
    _killedByTimeout = 0;

    if (command == NULL || command[0] == '\0') {
        return -1;
    }

    // Fast path: no cwd, no timeout -> delegate to the popen-based impl.
    // Preserves byte-for-byte behavior for existing-style callers.
    if (cwd == NULL && timeout_ms == 0) {
        return run(command);
    }

    int pipefd[2];
    if (pipe(pipefd) < 0) {
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }

    if (pid == 0) {
        // ----- Child -----
        // Route stdout+stderr to the pipe, chdir if requested, exec sh.
        close(pipefd[0]);
        dup2(pipefd[1], 1);     // STDOUT
        dup2(pipefd[1], 2);     // STDERR
        close(pipefd[1]);

        // Put child in its own process group so the parent can kill the
        // whole subtree (sh + grandchildren) with kill(-pid, ...).
        setpgid(0, 0);

        if (cwd != NULL) {
            if (chdir(cwd) < 0) {
                _exit(127);     // 127 by sh convention; parent infers
            }
        }

        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        // exec failed
        _exit(127);
    }

    // ----- Parent -----
    close(pipefd[1]);

    // Compute deadline (absolute wall-clock instant) if timeout is set
    struct timeval deadline;
    int hasDeadline = (timeout_ms > 0);
    if (hasDeadline) {
        gettimeofday(&deadline, NULL);
        deadline.tv_sec  += timeout_ms / 1000;
        deadline.tv_usec += (timeout_ms % 1000) * 1000;
        if (deadline.tv_usec >= 1000000) {
            deadline.tv_sec++;
            deadline.tv_usec -= 1000000;
        }
    }

    char buf[4096];
    int childExited = 0;
    int status = 0;
    int readClosed = 0;

    while (!childExited) {
        // 1. Non-blocking reap
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            childExited = 1;
            break;
        }

        // 2. Check deadline
        if (hasDeadline) {
            struct timeval now;
            gettimeofday(&now, NULL);
            long usLeft = (long)(deadline.tv_sec - now.tv_sec) * 1000000L
                        + (long)(deadline.tv_usec - now.tv_usec);
            if (usLeft <= 0) {
                _killedByTimeout = 1;
                kill(-pid, SIGTERM);
                // 1s grace via select-based sleep, then SIGKILL
                struct timeval grace;
                grace.tv_sec = 1;
                grace.tv_usec = 0;
                select(0, NULL, NULL, NULL, &grace);
                kill(-pid, SIGKILL);
                waitpid(pid, &status, 0);
                childExited = 1;
                break;
            }
        }

        // 3. Wait up to 100ms for pipe-readable, or just sleep if pipe is closed
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000;        // 100ms poll cadence

        fd_set rfds;
        FD_ZERO(&rfds);
        int maxfd = -1;
        if (!readClosed) {
            FD_SET(pipefd[0], &rfds);
            maxfd = pipefd[0];
        }

        int n = select(maxfd + 1,
                       (maxfd >= 0 ? &rfds : (fd_set *)NULL),
                       NULL, NULL, &tv);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;  // unrecoverable
        }

        // 4. Drain pipe if readable
        if (!readClosed && n > 0 && FD_ISSET(pipefd[0], &rfds)) {
            int r = read(pipefd[0], buf, sizeof(buf) - 1);
            if (r > 0) {
                buf[r] = '\0';
                _output += buf;
            } else if (r == 0) {
                close(pipefd[0]);
                readClosed = 1;
            }
            // r < 0 with EINTR: try again next iter
        }
    }

    // Drain any remaining output before mapping exit status
    if (!readClosed) {
        int r;
        while ((r = read(pipefd[0], buf, sizeof(buf) - 1)) > 0) {
            buf[r] = '\0';
            _output += buf;
        }
        close(pipefd[0]);
    }

    if (!_killedByTimeout) {
        if (WIFEXITED(status)) {
            _exitCode = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            _exitCode = 128 + WTERMSIG(status);   // shell convention
        } else {
            _exitCode = -1;
        }
    }

    return 0;
}


//-------------------------------------------------------------------------------------------------
// Get captured output
//-------------------------------------------------------------------------------------------------
CxString
CxProcess::getOutput(void)
{
    return _output;
}


//-------------------------------------------------------------------------------------------------
// Get exit code
//-------------------------------------------------------------------------------------------------
int
CxProcess::getExitCode(void)
{
    return _exitCode;
}


//-------------------------------------------------------------------------------------------------
// 1 if the last run() was terminated by the timeout, 0 otherwise.
//-------------------------------------------------------------------------------------------------
int
CxProcess::wasTimedOut(void)
{
    return _killedByTimeout;
}


//-------------------------------------------------------------------------------------------------
// Parse a line for build error pattern
//
// Recognizes:
//   file.cpp:123:45: error: message    (GCC/Clang with column)
//   file.cpp:123: error: message       (GCC/Clang without column)
//   file:123: message                  (generic)
//   /path/to/file.cpp:123:45: message  (absolute path)
//
// Returns CxBuildError with valid=1 if parsed successfully
//-------------------------------------------------------------------------------------------------
CxBuildError
CxProcess::parseBuildError(CxString line)
{
    CxBuildError result;

    // Look for the pattern: filename:line: or filename:line:col:
    // The filename can contain path separators but not colons (on Unix)

    int len = line.length();
    if (len == 0) {
        return result;
    }

    // Find first colon that's followed by a digit (the line number)
    int firstColon = -1;
    for (int i = 0; i < len - 1; i++) {
        if (line.charAt(i) == ':') {
            char next = line.charAt(i + 1);
            if (next >= '0' && next <= '9') {
                firstColon = i;
                break;
            }
        }
    }

    if (firstColon <= 0) {
        // No valid pattern found (colon at start or not found)
        return result;
    }

    // Extract filename
    result.filename = line.subString(0, firstColon);

    // Parse line number starting after the first colon
    int lineStart = firstColon + 1;
    int lineNum = 0;
    int i = lineStart;

    while (i < len) {
        char c = line.charAt(i);
        if (c >= '0' && c <= '9') {
            lineNum = lineNum * 10 + (c - '0');
            i++;
        } else {
            break;
        }
    }

    if (lineNum == 0) {
        // No valid line number
        result.filename = "";
        return result;
    }

    result.line = lineNum;

    // Check for column number (another colon followed by digits)
    if (i < len && line.charAt(i) == ':') {
        i++;  // skip colon
        int colNum = 0;
        while (i < len) {
            char c = line.charAt(i);
            if (c >= '0' && c <= '9') {
                colNum = colNum * 10 + (c - '0');
                i++;
            } else {
                break;
            }
        }
        if (colNum > 0) {
            result.column = colNum;
        }
    }

    // Skip colon and space after line/column
    while (i < len && (line.charAt(i) == ':' || line.charAt(i) == ' ')) {
        i++;
    }

    // Rest is the message
    if (i < len) {
        result.message = line.subString(i, len - i);
    }

    result.valid = 1;
    return result;
}
```

## Change 3: delete vestigial include in cm

**File:** `cx_apps/cm/ScreenEditorCommands.cpp`

Delete line 24 (and only line 24):

```cpp
#include <cx/process/process.h>
```

Nothing else in cm references `CxProcess`. If a future change wants to
use it, the include comes back trivially.

## Change 4: new test program

Create directory `cx_tests/cxprocess/` with three files. Mirrors the
`cxbuildoutput/` layout so the per-platform object subdirs and
TEST/ASSERT/PASS/RUN_TEST idiom match the rest of cx_tests.

### `cx_tests/cxprocess/cxprocess_test.cpp`

```cpp
//-------------------------------------------------------------------------------------------------
//
//  cxprocess_test.cpp
//
//  Test suite for CxProcess::run with cwd and timeout overloads.
//  The legacy CxProcess::run(const char *) is exercised in cxbuildoutput_test;
//  this file focuses on the new overload added for Helios seed-daemon use.
//
//-------------------------------------------------------------------------------------------------

#include <stdio.h>
#include <unistd.h>
#include <cx/base/string.h>
#include <cx/process/process.h>

static int gTestsPassed = 0;
static int gTestsFailed = 0;

#define TEST(name) static int name()
#define ASSERT(cond) if (!(cond)) { printf("  FAIL: %s\n", #cond); return 0; }
#define PASS() return 1

#define RUN_TEST(name) do { \
    printf("%-50s ", #name); \
    if (name()) { printf("PASS\n"); gTestsPassed++; } \
    else { gTestsFailed++; } \
} while(0)


//=================================================================================================
// New overload: run(command, cwd, timeout_ms)
//=================================================================================================

TEST(test_new_overload_simple)
{
    CxProcess proc;
    int rc = proc.run("echo hello", NULL, 0);
    ASSERT(rc == 0);
    ASSERT(proc.getExitCode() == 0);
    ASSERT(proc.wasTimedOut() == 0);
    ASSERT(proc.getOutput().index("hello") == 0);
    PASS();
}

TEST(test_new_overload_nonzero_exit)
{
    CxProcess proc;
    int rc = proc.run("false", NULL, 0);
    ASSERT(rc == 0);
    ASSERT(proc.getExitCode() == 1);
    ASSERT(proc.wasTimedOut() == 0);
    PASS();
}

TEST(test_new_overload_missing_command)
{
    CxProcess proc;
    int rc = proc.run("no_such_command_xyz_qqq", NULL, 0);
    ASSERT(rc == 0);
    // /bin/sh exits 127 when the command isn't found
    ASSERT(proc.getExitCode() == 127);
    PASS();
}

TEST(test_new_overload_null_command_returns_minus_one)
{
    CxProcess proc;
    int rc = proc.run((const char *)NULL, NULL, 0);
    ASSERT(rc == -1);
    PASS();
}

TEST(test_new_overload_empty_command_returns_minus_one)
{
    CxProcess proc;
    int rc = proc.run("", NULL, 0);
    ASSERT(rc == -1);
    PASS();
}

//-------------------------------------------------------------------------
// cwd
//-------------------------------------------------------------------------

TEST(test_cwd_pwd_reports_target)
{
    CxProcess proc;
    int rc = proc.run("pwd", "/tmp", 0);
    ASSERT(rc == 0);
    ASSERT(proc.getExitCode() == 0);
    // pwd output should contain "/tmp"
    ASSERT(proc.getOutput().index("/tmp") >= 0);
    PASS();
}

TEST(test_cwd_missing_dir_fails)
{
    CxProcess proc;
    int rc = proc.run("echo x", "/no/such/dir/zzz", 0);
    // Child chdir() fails -> child _exit(127), parent reaps fine
    ASSERT(rc == 0);
    ASSERT(proc.getExitCode() == 127);
    PASS();
}

//-------------------------------------------------------------------------
// Combined stdout / stderr capture
//-------------------------------------------------------------------------

TEST(test_combined_stdout_and_stderr)
{
    CxProcess proc;
    int rc = proc.run("echo a; echo b 1>&2", NULL, 0);
    ASSERT(rc == 0);
    ASSERT(proc.getExitCode() == 0);
    CxString out = proc.getOutput();
    ASSERT(out.index("a") >= 0);
    ASSERT(out.index("b") >= 0);
    PASS();
}

//-------------------------------------------------------------------------
// Timeout
//-------------------------------------------------------------------------

TEST(test_timeout_kills_sleep)
{
    CxProcess proc;
    // 200ms timeout against a 5s sleep -> killed
    int rc = proc.run("sleep 5", NULL, 200);
    ASSERT(rc == 0);
    ASSERT(proc.wasTimedOut() == 1);
    ASSERT(proc.getExitCode() == -1);
    PASS();
}

TEST(test_timeout_not_fired_for_fast_command)
{
    CxProcess proc;
    int rc = proc.run("echo fast", NULL, 5000);
    ASSERT(rc == 0);
    ASSERT(proc.wasTimedOut() == 0);
    ASSERT(proc.getExitCode() == 0);
    ASSERT(proc.getOutput().index("fast") == 0);
    PASS();
}

TEST(test_timeout_captures_output_before_kill)
{
    CxProcess proc;
    // Echo something, then sleep too long.
    // We should still see the echo'd line in the captured output.
    int rc = proc.run("echo before_sleep; sleep 5", NULL, 300);
    ASSERT(rc == 0);
    ASSERT(proc.wasTimedOut() == 1);
    ASSERT(proc.getOutput().index("before_sleep") == 0);
    PASS();
}

//-------------------------------------------------------------------------
// State reset across calls
//-------------------------------------------------------------------------

TEST(test_state_resets_between_runs)
{
    CxProcess proc;
    proc.run("sleep 5", NULL, 100);
    ASSERT(proc.wasTimedOut() == 1);
    // Second run on the same object should reset _killedByTimeout
    int rc = proc.run("echo ok", NULL, 0);
    ASSERT(rc == 0);
    ASSERT(proc.wasTimedOut() == 0);
    ASSERT(proc.getExitCode() == 0);
    ASSERT(proc.getOutput().index("ok") == 0);
    PASS();
}


//=================================================================================================
// Main
//=================================================================================================

int main(int /*argc*/, char ** /*argv*/)
{
    printf("\n== CxProcess::run(cmd, cwd, timeout_ms) test suite ==\n\n");

    RUN_TEST(test_new_overload_simple);
    RUN_TEST(test_new_overload_nonzero_exit);
    RUN_TEST(test_new_overload_missing_command);
    RUN_TEST(test_new_overload_null_command_returns_minus_one);
    RUN_TEST(test_new_overload_empty_command_returns_minus_one);
    RUN_TEST(test_cwd_pwd_reports_target);
    RUN_TEST(test_cwd_missing_dir_fails);
    RUN_TEST(test_combined_stdout_and_stderr);
    RUN_TEST(test_timeout_kills_sleep);
    RUN_TEST(test_timeout_not_fired_for_fast_command);
    RUN_TEST(test_timeout_captures_output_before_kill);
    RUN_TEST(test_state_resets_between_runs);

    printf("\n== %d passed, %d failed ==\n\n", gTestsPassed, gTestsFailed);
    return (gTestsFailed == 0) ? 0 : 1;
}
```

### `cx_tests/cxprocess/Makefile`

Copy from `cx_tests/cxbuildoutput/Makefile` and change exactly two things:
the `TEST_APP=` name and the `CX_LIBS = ` block (drop the buildoutput entry,
we don't need it). The result:

```make
## makefile: cxprocess_test ###############################################

TEST_APP=	cxprocess_test
CPP=        g++
SHELL=		/bin/sh
MOVE=		mv
COPY=		ln -s
RM=			rm -rf
TOUCH=		touch
LIBRARIAN=	ar rvu
INC=        -I../..

## Platform ###################################################

UNAME_S := $(shell uname -s | tr '[A-Z]' '[a-z]' )

ifeq ($(UNAME_S),linux)
	ARCH := $(shell uname -m | tr '[A-Z]' '[a-z]' )
	CPPFLAGS = -D _LINUX_  -g -Wno-deprecated
endif

ifeq ($(UNAME_S), darwin)
	ARCH := $(shell uname -m | tr '[A-Z]' '[a-z]' )
	CPPFLAGS = -D _OSX_ -g -Wno-deprecated
endif

ifeq ($(UNAME_S),sunos)
    UNAME_R := $(shell uname -r)

	ifeq ($(UNAME_R), 4.1.3)
        CPPFLAGS = -D _SUNOS_ -g
	endif

	ifeq ($(UNAME_R), 4.1.4)
        CPPFLAGS = -D _SUNOS_ -g
	endif

	ifeq ($(UNAME_R), 5.6)
        CPPFLAGS = -D _SOLARIS6_ -g
	endif

	ifeq ($(UNAME_R), 5.7)
        CPPFLAGS = -D _SOLARIS6_ -g
	endif

    ifeq ($(UNAME_R), 5.10)
        CPPFLAGS = -D _SOLARIS10_  -g
    endif
endif

ifeq ($(UNAME_S),irix)
    UNAME_R := $(shell uname -r)
    ifeq ($(UNAME_R), 6.5)
        CPPFLAGS = -D _IRIX6_ -g
    endif
endif

ifeq ($(UNAME_S),netbsd)
	CPPFLAGS = -D _NETBSD_ -g
endif

## Object & Libraries #########################################

LIB_CX_PLATFORM_LIB_DIR=../../lib/$(UNAME_S)_$(ARCH)

APP_OBJECT_DIR=$(UNAME_S)_$(ARCH)

LIB_CX_BASE_NAME=libcx_base.a
LIB_CX_PROCESS_NAME=libcx_process.a

CX_LIBS = \
	$(LIB_CX_PLATFORM_LIB_DIR)/$(LIB_CX_PROCESS_NAME) \
	$(LIB_CX_PLATFORM_LIB_DIR)/$(LIB_CX_BASE_NAME)

ALL_LIBS = $(CX_LIBS) $(PLATFORM_LIBS)

TEST_OBJECTS = \
	$(APP_OBJECT_DIR)/$(TEST_APP).o


## Targets ##################################################

ALL: MAKE_OBJ_DIR $(APP_OBJECT_DIR)/$(TEST_APP)

MAKE_OBJ_DIR:
	mkdir -p $(APP_OBJECT_DIR)

cleanupmac:
	$(RM) ._*

clean:
	$(RM) \
	$(APP_OBJECT_DIR)/$(TEST_APP) \
	$(APP_OBJECT_DIR)/*.o   \
	$(APP_OBJECT_DIR)/*.dbx \
	$(APP_OBJECT_DIR)/*.i   \
	$(APP_OBJECT_DIR)/*.ixx \
	$(APP_OBJECT_DIR)/core  \
	$(APP_OBJECT_DIR)/a.out \
	$(APP_OBJECT_DIR)/*.a


$(APP_OBJECT_DIR)/$(TEST_APP): $(TEST_OBJECTS)
	$(CPP) $(CPPFLAGS) $(INC) $(TEST_OBJECTS) -o $(APP_OBJECT_DIR)/$(TEST_APP) $(ALL_LIBS)


## Conversions ################################################

$(APP_OBJECT_DIR)/$(TEST_APP).o : $(TEST_APP).cpp
	$(CPP) $(CPPFLAGS) $(INC) -c $? -o $@


.PRECIOUS: $(CX_LIBS)
.SUFFIXES: .cpp .C .cc .cxx .o


test:
	./$(APP_OBJECT_DIR)/$(TEST_APP)
```

### `cx_tests/Makefile` — add cxprocess to the top-level build

In the same place where the other tests are listed (look for the block
where `cxbuildoutput` is built), add a parallel block:

```make
	@if [ -d "./cxprocess" ]; then \
		echo "Building cxprocess tests..."; \
		cd cxprocess; make; \
	fi
```

Match the style of the surrounding entries exactly. If there's also a
`clean:` cascade, mirror it.

## Solaris 2.6 portability notes (so this stays clean tomorrow)

Every API used by the new code is POSIX-standard and available on
Solaris 2.6 with g++ 2.95.3.

- **`fork`, `execl`, `chdir`, `pipe`, `dup2`, `close`, `read`, `_exit`,
  `setpgid`** — `<unistd.h>`, all on Solaris 2.6.
- **`waitpid`, `WIFEXITED`, `WEXITSTATUS`, `WIFSIGNALED`, `WTERMSIG`,
  `WNOHANG`** — `<sys/wait.h>`, all on Solaris 2.6.
- **`kill`, `SIGTERM`, `SIGKILL`** — `<signal.h>`, all on Solaris 2.6.
  `kill(-pid, sig)` for process-group kill is POSIX, works fine.
- **`select`, `fd_set`, `FD_ZERO`, `FD_SET`, `FD_ISSET`** — On Solaris
  2.6 these may live in `<sys/time.h>` rather than `<sys/select.h>`.
  The include block above pulls in **both**, which is the safe play.
- **`gettimeofday`, `struct timeval`** — `<sys/time.h>`, on Solaris 2.6.
  Not `clock_gettime` even though Solaris 2.6 has it; `gettimeofday`
  is more universal and the precision is fine.
- **`errno`, `EINTR`** — `<errno.h>`, on Solaris 2.6.

What's deliberately NOT used (avoids any "funny business"):

- No `<chrono>`, no `<thread>`, no `<filesystem>`, no `<sstream>`.
- No `nullptr` — `NULL`, with `(char *)NULL` cast where varargs need it.
- No `auto`, no range-for, no lambdas, no smart pointers, no STL beyond
  what cx already uses (`CxString`).
- No `posix_spawn` — fork+exec is what cx already does on Solaris.
- No `strerror()` in the child after fork — _exit(127) on failure, parent
  infers from exit code 127.
- No `O_CLOEXEC` — the seed daemon will manage CLOEXEC on its sockets at
  a higher level; not CxProcess's job.
- No signal handlers — pure waitpid + select polling, single-threaded.

## Acceptance checklist (tomorrow, in order)

State to confirm before moving to the bundled SS5 image:

- [ ] `cx/process/process.h` and `process.cpp` replaced. `cm`'s vestigial
      `#include <cx/process/process.h>` line in `ScreenEditorCommands.cpp`
      deleted.
- [ ] `cx_tests/cxprocess/` directory created with the three files above.
- [ ] `cx_tests/Makefile` references the new test alongside the other
      tests.
- [ ] **Mac**: `make` in `cx/` produces all the same libraries with no
      new errors (verifies the `process.cpp` rewrite didn't regress
      existing builds).
- [ ] **Mac**: `make` in `cx_tests/cxprocess/` builds, and running the
      test binary prints `12 passed, 0 failed`.
- [ ] **Mac**: `make` in `cx_tests/cxbuildoutput/` still builds and
      passes (proves the new code didn't break the existing test of
      the original `run(const char *)`).
- [ ] **Mac**: `cm` builds (proves the vestigial-include removal is safe).
- [ ] **Linux**: same three checks (`cx/`, `cx_tests/cxprocess/`,
      `cx_tests/cxbuildoutput/`).
- [ ] **SS5**: same three checks. If g++ 2.95.3 chokes on anything, it
      will be in the new process.cpp; the test output will say where.
- [ ] Once all three platforms green: move the SS5-validated cx onto
      the bundled SPARCplug disk image and continue toward the seed
      daemon design.

The legacy `run(const char *)` path remains popen-based and untouched
in behavior — its only diff is the one-line pclose-returns-minus-one
safety guard, which is dead code on any successful run. So any
regression in the new overload doesn't affect existing callers.

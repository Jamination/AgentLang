/* Starts gui.exe (an AL program built with --gui) the ways a GUI program gets started and
 * checks what it does; writes "ok <case>" or "FAIL <case>: ..." per case to gui_result.txt (our
 * standard output may be the console that the first case gives up).
 *   console  started from a console without redirection: the program attaches to it and its
 *            output appears there (run.sh runs this launcher in a terminal of `script` and finds
 *            the child's lines in it; without a usable console the case is skipped)
 *   none     no console and no standard handles (Explorer): output vanishes, no error
 *   pipes    standard output and error redirected to pipes: the text arrives there
 *   panic    the same with a panic: the message arrives on the error pipe (and no message
 *            box blocks the program: that would be a timeout) */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void fail(const char *name, const char *why) {
    printf("FAIL %s: %s\n", name, why);
    failures++;
}

/* runs gui.exe with the given handles (NULL: none); returns the exit status, -1 on a timeout */
static DWORD run(const char *args, HANDLE out, HANDLE err) {
    char cmd[256];
    snprintf(cmd, sizeof cmd, "gui.exe %s", args);
    STARTUPINFOA si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = NULL;
    si.hStdOutput = out;
    si.hStdError = err;
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        printf("CreateProcess failed: %lu\n", GetLastError());
        return (DWORD)-2;
    }
    CloseHandle(pi.hThread);
    if (out) CloseHandle(out);
    if (err && err != out) CloseHandle(err);
    DWORD code = (DWORD)-1;
    if (WaitForSingleObject(pi.hProcess, 30000) == WAIT_OBJECT_0) {
        GetExitCodeProcess(pi.hProcess, &code);
    } else {
        TerminateProcess(pi.hProcess, 99);
    }
    CloseHandle(pi.hProcess);
    return code;
}

/* an inheritable pipe: the read end for us, the write end for the child */
static void pipe_pair(HANDLE *r, HANDLE *w) {
    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    CreatePipe(r, w, &sa, 1 << 20);
    SetHandleInformation(*r, HANDLE_FLAG_INHERIT, 0);
}

static int read_all(HANDLE h, char *buf, int cap) {
    int n = 0;
    DWORD got;
    while (n < cap - 1 && ReadFile(h, buf + n, cap - 1 - n, &got, NULL) && got > 0) n += got;
    buf[n] = 0;
    CloseHandle(h);
    return n;
}

static char obuf[1 << 20], ebuf[1 << 16];

int main(void) {
    freopen("gui_result.txt", "w", stdout);
    setvbuf(stdout, NULL, _IONBF, 0);
    /* console: ours, if Wine gave us a working one (it does in a terminal) */
    HANDLE con = CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    DWORD mode, code;
    if (con == INVALID_HANDLE_VALUE || !GetConsoleMode(con, &mode)) {
        printf("skip console: no console\n");
    } else {
        code = run("", NULL, NULL);
        if (code != 42) { char m[64]; snprintf(m, sizeof m, "exit status %ld, expected 42", (long)code); fail("console", m); }
        else printf("ok console\n");
    }
    fflush(stdout);

    /* none: we give up our console so there is nothing to attach to */
    FreeConsole();
    code = run("", NULL, NULL);
    if (code != 42) { char m[64]; snprintf(m, sizeof m, "exit status %ld, expected 42", (long)code); fail("none", m); }
    else printf("ok none\n");

    /* pipes: the read ends are drained after the child ended (the pipes hold 1 MiB) */
    HANDLE ro, wo, re, we;
    pipe_pair(&ro, &wo);
    pipe_pair(&re, &we);
    code = run("", wo, we);
    read_all(ro, obuf, sizeof obuf);
    read_all(re, ebuf, sizeof ebuf);
    if (code != 42) fail("pipes", "exit status");
    else if (strncmp(obuf, "out 0\n", 6) != 0 || !strstr(obuf, "out 999\ninput 0\n")) fail("pipes", "standard output");
    else if (strcmp(ebuf, "err line\n") != 0) fail("pipes", "standard error");
    else printf("ok pipes\n");

    /* panic */
    pipe_pair(&ro, &wo);
    pipe_pair(&re, &we);
    code = run("panic", wo, we);
    read_all(ro, obuf, sizeof obuf);
    read_all(re, ebuf, sizeof ebuf);
    if (code == (DWORD)-1) fail("panic", "timeout (a message box?)");
    else if (code != 1) fail("panic", "exit status");
    else if (!strstr(ebuf, "panic at ") || !strstr(ebuf, "gui.al:13: boom")) { fail("panic", "message"); printf("%s", ebuf); }
    else printf("ok panic\n");
    return failures != 0;
}

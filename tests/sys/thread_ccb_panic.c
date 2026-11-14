/* For thread_ccb.al: a C library whose own thread calls the program back. */
#ifdef _WIN32
#include <windows.h>
typedef void (*cb)(int);
static cb g;
static DWORD WINAPI run(LPVOID a) { g((int)(long long)a); return 0; }
__declspec(dllexport) void call_from_thread(cb f, int x) {
    g = f;
    HANDLE h = CreateThread(0, 0, run, (LPVOID)(long long)x, 0, 0);
    WaitForSingleObject(h, INFINITE);
    CloseHandle(h);
}
#else
#include <pthread.h>
typedef void (*cb)(int);
static cb g;
static void *run(void *a) { g((int)(long)a); return 0; }
void call_from_thread(cb f, int x) {
    pthread_t t;
    g = f;
    pthread_create(&t, 0, run, (void *)(long)x);
    pthread_join(t, 0);
}
#endif

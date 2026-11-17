/* Makes the Ogg Vorbis fixtures of tests/std/audio_ogg*.al and their reference decodes.
   Not part of the test run: the fixtures are committed. It needs Windows and the libvorbis /
   libsndfile DLLs that Audacity installs (sndfile.dll for encoding, vorbisfile.dll, the
   reference decoder, for decoding); see ogg.txt.

     gcc -O2 -o ogg_make.exe ogg_make.c
     ogg_make enc SIGNAL RATE CHANNELS SECONDS QUALITY out.ogg   synthesise SIGNAL, encode it
     ogg_make dec in.ogg out.wav                                decode with libvorbisfile
                                                                (32-bit float WAV)

   SIGNAL: "tones" (a chord per channel with clicks every 0.1 s: transients make the encoder
   switch to short blocks) or "noise" (white noise with a decaying envelope per 50 ms). */
#include <windows.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DLLDIR "C:\\Program Files\\Audacity\\"

typedef struct { long long frames; int samplerate, channels, format, sections, seekable; } SF_INFO;
typedef void *(*sf_open_t)(const char *, int, SF_INFO *);
typedef int (*sf_command_t)(void *, int, void *, int);
typedef long long (*sf_writef_float_t)(void *, const float *, long long);
typedef int (*sf_close_t)(void *);
typedef const char *(*sf_strerror_t)(void *);

typedef struct { int version, channels; long rate; } vorbis_info_head;
typedef int (*ov_fopen_t)(const char *, void *);
typedef vorbis_info_head *(*ov_info_t)(void *, int);
typedef long (*ov_read_float_t)(void *, float ***, int, int *);
typedef int (*ov_clear_t)(void *);

static HMODULE load(const char *name) {
    char path[512];
    snprintf(path, sizeof path, "%s%s", DLLDIR, name);
    HMODULE h = LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h) { fprintf(stderr, "cannot load %s\n", path); exit(1); }
    return h;
}

static unsigned long long rng = 88172645463325252ULL;
static float noise(void) {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return (float)((rng >> 11) * (1.0 / 9007199254740992.0) * 2.0 - 1.0);
}

static void put32(FILE *f, unsigned v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, unsigned v) { fwrite(&v, 2, 1, f); }

int main(int argc, char **argv) {
    if (argc == 8 && !strcmp(argv[1], "enc")) {
        const char *sig = argv[2];
        int rate = atoi(argv[3]), ch = atoi(argv[4]);
        double secs = atof(argv[5]), q = atof(argv[6]);
        long long n = (long long)(secs * rate);
        float *x = calloc((size_t)(n * ch), sizeof(float));
        for (long long i = 0; i < n; i++) {
            double t = (double)i / rate;
            for (int c = 0; c < ch; c++) {
                double v;
                if (!strcmp(sig, "tones")) {
                    double f = 220.0 * (1 + c * 0.5);
                    v = 0.3 * sin(2 * M_PI * f * t) + 0.15 * sin(2 * M_PI * f * 2.01 * t + c) +
                        0.08 * sin(2 * M_PI * (f * 3.0 + 400 * t) * t);
                    double ph = fmod(t, 0.1);
                    if (ph < 0.004) v += 0.5 * (1 - ph / 0.004) * noise();
                } else {
                    double ph = fmod(t + c * 0.013, 0.05);
                    v = 0.6 * exp(-ph * 60) * noise();
                }
                x[i * ch + c] = (float)v;
            }
        }
        HMODULE sf = load("sndfile.dll");
        sf_open_t sf_open = (sf_open_t)GetProcAddress(sf, "sf_open");
        sf_command_t sf_command = (sf_command_t)GetProcAddress(sf, "sf_command");
        sf_writef_float_t sf_writef_float = (sf_writef_float_t)GetProcAddress(sf, "sf_writef_float");
        sf_close_t sf_close = (sf_close_t)GetProcAddress(sf, "sf_close");
        sf_strerror_t sf_strerror = (sf_strerror_t)GetProcAddress(sf, "sf_strerror");
        SF_INFO info = {0};
        info.samplerate = rate;
        info.channels = ch;
        info.format = 0x200000 | 0x0060; /* SF_FORMAT_OGG | SF_FORMAT_VORBIS */
        void *h = sf_open(argv[7], 0x20, &info);
        if (!h) { fprintf(stderr, "sf_open: %s\n", sf_strerror(NULL)); return 1; }
        /* SFC_SET_VBR_ENCODING_QUALITY, 0 (lowest) .. 1 (highest); returns SF_TRUE on success */
        if (sf_command(h, 0x1300, &q, sizeof q) != 1) { fprintf(stderr, "quality refused\n"); return 1; }
        for (long long i = 0; i < n; i += 4096) {
            long long k = n - i < 4096 ? n - i : 4096;
            if (sf_writef_float(h, x + i * ch, k) != k) { fprintf(stderr, "short write\n"); return 1; }
        }
        sf_close(h);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "dec")) {
        HMODULE vf = load("vorbisfile.dll");
        ov_fopen_t ov_fopen = (ov_fopen_t)GetProcAddress(vf, "ov_fopen");
        ov_info_t ov_info = (ov_info_t)GetProcAddress(vf, "ov_info");
        ov_read_float_t ov_read_float = (ov_read_float_t)GetProcAddress(vf, "ov_read_float");
        ov_clear_t ov_clear = (ov_clear_t)GetProcAddress(vf, "ov_clear");
        static char file[16384]; /* OggVorbis_File, opaque here */
        LARGE_INTEGER t0, t1, fq;
        QueryPerformanceFrequency(&fq);
        QueryPerformanceCounter(&t0);
        if (ov_fopen(argv[2], file)) { fprintf(stderr, "ov_fopen failed\n"); return 1; }
        vorbis_info_head *vi = ov_info(file, -1);
        int ch = vi->channels;
        long rate = vi->rate;
        size_t cap = 1 << 20, n = 0;
        float *out = malloc(cap * sizeof(float));
        for (;;) {
            float **pcm;
            int bs;
            long got = ov_read_float(file, &pcm, 4096, &bs);
            if (got == 0) break;
            if (got < 0) { fprintf(stderr, "ov_read_float: %ld\n", got); continue; }
            while ((n + got) * ch > cap) { cap *= 2; out = realloc(out, cap * sizeof(float)); }
            for (long i = 0; i < got; i++)
                for (int c = 0; c < ch; c++) out[(n + i) * ch + c] = pcm[c][i];
            n += got;
        }
        QueryPerformanceCounter(&t1);
        ov_clear(file);
        FILE *f = fopen(argv[3], "wb");
        unsigned bytes = (unsigned)(n * ch * 4);
        fwrite("RIFF", 1, 4, f); put32(f, 36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
        put32(f, 16); put16(f, 3); put16(f, ch); put32(f, rate); put32(f, rate * ch * 4);
        put16(f, ch * 4); put16(f, 32); fwrite("data", 1, 4, f); put32(f, bytes);
        fwrite(out, 4, n * ch, f);
        fclose(f);
        printf("%s: %d channels, %ld Hz, %zu frames (libvorbisfile: %.1f ms)\n", argv[2], ch, rate, n,
               (t1.QuadPart - t0.QuadPart) * 1000.0 / fq.QuadPart);
        return 0;
    }
    fprintf(stderr, "usage: ogg_make enc SIGNAL RATE CHANNELS SECONDS QUALITY out.ogg | dec in.ogg out.wav\n");
    return 2;
}

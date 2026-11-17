/* A small command-line front end to libjpeg-turbo's TurboJPEG DLL, used by tests/gen/jpegs.py
   to make the JPEG fixtures of tests/std and their reference decodes. Windows, MinGW-w64:

       gcc -O2 -o jpeg_tj.exe tests/gen/jpeg_tj.c

   It loads turbojpeg.dll at run time (no header or import library needed; the path is taken
   from TURBOJPEG_DLL, default the copy that ships with Audacity), so the API is declared here.

       jpeg_tj enc in.raw W H PF SUBSAMP QUALITY FLAGS out.jpg
           PF: 0 RGB, 6 grey, 11 CMYK; SUBSAMP: 0 4:4:4, 1 4:2:2, 2 4:2:0, 3 grey, 4 4:4:0, 5 4:1:1
           FLAGS: TJFLAG_* (16384 progressive, 4096 accurate DCT). libjpeg-turbo also reads the
           environment: TJ_RESTART=N (rows) or NB (MCUs), TJ_OPTIMIZE=1 (optimised Huffman tables)
       jpeg_tj dec in.jpg PF out.raw
           decodes with the default settings (accurate integer IDCT, fancy upsampling); prints W H */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

typedef void *tjhandle;
typedef tjhandle (*init_t)(void);
typedef int (*comp_t)(tjhandle, const unsigned char *, int, int, int, int, unsigned char **,
                      unsigned long *, int, int, int);
typedef int (*hdr_t)(tjhandle, const unsigned char *, unsigned long, int *, int *, int *, int *);
typedef int (*dec_t)(tjhandle, const unsigned char *, unsigned long, unsigned char *, int, int,
                     int, int, int);
typedef char *(*err_t)(tjhandle);

static unsigned char *slurp(const char *path, long *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    *n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(*n + 1);
    if (fread(b, 1, *n, f) != (size_t)*n) { fprintf(stderr, "cannot read %s\n", path); exit(1); }
    fclose(f);
    return b;
}

static void spit(const char *path, const unsigned char *b, long n) {
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(b, 1, n, f) != (size_t)n) { fprintf(stderr, "cannot write %s\n", path); exit(1); }
    fclose(f);
}

int main(int argc, char **argv) {
    const char *dll = getenv("TURBOJPEG_DLL");
    HMODULE m = LoadLibraryA(dll ? dll : "C:\\Program Files\\Audacity\\turbojpeg.dll");
    if (!m) { fprintf(stderr, "cannot load turbojpeg.dll\n"); return 1; }
    err_t errstr = (err_t)GetProcAddress(m, "tjGetErrorStr2");
    if (argc == 10 && !strcmp(argv[1], "enc")) {
        init_t init = (init_t)GetProcAddress(m, "tjInitCompress");
        comp_t comp = (comp_t)GetProcAddress(m, "tjCompress2");
        long n;
        unsigned char *src = slurp(argv[2], &n);
        tjhandle h = init();
        unsigned char *out = NULL;
        unsigned long size = 0;
        if (comp(h, src, atoi(argv[3]), 0, atoi(argv[4]), atoi(argv[5]), &out, &size, atoi(argv[6]),
                 atoi(argv[7]), atoi(argv[8]))) {
            fprintf(stderr, "tjCompress2: %s\n", errstr(h));
            return 1;
        }
        spit(argv[9], out, (long)size);
        return 0;
    }
    if (argc == 5 && !strcmp(argv[1], "dec")) {
        init_t init = (init_t)GetProcAddress(m, "tjInitDecompress");
        hdr_t hdr = (hdr_t)GetProcAddress(m, "tjDecompressHeader3");
        dec_t dec = (dec_t)GetProcAddress(m, "tjDecompress2");
        long n;
        unsigned char *src = slurp(argv[2], &n);
        tjhandle h = init();
        int w, ht, ss, cs, pf = atoi(argv[3]);
        if (hdr(h, src, (unsigned long)n, &w, &ht, &ss, &cs)) {
            fprintf(stderr, "tjDecompressHeader3: %s\n", errstr(h));
            return 1;
        }
        int ps = pf == 6 ? 1 : pf == 11 ? 4 : 3;
        unsigned char *out = malloc((size_t)w * ht * ps);
        if (dec(h, src, (unsigned long)n, out, w, 0, ht, pf, 0)) {
            fprintf(stderr, "tjDecompress2: %s\n", errstr(h));
            return 1;
        }
        spit(argv[4], out, (long)w * ht * ps);
        printf("%d %d\n", w, ht);
        return 0;
    }
    fprintf(stderr, "usage: see the comment at the top of jpeg_tj.c\n");
    return 2;
}

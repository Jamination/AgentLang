#include <math.h>
#include <stdio.h>
#include <stdlib.h>
static double fract64(double x){ return x - floor(x); }
static float fract32(float x){ return x - floorf(x); }
int main(void){
  FILE*f=fopen("/tmp/mfz/in64.bin","rb"); fseek(f,0,2); long sz=ftell(f); rewind(f);
  double*a=malloc(sz); fread(a,1,sz,f); fclose(f); long n=sz/16;
  double*o=malloc(n*19*8); long k=0;
  for(long i=0;i<n;i++){ double x=a[2*i],y=a[2*i+1];
    double v[19]={sin(x),cos(x),tan(x),asin(x),acos(x),atan(x),atan2(y,x),exp(x),log(x),log2(x),pow(x,y),fmod(x,y),trunc(x),round(x),fract64(x),sin(x),cos(x),floor(x),ceil(x)};
    for(int j=0;j<19;j++) o[k++]=v[j]; }
  f=fopen("/tmp/mfz/ref64.bin","wb"); fwrite(o,8,k,f); fclose(f);
  f=fopen("/tmp/mfz/in32.bin","rb"); fseek(f,0,2); sz=ftell(f); rewind(f);
  float*b=malloc(sz); fread(b,1,sz,f); fclose(f); n=sz/8;
  float*p=malloc(n*19*4); k=0;
  for(long i=0;i<n;i++){ float x=b[2*i],y=b[2*i+1];
    float v[19]={sinf(x),cosf(x),tanf(x),asinf(x),acosf(x),atanf(x),atan2f(y,x),expf(x),logf(x),log2f(x),powf(x,y),fmodf(x,y),truncf(x),roundf(x),fract32(x),sinf(x),cosf(x),floorf(x),ceilf(x)};
    for(int j=0;j<19;j++) p[k++]=v[j]; }
  f=fopen("/tmp/mfz/ref32.bin","wb"); fwrite(p,4,k,f); fclose(f);
  return 0; }

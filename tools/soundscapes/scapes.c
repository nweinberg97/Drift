// Reference implementation of Drift's focus soundscapes.
// Renders WAV previews; the Swift SoundGenerator mirrors this code.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FS 44100.0
#define TAU 6.283185307179586

static uint64_t rng = 0x9E3779B97F4A7C15ULL;
static inline double rnd01(void) { // [0,1)
  rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27;
  return (double)((rng * 0x2545F4914F6CDD1DULL) >> 11) / 9007199254740992.0;
}
static inline double white(void) { return rnd01() * 2.0 - 1.0; }

// ---------- primitives ----------
typedef struct { double y, a; } OnePole;
static void op_set(OnePole *f, double fc) { f->a = 1.0 - exp(-TAU * fc / FS); }
static inline double op_lp(OnePole *f, double x) { f->y += f->a * (x - f->y); return f->y; }
static inline double op_hp(OnePole *f, double x) { return x - op_lp(f, x); }

typedef struct { double b0, b1, b2, a1, a2, z1, z2; } Biquad;
static void bq_lowpass(Biquad *b, double fc, double q) {
  double w = TAU * fc / FS, c = cos(w), s = sin(w), al = s / (2 * q), a0 = 1 + al;
  b->b0 = (1 - c) / 2 / a0; b->b1 = (1 - c) / a0; b->b2 = (1 - c) / 2 / a0;
  b->a1 = -2 * c / a0; b->a2 = (1 - al) / a0;
}
static void bq_highpass(Biquad *b, double fc, double q) {
  double w = TAU * fc / FS, c = cos(w), s = sin(w), al = s / (2 * q), a0 = 1 + al;
  b->b0 = (1 + c) / 2 / a0; b->b1 = -(1 + c) / a0; b->b2 = (1 + c) / 2 / a0;
  b->a1 = -2 * c / a0; b->a2 = (1 - al) / a0;
}
static inline double bq(Biquad *b, double x) { // transposed direct form II
  double y = b->b0 * x + b->z1;
  b->z1 = b->b1 * x - b->a1 * y + b->z2;
  b->z2 = b->b2 * x - b->a2 * y;
  return y;
}

typedef struct { double p[7]; } Pink; // Paul Kellet
static inline double pink(Pink *k) {
  double w = white();
  k->p[0] = 0.99886 * k->p[0] + w * 0.0555179;
  k->p[1] = 0.99332 * k->p[1] + w * 0.0750759;
  k->p[2] = 0.96900 * k->p[2] + w * 0.1538520;
  k->p[3] = 0.86650 * k->p[3] + w * 0.3104856;
  k->p[4] = 0.55000 * k->p[4] + w * 0.5329522;
  k->p[5] = -0.7616 * k->p[5] - w * 0.0168980;
  double out = k->p[0] + k->p[1] + k->p[2] + k->p[3] + k->p[4] + k->p[5] + k->p[6] + w * 0.5362;
  k->p[6] = w * 0.115926;
  return out * 0.11;
}
typedef struct { double y; } Brown;
static inline double brown(Brown *b) { b->y = (b->y + 0.02 * white()) / 1.02; return b->y * 3.5; }

// Smooth random wander: cosine interpolation between random points.
typedef struct { double a, b, t, step; } Wander;
static void wander_init(Wander *w, double seconds) { w->a = rnd01(); w->b = rnd01(); w->t = 0; w->step = 1.0 / (seconds * FS); }
static inline double wander(Wander *w) { // 0..1
  w->t += w->step;
  if (w->t >= 1) { w->t -= 1; w->a = w->b; w->b = rnd01(); }
  double m = (1 - cos(w->t * M_PI)) * 0.5;
  return w->a + (w->b - w->a) * m;
}

// Freeverb-style reverb, mono in → stereo out.
#define NCOMB 4
#define NAP 2
static const int combLen[NCOMB] = {1116, 1188, 1277, 1356};
static const int apLen[NAP] = {556, 441};
#define SPREAD 23
typedef struct { float *buf; int len, idx; double store; } Comb;
typedef struct { float *buf; int len, idx; } AllPass;
typedef struct { Comb c[2][NCOMB]; AllPass a[2][NAP]; double feedback, damp; } Reverb;
static void rv_init(Reverb *r, double feedback, double damp) {
  r->feedback = feedback; r->damp = damp;
  for (int ch = 0; ch < 2; ch++) {
    for (int i = 0; i < NCOMB; i++) { int n = combLen[i] + ch * SPREAD; r->c[ch][i] = (Comb){calloc(n, sizeof(float)), n, 0, 0}; }
    for (int i = 0; i < NAP; i++) { int n = apLen[i] + ch * SPREAD; r->a[ch][i] = (AllPass){calloc(n, sizeof(float)), n, 0}; }
  }
}
static inline double rv_channel(Reverb *r, int ch, double in) {
  double out = 0;
  for (int i = 0; i < NCOMB; i++) {
    Comb *c = &r->c[ch][i];
    double y = c->buf[c->idx];
    c->store = y * (1 - r->damp) + c->store * r->damp;
    c->buf[c->idx] = (float)(in + c->store * r->feedback);
    if (++c->idx >= c->len) c->idx = 0;
    out += y;
  }
  for (int i = 0; i < NAP; i++) {
    AllPass *a = &r->a[ch][i];
    double b = a->buf[a->idx];
    a->buf[a->idx] = (float)(out + b * 0.5);
    out = b - out;
    if (++a->idx >= a->len) a->idx = 0;
  }
  return out;
}

// Short one-shot voices for drops and crackles.
#define NV 24
typedef struct { double amp, decay, freq, phase, glide, pan; int kind; OnePole hp; } Voice;
static Voice voices[NV];
static void voice_spawn(double amp, double tau, double freq, double glide, double pan, int kind, double hpHz) {
  for (int i = 0; i < NV; i++) if (voices[i].amp < 1e-4) {
    voices[i] = (Voice){amp, exp(-1.0 / (tau * FS)), freq, 0, glide, pan, kind, {0, 0}};
    op_set(&voices[i].hp, hpHz);
    return;
  }
}
static inline void voices_tick(double *l, double *r) {
  for (int i = 0; i < NV; i++) {
    Voice *v = &voices[i];
    if (v->amp < 1e-4) continue;
    double s;
    if (v->kind == 0) { // tonal drop: decaying sine, pitch rising
      s = sin(v->phase); v->phase += TAU * v->freq / FS; v->freq *= v->glide;
    } else {            // noise pop
      s = op_hp(&v->hp, white());
    }
    s *= v->amp; v->amp *= v->decay;
    *l += s * (1 - v->pan); *r += s * v->pan;
  }
}

// ---------- soundscapes ----------
typedef void (*Scape)(double *l, double *r);

// 1. Brown noise: deep and smooth.
static Brown bnL, bnR; static OnePole bnLpL, bnLpR; static Wander bnW;
static void brown_init(void) { op_set(&bnLpL, 700); op_set(&bnLpR, 700); wander_init(&bnW, 19); }
static void brown_tick(double *l, double *r) {
  double a = brown(&bnL), b = brown(&bnR), g = 0.88 + 0.12 * wander(&bnW);
  double L = op_lp(&bnLpL, a * 0.8 + b * 0.2), R = op_lp(&bnLpR, b * 0.8 + a * 0.2);
  *l = L * g * 1.25; *r = R * g * 1.25;
}

// 2. Rain: soft steady bed, close drops, distant rumble, a little room.
static Pink rnPL, rnPR; static Biquad rnHpL, rnHpR, rnLpL, rnLpR; static Brown rnB; static OnePole rnRum;
static Wander rnW; static Reverb rnRv;
static void rain_init(void) {
  bq_highpass(&rnHpL, 420, 0.6); bq_highpass(&rnHpR, 420, 0.6);
  bq_lowpass(&rnLpL, 6500, 0.6); bq_lowpass(&rnLpR, 6500, 0.6);
  op_set(&rnRum, 180); wander_init(&rnW, 13); rv_init(&rnRv, 0.80, 0.4);
}
static void rain_tick(double *l, double *r) {
  double intensity = 0.8 + 0.2 * wander(&rnW);
  double L = bq(&rnLpL, bq(&rnHpL, pink(&rnPL))) * intensity * 1.1;
  double R = bq(&rnLpR, bq(&rnHpR, pink(&rnPR))) * intensity * 1.1;
  double rum = op_lp(&rnRum, brown(&rnB)) * 0.22;
  if (rnd01() < 55.0 * intensity / FS) {
    double u = rnd01();
    voice_spawn(0.02 + 0.12 * u * u * u, 0.0025 + 0.004 * rnd01(), 1900 + 2600 * rnd01(), 1.00004, rnd01(), 0, 0);
  }
  double dl = 0, dr = 0; voices_tick(&dl, &dr);
  double wetIn = (L + R) * 0.5 + (dl + dr) * 0.5;
  double wl = rv_channel(&rnRv, 0, wetIn * 0.015), wr = rv_channel(&rnRv, 1, wetIn * 0.015);
  *l = L + rum + dl + wl; *r = R + rum + dr + wr;
}

// 3. Ocean: waves that swell and pull back, slightly out of step left/right.
typedef struct { double phase, period; } Wave;
static Wave ocW[2]; static Brown ocB[2]; static Pink ocP[2]; static Biquad ocLp[2]; static OnePole ocFoamHp[2];
static Reverb ocRv; static int ocCount;
static double wave_env(Wave *w) {
  w->phase += 1.0 / (w->period * FS);
  if (w->phase >= 1) { w->phase -= 1; w->period = 8.5 + 4.5 * rnd01(); }
  double p = w->phase, e;
  if (p < 0.38) { double x = p / 0.38; e = x * x * (3 - 2 * x); }
  else e = exp(-(p - 0.38) * 4.2);
  return e;
}
static void ocean_init(void) {
  ocW[0] = (Wave){0.0, 10.5}; ocW[1] = (Wave){0.55, 11.7};
  for (int c = 0; c < 2; c++) { bq_lowpass(&ocLp[c], 400, 0.5); op_set(&ocFoamHp[c], 2500); }
  rv_init(&ocRv, 0.78, 0.5); ocCount = 0;
}
static void ocean_tick(double *l, double *r) {
  double out[2];
  for (int c = 0; c < 2; c++) {
    double e = wave_env(&ocW[c]);
    if ((ocCount & 31) == 0) bq_lowpass(&ocLp[c], 260 + 2400 * pow(e, 1.6), 0.55);
    double src = 0.65 * brown(&ocB[c]) + 0.5 * pink(&ocP[c]);
    double body = bq(&ocLp[c], src) * (0.14 + 0.86 * e);
    double foam = op_hp(&ocFoamHp[c], white()) * e * e * e * 0.05;
    out[c] = (body + foam) * 1.15;
  }
  ocCount++;
  double wl = rv_channel(&ocRv, 0, (out[0] + out[1]) * 0.012), wr = rv_channel(&ocRv, 1, (out[0] + out[1]) * 0.012);
  *l = out[0] * 0.85 + out[1] * 0.15 + wl; *r = out[1] * 0.85 + out[0] * 0.15 + wr;
}

// 4. Fireplace: low roar, flicker, and crackles that come in little clusters.
static Brown fpB, fpB2; static OnePole fpLp, fpLp2, fpHissHp; static Pink fpFlameP; static Biquad fpFlameHp, fpFlameLp; static Pink fpP; static Wander fpFlick; static Reverb fpRv;
static int fpCluster; static double fpClusterGap;
static void fire_init(void) { op_set(&fpLp, 420); op_set(&fpLp2, 420); op_set(&fpHissHp, 3500); bq_highpass(&fpFlameHp, 350, 0.7); bq_lowpass(&fpFlameLp, 1400, 0.7); wander_init(&fpFlick, 1.7); rv_init(&fpRv, 0.70, 0.5); fpCluster = 0; fpClusterGap = 0; }
static void fire_tick(double *l, double *r) {
  double flick = 0.8 + 0.2 * wander(&fpFlick);
  double roarL = op_lp(&fpLp, brown(&fpB)) * 0.35 * flick, roarR = op_lp(&fpLp2, brown(&fpB2)) * 0.35 * flick;
  double flame = bq(&fpFlameLp, bq(&fpFlameHp, pink(&fpFlameP))) * 0.55 * flick * flick;
  double hiss = op_hp(&fpHissHp, pink(&fpP)) * 0.08 * flick;
  if (fpCluster > 0) {
    fpClusterGap -= 1;
    if (fpClusterGap <= 0) {
      double u = rnd01();
      voice_spawn(0.12 + 0.55 * u * u * u, 0.0006 + 0.003 * rnd01(), 0, 1, 0.2 + 0.6 * rnd01(), 1, 900 + 2500 * rnd01());
      fpCluster--; fpClusterGap = (0.004 + 0.03 * rnd01()) * FS;
    }
  } else if (rnd01() < 3.4 / FS) {
    fpCluster = 1 + (int)(rnd01() * rnd01() * 6); fpClusterGap = 0;
  } else if (rnd01() < 9.0 / FS) {
    voice_spawn(0.05 + 0.14 * rnd01(), 0.0005 + 0.0015 * rnd01(), 0, 1, rnd01(), 1, 2500);
  }
  double cl = 0, cr = 0; voices_tick(&cl, &cr);
  double wl = rv_channel(&fpRv, 0, (cl + cr) * 0.02), wr = rv_channel(&fpRv, 1, (cl + cr) * 0.02);
  *l = roarL + flame + hiss + cl + wl; *r = roarR + flame + hiss + cr + wr;
}

// 5. Soft pad: slow major-seventh/ninth chords in a big room.
#define PV 5
static const double chords[4][PV] = {
  {146.83, 220.00, 277.18, 329.63, 369.99}, // Dmaj9
  {123.47, 185.00, 220.00, 277.18, 293.66}, // Bm9
  { 98.00, 146.83, 185.00, 220.00, 246.94}, // Gmaj9
  {110.00, 164.81, 220.00, 246.94, 277.18}, // A6/9
};
static double padPh[2][PV][2]; static Wander padW[PV]; static Biquad padLp[2]; static Reverb padRv; static double padT; static Brown padAir;
static void pad_init(void) {
  for (int v = 0; v < PV; v++) wander_init(&padW[v], 6 + v * 1.7);
  bq_lowpass(&padLp[0], 1600, 0.6); bq_lowpass(&padLp[1], 1600, 0.6);
  rv_init(&padRv, 0.88, 0.35); padT = 0; memset(padPh, 0, sizeof padPh);
}
static inline double padOsc(double ph) { return sin(ph) + 0.22 * sin(2 * ph) + 0.07 * sin(3 * ph); }
static void pad_tick(double *l, double *r) {
  const double chordLen = 14.0, fade = 5.0;
  padT += 1.0 / FS;
  double pos = fmod(padT, chordLen * 4);
  int ci = (int)(pos / chordLen), ni = (ci + 1) % 4;
  double into = pos - ci * chordLen, mix = 0;
  if (into > chordLen - fade) mix = (1 - cos((into - (chordLen - fade)) / fade * M_PI)) * 0.5;
  // Fade in from silence at start.
  double startGain = padT < 4 ? padT / 4 : 1;
  double sum[2] = {0, 0};
  for (int v = 0; v < PV; v++) {
    double f = chords[ci][v] * (1 - mix) + chords[ni][v] * mix; // gentle glide between chords
    double amp = (0.55 + 0.45 * wander(&padW[v])) * (v == 0 ? 0.32 : 0.2);
    double pan = 0.25 + 0.5 * ((double)v / (PV - 1));
    for (int d = 0; d < 2; d++) {
      double det = d == 0 ? 0.9983 : 1.0017;
      padPh[0][v][d] += TAU * f * det / FS;
      if (padPh[0][v][d] > TAU) padPh[0][v][d] -= TAU;
      double s = padOsc(padPh[0][v][d]) * amp * 0.5;
      sum[0] += s * (1 - pan) * 2; sum[1] += s * pan * 2;
    }
  }
  double air = brown(&padAir) * 0.015;
  double L = bq(&padLp[0], sum[0]) * startGain + air, R = bq(&padLp[1], sum[1]) * startGain + air;
  double wl = rv_channel(&padRv, 0, (L + R) * 0.02), wr = rv_channel(&padRv, 1, (L + R) * 0.02);
  *l = (L * 0.55 + wl * 1.0) * 0.9; *r = (R * 0.55 + wr * 1.0) * 0.9;
}

// Transparent below 0.7, rounds peaks off smoothly above (never exceeds 1).
static inline double softclip(double x) {
  double a = fabs(x);
  if (a <= 0.7) return x;
  double y = 0.7 + 0.3 * tanh((a - 0.7) / 0.3);
  return x < 0 ? -y : y;
}

// ---------- render ----------
static void write_wav(const char *path, const float *data, int frames) {
  FILE *f = fopen(path, "wb");
  int bytes = frames * 4;
  int32_t i32; int16_t i16;
  fwrite("RIFF", 1, 4, f); i32 = 36 + bytes; fwrite(&i32, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
  i32 = 16; fwrite(&i32, 4, 1, f); i16 = 1; fwrite(&i16, 2, 1, f); i16 = 2; fwrite(&i16, 2, 1, f);
  i32 = 44100; fwrite(&i32, 4, 1, f); i32 = 44100 * 4; fwrite(&i32, 4, 1, f); i16 = 4; fwrite(&i16, 2, 1, f); i16 = 16; fwrite(&i16, 2, 1, f);
  fwrite("data", 1, 4, f); i32 = bytes; fwrite(&i32, 4, 1, f);
  for (int i = 0; i < frames * 2; i++) { double x = data[i]; if (x > 1) x = 1; if (x < -1) x = -1; i16 = (int16_t)(x * 32767); fwrite(&i16, 2, 1, f); }
  fclose(f);
}

int main(int argc, char **argv) {
  double seconds = argc > 1 ? atof(argv[1]) : 20;
  const char *names[] = {"brown", "rain", "ocean", "fire", "pad"};
  void (*inits[])(void) = {brown_init, rain_init, ocean_init, fire_init, pad_init};
  Scape ticks[] = {brown_tick, rain_tick, ocean_tick, fire_tick, pad_tick};
  int frames = (int)(seconds * FS);
  float *buf = malloc(sizeof(float) * frames * 2);
  double gains[5] = {1, 1, 1, 1, 1};
  if (argc > 2) for (int i = 0; i < 5; i++) gains[i] = atof(argv[2 + i]);
  for (int s = 0; s < 5; s++) {
    memset(voices, 0, sizeof voices);
    inits[s]();
    Biquad dcL, dcR; memset(&dcL, 0, sizeof dcL); memset(&dcR, 0, sizeof dcR);
    bq_highpass(&dcL, 35, 0.707); bq_highpass(&dcR, 35, 0.707);
    double sum = 0, peak = 0;
    for (int i = 0; i < frames; i++) {
      double l, r; ticks[s](&l, &r);
      l = softclip(bq(&dcL, l) * gains[s]); r = softclip(bq(&dcR, r) * gains[s]);
      // Master: fade in over 1.5s like the app does.
      double g = i < 1.5 * FS ? i / (1.5 * FS) : 1;
      if (i > frames - FS) g *= (frames - i) / FS;
      l *= g; r *= g;
      buf[2 * i] = (float)l; buf[2 * i + 1] = (float)r;
      sum += l * l + r * r; if (fabs(l) > peak) peak = fabs(l); if (fabs(r) > peak) peak = fabs(r);
    }
    double rms = sqrt(sum / (2.0 * frames));
    printf("%-6s rms %.3f (%.1f dBFS) peak %.3f\n", names[s], rms, 20 * log10(rms), peak);
    char path[256]; snprintf(path, sizeof path, "%s.wav", names[s]);
    write_wav(path, buf, frames);
  }
  return 0;
}

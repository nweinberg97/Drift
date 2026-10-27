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


// ---------- shared note voices (keys, bells, bass) ----------
#define NN 32
typedef struct { double f, ph, mph, tph, amp, decay, idx, idxDecay, tIdx, tDecay, pan, att, attStep; int kind; } Note;
static Note notes[NN];
static void note_on(int kind, double f, double vel, double pan) {
  int slot = 0; double quiet = 1e9;
  for (int i = 0; i < NN; i++) { if (notes[i].amp < quiet) { quiet = notes[i].amp; slot = i; } }
  Note n; memset(&n, 0, sizeof n);
  n.kind = kind; n.f = f; n.amp = vel; n.pan = pan; n.att = 0;
  if (kind == 0) {        // electric piano (FM): warm body + short tine
    n.decay = exp(-1.0 / (1.7 * FS)); n.idx = 1.3; n.idxDecay = exp(-1.0 / (0.35 * FS));
    n.tIdx = 0.35; n.tDecay = exp(-1.0 / (0.04 * FS)); n.attStep = 1.0 / (0.004 * FS);
  } else if (kind == 1) { // bell / soft mallet
    n.decay = exp(-1.0 / (2.6 * FS)); n.attStep = 1.0 / (0.008 * FS);
  } else {                // bass
    n.decay = exp(-1.0 / (0.55 * FS)); n.attStep = 1.0 / (0.006 * FS);
  }
  notes[slot] = n;
}
static inline void notes_tick(double wow, double *l, double *r) {
  for (int i = 0; i < NN; i++) {
    Note *n = &notes[i];
    if (n->amp < 1e-5) continue;
    if (n->att < 1) { n->att += n->attStep; if (n->att > 1) n->att = 1; }
    double f = n->f * wow, s;
    if (n->kind == 0) {
      s = sin(n->ph + n->idx * sin(n->mph) + n->tIdx * sin(n->tph));
      n->mph += TAU * f / FS; n->tph += TAU * f * 14.0 / FS;
      n->idx *= n->idxDecay; n->tIdx *= n->tDecay;
    } else if (n->kind == 1) {
      s = sin(n->ph) + 0.28 * sin(2.0 * n->ph) * n->amp + 0.08 * sin(3.01 * n->ph) * n->amp;
    } else {
      s = sin(n->ph) + 0.18 * sin(2 * n->ph);
    }
    n->ph += TAU * f / FS;
    if (n->ph > 1e6) { n->ph = fmod(n->ph, TAU); n->mph = fmod(n->mph, TAU); n->tph = fmod(n->tph, TAU); }
    s *= n->amp * n->att;
    n->amp *= n->decay;
    *l += s * (1 - n->pan); *r += s * n->pan;
  }
}

// 6. Lo-fi: a slow, swung beat with jazzy electric-piano chords, bass and vinyl.
static const double lfChords[4][4] = {
  {174.61, 220.00, 261.63, 329.63}, // Fmaj7
  {164.81, 196.00, 246.94, 293.66}, // Em7
  {146.83, 174.61, 220.00, 261.63}, // Dm7
  {130.81, 164.81, 196.00, 246.94}, // Cmaj7
};
static const double lfBass[4] = {87.31, 82.41, 73.42, 65.41};
static double lfT, lfNext; static int lfStep;
static double kAmp, kPh, kF, sAmp, sPh, hAmp; static OnePole sHp, hHp, vHp; static Biquad lfLp[2]; static Reverb lfRv; static double lfWowPh; static Pink lfP;
static void lofi_init(void) {
  lfT = 0; lfNext = 0; lfStep = 0; kAmp = sAmp = hAmp = 0; kPh = sPh = 0; kF = 50; lfWowPh = 0;
  op_set(&sHp, 1200); op_set(&hHp, 7000); op_set(&vHp, 3000);
  bq_lowpass(&lfLp[0], 5200, 0.7); bq_lowpass(&lfLp[1], 5200, 0.7);
  rv_init(&lfRv, 0.76, 0.5); memset(notes, 0, sizeof notes);
}
static void lofi_step(int step) {
  int bar = (step / 16) % 4, k = step % 16;
  double hum = 0.9 + 0.2 * rnd01();
  if (k == 0 || k == 7 || k == 10) { kAmp = (k == 0 ? 0.42 : 0.28) * hum; kF = 115; }
  if (k == 4 || k == 12) sAmp = 0.30 * hum;
  if (k % 2 == 0) hAmp = (k % 4 == 0 ? 0.20 : 0.13) * hum;
  if (k == 15 && rnd01() < 0.5) hAmp = 0.06;
  if (k == 0 || k == 10) {
    double vel = (k == 0 ? 0.30 : 0.17) * hum;
    for (int v = 0; v < 4; v++) note_on(0, lfChords[bar][v], vel * (v == 0 ? 0.8 : 1.0), 0.2 + 0.2 * v);
  }
  if (k == 0 || k == 8) note_on(2, lfBass[bar], 0.17 * hum, 0.5);
  if (k == 14) note_on(2, lfBass[bar] * 1.5, 0.11 * hum, 0.5);
}
static void lofi_tick(double *l, double *r) {
  const double s16 = 60.0 / 74.0 / 4.0, swing = 0.6;
  lfT += 1.0 / FS;
  while (lfT >= lfNext) { lofi_step(lfStep); lfNext += s16 * 2 * (lfStep % 2 == 0 ? swing : 1 - swing); lfStep++; }
  lfWowPh += TAU * 0.45 / FS;
  double wow = 1 + 0.0025 * sin(lfWowPh);
  double nl = 0, nr = 0; notes_tick(wow, &nl, &nr);
  // drums
  double kick = sin(kPh) * kAmp; kPh += TAU * kF / FS; kF = 48 + (kF - 48) * 0.9993; kAmp *= exp(-1.0 / (0.22 * FS));
  double sn = (op_hp(&sHp, white()) * 0.7 + sin(sPh) * 0.4) * sAmp; sPh += TAU * 185 / FS; sAmp *= exp(-1.0 / (0.12 * FS));
  double hat = op_hp(&hHp, white()) * hAmp; hAmp *= exp(-1.0 / (0.028 * FS));
  double drums = kick + sn * 0.8;
  double L = nl + drums + hat * 0.45, R = nr + drums + hat * 1.0;
  double wl = rv_channel(&lfRv, 0, (nl + nr + sn) * 0.012), wr = rv_channel(&lfRv, 1, (nl + nr + sn) * 0.012);
  L = bq(&lfLp[0], L + wl); R = bq(&lfLp[1], R + wr);
  L = tanh(L * 1.4) / 1.4; R = tanh(R * 1.4) / 1.4;
  // vinyl: soft hiss and the odd pop
  double hiss = op_hp(&vHp, pink(&lfP)) * 0.018;
  double pop = rnd01() < 7.0 / FS ? (white() * 0.12) : 0;
  *l = L + hiss + pop; *r = R + hiss + pop;
}

// 7. Ambient: a slow drone with sparse, unhurried bell notes in a big room.
static const double amScale[10] = {293.66, 329.63, 369.99, 440.00, 493.88, 587.33, 659.25, 739.99, 880.00, 987.77};
static double amT, amNext, amEcho, amEchoF, drPh[2]; static Wander amW[2]; static Reverb amRv; static Biquad amLp[2];
static void ambient_init(void) {
  amT = 0; amNext = 1.0; amEcho = -1; drPh[0] = drPh[1] = 0;
  wander_init(&amW[0], 9); wander_init(&amW[1], 11.5);
  rv_init(&amRv, 0.90, 0.3); bq_lowpass(&amLp[0], 4000, 0.6); bq_lowpass(&amLp[1], 4000, 0.6);
  memset(notes, 0, sizeof notes);
}
static void ambient_tick(double *l, double *r) {
  amT += 1.0 / FS;
  if (amT >= amNext) {
    int i = (int)(rnd01() * 10);
    note_on(1, amScale[i], 0.22 + 0.12 * rnd01(), 0.15 + 0.7 * rnd01());
    if (rnd01() < 0.25) { amEcho = amT + 0.18 + 0.2 * rnd01(); amEchoF = amScale[(i + 2) % 10]; }
    amNext = amT + 0.9 + 2.6 * rnd01();
  }
  if (amEcho > 0 && amT >= amEcho) { note_on(1, amEchoF, 0.15, 0.15 + 0.7 * rnd01()); amEcho = -1; }
  double nl = 0, nr = 0; notes_tick(1.0, &nl, &nr);
  double d1 = sin(drPh[0]) * (0.018 + 0.018 * wander(&amW[0])), d2 = sin(drPh[1]) * (0.014 + 0.014 * wander(&amW[1]));
  drPh[0] += TAU * 73.42 / FS; drPh[1] += TAU * 110.0 / FS;
  if (drPh[0] > TAU) drPh[0] -= TAU; if (drPh[1] > TAU) drPh[1] -= TAU;
  double wl = rv_channel(&amRv, 0, (nl + nr) * 0.03), wr = rv_channel(&amRv, 1, (nl + nr) * 0.03);
  *l = bq(&amLp[0], nl * 0.6 + wl) + d1 + d2 * 0.6; *r = bq(&amLp[1], nr * 0.6 + wr) + d1 * 0.6 + d2;
}

// 8/9. Binaural beats: a slightly different tone in each ear, over a soft bed.
// Needs headphones. Focus = 15 Hz (beta), Calm = 10 Hz (alpha).
static double bbPh[2], bbBeat, bbCarrier; static Pink bbP[2]; static Biquad bbLp[2]; static Wander bbW;
static void binaural_setup(double carrier, double beat) {
  bbPh[0] = bbPh[1] = 0; bbCarrier = carrier; bbBeat = beat;
  bq_lowpass(&bbLp[0], 900, 0.6); bq_lowpass(&bbLp[1], 900, 0.6); wander_init(&bbW, 8);
}
static void bfocus_init(void) { binaural_setup(220, 15); }
static void bcalm_init(void) { binaural_setup(160, 10); }
static void binaural_tick(double *l, double *r) {
  double swell = 0.85 + 0.15 * wander(&bbW);
  bbPh[0] += TAU * bbCarrier / FS; bbPh[1] += TAU * (bbCarrier + bbBeat) / FS;
  if (bbPh[0] > TAU) bbPh[0] -= TAU; if (bbPh[1] > TAU) bbPh[1] -= TAU;
  double bedL = bq(&bbLp[0], pink(&bbP[0])) * 0.55, bedR = bq(&bbLp[1], pink(&bbP[1])) * 0.55;
  *l = sin(bbPh[0]) * 0.16 * swell + bedL; *r = sin(bbPh[1]) * 0.16 * swell + bedR;
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
  const char *names[] = {"brown", "rain", "ocean", "fire", "pad", "lofi", "ambient", "bfocus", "bcalm"};
  void (*inits[])(void) = {brown_init, rain_init, ocean_init, fire_init, pad_init, lofi_init, ambient_init, bfocus_init, bcalm_init};
  Scape ticks[] = {brown_tick, rain_tick, ocean_tick, fire_tick, pad_tick, lofi_tick, ambient_tick, binaural_tick, binaural_tick};
#define NSCAPE 9
  int frames = (int)(seconds * FS);
  float *buf = malloc(sizeof(float) * frames * 2);
  double gains[NSCAPE] = {1, 1, 1, 1, 1, 1, 1, 1, 1};
  for (int i = 0; i < NSCAPE && 2 + i < argc; i++) gains[i] = atof(argv[2 + i]);
  const char *only = getenv("ONLY");
  for (int s = 0; s < NSCAPE; s++) {
    if (only && !strstr(only, names[s])) continue;
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

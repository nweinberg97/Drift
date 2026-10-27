# Soundscape reference

`scapes.c` is the reference implementation of Drift's focus sounds. The Swift
`SoundGenerator` (Sources/Drift/Audio/FocusSound.swift) mirrors it line for
line, so you can tune a sound here, listen, then port the change.

```bash
cc -O2 -o scapes scapes.c -lm
./scapes 30 1.06 0.73 1.97 1.65 1.34 1.19 2.02 1.64 1.98   # seconds, then per-scape gains
# → brown rain ocean fire pad lofi ambient bfocus bcalm (.wav)
ONLY="lofi" ./scapes 30 ...   # render just some
```

The gains match perceived loudness across scapes (A-weighted, about −26 dB).
If you change a scape, re-measure and update `Soundscape.gain` in Swift.

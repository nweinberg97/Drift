# Soundscape reference

`scapes.c` is the reference implementation of Drift's focus sounds. The Swift
`SoundGenerator` (Sources/Drift/Audio/FocusSound.swift) mirrors it line for
line, so you can tune a sound here, listen, then port the change.

```bash
cc -O2 -o scapes scapes.c -lm
./scapes 30 1.06 0.73 1.97 1.65 1.34   # seconds, then per-scape gains
# → brown.wav rain.wav ocean.wav fire.wav pad.wav
```

The gains match perceived loudness across scapes (A-weighted, about −26 dB).
If you change a scape, re-measure and update `Soundscape.gain` in Swift.

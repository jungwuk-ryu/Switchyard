# ADR 0004: Rosetta AVX Advertising

## Status

Accepted.

## Context

Rosetta on macOS 15 and later can translate AVX and AVX2 instructions, but Apple's
Game Porting Toolkit keeps `ROSETTA_ADVERTISE_AVX` off by default. The variable
changes the CPUID capabilities reported to translated applications; it does not
add instruction support. Some Windows games refuse to start when AVX is hidden,
while other software can select a different optimized code path when it is
advertised.

Apple documents AVX and AVX2 translation as available under Rosetta and AVX512 as
unsupported. The behavior is an operating-system translation capability, not a
feature that differs between M-series CPU generations.

## Decision

Switchyard uses an automatic, per-container Rosetta AVX advertising policy:

| Host | macOS | Default |
| --- | --- | --- |
| Apple Silicon, including a translated Switchyard process | 15 or later | On |
| Apple Silicon | 14 | Off |
| Intel or an unknown CPU architecture | Any | Off |

A missing `ROSETTA_ADVERTISE_AVX` container override means automatic. Explicit
`1` keeps advertising enabled and explicit `0` keeps it disabled. Any other
stored value fails closed as disabled. The runner resolves the effective value
immediately before launching Wine so ambient shell variables cannot bypass the
platform gate or a user's explicit choice.

The preference is carried through direct launches, URL callbacks, and generated
desktop shortcuts. Existing route data without the preference remains compatible
and uses the automatic default.

AVX512 remains unadvertised and unsupported. Switchyard does not infer support
from an individual M-series model because Apple exposes the capability through
the macOS Rosetta implementation.

## Consequences

- Games that require an AVX CPUID bit can start without per-game setup on
  supported Macs.
- A game may choose a different AVX or AVX2 code path. Users retain a per-container
  off switch for regressions, performance changes, or application bugs.
- Steam and every child process in its container receive the same effective
  preference. A full Wine session restart is required for a changed preference
  to affect already-running processes.
- Existing containers with no explicit value change from Apple's GPTK default to
  Switchyard's supported-host default.
- macOS 14, Intel Macs, and unknown architectures receive an explicit off value,
  even if the parent process environment requests advertising.

## References

- [Apple: About the Rosetta translation environment](https://developer.apple.com/documentation/Apple-Silicon/about-the-rosetta-translation-environment)
- Apple Game Porting Toolkit 3 and 4 evaluation-environment Read Me files,
  “Environment Variables” and “Troubleshooting”

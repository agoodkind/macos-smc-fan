# Testing observations

This document captures currently observed integration test results across tested hardware. It is updated as new runs are recorded.

The hardware-specific expectations checked by the integration test target are encoded as plists under [`Tests/IntegrationTests/Fixtures`](../Tests/IntegrationTests/Fixtures), and consumed by [`HardwareExpectations.swift`](../Tests/IntegrationTests/HardwareExpectations.swift). Those fixtures encode typed expectations such as mode key casing, `Ftst` presence, fan count, and reported min/max. They are not a replacement for the observation tables below.

### Test Results

The following measurements were collected on M4 Max hardware (2 fans, reported min=2317, max=7826).

#### Command Timing

| Transition Type                | Command Time | Notes                                      |
| ------------------------------ | ------------ | ------------------------------------------ |
| Auto → Manual (first fan)      | ~5-6.5s      | Includes `Ftst=1` unlock + mode retry loop |
| Auto → Manual (subsequent fan) | ~20ms        | `Ftst` already set, just set mode          |
| Manual → Manual (RPM change)   | ~20ms        | No mode change needed                      |
| Manual → Auto (not last)       | ~20ms        | Just clear mode, keep `Ftst=1`             |
| Manual → Auto (last fan)       | ~20ms        | Triggers `Ftst=0` and daemon reclaim       |

#### RPM Ramp Timing

| RPM Delta   | Time to Stable | Notes                            |
| ----------- | -------------- | -------------------------------- |
| 0 → 5000    | ~4s            | Initial spin-up from stopped     |
| 5000 → 7000 | ~4s            | Within operating range           |
| 7000 → 0    | ~1s            | Spin-down is faster than spin-up |
| 8500 → 0    | ~1s            | High RPM to stop                 |

#### State Transition Table

Each row shows a tested transition with measured results.

**Legend:** `F0`/`F1` = Fan 0/1, `A` = Auto, `M` = Manual, `@RPM` = actual RPM

| From State             | Action      | To State               | Cmd (ms) | Stable (ms) | Side Effects            |
| ---------------------- | ----------- | ---------------------- | -------- | ----------- | ----------------------- |
| F0: A@0, F1: A@0       | set 0 5000  | F0: M@5000, F1: A@2500 | 5252     | 8000        | F1 wakes to auto min    |
| F0: M@5000, F1: A@2500 | set 0 7000  | F0: M@7000, F1: A@2500 | 22       | 4500        | -                       |
| F0: M@7000, F1: A@2500 | auto 0      | F0: A@0, F1: A@0       | 25       | 4500        | System mode restored    |
| F0: A@0, F1: A@0       | set 0 10000 | F0: M@8560, F1: A@2500 | 5085     | 8000        | Clamped at hw max ~8560 |
| F0: M@8560, F1: A@2500 | set 0 0     | F0: M@0, F1: A@2500    | 22       | 1000        | Fan stops completely    |
| F0: A@0, F1: A@0       | set 0 1000  | F0: M@1000, F1: A@2500 | 6657     | 9000        | Below "min" works       |
| F0: M@1000, F1: A@2500 | set 1 6000  | F0: M@1000, F1: M@6000 | 21       | 5000        | Both fans independent   |

#### State Diagram

```text
                              ┌─────────────────────────────────┐
                              │         SYSTEM IDLE             │
                              │   F0: Auto @ 0, F1: Auto @ 0    │
                              │   Ftst=0, thermalmonitord ctrl  │
                              └─────────────┬───────────────────┘
                                            │
                          set fan N to RPM  │  (~5-6s unlock)
                                            ▼
                              ┌─────────────────────────────────┐
                              │       DIAGNOSTIC MODE           │
                              │   Ftst=1, partial manual ctrl   │
                              │   Other fans wake to auto min   │
                              └─────────────┬───────────────────┘
                                            │
              ┌─────────────────────────────┼─────────────────────────────┐
              │                             │                             │
              ▼                             ▼                             ▼
    ┌─────────────────┐         ┌─────────────────────┐       ┌─────────────────┐
    │  ONE FAN MANUAL │         │  BOTH FANS MANUAL   │       │   RPM CHANGE    │
    │  F0: M, F1: A   │◀───────▶│  F0: M, F1: M       │──────▶│   (~20ms cmd)   │
    │  (~2500 auto)   │ set 1   │  Independent ctrl   │       │   ~4s to stable │
    └────────┬────────┘         └──────────┬──────────┘       └─────────────────┘
             │                             │
             │ auto 0 (last)               │ auto N (not last)
             │ (~20ms + 4-5s reclaim)      │ (~20ms)
             ▼                             ▼
    ┌─────────────────┐         ┌─────────────────────┐
    │  SYSTEM IDLE    │         │  PARTIAL AUTO       │
    │  Ftst=0         │◀────────│  Ftst=1 maintained  │
    │  F0: A@0, F1:A@0│         │  Other fan: Manual  │
    └─────────────────┘         └─────────────────────┘
```

#### Edge Case Behavior

| Hardware | Requested | Reported Limits | Actual Result | Notes                                            |
| -------- | --------- | --------------- | ------------- | ------------------------------------------------ |
| M4 Max   | 0 RPM     | min=2317        | 0 RPM         | Fan stops completely                             |
| M4 Max   | 1000 RPM  | min=2317        | ~1000 RPM     | Below "min" works                                |
| M4 Max   | 10000 RPM | max=7826        | ~8560 RPM     | Hardware spins above reported max                |
| M5 Max   | 0 RPM     | min=2317        | 2317 RPM      | Firmware clamps below-min up to min              |
| M5 Max   | 1000 RPM  | min=2317        | 2317 RPM      | Firmware clamps below-min up to min              |
| M5 Max   | 10000 RPM | max=7826        | ~9600 RPM     | Target stays at 10000, fan spins to physical max |

**Key Observations:**

- The reported min/max values are thermal management thresholds, not hardware limits.
- On M4 Max, hardware can exceed reported max (~8560 actual vs 7826 reported) and can go below reported min (1000 actual vs 2317 reported).
- On M5 Max, hardware can exceed reported max (target 10000 accepted, fan spins to ~9600 RPM). Below-min targets are clamped up to the reported min.
- Setting 0 RPM in manual mode stops the fan completely on M4 Max. On M5 Max the firmware clamps the target to the reported min instead.

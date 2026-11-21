# Meterbar

A lightweight macOS menu bar system monitor: CPU, GPU, memory, disk, network, sensors and battery.
It's a single Swift file built on AppKit and Core Graphics, with no SwiftUI and no dependencies.

The layout of the menu bar widgets and popups is inspired by [Stats](https://github.com/exelban/stats).
Meterbar is an independent project and is not affiliated with Stats.

## Download

Get **Meterbar.zip** from the [latest release](https://github.com/ShivamHimatsingka/Meterbar/releases/latest), unzip it, and move `Meterbar.app` to `/Applications`.

The app is a universal build (Apple Silicon and Intel) for macOS 13 or later. It's ad-hoc signed but not notarized by Apple, so the first time you open it macOS will say it can't verify the developer. To open it anyway, do one of these:
- **Settings:** open it once, then go to System Settings → Privacy & Security and click **Open Anyway**.
- **Terminal:** run `xattr -dr com.apple.quarantine /Applications/Meterbar.app`.

You can also build it yourself from source (see [Build](#build)).

## Modules

| Module | Menu bar widgets | Popup |
|---|---|---|
| **CPU** | mini, line chart, per-core bars, pie | usage donut, temperature, load, stacked system/user history, efficiency/performance core usage, per-core bars, uptime, top processes |
| **GPU** | mini, line chart, bar, pie | utilization, renderer/tiler, memory in use, temperature, history |
| **Memory** | mini, line chart, bar, pie | app/wired/compressed/free, cached files, swap, memory pressure, history, top processes |
| **Disk** | mini, read/write speed, bar, pie | used/free space, read/write speed and totals |
| **Network** | upload/download speed, line chart | speeds, interface, local IP, totals |
| **Sensors** | CPU + GPU temperature, CPU temperature + power, mini, line chart | CPU/GPU average and hottest, efficiency and performance clusters, memory, SSD, battery, Wi‑Fi, palm rest, fans, system power |
| **Battery** | battery + %, icon, mini | level, health, cycles, temperature, voltage, current, power, adapter, time remaining |

Settings let you turn modules on and off, pick each widget's style, set the update interval and turn on launch at login.

## Resource use

Measured on a MacBook Air (Apple M5) running macOS 26, with the CPU, GPU, RAM and Sensors modules updating every second, over two minutes at idle:

| | Meterbar | Stats |
|---|---|---|
| CPU | ~0.3% | ~2.5% |
| Memory | ~12 MB | ~138 MB |
| Threads | 4 | 12 |

With a popup open, memory is about 20–31 MB.

How it stays light:
- **Drawing:** widgets are drawn directly with Core Graphics, and only redrawn when the displayed value changes.
- **Hidden items:** items hidden behind the notch aren't drawn at all.
- **Popups:** created on demand, painted on the CPU into a bitmap, and released when closed.
- **Sensors:** read every 2 s, from a small subset unless the Sensors popup is open.
- **Slow-changing values:** battery and disk are polled less often.
- **Sleep and lock:** sampling pauses while the display is asleep or the session is locked.

## Data sources

- **CPU:** `host_processor_info`, with efficiency and performance cores identified from the IORegistry device tree.
- **GPU:** `IOAccelerator` `PerformanceStatistics`.
- **Memory:** `host_statistics64`, using the same "Memory Used" formula as Activity Monitor (app + wired + compressed).
- **Disk:** `IOBlockStorageDriver` statistics, plus volume capacity.
- **Network:** 64-bit interface counters (`NET_RT_IFLIST2`).
- **Sensors:** SMC keys, discovered at launch:
  - `Te*` efficiency cluster, `Tp*` performance cluster, `Tg*` GPU
  - memory, SSD, battery, Wi‑Fi, palm rest
  - `PSTR`/`PPBR` power, and fans.
  
  Each cluster has several thermal sensors, so there are more sensors than cores.
- **Battery:** IOPowerSources and `AppleSmartBattery`.
- **Top processes:** `/usr/bin/top`, run only while the CPU or Memory popup is open. macOS doesn't let normal apps read CPU usage of system processes such as WindowServer; `top` is setuid root.

## Build

You need Xcode or the Command Line Tools. `build.sh` produces a universal app (Apple Silicon + Intel) that runs on macOS 13 or later. Sensors were developed on Apple Silicon; Intel Macs are untested.

```bash
./build.sh
open Meterbar.app
```

To install, copy `Meterbar.app` to `/Applications`.

Developer flags:
- `--dump` prints every reading once and exits.
- `--dump --render <dir>` also saves each popup as a PNG.
- `--open <cpu|gpu|ram|disk|sensors|net|battery>` opens that popup on launch.

## Tips

- **Reordering:** ⌘-drag menu bar items to reorder them.
- **Notch:** on MacBooks with a notch, macOS hides items that don't fit beside it. Turn off modules you don't need, or hide unused system items in System Settings → Menu Bar.
- **NotchOverflow:** Meterbar supports the NotchOverflow app. It can show hidden Meterbar items and open their popups.

## License

[MIT](LICENSE) © 2026 Shivam Himatsingka.

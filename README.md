# AirClicker

**Turn an AirPod into a presentation clicker.** Hold one AirPod and flick your wrist: right for the next slide, left to go back.

<p align="center"><img src="docs/demo.gif" width="400" alt="Flicking an AirPod changes the slide on a MacBook"></p>

AirClicker is a tiny macOS menu bar app. It reads the motion sensors in your AirPods, spots a quick wrist flick, and presses the arrow key for you, so it works with Keynote, PowerPoint, Google Slides, PDFs, or any deck that moves with the arrow keys. No extra hardware, no phone app.

It started as a 15 minute build with [Claude Code](https://claude.com/claude-code) on the morning of a presentation, and was then tuned on 159 logged test flicks.

## Requirements

- macOS 14 or later
- AirPods with motion sensors (the ones that support head tracking: AirPods Pro, AirPods 3rd gen or later, AirPods Max)
- Xcode Command Line Tools for `swiftc` (`xcode-select --install`)

## Install

```sh
git clone https://github.com/Harelzx/airclicker.git
cd airclicker
./build.sh
open build/AirClicker.app
```

The first time it runs, macOS asks for two permissions:

1. **Motion & Fitness**, to read the AirPods sensors. Click Allow.
2. **Accessibility**, to press the arrow keys. Choose *Grant Accessibility permission…* in the menu, then turn AirClicker on in System Settings → Privacy & Security → Accessibility.

## Use it

1. Connect your AirPods to the Mac.
2. Click the AirPod icon in the menu bar and turn on **Presentation mode**. The menu should show *Motion sensors: receiving ●*.
3. Take one AirPod out, hold it between your fingers, and open your slides.
4. **Flick right → next slide. Flick left → previous slide.** A quick, wide flick, like turning a key.

Want to try it before your real talk? Open [`demo/index.html`](demo/index.html) in a browser and flick through the demo deck from the video.

### Menu options

| Option | What it does |
|---|---|
| Presentation mode | Turns listening on or off |
| Sensitivity | Low for very sharp flicks only, High for lighter flicks |
| Reverse direction | Swaps next and back |
| Test: send Next in 3 seconds | Checks the key press works without the AirPods |

### Tips

- Flick from the wrist, quick and wide. A slow turn is ignored on purpose, so normal hand movement while you talk never changes a slide.
- Right flicks are often weaker than left ones. If they get missed, set Sensitivity to High, or turn on **Reverse direction** so your stronger flick moves forward.
- Wait for the slide to change before the next flick: the swing back to center is ignored for about half a second.

## Privacy

AirClicker has no network code. Motion data stays on your Mac and is used only to detect flicks; the only thing it writes is a local log of flick timings in `~/Library/Logs/AirClicker.log`.

## How it works

- `CMHeadphoneMotionManager` streams the AirPod's gyroscope and gravity at about 50 Hz.
- The rotation is projected onto gravity, so only the turn around the vertical axis counts. It doesn't matter how you hold the AirPod.
- A turn is a flick only when it is **fast** (above ~370°/s for two samples in a row), **wide** (past 75°) and **mostly horizontal** (twisting or lifting your hand is ignored).
- The swing back to center right after a flick is ignored, and so is the small pull back people make before flicking the other way.
- A flick posts a Right or Left Arrow key event with `CGEvent`.
- A silent audio loop keeps the AirPods connection, and the motion stream, alive while the AirPod is out of your ear.

All of it is one Swift file: [`Sources/AirClicker/main.swift`](Sources/AirClicker/main.swift).

## Troubleshooting

- **"Motion sensors: no data"**: make sure the AirPods are the Mac's current audio output, then toggle Presentation mode off and on.
- **Slides don't move**: the presentation app has to be the active window. Click on it once. Also check the Accessibility permission.
- **Asked for Accessibility again after rebuilding**: the default build is signed ad hoc, so macOS treats each build as a new app. Remove the old entry in Accessibility and add the new one, or sign with your own Apple Development identity (see the top of `build.sh`).
- **Flicks are missed or too eager**: change Sensitivity. Every flick is logged with its speed and angle in `~/Library/Logs/AirClicker.log`, which helps when tuning.

## License

MIT. See [LICENSE](LICENSE).

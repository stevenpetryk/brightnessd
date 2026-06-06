# brightnessd

Routes the native macOS brightness keys to DDC-capable external monitors,
with a native-style HUD, a menubar slider, and an adjustable perceptual
brightness curve.

macOS only adjusts the built-in display (or Apple displays) with the
brightness keys. brightnessd fills the gap: when the mouse cursor is on an
external display, the brightness keys are intercepted and turned into DDC
luminance writes for that display; otherwise they pass through untouched.
Each display's luminance range is read from the monitor itself — real nits
on HDR panels like an ASUS PA32QCV (0–400), 0–100 on most monitors.

Brightness is mapped through `value = max × position^γ`. γ is selectable
from the menubar (persisted); values below 1 give more usable steps on
panels whose luminance control already feels perceptually compressed.
Shift+Option+brightness keys = quarter steps.

DDC is handled by a vendored [m1ddc](https://github.com/waydabber/m1ddc)
with fixes not yet upstream: 16-bit VCP value handling and reply checksum
validation with retries (without these, panels like the PA32QCV return
garbage values).

## Requirements

- Apple Silicon Mac (an m1ddc limitation)
- A Swift compiler. Any Xcode/CLT install provides one. With nix:
  `make SWIFTC="$(nix build nixpkgs#swift --no-link --print-out-paths | grep -v -- -man)/bin/swiftc"`

## Setup

```sh
git clone --recurse-submodules https://github.com/stevenpetryk/brightnessd
cd brightnessd
make install   # builds m1ddc + brightnessd, installs & loads a LaunchAgent
```

On first launch macOS will prompt for Accessibility permission (needed for
the key event tap). Grant it in System Settings → Privacy & Security →
Accessibility, then the agent's next automatic restart picks it up.

`make uninstall` removes the LaunchAgent. To run in the foreground instead,
just `make && ./brightnessd`.

## Notes

- Displays that don't answer DDC (projectors, some docks/KVMs that eat the
  DDC lines) are detected and skipped; the keys pass through to macOS.
- External changes (monitor OSD, manual `m1ddc`) aren't observed; the next
  keypress snaps back to brightnessd's last value.

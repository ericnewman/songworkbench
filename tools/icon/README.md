# App icon

`songworkbench-icon.svg` is the source of the macOS app icon in
`Resources/Assets.xcassets/AppIcon.appiconset`, drawn to the Endogen per-app icon rule:
Scope `#070A0E` ground, one P31 Phosphor trace, one Contact Amber contact. The trace is
a dense mixed recording that resolves into one clean decaying wave (the app decoding a
song); the contact marks where it resolves.

Regenerate the PNGs after editing the SVG:

```bash
qlmanage -t -s 1024 -o /tmp tools/icon/songworkbench-icon.svg
```

Then resize `/tmp/songworkbench-icon.svg.png` with `sips -z <px> <px>` into each
`icon_<size>.png` the asset catalog lists.

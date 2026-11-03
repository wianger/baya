# Baya artwork

The mark is a baya weaver's nest: a straw chamber hanging from a branch, two
strands wound across it, the entrance tube below. Graphite `#131315`, branch
`#EDE6D8`, straw `#F8DE97` → `#DC9A3A`.

Everything comes from one geometry in `generate.py`. Run it from the
repository root after any change:

```sh
python branding/generate.py
```

It writes:

- `baya-mark.svg`, the mark on its graphite tile;
- `baya-foreground.svg` and `baya-monochrome.svg`, the Android adaptive and
  themed-icon layers;
- `banner.svg`, the repository and social banner;
- the Android vector drawables `ic_launcher_foreground`,
  `ic_launcher_monochrome` and `baya_icon_background`.

The Flutter `AppMarkPainter` (`app/lib/ui/core/branding/app_brand.dart`)
draws the same paths.

`banner.png` is `banner.svg` rendered at 1280×640 with the bundled Geist font
(`app/assets/fonts/Geist`), for example with resvg.

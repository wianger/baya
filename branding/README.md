# Baya artwork

The mark is a perched baya weaver, drawn the way DeepSeek draws its whale:
one flat silhouette in a single colour, a few large rounded curves, the
wing and eye cut out, a slight lean forward, and one playful detail — the
weaver's curled crest. It is black and white only: white on a black tile
for the launcher, and in the app the bird takes the text colour, so it
reads in both themes.

Everything comes from one geometry in `generate.py`. Run it from the
repository root after any change:

```sh
python branding/generate.py
```

It writes:

- `baya-mark.svg`, the mark on its grey tile;
- `baya-foreground.svg` and `baya-monochrome.svg`, the Android adaptive and
  themed-icon layers;
- `banner.svg`, the repository and social banner;
- the Android vector drawables `ic_launcher_foreground`,
  `ic_launcher_monochrome` and `baya_icon_background`, and the
  notification icon `ic_stat_baya`;
- `app/lib/ui/core/branding/mark_geometry.g.dart`, the paths the app's
  `AppMarkPainter` draws.

`banner.png` is `banner.svg` rendered at 1280×640 with the bundled Inter
font (`app/assets/fonts`), for example with resvg
(`resvg --use-fonts-dir app/assets/fonts/Inter -w 1280 branding/banner.svg
branding/banner.png`).

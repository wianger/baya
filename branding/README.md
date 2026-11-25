# Baya artwork

The mark is a perched baya weaver, drawn the way magpie draws its icon: one
ink silhouette, with white cut in for the pale breast,
wing and tail feathers, and the crown of a breeding male, all in white: the mark
is black and white only. In the app the bird takes the text colour and
its cut-outs the page colour, so it reads in both themes.

Everything comes from one geometry in `generate.py`. Run it from the
repository root after any change:

```sh
python branding/generate.py
```

It writes:

- `baya-mark.svg`, the mark (never on a tile; the launcher background is plain white);
- `baya-foreground.svg` and `baya-monochrome.svg`, the Android adaptive and
  themed-icon layers;
- `banner.svg`, the repository and social banner;
- the Android vector drawables `ic_launcher_foreground`,
  `ic_launcher_monochrome` and `baya_icon_background`, and the
  notification icon `ic_stat_baya`;
- `app/lib/ui/core/branding/mark_geometry.g.dart`, the paths the app's
  `AppMarkPainter` draws.

`banner.png` is `banner.svg` rendered at 1280×640 with the bundled Pinyon
Script and Inter fonts (`app/assets/fonts`), for example with resvg
(`resvg --use-fonts-dir app/assets/fonts/Inter --use-fonts-dir
app/assets/fonts/PinyonScript -w 1280 branding/banner.svg branding/banner.png`).

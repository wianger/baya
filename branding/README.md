# Baya artwork

The mark is a perched baya weaver, drawn the way magpie draws its icon: one
ink silhouette on a soft grey tile, with white cut in for the pale breast,
wing and tail feathers, and the one colour of the mark: the golden crown of
a breeding male, the same gold as the app's accent. In the app the bird
takes the text colour, so it reads in both themes; the crown stays gold.

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

`banner.png` is `banner.svg` rendered at 1280×640 with the bundled Pinyon
Script and Geist fonts (`app/assets/fonts`), for example with resvg
(`resvg --use-fonts-dir app/assets/fonts/Geist --use-fonts-dir
app/assets/fonts/PinyonScript -w 1280 branding/banner.svg branding/banner.png`).

# Baya artwork

The mark is a baya weaver in flight: one ink silhouette (`#141416`) on a
light tile (`#F3F1EC`), the wing and its feathers set apart by thin cuts. In
the app the bird takes the text colour, so it reads in both themes.

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
  `ic_launcher_monochrome` and `baya_icon_background`;
- `app/lib/ui/core/branding/mark_geometry.g.dart`, the paths the app's
  `AppMarkPainter` draws.

`banner.png` is `banner.svg` rendered at 1280×640 with the bundled Pinyon
Script and Geist fonts (`app/assets/fonts`), for example with resvg.

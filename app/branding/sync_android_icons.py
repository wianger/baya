"""Export Android vectors, SVG layers and density PNGs from baya-mark.svg.

The launcher background uses the same softly lit ivory gradient as the source
tile, while the bird keeps its filled silhouette and negative-space wing. Only
Python's standard library is required for the vectors; density PNGs are
rendered with `resvg` when it is on PATH.
"""
from copy import deepcopy
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
ANDROID_RES = ROOT.parent / 'android/app/src/main/res'
RES = ANDROID_RES / 'drawable'
SVG = 'http://www.w3.org/2000/svg'
ANDROID = 'http://schemas.android.com/apk/res/android'
AAPT = 'http://schemas.android.com/aapt'
ET.register_namespace('', SVG)
ET.register_namespace('android', ANDROID)
ET.register_namespace('aapt', AAPT)
source = ET.parse(ROOT / 'baya-mark.svg').getroot()
defs = source.find('{%s}defs' % SVG)
bird = source.find("{%s}g[@id='baya-bird']" % SVG)
gradients = {
    item.attrib['id']: item
    for item in defs
    if item.tag.endswith('linearGradient')
}

# Launcher icons are 108dp; each density maps 1dp to <ratio> pixels.
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
STYLE_INHERIT = (
    'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin',
    'fill', 'fill-rule', 'stroke-opacity',
)


def color(value, opacity=1):
    digits = value.removeprefix('#')
    if len(digits) == 3:
        digits = ''.join(char * 2 for char in digits)
    return '#%02X%s' % (round(float(opacity) * 255), digits.upper())


def paint(path, attribute, value):
    if value.startswith('url(#'):
        gradient = gradients[value[5:-1]]
        holder = ET.SubElement(
            path, '{%s}attr' % AAPT, {'name': 'android:%s' % attribute})
        shader = ET.SubElement(holder, 'gradient', {
            '{%s}type' % ANDROID: 'linear',
            **{
                '{%s}%s' % (ANDROID, target): gradient.attrib[key]
                for key, target in
                [('x1', 'startX'), ('y1', 'startY'), ('x2', 'endX'), ('y2', 'endY')]
            },
        })
        for stop in gradient:
            ET.SubElement(shader, 'item', {
                '{%s}offset' % ANDROID: stop.get('offset', '0'),
                '{%s}color' % ANDROID: color(
                    stop.get('stop-color'), stop.get('stop-opacity', '1')),
            })
    else:
        path.set(
            '{%s}%s' % (ANDROID, attribute),
            '@android:color/transparent' if value == 'none' else color(value))


def apply_style(path, element):
    for key, target in [('fill', 'fillColor'), ('stroke', 'strokeColor')]:
        if key in element.attrib:
            paint(path, target, element.attrib[key])
    for key, target in [
        ('fill-rule', 'fillType'), ('stroke-width', 'strokeWidth'),
        ('stroke-linecap', 'strokeLineCap'), ('stroke-linejoin', 'strokeLineJoin'),
        ('stroke-opacity', 'strokeAlpha'),
    ]:
        if key in element.attrib:
            path.set('{%s}%s' % (ANDROID, target),
                     element.attrib[key].replace('evenodd', 'evenOdd'))
    if 'opacity' in element.attrib:
        path.set('{%s}fillAlpha' % ANDROID, element.attrib['opacity'])


def circle_to_vector(parent, element):
    cx, cy, radius = (float(element.attrib[key]) for key in ('cx', 'cy', 'r'))
    # Android vectors have no <circle>; approximate with two half arcs.
    arc = 'a%s %s 0 1 0' % (radius, radius)
    path = ET.SubElement(parent, 'path', {
        '{%s}pathData' % ANDROID:
            'M%s %s%s %s 0%s %s 0Z' % (
                cx - radius, cy, arc, radius * 2, arc, -radius * 2),
    })
    apply_style(path, element)


def element_to_vector(parent, element):
    if element.tag.endswith('g'):
        # Android vectors have no cascading styles, so push the group's style
        # down onto each child.
        inherited = {
            key: element.attrib[key] for key in STYLE_INHERIT if key in element.attrib}
        for child in element:
            merged = dict(inherited)
            merged.update(child.attrib)
            element_to_vector(parent, ET.Element(child.tag, merged))
        return
    if element.tag.endswith('circle'):
        circle_to_vector(parent, element)
        return
    path = ET.SubElement(
        parent, 'path', {'{%s}pathData' % ANDROID: element.attrib['d']})
    apply_style(path, element)


def vector():
    return ET.Element('vector', {
        '{%s}width' % ANDROID: '108dp',
        '{%s}height' % ANDROID: '108dp',
        '{%s}viewportWidth' % ANDROID: '108',
        '{%s}viewportHeight' % ANDROID: '108',
    })


def safe_group(parent, svg=False):
    if svg:
        return ET.SubElement(
            parent, '{%s}g' % SVG, {'transform': 'translate(11.88 11.88) scale(.78)'})
    return ET.SubElement(parent, 'group', {
        '{%s}pivotX' % ANDROID: '54',
        '{%s}pivotY' % ANDROID: '54',
        '{%s}scaleX' % ANDROID: '.78',
        '{%s}scaleY' % ANDROID: '.78',
    })


def write(root, target):
    ET.indent(root, space='  ')
    ET.ElementTree(root).write(target, encoding='utf-8', xml_declaration=True)


def render(svg_path, width, target):
    resvg = shutil.which('resvg')
    if resvg is None:
        raise SystemExit('resvg is required to render the density PNGs.')
    subprocess.run(
        [resvg, '--width', str(width), '--height', str(width), str(svg_path), str(target)],
        check=True)


foreground = vector()
group = safe_group(foreground)
for element in bird:
    element_to_vector(group, element)
write(foreground, RES / 'ic_launcher_foreground.xml')

# Android applies its own launcher mask, so the exported background is a
# full-bleed square using the source tile gradient; the in-app tile keeps its
# rounded rim.
background = vector()
element_to_vector(
    background, ET.Element('path', {'d': 'M0 0H108V108H0Z', 'fill': 'url(#tile)'}))
write(background, RES / 'baya_icon_background.xml')

svg = ET.Element('{%s}svg' % SVG, {'viewBox': '0 0 108 108'})
svg.append(deepcopy(defs))
safe_group(svg, svg=True).append(deepcopy(bird))
write(svg, ROOT / 'baya-foreground.svg')

# The monochrome layer is tinted by Android, so it is exported all-white.
mono_paths = []
for element in bird:
    if element.tag.endswith('g'):
        for child in element:
            attrs = {
                key: child.attrib[key]
                for key in ('d', 'cx', 'cy', 'r') if key in child.attrib}
            if child.tag.endswith('circle'):
                attrs['fill'] = '#FFFFFF'
            else:
                attrs['fill'] = 'none'
                attrs['stroke'] = '#FFFFFF'
                attrs['stroke-width'] = child.attrib.get('stroke-width', '3')
                attrs['stroke-linecap'] = 'round'
                attrs['stroke-linejoin'] = 'round'
            mono_paths.append(ET.Element(child.tag, attrs))
    elif element.tag.endswith('circle'):
        attrs = {key: element.attrib[key] for key in ('cx', 'cy', 'r')}
        attrs['fill'] = '#FFFFFF'
        mono_paths.append(ET.Element(element.tag, attrs))
    else:
        attrs = {'d': element.attrib['d'], 'fill': '#FFFFFF'}
        mono_paths.append(ET.Element(element.tag, attrs))

mono_svg = ET.Element('{%s}svg' % SVG, {'viewBox': '0 0 108 108'})
mono_group = safe_group(mono_svg, svg=True)
mono = vector()
mono_vector_group = safe_group(mono)
for element in mono_paths:
    mono_group.append(deepcopy(element))
    element_to_vector(mono_vector_group, element)
write(mono_svg, ROOT / 'baya-monochrome.svg')
write(mono, RES / 'ic_launcher_monochrome.xml')

for density, ratio in DENSITIES.items():
    size = round(108 * ratio)
    target_dir = ANDROID_RES / ('mipmap-%s' % density)
    target_dir.mkdir(parents=True, exist_ok=True)
    render(ROOT / 'baya-foreground.svg', size, target_dir / 'ic_launcher_foreground.png')
    render(ROOT / 'baya-monochrome.svg', size, target_dir / 'ic_launcher_monochrome.png')

print('Exported Android vectors, SVG layers and density PNGs.')

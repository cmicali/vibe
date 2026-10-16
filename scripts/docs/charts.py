"""The SVG charts and tables in docs/performance.md and docs/audio-quality.md.

Hand-written SVG, no plotting dependency. One file per chart. Light and dark
come from the SVG's own media query, so one file serves both themes.

Every chart is a card: a title, a subtitle that says which way is better, then
the plot. A legend lists the series in the order given. Pass the same order
everywhere and the same color for the same thing, and the pages stay consistent.

Tables color each cell's background against the others it is compared with:
the best green, the worst red, the rest in between. The best is also bold, so
the color is never the only cue.
"""
import html
import math

FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"

# The reference categorical palette, (light, dark), in its fixed order.
SLOTS = [('#2a78d6', '#3987e5'), ('#eb6834', '#d95926'), ('#1baf7a', '#199e70'), ('#eda100', '#c98500'),
         ('#e87ba4', '#d55181'), ('#008300', '#008300'), ('#6250d6', '#9085e9'), ('#e34948', '#e66767')]
GRAY = ('#a8a7a1', '#6e6d68')
INK = {  # class: (light, dark), as fill for text and shapes
    'bg': ('#fcfcfb', '#1a1a19'),
    't': ('#0b0b0b', '#f0efec'),
    'm': ('#52514e', '#c3c2b7'),
    'q': ('#898781', '#898781'),
    'box': ('#f0efec', '#262624'),
}
RULES = {  # class: (light, dark), as stroke
    'g': ('#e1e0d9', '#2c2c2a'),
    'a': ('#c3c2b7', '#383835'),
    'k': ('#b9b8b2', '#55554f'),
}
GOOD, BAD = '#0ca30c', '#d03b3b'
STEPS = 4
# Each step's opacity over the surface, light and dark: a wash, never a block.
ALPHA = ([0.07, 0.13, 0.2, 0.28], [0.12, 0.19, 0.27, 0.36])

GLYPH = {}
for chars, w in (('il.,:;!|\'’ ', 0.27), ('frtjI()[]/-–', 0.35), ('abcdeghknopqsuvxyz', 0.52),
                 ('0123456789$#?→±×−', 0.58), ('ABCDEFGHJKLNOPQRSTUVXYZ%&', 0.66), ('mwMW@', 0.82)):
    for ch in chars:
        GLYPH[ch] = w


def text_width(s, size):
    return sum(GLYPH.get(ch, 0.58) for ch in s) * size


def esc(s):
    return html.escape(str(s), quote=True)


def blend(color, alpha, surface):
    a = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(surface[i:i + 2], 16) for i in (1, 3, 5)]
    return '#' + ''.join(f'{round(x * alpha + y * (1 - alpha)):02x}' for x, y in zip(a, b))


def color(key):
    """A series color: a slot index, or 'gray' for context the chart is not about."""
    return GRAY if key == 'gray' else SLOTS[key]


def nice_axis(hi, lo=0.0, max_ticks=6):
    """(lo, hi, step): round ticks, 1/2/2.5/5 × 10^n, covering lo..hi with headroom."""
    span = hi - lo
    if span <= 0:
        return lo, lo + 1, 0.25
    for m in range(-4, 8):
        for s in (1, 2, 2.5, 5):
            step = s * 10 ** m
            a = math.floor(lo / step + 1e-9) * step
            b = math.ceil((hi + span * 0.05) / step - 1e-9) * step
            if round((b - a) / step) <= max_ticks:
                return a, b, step
    return lo, hi, span


def tick_decimals(step):
    for decimals in range(5):
        if abs(round(step, decimals) - step) < 1e-9:
            return decimals
    return 4


def wrap(s, width, size):
    lines, line = [], ''
    for word in s.split(' '):
        trial = f'{line} {word}'.strip()
        if line and text_width(trial, size) > width:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line] if line else lines


class Card:
    """One SVG: a rounded card with a title and subtitle, and the plot below."""

    def __init__(self, width, title, subtitle=None):
        self.w = width
        self.title = title
        self.parts = []
        self.series = set()
        self.tints = False
        self.text(24, 32, title, size=15, weight=600)
        y = 32
        for line in wrap(subtitle or '', width - 48, 12):
            y += 18
            self.text(24, y, line, cls='m', size=12)
        self.y = y + 14

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, cls='t', size=12, anchor='start', weight=None, tip=None):
        w = f' font-weight="{weight}"' if weight else ''
        tip = f'<title>{esc(tip)}</title>' if tip else ''
        self.add(f'<text class="{cls}" x="{x:.1f}" y="{y:.1f}" font-size="{size}" text-anchor="{anchor}"{w}>'
                 f'{tip}{esc(s)}</text>')

    def rule(self, x1, y1, x2, y2, cls='g', width=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ''
        self.add(f'<line class="{cls}" x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke-width="{width}"{d}/>')

    def swatch_class(self, key):
        self.series.add(key)
        return 'sg' if key == 'gray' else f's{key}'

    def legend(self, items, x=24):
        """One row of keys, wrapped to the card: (label, color key) or
        (label, color key, value), the value in lighter ink after the label."""
        y = self.y + 4
        for label, key, *value in items:
            value = value[0] if value else ''
            w = 22 + text_width(label, 12) + (text_width(value, 12) + 6 if value else 0) + 20
            if x + w > self.w - 24 and x > 24:
                x, y = 24, y + 20
            self.add(f'<rect class="{self.swatch_class(key)}" x="{x}" y="{y - 5:.1f}" width="14" height="4" rx="2"/>')
            self.text(x + 20, y, label, size=12)
            if value:
                self.text(x + 26 + text_width(label, 12), y, value, cls='m', size=12, weight=600)
            x += w
        self.y = y + 16

    def style(self):
        light, dark = [], []
        for name, (lc, dc) in INK.items():
            light.append(f'.{name}{{fill:{lc}}}')
            dark.append(f'.{name}{{fill:{dc}}}')
        for name, (lc, dc) in RULES.items():
            light.append(f'.{name}{{stroke:{lc}}}')
            dark.append(f'.{name}{{stroke:{dc}}}')
        light.append(f'.ring{{stroke:{INK["bg"][0]}}}')
        dark.append(f'.ring{{stroke:{INK["bg"][1]}}}')
        for key in sorted(self.series, key=str):
            lc, dc = color(key)
            name = 'sg' if key == 'gray' else f's{key}'
            light.append(f'.{name}{{fill:{lc};stroke:{lc}}}')
            dark.append(f'.{name}{{fill:{dc};stroke:{dc}}}')
        if self.tints:
            for mode, (out, surface) in enumerate(((light, INK['bg'][0]), (dark, INK['bg'][1]))):
                for i in range(STEPS):
                    out.append(f'.good{i + 1}{{fill:{blend(GOOD, ALPHA[mode][i], surface)}}}')
                    out.append(f'.bad{i + 1}{{fill:{blend(BAD, ALPHA[mode][i], surface)}}}')
        return (f'<style>{"".join(light)}@media (prefers-color-scheme:dark){{{"".join(dark)}}}'
                'text{font-variant-numeric:tabular-nums}.ln{fill:none;stroke-linejoin:round;stroke-linecap:round}'
                'rect.s0,rect.s1,rect.s2,rect.s3,rect.s4,rect.s5,rect.s6,rect.s7,rect.sg{stroke:none}</style>')

    def svg(self, height):
        h = math.ceil(height)
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {h}" width="{self.w}" height="{h}" '
                f'font-family="{FONT}" role="img" aria-label="{esc(self.title)}">')
        return '\n'.join([head, self.style(), f'<rect class="bg" width="{self.w}" height="{h}" rx="10"/>']
                         + self.parts + ['</svg>']) + '\n'


def fmt(v, decimals):
    return f'{v:,.{decimals}f}'.replace('-', '−')


def line_chart(title, subtitle, x_labels, series, decimals, width=720, plot_h=180):
    """Versions along x, one line per series: [(label, color key, values)].

    The last x label is bold: it is the newest version. Each key in the legend
    carries its series' newest value, so lines that end close together never
    fight over labels."""
    newest = x_labels[-1].split(' ')[0]
    card = Card(width, title, f'{subtitle} The numbers in the key are {newest}\'s.')
    card.legend([(label, key, next((fmt(v, decimals) for v in reversed(vals) if v is not None), ''))
                 for label, key, vals in series])
    pad_l, pad_r = 52, 24
    top = card.y + 10
    plot_w = width - pad_l - pad_r
    present = [v for *_, vals in series for v in vals if v is not None]
    lo, hi, step = nice_axis(max(present) if present else 1)
    n = len(x_labels)

    def x(i):
        return pad_l + plot_w * (i + 0.5) / n

    def y(v):
        return top + plot_h * (1 - (v - lo) / (hi - lo))

    for k in range(round((hi - lo) / step) + 1):
        v = lo + step * k
        card.rule(pad_l, y(v), pad_l + plot_w, y(v), 'a' if k == 0 else 'g')
        card.text(pad_l - 8, y(v) + 4, fmt(v, tick_decimals(step)), cls='q', size=11, anchor='end')
    for i, label in enumerate(x_labels):
        version, _, note = label.partition(' ')
        newest = i == n - 1
        card.text(x(i), top + plot_h + 18, version, cls='t' if newest else 'm', size=11, anchor='middle',
                  weight=600 if newest else None)
        if note:
            card.text(x(i), top + plot_h + 31, note, cls='q', size=10, anchor='middle')
    for label, key, vals in series:
        pts = [(x(i), y(v), v, x_labels[i]) for i, v in enumerate(vals) if v is not None]
        if not pts:
            continue
        cls = card.swatch_class(key)
        d = ' '.join(f'{"M" if j == 0 else "L"}{px:.1f},{py:.1f}' for j, (px, py, *_) in enumerate(pts))
        card.add(f'<path class="ln {cls}" stroke-width="2" d="{d}"/>')
        for px, py, v, xl in pts:
            card.add(f'<circle class="{cls} ring" cx="{px:.1f}" cy="{py:.1f}" r="3.5" stroke-width="2">'
                     f'<title>{esc(xl)}, {esc(label)}: {fmt(v, decimals)}</title></circle>')
    return card.svg(top + plot_h + 44)


def bars(title, subtitle, groups, entities, fmt_value, width=720, axis_max=None, label_w=None, fmt_tick=None):
    """Horizontal bars from one baseline. groups: [(label, [value per entity])],
    entities: [(label, color key)], in the order they are drawn in every group.

    With one unlabeled group, each bar is labeled with its entity, and there is
    no legend. fmt_tick formats the axis, fmt_value by default."""
    fmt_tick = fmt_tick or fmt_value
    single = len(groups) == 1 and not groups[0][0]
    card = Card(width, title, subtitle)
    if not single:
        card.legend(entities)
    names = [e[0] for e in entities] if single else [g[0] for g in groups]
    label_w = label_w or max(text_width(s, 12) for s in names) + 16
    pad_l = 24 + label_w
    values = [v for _, vals in groups for v in vals if v is not None]
    longest = max(text_width(fmt_value(v), 11) for v in values)
    plot_w = width - pad_l - 24 - longest - 12
    lo, hi, step = nice_axis(axis_max or max(values))
    bar_h = 12 if single else 9
    pitch = 26 if single else bar_h + 3
    top = card.y + 10
    y = top

    def bx(v):
        return pad_l + plot_w * v / hi

    rows = []
    for label, vals in groups:
        if single:
            for (name, key), v in zip(entities, vals):
                rows.append((name, [(key, v, name)], y))
                y += pitch
        else:
            drawn = [(key, v, name) for (name, key), v in zip(entities, vals) if v is not None]
            rows.append((label, drawn, y))
            y += pitch * len(drawn) + 12
    bottom = y - (pitch - bar_h if single else 12) + 6
    for k in range(round(hi / step) + 1):
        v = step * k
        card.rule(bx(v), top - 4, bx(v), bottom, 'a' if k == 0 else 'g')
        card.text(bx(v), bottom + 16, fmt_tick(v), cls='q', size=11, anchor='middle')
    for label, drawn, y0 in rows:
        mid = y0 + (len(drawn) * pitch - (pitch - bar_h)) / 2
        card.text(pad_l - 12, mid + 4, label, cls='m', size=12, anchor='end')
        for j, (key, v, name) in enumerate(drawn):
            by = y0 + j * pitch
            w = max(bx(v) - pad_l, 1.5)
            r = min(4, w / 2, bar_h / 2)
            cls = card.swatch_class(key)
            card.add(f'<path class="{cls}" d="M{pad_l:.1f},{by:.1f} h{w - r:.1f} a{r},{r} 0 0 1 {r},{r} '
                     f'v{bar_h - 2 * r:.1f} a{r},{r} 0 0 1 -{r},{r} h-{w - r:.1f} z">'
                     f'<title>{esc(label)}, {esc(name)}: {esc(fmt_value(v))}</title></path>')
            card.text(pad_l + w + 6, by + bar_h / 2 + 4, fmt_value(v), cls='m', size=11)
    return card.svg(bottom + 30)


def curves(title, subtitle, panels, entities, width=900, plot_h=220):
    """Line plots side by side on their own axes. panels: [dict(xs, series (one
    list of y per entity, None where off), x=(lo, hi, step, fmt), y=(lo, hi, step),
    xlabel, ylabel, caption)]. Entities draw in reverse, so the first is on top."""
    card = Card(width, title, subtitle)
    card.legend(entities)
    top = card.y + 30
    gap = 56
    pw = (width - 48 - gap * len(panels)) / len(panels)
    for p, panel in enumerate(panels):
        left = 24 + gap + p * (pw + gap)
        xlo, xhi, xstep, xfmt = panel['x']
        ylo, yhi, ystep = panel['y']
        card.text(left - 46, top - 24, panel['caption'], size=12, weight=600)
        clip = f'clip{p}'
        card.add(f'<clipPath id="{clip}"><rect x="{left:.1f}" y="{top - 2:.1f}" width="{pw:.1f}" '
                 f'height="{plot_h + 2}"/></clipPath>')

        def px(v):
            return left + pw * (v - xlo) / (xhi - xlo)

        def py(v):
            return top + plot_h * (yhi - min(v, yhi)) / (yhi - ylo)

        for k in range(round((yhi - ylo) / ystep) + 1):
            v = ylo + ystep * k
            card.rule(left, py(v), left + pw, py(v), 'g')
            card.text(left - 8, py(v) + 4, fmt(v, tick_decimals(ystep)), cls='q', size=11, anchor='end')
        for k in range(round((xhi - xlo) / xstep) + 1):
            v = xlo + xstep * k
            card.rule(px(v), top + plot_h, px(v), top + plot_h + 4, 'a')
            card.text(px(v), top + plot_h + 18, xfmt(v), cls='q', size=11, anchor='middle')
        card.rule(left, top + plot_h, left + pw, top + plot_h, 'a')
        card.text(left + pw, top + plot_h + 34, panel['xlabel'], cls='q', size=11, anchor='end')
        card.text(left - 30, top + 4, panel['ylabel'], cls='q', size=11, anchor='end')
        for e in range(len(entities) - 1, -1, -1):
            cls = card.swatch_class(entities[e][1])
            d = ' '.join(f'{"M" if i == 0 else "L"}{px(xv):.1f},{py(yv):.1f}'
                         for i, (xv, yv) in enumerate(zip(panel['xs'], panel['series'][e])))
            card.add(f'<path class="ln {cls}" stroke-width="1.75" clip-path="url(#{clip})" d="{d}"/>')
    return card.svg(top + plot_h + 50)


def flow(title, subtitle, lanes, width=1000):
    """Rows of stages joined by arrows: [(name, note, [(stage, detail, skipped when idle)])]."""
    card = Card(width, title, subtitle)
    card.add(f'<rect class="box k" x="24" y="{card.y:.1f}" width="22" height="12" rx="3" stroke-width="1"/>')
    card.text(52, card.y + 10, 'Always runs', cls='m', size=12)
    card.add(f'<rect class="bg k" x="150" y="{card.y:.1f}" width="22" height="12" rx="3" stroke-width="1" '
             'stroke-dasharray="3 2"/>')
    card.text(178, card.y + 10, 'Skipped when it has nothing to do', cls='m', size=12)
    y = card.y + 34
    box_w, box_h, arrow = 118, 46, 22
    for name, note, stages in lanes:
        card.text(24, y + 12, name, size=13, weight=600)
        card.text(24 + text_width(name, 13) + 12, y + 12, note, cls='m', size=12)
        y += 24
        for i, (stage, detail, optional) in enumerate(stages):
            x = 24 + i * (box_w + arrow)
            dash = ' stroke-dasharray="4 3"' if optional else ''
            fill = 'bg' if optional else 'box'
            card.add(f'<rect class="{fill} k" x="{x}" y="{y:.1f}" width="{box_w}" height="{box_h}" rx="6" '
                     f'stroke-width="1"{dash}/>')
            card.text(x + box_w / 2, y + 20, stage, size=12, anchor='middle', weight=600)
            card.text(x + box_w / 2, y + 36, detail, cls='m', size=10.5, anchor='middle')
            if i:
                ax = x - arrow
                card.add(f'<path class="ln k" stroke-width="1.25" d="M{ax + 5},{y + box_h / 2:.1f} h{arrow - 10} '
                         f'm-4,-4 l4,4 l-4,4"/>')
        y += box_h + 22
    return card.svg(y)


def rate(cells, better, min_spread=0.0):
    """Tint steps for the numeric cells of one comparison, +STEPS for the best
    down to -STEPS for the worst, and whether each cell is the best. Cells
    closer together than min_spread, a fraction of the best, are not rated."""
    nums = [c for c in cells if isinstance(c, (int, float))]
    if better not in ('lower', 'higher') or len(nums) < 2 or max(nums) == min(nums):
        return [0] * len(cells), [False] * len(cells)
    best = min(nums) if better == 'lower' else max(nums)
    worst = max(nums) if better == 'lower' else min(nums)
    if abs(worst - best) <= abs(best) * min_spread:
        return [0] * len(cells), [False] * len(cells)
    steps = [round((1 - 2 * (c - best) / (worst - best)) * STEPS) if isinstance(c, (int, float)) else 0
             for c in cells]
    return steps, [c == best for c in cells]


def table(title, subtitle, columns, rows, spans=None, compare=None, width=None, label_header='', min_spread=0.0):
    """A table whose cells are tinted from best to worst along each row.

    columns: header labels, '\\n' for a second line. rows: (label, cells, better),
    better 'lower', 'higher' or None. A cell is None (shown as a dash), text, or
    (text, value): a number to compare, or 'good' / 'bad' to tint it outright.
    compare: groups of column indexes compared with each other, all columns by
    default. spans: [(label, first column, last column)] above the headers.
    min_spread leaves a comparison uncolored when its cells are that close."""
    compare = compare or [list(range(len(columns)))]
    texts = [[('–' if c is None else c[0] if isinstance(c, tuple) else c) for c in cells] for _, cells, _ in rows]
    col_w = []
    for j, head in enumerate(columns):
        widest = max([text_width(t[j], 12) for t in texts] + [text_width(h, 11.5) for h in head.split('\n')])
        col_w.append(max(widest + 26, 64))
    for label, a, b in spans or []:
        short = text_width(label, 11.5) + 24 - sum(col_w[a:b + 1])
        for j in range(a, b + 1):
            col_w[j] += max(short, 0) / (b - a + 1)
    label_w = max([text_width(r[0], 12) for r in rows] + [text_width(label_header, 11.5)]) + 28
    total = 24 + label_w + sum(col_w) + 24
    width = max(width or 0, math.ceil(total), 480)
    card = Card(width, title, subtitle)
    card.tints = True
    x0 = 24 + label_w + (width - total)  # extra width goes to the label column
    label_w += width - total
    xs = [x0 + sum(col_w[:j]) for j in range(len(columns))]
    y = card.y + 6
    if spans:
        for label, a, b in spans:
            card.text((xs[a] + xs[b] + col_w[b]) / 2, y + 10, label, cls='t', size=11.5, anchor='middle', weight=600)
            card.rule(xs[a] + 6, y + 16, xs[b] + col_w[b] - 6, y + 16, 'a')
        y += 22
    head_lines = max(len(h.split('\n')) for h in columns)
    for j, head in enumerate(columns):
        for k, line in enumerate(head.split('\n')):
            card.text(xs[j] + col_w[j] / 2, y + 12 + 14 * k, line, cls='m', size=11.5, anchor='middle', weight=600)
    if label_header:
        card.text(24, y + 12, label_header, cls='m', size=11.5, weight=600)
    y += 14 * head_lines + 8
    card.rule(24, y, width - 24, y, 'a')
    row_h = 30
    for r, (label, cells, better) in enumerate(rows):
        values = [c[1] if isinstance(c, tuple) else None for c in cells]
        steps, bests = [0] * len(cells), [False] * len(cells)
        for group in compare:
            group_steps, group_bests = rate([values[j] for j in group], better, min_spread)
            for j, s, b in zip(group, group_steps, group_bests):
                steps[j], bests[j] = s, b
        for j, v in enumerate(values):
            if v in ('good', 'bad'):
                steps[j] = STEPS - 1 if v == 'good' else 1 - STEPS
        card.text(24, y + 19, label, cls='t', size=12)
        for j, text in enumerate(texts[r]):
            s = steps[j]
            if s:
                card.add(f'<rect class="{"good" if s > 0 else "bad"}{abs(s)}" x="{xs[j] + 2:.1f}" y="{y + 2:.1f}" '
                         f'width="{col_w[j] - 4:.1f}" height="{row_h - 4}" rx="4"/>')
            card.text(xs[j] + col_w[j] / 2, y + 19, text, cls='t', size=12, anchor='middle',
                      weight=650 if bests[j] else None)
        y += row_h
        if r < len(rows) - 1:
            card.rule(24, y, width - 24, y, 'g')
    return card.svg(y + 22)

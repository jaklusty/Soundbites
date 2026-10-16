# Soundbites app icon: four variants

One concept, decided already: **a music symbol with a bite taken out of it.** Below are four
takes on it so one can be picked. Each is a 1024x1024 flat-vector SVG with the macOS rounded-square
icon grid built in (an 824x824 rounded square, corner radius 185, centred on the canvas); the same
artwork works for Windows. There are no fonts, raster images, gradients or filter effects, so any
SVG renderer produces the same result. After a first review, variants 2 and 3 were shortlisted and
each got a "b" version with a much bigger, toothier bite, and then a "c" version that adds a trail of
crumbs flying off the bite (after a reference image Jak supplied), in a light "c" and a heavy "d" weight;
`preview.png` now shows 2c, 2d, 3c and 3d side by side at 512px and 32px (every earlier variant is
still here as a file).

## Variant 1: single note, bite in the head (`variant-1.svg`)

One classic eighth note (the "quaver" shape everyone recognises) in deep plum on a warm cream
background. A clean semicircular bite has been taken out of the top-left of the round note head, and
a small coral dot nearby is the crumb that fell off. It is the lightest and friendliest of the four,
and the only one on a pale background, so it stands out among the mostly dark icons in a dock or taskbar.

## Variant 2: two notes, bite through the beam (`variant-2.svg`)

A pair of eighth notes joined by a thick slanted bar (the "beam"), in saffron yellow on a near-black
plum background. The bite is a semicircle taken out of the top edge of the beam, right between the two
notes, as if someone bit into the connecting bar. This reads as "music" even faster than a single note,
and the dark background suits a desktop app that lives alongside video-editing tools.

## Variant 2b: two notes, big chomp out of the beam corner (`variant-2b.svg`)

The same two beamed notes and the same saffron-on-black palette as variant 2, but the bite is now a
big round chomp, as large as variant 4's, taken out of the top-right corner of the beam where it meets
the right-hand note's stem. Three chunky tooth-mark scallops run along the rim of the chomp so it is
plainly a bite, not a cut. The beam was made a little thicker and the whole drawing nudged left so the
beam still holds together under the bite and the chomp stays inside the rounded square. At 32px the
missing corner is clearly visible; the tooth marks soften into a rough edge.

## Variant 2c: two notes, scalloped chomp with flying crumbs (`variant-2c.svg`)

Variant 2b's notes, palette and chomp, redrawn to match the reference bite style: the chomp out of the
beam's top-right corner now has four clear tooth-mark scallops, and a trail of nine saffron crumbs (a mix
of small dots and jagged shards, pieces of the note) flies up and to the right away from the bite,
shrinking with distance. Because 2b's chomp already filled the corner of the rounded square, the whole
note drawing (chomp included, so the chomp keeps its size relative to the notes) is scaled to 88% and
nudged down-left to make room for the trail. At 32px the crumbs become a faint speckle in the corner
and the missing beam corner still reads clearly.

## Variant 2d: two notes, scalloped chomp with a heavy crumb fan (`variant-2d.svg`)

Identical to 2c (same 88%-scaled notes and the same four-scallop chomp) except for the trail, which is
much heavier to match the reference image: fifteen saffron crumbs instead of nine, the first three of
them big chunks (a jagged shard about a quarter of the bite's width, then a large dot and another chunk
above), spreading in a wider fan up and to the right and shrinking to specks. It reads as the corner of
the beam physically breaking apart. At 32px the big chunks stay visible as a cluster in the top-right
corner, so the icon is busier there than 2c; that is the trade-off to compare.

## Variant 3: sound bars, bite out of the tallest bar (`variant-3.svg`)

Five rounded vertical bars of different heights, the familiar "audio playing" or waveform glyph, in cream
on a deep teal background. The semicircular bite is taken out of the right side of the tallest, central
bar. This is the least "sheet music" of the four and the most "audio clip", which fits the app's job of
serving short sound snippets, and the simple shapes stay crisp even at 16px.

## Variant 3b: sound bars, big chomp through the tallest bar (`variant-3b.svg`)

The same five bars and cream-on-teal palette as variant 3, but with a big circular chomp taken out of
the right-hand side of the tallest bar, deep enough that the bar is visibly narrowed, with five tooth-mark
scallops around the rim. Because the chomp is so large, the same arc also slices the top off the shorter
bar next to it, which makes the bite read as one single mouthful across the glyph rather than a notch.
At 32px it shows as an obvious bite out of the central bar.

## Variant 3c: sound bars, scalloped chomp with flying crumbs (`variant-3c.svg`)

Variant 3b's bars, palette and chomp, unchanged, plus a trail of nine cream crumbs (dots and shards,
pieces of the bar) that starts at the top edge of the bite and flies up and to the right between the
tallest bar and the right-hand bars, shrinking as it goes. Nothing else moved, since this layout already
had empty space above the shorter bars for the trail. At 32px the trail reads as a few light specks
leading away from the bite.

## Variant 3d: sound bars, scalloped chomp with a heavy crumb fan (`variant-3d.svg`)

Identical to 3c except for the trail: fifteen cream crumbs, led by a big jagged chunk right at the top of
the bite, a large dot beside it and a third chunk above, fanning up and to the right across the space
above the two right-hand bars and shrinking to specks near the corner. The bars themselves are untouched.
At 32px the chunks read as a visible spray leaving the bite, noticeably heavier than 3c.

## Variant 4: bold note, chomp with tooth marks (`variant-4.svg`)

A chunky, heavyweight eighth note in near-black on a mustard background. Instead of a smooth semicircle,
the bite is a big round "chomp" out of the note's flag with a row of small tooth marks along its rim, so it
is unmistakably a bite rather than a design cut-out. It is the most playful and characterful of the four;
the tooth marks disappear at favicon size but the overall silhouette still reads as a bitten note.

## Files

- `variant-N.svg`: the source artwork (edit these, everything else is generated from them).
- `variant-N-512.png`, `variant-N-32.png`: renders at the two sizes used for the preview sheet.
- `preview.png`: variants 2c, 2d, 3c and 3d side by side at 512px and 32px, labelled.

Renders were made with `cairosvg` (`python3 -m pip install --user cairosvg`) and the sheet assembled with Pillow.

## Turning the chosen variant into the app icon

The Flutter app keeps a 1024x1024 PNG at `assets/icon/icon.png` (shown in About and used as the
source for the platform icons). Once a variant is chosen, render it at 1024x1024 and copy it there:

```sh
python3 -c "import cairosvg; cairosvg.svg2png(url='design/logo/variant-2.svg', write_to='assets/icon/icon.png', output_width=1024, output_height=1024)"
```

Then regenerate the platform icons from it: the macOS set in
`macos/Runner/Assets.xcassets/AppIcon.appiconset/` (16 to 1024 px) and the Windows
`windows/runner/resources/app_icon.ico` (16 to 256 px). The `flutter_launcher_icons` package
does both from one PNG.

The rounded-square background is part of the artwork on purpose: macOS does not clip icons, so the
PNG must already contain the rounded square with transparent corners, which these SVGs do.

## Series 5: one silhouette, one bite (`variant-5a.svg`, `variant-5b.svg`, `variant-5c.svg`)

After the crumb variants Jak asked for something as professional as the Apple logo but on the
music theme. The Apple mark works because it is a single flat silhouette with one clean bite and
nothing else: no outline, no crumbs, no background needed, and it reads the same in black, in
white, and at 16 pixels. Series 5 applies that rule to the note.

- **5a:** a single eighth note, redrawn with a straight stem and a tapered flag that sweeps out
  and comes back to a point, with one round bite out of the upper left of the note head. The
  bite sits opposite the flag so the mark balances.
- **5b:** the same note with the bite out of the lower right of the head, nearer the stem.
- **5c:** two beamed notes with a round bite out of the top edge of the beam.

Each variant exists as the plain mark (`variant-5x.svg`, black on white; swap the fill for white
on black) and as the app tile (`variant-5x-tile.svg`, white on the macOS rounded square in
near-black). `preview-5.png` shows all three on white, on black, in the tile, and at 32 and
16 pixels. The tile colour is the one open choice once a shape is picked; the mark itself stays
one colour.

## Series 6: the chosen logo (`logo-6-source.jpg`)

On 16 October 2026 Jak supplied the logo to use: a row of sound bars rising into a play
triangle, in a blue-violet to coral gradient on a near-black rounded tile, with the word
"soundbites" beneath. Three icon files were made from it:

- **6a, as given** (`logo-6a-as-given.png`): the tile cut out of the picture and placed on the
  macOS icon grid with transparent corners. **This is the installed app icon.**
- **6b, no wordmark** (`logo-6b-no-wordmark.png`): the same picture with the word removed and the
  mark centred, because a word in an icon turns to a smudge at dock and taskbar sizes.
- **6c, vector remake** (`logo-6c-vector.svg` and `.png`): the mark redrawn as shapes with the
  same gradient, so it is crisp at every size and can be recoloured or reused elsewhere.

`preview-6.png` shows the three at 320, 64, 32 and 16 px. To switch the app icon to another one:

```sh
python3 scripts/make-icons.py design/logo/logo-6b-no-wordmark.png
```

which rewrites the macOS icon set, the Windows .ico and the in-app `assets/icon/icon.png`.

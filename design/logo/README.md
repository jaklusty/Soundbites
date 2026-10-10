# Soundbites app icon: four variants

One concept, decided already: **a music symbol with a bite taken out of it.** Below are four
takes on it so one can be picked. Each is a 1024x1024 flat-vector SVG with the macOS rounded-square
icon grid built in (an 824x824 rounded square, corner radius 185, centred on the canvas); the same
artwork works for Windows. There are no fonts, raster images, gradients or filter effects, so any
SVG renderer produces the same result. After a first review, variants 2 and 3 were shortlisted and
each got a "b" version with a much bigger, toothier bite; `preview.png` now shows 2, 2b, 3, 3b and 4
side by side at 512px and 32px (variants 1 to 4 are all still here).

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

## Variant 4: bold note, chomp with tooth marks (`variant-4.svg`)

A chunky, heavyweight eighth note in near-black on a mustard background. Instead of a smooth semicircle,
the bite is a big round "chomp" out of the note's flag with a row of small tooth marks along its rim, so it
is unmistakably a bite rather than a design cut-out. It is the most playful and characterful of the four;
the tooth marks disappear at favicon size but the overall silhouette still reads as a bitten note.

## Files

- `variant-N.svg`: the source artwork (edit these, everything else is generated from them).
- `variant-N-512.png`, `variant-N-32.png`: renders at the two sizes used for the preview sheet.
- `preview.png`: variants 2, 2b, 3, 3b and 4 side by side at 512px and 32px, labelled.

Renders were made with `cairosvg` (`python3 -m pip install --user cairosvg`) and the sheet assembled with Pillow.

## Turning the chosen variant into the app icon

electron-builder generates `icon.icns` (macOS) and `icon.ico` (Windows) itself from a single
1024x1024 PNG placed at `build/icon.png` in the project root. So once a variant is chosen, render it
at 1024x1024 and copy it there, for example:

```sh
python3 -c "import cairosvg; cairosvg.svg2png(url='design/logo/variant-2.svg', write_to='build/icon.png', output_width=1024, output_height=1024)"
```

The rounded-square background is part of the artwork on purpose: macOS does not clip icons, so the
PNG must already contain the rounded square with transparent corners, which these SVGs do.

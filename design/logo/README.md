# Soundbites app icon: four variants

One concept, decided already: **a music symbol with a bite taken out of it.** Below are four
takes on it so one can be picked. Each is a 1024x1024 flat-vector SVG with the macOS rounded-square
icon grid built in (an 824x824 rounded square, corner radius 185, centred on the canvas); the same
artwork works for Windows. There are no fonts, raster images, gradients or filter effects, so any
SVG renderer produces the same result. `preview.png` shows all four at 512px and 32px.

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

## Variant 3: sound bars, bite out of the tallest bar (`variant-3.svg`)

Five rounded vertical bars of different heights, the familiar "audio playing" or waveform glyph, in cream
on a deep teal background. The semicircular bite is taken out of the right side of the tallest, central
bar. This is the least "sheet music" of the four and the most "audio clip", which fits the app's job of
serving short sound snippets, and the simple shapes stay crisp even at 16px.

## Variant 4: bold note, chomp with tooth marks (`variant-4.svg`)

A chunky, heavyweight eighth note in near-black on a mustard background. Instead of a smooth semicircle,
the bite is a big round "chomp" out of the note's flag with a row of small tooth marks along its rim, so it
is unmistakably a bite rather than a design cut-out. It is the most playful and characterful of the four;
the tooth marks disappear at favicon size but the overall silhouette still reads as a bitten note.

## Files

- `variant-N.svg`: the source artwork (edit these, everything else is generated from them).
- `variant-N-512.png`, `variant-N-32.png`: renders at the two sizes used for the preview sheet.
- `preview.png`: all four variants side by side at 512px and 32px, labelled.

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

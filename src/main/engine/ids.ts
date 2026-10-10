/**
 * Track ids. A byte-for-byte port of `slugify` in the original ingest.py (hard requirement 10).
 * favourites.json, clips/<id>.mp3 and full/<id>/ are all keyed on this, so any drift would orphan
 * every favourite and clip.
 *
 * The Python:
 *   readable_part(s): NFKD → drop non-ASCII → lower() → strip [^\w\s-] → [\s_-]+ → "-" → strip("-")
 *   identity(s):      NFKC → casefold() → strip [^\w\s] (Unicode \w) → collapse \s+ → strip; or raw if empty
 *   id = (readable(artist)-readable(title))[:50] + "-" + sha1(identity(artist) NUL identity(title))[:8]
 *        or "track-" + hash when the readable part is empty.
 *
 * Where JavaScript's defaults differ from Python's and are corrected here:
 *   - casefold: JS has no casefold; per-character toLowerCase plus a table of the code points
 *     where Python folds differently (ß→ss, ς→σ, Cherokee, ligatures, ...).
 *   - \s: Python's includes \x1c-\x1f and \x85, and excludes ﻿.
 *   - \w: Python's is "alphanumeric or _" in its Unicode database; JS uses \p{L}\p{N}_. These
 *     agree except for characters added in Unicode versions newer than the Python's. None of
 *     those occur in real titles; the oracle test covers every script that does.
 */
import { createHash } from 'node:crypto'
import { CASEFOLD_EXCEPTIONS } from './casefoldTable'

const foldTable: Map<number, string> = new Map(
  CASEFOLD_EXCEPTIONS.split(';').map((entry) => {
    const [cp, folded] = entry.split(':') as [string, string]
    return [parseInt(cp, 16), String.fromCodePoint(...folded.split(',').map((h) => parseInt(h, 16)))]
  })
)

/** Python str.casefold(), character by character (Python's casefold is not context-sensitive). */
export function casefold(s: string): string {
  let out = ''
  for (const ch of s) {
    const cp = ch.codePointAt(0)!
    const mapped = foldTable.get(cp)
    out += mapped !== undefined ? mapped : ch.toLowerCase()
  }
  return out
}

// Python's str.isspace() set, which is what its regex \s and str.strip() use.
const PY_SPACE = '\\t\\n\\x0b\\x0c\\r\\x1c-\\x1f \\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000'
const PY_SPACE_RUN = new RegExp(`[${PY_SPACE}]+`, 'gu')
const PY_STRIP = new RegExp(`^[${PY_SPACE}]+|[${PY_SPACE}]+$`, 'gu')
// Unicode \w per Python: letters, numbers, underscore.
const NOT_WORD_OR_SPACE = new RegExp(`[^\\p{L}\\p{N}_${PY_SPACE}]`, 'gu')
// After ASCII folding only ASCII remains, so these are the ASCII subsets.
const ASCII_NOT_WORD_SPACE_DASH = /[^A-Za-z0-9_\t\n\x0b\x0c\r\x1c-\x1f -]/g
const ASCII_SEP_RUN = /[\t\n\x0b\x0c\r\x1c-\x1f _-]+/g

function readablePart(s: string): string {
  // NFKD then drop everything outside ASCII (Python: encode("ascii", "ignore")).
  // eslint-disable-next-line no-control-regex
  const ascii = s.normalize('NFKD').replace(/[^\x00-\x7f]/g, '')
  const lowered = ascii.toLowerCase()
  const cleaned = lowered.replace(ASCII_NOT_WORD_SPACE_DASH, '')
  return cleaned.replace(ASCII_SEP_RUN, '-').replace(/^-+|-+$/g, '')
}

function identity(s: string): string {
  const raw = casefold(s.normalize('NFKC'))
  const cleaned = raw.replace(NOT_WORD_OR_SPACE, '').replace(PY_SPACE_RUN, ' ').replace(PY_STRIP, '')
  // An emoji-only title cleans to nothing; fall back to the raw form so such titles stay distinct.
  return cleaned || raw.replace(PY_STRIP, '')
}

export function slugify(artist: string | null | undefined, title: string | null | undefined): string {
  const a = artist ?? ''
  const t = title ?? ''
  const readable = [readablePart(a), readablePart(t)].filter((p) => p).join('-').slice(0, 50)
  const digest = createHash('sha1')
    .update(`${identity(a)}\x00${identity(t)}`, 'utf8')
    .digest('hex')
    .slice(0, 8)
  return readable ? `${readable}-${digest}` : `track-${digest}`
}

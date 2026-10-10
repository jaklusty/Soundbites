#!/usr/bin/env python3
"""
hook.py — find the most recognisable 30 seconds of a track.

Three methods, tried in order, because each fails differently:

  1. heatmap  YouTube's "most replayed" data, which yt-dlp extracts alongside
              the audio. 100 buckets, each normalised 0-1. This is literally
              crowd-sourced "the bit people rewind to" — no model, no guessing,
              and it is the strongest signal available. Absent on low-view
              uploads, and needs care (see the t=0 problem below).

  2. chorus   Audio thumbnailing. Chroma features into a self-similarity
              matrix: the section that resembles the rest of the song most is
              the chorus, by definition. Works regardless of view count.
              Requires librosa.

  3. energy   Loudest sustained 30-second window. Crude, catches drops, needs
              only librosa's loader. Last resort before a plain guess.

Every result records which method produced it, so the dashboard can show it and
the user knows whether to trust it.

KNOWN LIMIT, worth stating plainly: for a *trending* sound, the recognisable
bit is whatever TikTok users cut to, which is not always the chorus — sometimes
it is a spoken intro or a pre-chorus. The heatmap on a YouTube upload knows
nothing about the TikTok trend. Expect this to be right most of the time, not
always, and let an explicit hook_start override it.
"""

import json
import sys

WINDOW = 30.0
# People restart videos, so bucket zero is nearly always the global maximum.
# Treating it as "the hook" would put every clip at 0:00.
HEAD_SKIP = 10.0
TAIL_SKIP = 5.0
# A heatmap where every bucket is about the same tells us nothing; demand that
# the peak stands clear of the average before believing it.
FLATNESS_MIN = 1.25
# The detrended bump must clear this fraction of the track's mean replay value.
# Below it we are reading noise off a drop-off curve, and 0:20 is more honest.
EXCESS_MIN = 0.08


def _clamp(start, duration):
    if not duration or duration <= WINDOW:
        return 0.0
    return max(0.0, min(float(start), duration - WINDOW))


# ---------------------------------------------------------------- 1. heatmap

def from_heatmap(heatmap, duration):
    """Best 30s window by summed replay value. Returns (seconds, detail) or None."""
    if not heatmap or not isinstance(heatmap, list) or len(heatmap) < 8:
        return None
    try:
        pts = [(float(h["start_time"]), float(h["end_time"]), float(h["value"]))
               for h in heatmap]
    except (KeyError, TypeError, ValueError):
        return None

    usable = [p for p in pts
              if p[0] >= HEAD_SKIP and (not duration or p[1] <= duration - TAIL_SKIP)]
    if len(usable) < 5:
        usable = pts[1:] or pts
    if not usable:
        return None

    values = [v for _, _, v in usable]
    mean = sum(values) / len(values)
    peak = max(values)
    if mean <= 0 or peak / mean < FLATNESS_MIN:
        return None  # flat heatmap: no opinion

    # DETREND. A YouTube heatmap is dominated by drop-off: viewers leak away
    # steadily, so raw values decay from the start and the earliest allowed
    # window almost always wins on absolute value. Verified on real tracks —
    # every hook landed within two seconds of the head-skip boundary. What we
    # actually want is a BUMP: where replaying exceeds the local trend. So
    # subtract a wide moving baseline and score only the excess.
    n = len(usable)
    span = max(3, n // 5)          # baseline window ~20% of the track
    excess = []
    for i, (a, b, v) in enumerate(usable):
        lo, hi = max(0, i - span), min(n, i + span + 1)
        baseline = sum(values[lo:hi]) / (hi - lo)
        excess.append((a, max(0.0, v - baseline)))

    # A pure decay curve still yields tiny positive excesses at the edges of
    # the moving baseline, so "any excess at all" is not a real test. Demand a
    # bump that actually stands out relative to the track's own scale.
    peak_excess = max(e for _, e in excess)
    if peak_excess < EXCESS_MIN * mean:
        return None                # no bump worth calling a hook

    # A hook RISES INTO. Drop-off never does — it only falls. So a candidate
    # window must be louder than the stretch immediately before it. This is
    # what finally separates "the chorus" from "the first ten seconds", which
    # detrending alone could not: a steep decay leaves a large apparent excess
    # at the head because a centred baseline has no left-hand context there.
    lookback = WINDOW * 0.7
    by_time = {a: v for a, _, v in usable}

    def rises_into(start):
        before = [v for a, v in by_time.items() if start - lookback <= a < start]
        inside = [v for a, v in by_time.items() if start <= a < start + WINDOW]
        if not before or not inside:
            return False
        return sum(inside) / len(inside) > sum(before) / len(before)

    best_start, best_score = None, -1.0
    for start, _ in excess:
        if not rises_into(start):
            continue
        score = sum(e for a, e in excess if start <= a < start + WINDOW)
        if score > best_score:
            best_score, best_start = score, start

    if best_start is None or best_score <= 0:
        return None
    return _clamp(best_start, duration), f"replay bump, peak {peak / mean:.1f}x average"


# ---------------------------------------------------------------- 2 & 3

# Tuned empirically against a synthetic track with a known chorus structure:
# hop 8192 at 22050 Hz keeps enough chroma resolution to land on the right
# section while running ~25x faster than hop 2048 (0.8s vs 22s per track).
# That matters when seeding a 50-track pool, not for a single lookup.
ANALYSIS_SR = 22050
ANALYSIS_HOP = 8192


def _load(path, sr=ANALYSIS_SR):
    import librosa
    y, sr = librosa.load(str(path), sr=sr, mono=True)
    return y, sr


def from_chorus(path, duration=None):
    """
    Most-repeated section. Chroma -> affinity matrix -> the window whose frames
    are collectively most similar to the rest of the track.
    """
    try:
        import numpy as np
        import librosa
    except ImportError:
        return None

    try:
        y, sr = _load(path)
        if y.size == 0:
            return None
        hop = ANALYSIS_HOP
        chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop)
        # Smooth over ~1s so short transients don't dominate the similarity.
        smooth = max(1, int(round(sr / hop)))
        chroma = np.apply_along_axis(
            lambda m: np.convolve(m, np.ones(smooth) / smooth, mode="same"), 1, chroma)

        rec = librosa.segment.recurrence_matrix(
            chroma, mode="affinity", metric="cosine", sparse=False)
        # How much each frame is echoed elsewhere in the track.
        repetition = rec.sum(axis=1)

        times = librosa.frames_to_time(np.arange(len(repetition)), sr=sr, hop_length=hop)
        dur = duration or float(times[-1]) if len(times) else 0.0
        if dur <= WINDOW:
            return 0.0, "track shorter than the clip"

        best_start, best_score = None, -1.0
        for i, t in enumerate(times):
            if t < HEAD_SKIP or t > dur - WINDOW - TAIL_SKIP:
                continue
            j = np.searchsorted(times, t + WINDOW)
            score = float(repetition[i:j].sum())
            if score > best_score:
                best_score, best_start = score, float(t)

        if best_start is None:
            return None
        return _clamp(best_start, dur), "most-repeated section"
    except Exception as exc:                       # librosa is fussy about odd files
        print(f"  · chorus detection failed: {exc}", file=sys.stderr)
        return None


def from_energy(path, duration=None):
    """Loudest sustained 30s. Catches drops; fooled by uniformly loud masters."""
    try:
        import numpy as np
        import librosa
    except ImportError:
        return None

    try:
        y, sr = _load(path)
        if y.size == 0:
            return None
        hop = ANALYSIS_HOP
        rms = librosa.feature.rms(y=y, hop_length=hop)[0]
        times = librosa.frames_to_time(np.arange(len(rms)), sr=sr, hop_length=hop)
        dur = duration or (float(times[-1]) if len(times) else 0.0)
        if dur <= WINDOW:
            return 0.0, "track shorter than the clip"

        best_start, best_score = None, -1.0
        for i, t in enumerate(times):
            if t < HEAD_SKIP or t > dur - WINDOW - TAIL_SKIP:
                continue
            j = np.searchsorted(times, t + WINDOW)
            score = float(rms[i:j].mean())
            if score > best_score:
                best_score, best_start = score, float(t)

        if best_start is None:
            return None
        return _clamp(best_start, dur), "loudest sustained window"
    except Exception as exc:
        print(f"  · energy detection failed: {exc}", file=sys.stderr)
        return None


# ---------------------------------------------------------------- cascade

def detect(audio_path, info=None, duration=None, explicit=None):
    """
    Returns (seconds, method, detail).

    `explicit` is an author-supplied hook_start and always wins — when a
    roundup names the section people actually use, that beats any inference.
    `info` is yt-dlp's info dict (for the heatmap).
    """
    if explicit is not None:
        return float(explicit), "explicit", "set in candidates.json"

    info = info or {}
    duration = duration or info.get("duration")

    got = from_heatmap(info.get("heatmap"), duration)
    if got:
        return got[0], "heatmap", got[1]

    got = from_chorus(audio_path, duration)
    if got:
        return got[0], "chorus", got[1]

    got = from_energy(audio_path, duration)
    if got:
        return got[0], "energy", got[1]

    return 20.0, "default", "no signal — used 0:20"


def fmt(seconds):
    m, s = divmod(int(round(seconds)), 60)
    return f"{m}:{s:02d}"


if __name__ == "__main__":
    # hook.py <audio> [info.json]
    audio = sys.argv[1]
    info = {}
    if len(sys.argv) > 2:
        info = json.loads(open(sys.argv[2]).read())
    at, method, detail = detect(audio, info)
    print(f"{fmt(at)}  ({method}: {detail})")

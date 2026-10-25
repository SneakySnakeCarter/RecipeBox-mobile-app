"""Prototype of the screenshot-overlap detection that will be ported to Swift.
Images are 2D uint8 gray arrays of identical width. Returns for pair (A,B):
  None  -> no confident overlap (caller stacks B fully)
  (aKeepBottom, bCropTop): keep A rows [.., aKeepBottom), B rows [bCropTop, ..)
"""
import numpy as np

COL_STEP = 3          # sample every 3rd column
ROW_TOL = 2.5         # mean abs diff allowed for two rows to "match"
CANDIDATES = [0.10, 0.14, 0.18, 0.22, 0.28, 0.35, 0.45]

def row_match_run(A, B, y, t0, maxrun=None):
    """Number of consecutive rows starting at (A[y], B[t0]) that match, stopping
    at 4 consecutive mismatches (anti-aliasing / cursor blips tolerated)."""
    Ha, Hb = A.shape[0], B.shape[0]
    n = min(Ha - y, Hb - t0)
    if maxrun: n = min(n, maxrun)
    a = A[y:y+n, ::COL_STEP].astype(np.int16)
    b = B[t0:t0+n, ::COL_STEP].astype(np.int16)
    d = np.abs(a - b).mean(axis=1)
    bad = d > ROW_TOL
    run = 0; consec = 0; last_good = 0
    for i in range(n):
        if bad[i]:
            consec += 1
            if consec >= 4: break
        else:
            consec = 0; last_good = i + 1
    return last_good

def find_overlap(A, B):
    Ha, Hb = A.shape[0], B.shape[0]
    min_run = max(48, int(0.04 * Hb))
    sigA = A[:, ::COL_STEP].astype(np.float32).mean(axis=1)
    sigB = B[:, ::COL_STEP].astype(np.float32).mean(axis=1)
    th = max(24, int(0.04 * Hb))
    for frac in CANDIDATES:
        t0 = int(frac * Hb)
        if t0 + th > Hb: continue
        tmpl = sigB[t0:t0+th]
        # need enough variation for the template to be distinctive
        if np.count_nonzero(np.abs(np.diff(tmpl)) > 1.0) < 6: continue
        best = None
        # slide over A via 1-D signature comparison
        for y in range(max(0, t0 - 0), Ha - th + 1):   # y >= t0 required
            if np.abs(sigA[y:y+th] - tmpl).mean() > ROW_TOL: continue
            run = row_match_run(A, B, y, t0)
            if abs(y - t0) <= 2:
                # Same position in both images: either a persistent header
                # (not an overlap!) or a duplicate screenshot. Only accept it
                # as a duplicate when everything below also matches.
                remaining = min(Ha - y, Hb - t0)
                if not (remaining >= 0.5 * Hb and run >= remaining - 4):
                    continue
            if run >= min_run and (best is None or run > best[1]):
                best = (y, run)
        if best:
            y, run = best
            return (y + run, t0 + run)
    return None

def stitch(images, remove_overlap=True):
    """returns list of (image, cropTop, cropBottom_exclusive_keep_end) segments"""
    segs = [[img, 0, img.shape[0]] for img in images]
    joins = 0
    if remove_overlap:
        for i in range(1, len(images)):
            res = find_overlap(images[i-1], images[i])
            if res:
                aKeep, bTop = res
                segs[i-1][2] = min(segs[i-1][2], aKeep)
                segs[i][1] = bTop
                joins += 1
    parts = [s[0][s[1]:s[2]] for s in segs if s[2] > s[1]]
    return np.vstack(parts), joins

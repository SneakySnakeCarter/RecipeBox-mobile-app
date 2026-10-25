import numpy as np, random
from PIL import Image, ImageDraw, ImageFont
from overlap import stitch, find_overlap

random.seed(3); np.random.seed(3)
W = 600
def make_doc(h=6000):
    im = Image.new("L", (W, h), 255)
    d = ImageDraw.Draw(im)
    y = 20
    words = "salt pepper flour butter sugar eggs milk onion garlic cup tablespoon teaspoon chopped diced minced".split()
    while y < h - 40:
        if random.random() < 0.12:
            y += random.randint(30, 80)   # paragraph gap
        text = " ".join(random.choice(words) for _ in range(random.randint(3, 9)))
        d.text((random.choice([20, 20, 20, 60]), y), text, fill=random.randint(0, 60))
        y += 28
    return np.array(im)

doc = make_doc()
def screen(doc, s, content_h=1120, header=100, footer=80, hdr_val=40, ftr_val=210):
    hdr = np.full((header, W), hdr_val, np.uint8); hdr[10:30, 10:200] = 255   # a "title" blob
    ftr = np.full((footer, W), ftr_val, np.uint8); ftr[20:50, 100:500] = 90
    return np.vstack([hdr, doc[s:s+content_h], ftr])

def check(name, shots, expect_range, expect_joins):
    out, joins = stitch(shots)
    ok_j = (joins == expect_joins)
    # expected body: doc[a:b] contiguous, preceded by first header and followed by last footer
    a, b = expect_range
    exp = np.vstack([shots[0][:100], doc[a:b], shots[-1][-80:]]) if expect_range else None
    same = exp is not None and out.shape == exp.shape and np.array_equal(out, exp)
    print(f"{name}: joins={joins} (want {expect_joins}) shape={out.shape} exact={same}")
    if exp is not None and not same:
        print("   expected shape", exp.shape)

# 1) normal scroll: step 900 of 1120 visible => 220 overlap
shots = [screen(doc, s) for s in (0, 900, 1800, 2700)]
check("scroll-4", shots, (0, 2700 + 1120), 3)
# 2) small overlap 15% (170 rows)
shots = [screen(doc, s) for s in (0, 950, 1900)]
check("scroll-small-overlap", shots, (0, 1900 + 1120), 2)
# 3) no overlap (gap): step bigger than visible
shots = [screen(doc, s) for s in (0, 1500, 3000)]
out, joins = stitch(shots); print("gap:", joins, "joins; shape", out.shape, "== plain stack", out.shape[0] == sum(s.shape[0] for s in shots))
# 4) duplicate screenshot
shots = [screen(doc, 0), screen(doc, 0), screen(doc, 900)]
out, joins = stitch(shots); print("dup: joins", joins, "shape", out.shape)
# 5) unrelated images
other = make_doc()
shots = [screen(doc, 0), screen(other, 0)]
out, joins = stitch(shots); print("unrelated:", joins, "joins")
# 6) mostly blank bottom of A (white space) then text
shots = [screen(doc, s) for s in (0, 1000)]
check("scroll-1000 (120 overlap)", shots, (0, 1000 + 1120), 1)

print("---- extra")
# tall persistent header (400 rows) that is identical in all shots
def screen2(doc, s, content_h=1000, header=400, footer=80):
    hdr = np.full((header, W), 40, np.uint8)
    for k in range(0, header, 37): hdr[k:k+6, 20:400] = 200     # bars => distinctive
    ftr = np.full((footer, W), 210, np.uint8); ftr[20:50, 100:500] = 90
    return np.vstack([hdr, doc[s:s+content_h], ftr])
shots = [screen2(doc, s) for s in (0, 800, 1600)]
out, joins = stitch(shots)
exp = np.vstack([shots[0][:400], doc[0:1600+1000], shots[-1][-80:]])
print("tall-header: joins", joins, "exact", out.shape == exp.shape and np.array_equal(out, exp))
# unrelated screens sharing the same tall header => must NOT join
shots = [screen2(doc, 0), screen2(doc, 3000)]
out, joins = stitch(shots); print("same-header different content: joins", joins)
# duplicate
shots = [screen(doc, 0), screen(doc, 0)]
out, joins = stitch(shots); print("duplicate pair: joins", joins, "shape", out.shape, "single shape", shots[0].shape)
# compression-like noise on B
shots = [screen(doc, 0), screen(doc, 900)]
noisy = (shots[1].astype(np.int16) + np.random.randint(-3, 4, shots[1].shape)).clip(0,255).astype(np.uint8)
out, joins = stitch([shots[0], noisy]); print("noisy: joins", joins, "shape", out.shape, "(exact would be", 100+900+1120+80, ")")
# 120-row overlap again
shots = [screen(doc, s) for s in (0, 1000)]
check("scroll-1000 (120 overlap)", shots, (0, 1000 + 1120), 1)

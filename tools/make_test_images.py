"""Generate synthetic PPM test images (no dependencies) and encode them with cjpeg
in every mode the decoder supports. Usage: python3 make_test_images.py OUTDIR"""
import math, os, random, subprocess, sys

def make_ppm(path, w, h, seed):
    rnd = random.Random(seed)
    data = bytearray()
    for y in range(h):
        for x in range(w):
            r = int(127 + 127 * math.sin(x / 9.0 + seed))
            g = int(255 * y / max(1, h - 1))
            b = int(127 + 127 * math.cos((x + y) / 13.0))
            # a few hard-edged shapes
            if (x - w * 0.3) ** 2 + (y - h * 0.4) ** 2 < (min(w, h) * 0.2) ** 2:
                r, g, b = 250, 30, 40
            if w * 0.55 < x < w * 0.8 and h * 0.2 < y < h * 0.6:
                r, g, b = 20, 40, 230
            if (x // 4 + y // 4) % 2 == 0 and y > h * 0.75:
                r, g, b = 255 - r, 255 - g, 255 - b
            n = rnd.randint(-20, 20)
            data += bytes(max(0, min(255, c + n)) for c in (r, g, b))
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        f.write(data)

def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    sizes = [(64, 48, 1), (77, 53, 2), (320, 240, 3), (17, 9, 4)]
    cases = []
    for (w, h, seed) in sizes:
        src = os.path.join(out, "src_%dx%d.ppm" % (w, h))
        make_ppm(src, w, h, seed)
        variants = {
            "444": ["-sample", "1x1"],
            "422": ["-sample", "2x1"],
            "440": ["-sample", "1x2"],
            "420": ["-sample", "2x2"],
            "gray": ["-grayscale"],
            "420_q95_opt": ["-sample", "2x2", "-quality", "95", "-optimize"],
            "420_rst": ["-sample", "2x2", "-restart", "1"],
            "444_rst3b": ["-sample", "1x1", "-restart", "3B"],
            "422_q10": ["-sample", "2x1", "-quality", "10"],
            "420_q3_16bitq": ["-sample", "2x2", "-quality", "3"],
            "gray_rst_opt": ["-grayscale", "-restart", "2B", "-optimize"],
        }
        for name, opts in variants.items():
            jpg = os.path.join(out, "t_%dx%d_%s.jpg" % (w, h, name))
            subprocess.run(["cjpeg", "-dct", "int"] + opts + ["-outfile", jpg, src], check=True)
            cases.append(jpg)
    print("\n".join(cases))

main()

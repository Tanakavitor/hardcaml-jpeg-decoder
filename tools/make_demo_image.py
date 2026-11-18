"""Render the 320x240 demo picture (a Mandelbrot set) as a PPM. Usage: make_demo_image.py out.ppm"""
import math, sys
W, H, MAXI = 320, 240, 200
out = bytearray()
for y in range(H):
    for x in range(W):
        cr = -2.2 + 3.1 * x / W
        ci = -1.16 + 2.32 * y / H
        zr = zi = 0.0
        i = 0
        while i < MAXI and zr * zr + zi * zi < 16.0:
            zr, zi = zr * zr - zi * zi + cr, 2 * zr * zi + ci
            i += 1
        if i == MAXI:
            r, g, b = 10, 10, 30
        else:
            t = i + 1 - math.log(math.log(math.sqrt(zr * zr + zi * zi))) / math.log(2)
            r = int(127.5 * (1 + math.sin(0.16 * t + 4.0)))
            g = int(127.5 * (1 + math.sin(0.16 * t + 2.3)))
            b = int(127.5 * (1 + math.sin(0.16 * t + 1.0)))
        out += bytes((r, g, b))
with open(sys.argv[1], "wb") as f:
    f.write(b"P6\n%d %d\n255\n" % (W, H))
    f.write(out)

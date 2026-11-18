#!/usr/bin/env python3
"""Bit-exact software model of the FPGA JPEG decoder (no dependencies).

Same algorithm and the same limits as the Hardcaml core:
  - baseline / extended sequential Huffman (SOF0, SOF1), 8-bit samples
  - 1 component (grayscale) or 3 components (YCbCr) in a single interleaved scan
  - luma sampling 1x1, 2x1, 1x2, 2x2 with 1x1 chroma; box (replicating) chroma upsampling
  - libjpeg "islow" integer IDCT and libjpeg YCbCr->RGB tables
Output equals `djpeg -dct int -nosmooth`.

usage: jpeg_ref.py image.jpg [-o out.ppm]
Prints the image info and the checksum the FPGA shows on its 7-segment displays.
"""
import sys

ZIGZAG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
          41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22,
          15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55,
          62, 63]

ERRORS = {
    1: "progressive / lossless / arithmetic-coded JPEG (only baseline is supported)",
    2: "sample precision is not 8 bits",
    3: "number of components is not 1 or 3",
    4: "unsupported chroma subsampling (supported: 4:4:4, 4:2:2, 4:4:0, 4:2:0, gray)",
    5: "image uses several scans (only one interleaved scan is supported)",
    6: "invalid Huffman code (corrupt data)",
    8: "malformed DHT segment",
    9: "malformed DQT segment",
    10: "segment length < 2",
    11: "height is 0 (DNL marker not supported)",
    12: "not a JPEG file (does not start with FF D8)",
}


class DecodeError(Exception):
    def __init__(self, code):
        super().__init__("error %d: %s" % (code, ERRORS.get(code, "?")))
        self.code = code


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def idct_1d(x, rnd):
    """jidctint.c butterfly; rnd is the DESCALE rounding constant."""
    z1 = (x[2] + x[6]) * 4433
    tmp2 = z1 - x[6] * 15137
    tmp3 = z1 + x[2] * 6270
    tmp0 = ((x[0] + x[4]) << 13) + rnd
    tmp1 = ((x[0] - x[4]) << 13) + rnd
    tmp10, tmp13 = tmp0 + tmp3, tmp0 - tmp3
    tmp11, tmp12 = tmp1 + tmp2, tmp1 - tmp2
    t0, t1, t2, t3 = x[7], x[5], x[3], x[1]
    z1, z2, z3, z4 = t0 + t3, t1 + t2, t0 + t2, t1 + t3
    z5 = (z3 + z4) * 9633
    t0 *= 2446
    t1 *= 16819
    t2 *= 25172
    t3 *= 12299
    z1 *= -7373
    z2 *= -20995
    z3 = z3 * -16069 + z5
    z4 = z4 * -3196 + z5
    t0 += z1 + z3
    t1 += z2 + z4
    t2 += z2 + z3
    t3 += z1 + z4
    return [tmp10 + t3, tmp11 + t2, tmp12 + t1, tmp13 + t0,
            tmp13 - t0, tmp12 - t1, tmp11 - t2, tmp10 - t3]


def range_limit(i):
    i &= 1023
    if i < 128 or i >= 896:
        return (i + 128) & 255
    return 255 if i < 512 else 0


def idct_block(coef):
    """coef: 64 dequantised coefficients (natural order). Returns 64 samples."""
    ws = [0] * 64
    for u in range(8):
        y = idct_1d([coef[k * 8 + u] for k in range(8)], 1 << 10)
        for k in range(8):
            ws[k * 8 + u] = (y[k] >> 11) & 0xFFFFFFF   # pass 1 keeps 28 bits
    out = [0] * 64
    for r in range(8):
        y = idct_1d(ws[r * 8:r * 8 + 8], 1 << 17)
        for k in range(8):
            out[r * 8 + k] = range_limit(y[k] >> 18)
    return out


def clamp8(v):
    return 0 if v < 0 else (255 if v > 255 else v)


def ycc_to_rgb(y, cb, cr):
    cbx, crx = cb - 128, cr - 128
    r = y + ((91881 * crx + 32768) >> 16)
    g = y + ((-22554 * cbx + 32768 - 46802 * crx) >> 16)
    b = y + ((116130 * cbx + 32768) >> 16)
    return clamp8(r), clamp8(g), clamp8(b)


class BitReader:
    def __init__(self, data, pos):
        self.data, self.pos = data, pos
        self.buf, self.cnt = 0, 0
        self.marker = None          # marker found inside entropy-coded data

    def _fill(self):
        while self.cnt <= 24:
            if self.marker is not None or self.pos >= len(self.data):
                return
            b = self.data[self.pos]
            self.pos += 1
            if b == 0xFF:
                while self.pos < len(self.data) and self.data[self.pos] == 0xFF:
                    self.pos += 1
                nxt = self.data[self.pos] if self.pos < len(self.data) else 0xD9
                self.pos += 1
                if nxt != 0:
                    self.marker = nxt
                    return
            self.buf = (self.buf << 8) | b
            self.cnt += 8

    def peek(self, n):
        self._fill()
        if self.cnt >= n:
            return (self.buf >> (self.cnt - n)) & ((1 << n) - 1)
        return (self.buf << (n - self.cnt)) & ((1 << n) - 1)   # zeros after a marker

    def skip(self, n):
        if n >= self.cnt:
            self.buf, self.cnt = 0, 0
        else:
            self.cnt -= n
            self.buf &= (1 << self.cnt) - 1

    def get(self, n):
        v = self.peek(n)
        self.skip(n)
        return v

    def restart(self):
        """Discard the rest of the current byte and expect an RSTn marker."""
        self.buf, self.cnt = 0, 0
        while self.marker is None and self.pos < len(self.data):
            self._fill()
            self.buf, self.cnt = 0, 0
        m, self.marker = self.marker, None
        return m


def build_huffman(bits, vals):
    """Return list over code lengths 1..16 of (maxp1, mincode, valptr)."""
    table, code, k = [], 0, 0
    for n in bits:
        table.append((code + n, code, k))
        code = (code + n) << 1
        k += n
    return (table, vals)


def huff_decode(br, tbl):
    table, vals = tbl
    word = br.peek(16)
    for length in range(1, 17):
        code = word >> (16 - length)
        maxp1, mincode, valptr = table[length - 1]
        if code < maxp1:
            br.skip(length)
            return vals[(valptr + code - mincode) & 0xFF]
    raise DecodeError(6)


def extend(v, s):
    if s == 0:
        return 0
    return v if v >= (1 << (s - 1)) else v - (1 << s) + 1


def decode(data):
    """Returns (width, height, components, rgb bytearray)."""
    if not data.startswith(b"\xff\xd8"):
        raise DecodeError(12)
    pos = 2
    qt = [[0] * 64 for _ in range(4)]
    ht = {}
    ri = 0
    frame = None
    rgb = None

    def u16(p):
        return (data[p] << 8) | data[p + 1]

    while True:
        # find the next marker
        while pos < len(data) and data[pos] != 0xFF:
            pos += 1
        while pos < len(data) and data[pos] == 0xFF:
            pos += 1
        if pos >= len(data):
            raise ValueError("unexpected end of file (no EOI)")
        m = data[pos]
        pos += 1
        if m == 0xD8 or 0xD0 <= m <= 0xD7 or m == 0x01:
            continue
        if m == 0xD9:
            if rgb is None:
                raise ValueError("EOI before image data")
            return frame["w"], frame["h"], frame["nf"], rgb
        if m in (0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            raise DecodeError(1)
        length = u16(pos)
        if length < 2:
            raise DecodeError(10)
        seg = data[pos + 2:pos + length]
        pos += length
        if m in (0xC0, 0xC1):
            if seg[0] != 8:
                raise DecodeError(2)
            h, w, nf = (seg[1] << 8) | seg[2], (seg[3] << 8) | seg[4], seg[5]
            comps = [(seg[6 + 3 * c], seg[7 + 3 * c] >> 4, seg[7 + 3 * c] & 15, seg[8 + 3 * c] & 3)
                     for c in range(min(nf, 3))]
            if nf not in (1, 3):
                raise DecodeError(3)
            if nf == 3 and not (comps[0][1] in (1, 2) and comps[0][2] in (1, 2)
                                and all(c[1] == 1 and c[2] == 1 for c in comps[1:])):
                raise DecodeError(4)
            if w == 0 or h == 0:
                raise DecodeError(11)
            frame = {"w": w, "h": h, "nf": nf, "comps": comps,
                     "h2": nf == 3 and comps[0][1] == 2, "v2": nf == 3 and comps[0][2] == 2}
        elif m == 0xC4:
            p = 0
            while p < len(seg):
                tc_th = seg[p]
                if tc_th & 0xEC:
                    raise DecodeError(8)
                bits = list(seg[p + 1:p + 17])
                total = sum(bits)
                if total > 256:
                    raise DecodeError(8)
                vals = list(seg[p + 17:p + 17 + total])
                ht[(tc_th >> 4, tc_th & 3)] = build_huffman(bits, vals)
                p += 17 + total
        elif m == 0xDB:
            p = 0
            while p < len(seg):
                pq_tq = seg[p]
                if pq_tq & 0xEC:
                    raise DecodeError(9)
                pq, tq = pq_tq >> 4, pq_tq & 3
                p += 1
                for k in range(64):
                    if pq:
                        qt[tq][k] = (seg[p] << 8) | seg[p + 1]
                        p += 2
                    else:
                        qt[tq][k] = seg[p]
                        p += 1
        elif m == 0xDD:
            ri = (seg[0] << 8) | seg[1]
        elif m == 0xDA:
            if frame is None:
                raise DecodeError(5)
            ns = seg[0]
            ids = [c[0] for c in frame["comps"]]
            scomps = []
            for j in range(ns):
                cid, tdta = seg[1 + 2 * j], seg[2 + 2 * j]
                if cid not in ids or tdta & 0xCC:
                    raise DecodeError(5)
                scomps.append((ids.index(cid), tdta >> 4, tdta & 3))
            if ns != frame["nf"] or len({c[0] for c in scomps}) != ns:
                raise DecodeError(5)
            rgb, pos = decode_scan(data, pos, frame, scomps, qt, ht, ri)
        # any other marker: segment skipped


def decode_scan(data, pos, frame, scomps, qt, ht, ri):
    w, h, nf = frame["w"], frame["h"], frame["nf"]
    h2, v2 = frame["h2"], frame["v2"]
    mcu_w, mcu_h = (16 if h2 else 8), (16 if v2 else 8)
    mcus_x, mcus_y = (w + mcu_w - 1) // mcu_w, (h + mcu_h - 1) // mcu_h
    rgb = bytearray(w * h * 3)
    br = BitReader(data, pos)
    pred = [0, 0, 0]
    left = ri
    for my in range(mcus_y):
        for mx in range(mcus_x):
            ybuf = [0] * 256
            cbuf = [[0] * 64, [0] * 64, [0] * 64]
            for j, (fc, td, ta) in enumerate(scomps):
                nh = 2 if (fc == 0 and h2) else 1
                nv = 2 if (fc == 0 and v2) else 1
                q = qt[frame["comps"][fc][3]]
                dc_tbl, ac_tbl = ht.get((0, td)), ht.get((1, ta))
                for bv in range(nv):
                    for bh in range(nh):
                        coef = [0] * 64
                        if dc_tbl is None:
                            raise DecodeError(6)
                        s = huff_decode(br, dc_tbl) & 15
                        pred[j] = s16(pred[j] + extend(br.get(s), s))
                        coef[0] = s32(pred[j] * q[0])
                        k = 1
                        while k < 64:
                            if ac_tbl is None:
                                raise DecodeError(6)
                            rs = huff_decode(br, ac_tbl)
                            r, s = rs >> 4, rs & 15
                            if s == 0:
                                if r != 15:
                                    break
                                k += 16
                                continue
                            k += r
                            kq = min(k, 63)
                            coef[ZIGZAG[kq]] = s32(s16(extend(br.get(s), s)) * q[kq])
                            k += 1
                        samples = idct_block(coef)
                        if fc == 0:
                            for r_ in range(8):
                                for c_ in range(8):
                                    ybuf[(bv * 8 + r_) * 16 + bh * 8 + c_] = samples[r_ * 8 + c_]
                        else:
                            cbuf[fc] = samples
            for py in range(mcu_h):
                yy = my * mcu_h + py
                if yy >= h:
                    break
                for px in range(mcu_w):
                    xx = mx * mcu_w + px
                    if xx >= w:
                        break
                    yv = ybuf[py * 16 + px]
                    o = (yy * w + xx) * 3
                    if nf == 1:
                        rgb[o] = rgb[o + 1] = rgb[o + 2] = yv
                    else:
                        ci = ((py >> 1) if v2 else py) * 8 + ((px >> 1) if h2 else px)
                        rgb[o:o + 3] = bytes(ycc_to_rgb(yv, cbuf[1][ci], cbuf[2][ci]))
            last = mx == mcus_x - 1 and my == mcus_y - 1
            if ri and not last:
                left -= 1
                if left == 0:
                    left = ri
                    m = br.restart()
                    if m is None or not (0xD0 <= m <= 0xD7):
                        raise ValueError("expected RST marker")
                    pred = [0, 0, 0]
    # resume header parsing after the entropy-coded data
    end = br.pos
    if br.marker is not None:
        end = br.pos - 2
    return rgb, end


def checksum(w, h, rgb):
    """The FPGA self-check value: sum (2*idx+1) * (R | G<<8 | B<<16) mod 2^32."""
    acc = 0
    for idx in range(w * h):
        o = idx * 3
        acc += (2 * idx + 1) * (rgb[o] | (rgb[o + 1] << 8) | (rgb[o + 2] << 16))
    return acc & 0xFFFFFFFF


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    out = None
    if "-o" in args:
        i = args.index("-o")
        out = args[i + 1]
        del args[i:i + 2]
    with open(args[0], "rb") as f:
        data = f.read()
    try:
        w, h, nf, rgb = decode(data)
    except DecodeError as e:
        print("%s: NOT SUPPORTED - %s" % (args[0], e))
        sys.exit(2)
    print("%s: %dx%d, %s, checksum %08X" % (args[0], w, h, "YCbCr" if nf == 3 else "grayscale",
                                            checksum(w, h, rgb)))
    if out:
        with open(out, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (w, h))
            f.write(rgb)


if __name__ == "__main__":
    main()

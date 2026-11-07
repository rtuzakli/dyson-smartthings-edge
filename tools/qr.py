"""Minimal QR code encoder (stdlib only) for showing the MQTT password on a terminal.

Supports what the tool needs: byte mode, version 5, error correction level L (up to 106 bytes;
a Dyson password is 88). Follows ISO/IEC 18004 and Project Nayuki's reference implementation;
mask 0 is used throughout (any mask gives a valid code).
"""

VERSION, SIZE = 5, 37
DATA_CODEWORDS, ECC_CODEWORDS = 108, 26  # version 5-L: one block
CAPACITY_BYTES = 106
ALIGNMENT_CENTERS = (6, 30)
FORMAT_ECC_L = 1


def _gf_mul(x, y):
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _rs_divisor(degree):
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = _gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = _gf_mul(root, 0x02)
    return result


def _rs_remainder(data, divisor):
    result = [0] * len(divisor)
    for b in data:
        factor = b ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(divisor):
            result[i] ^= _gf_mul(coef, factor)
    return result


def _codewords(payload):
    if len(payload) > CAPACITY_BYTES:
        raise ValueError(f"QR payload too long: {len(payload)} > {CAPACITY_BYTES} bytes")
    bits = [0, 1, 0, 0]  # byte mode
    bits += [(len(payload) >> i) & 1 for i in reversed(range(8))]
    for b in payload:
        bits += [(b >> i) & 1 for i in reversed(range(8))]
    capacity = DATA_CODEWORDS * 8
    bits += [0] * min(4, capacity - len(bits))
    bits += [0] * (-len(bits) % 8)
    data = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(data) < DATA_CODEWORDS:
        data.append(pad)
        pad ^= 0xEC ^ 0x11
    return data + _rs_remainder(data, _rs_divisor(ECC_CODEWORDS))


def encode(text):
    """Return the QR matrix (list of rows of bools, True = dark) for text."""
    modules = [[False] * SIZE for _ in range(SIZE)]
    function = [[False] * SIZE for _ in range(SIZE)]

    def setf(x, y, dark):
        modules[y][x] = dark
        function[y][x] = True

    for i in range(SIZE):  # timing patterns
        setf(6, i, i % 2 == 0)
        setf(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (SIZE - 4, 3), (3, SIZE - 4)):  # finders with separators
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < SIZE and 0 <= y < SIZE:
                    setf(x, y, max(abs(dx), abs(dy)) not in (2, 4))
    last = len(ALIGNMENT_CENTERS) - 1
    for i, cx in enumerate(ALIGNMENT_CENTERS):
        for j, cy in enumerate(ALIGNMENT_CENTERS):
            if (i, j) in ((0, 0), (0, last), (last, 0)):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    setf(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)

    mask = 0
    data = FORMAT_ECC_L << 3 | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    fmt = (data << 10 | rem) ^ 0x5412
    bit = lambda i: (fmt >> i) & 1 == 1  # noqa: E731
    for i in range(6):
        setf(8, i, bit(i))
    setf(8, 7, bit(6))
    setf(8, 8, bit(7))
    setf(7, 8, bit(8))
    for i in range(9, 15):
        setf(14 - i, 8, bit(i))
    for i in range(8):
        setf(SIZE - 1 - i, 8, bit(i))
    for i in range(8, 15):
        setf(8, SIZE - 15 + i, bit(i))
    setf(8, SIZE - 8, True)  # dark module

    codewords = _codewords(text.encode("utf-8"))
    i, right = 0, SIZE - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(SIZE):
            for j in range(2):
                x = right - j
                upward = (right + 1) & 2 == 0
                y = SIZE - 1 - vert if upward else vert
                if not function[y][x] and i < len(codewords) * 8:
                    modules[y][x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1 == 1
                    i += 1
        right -= 2
    for y in range(SIZE):
        for x in range(SIZE):
            if not function[y][x] and (x + y) % 2 == 0:
                modules[y][x] = not modules[y][x]
    return modules


def to_terminal(matrix, dark_background=True, quiet=2):
    """Render with half blocks. On a dark terminal the light modules are drawn, so the code shows
    the right way round (dark modules dark)."""
    n = len(matrix) + 2 * quiet
    light = [[True] * n for _ in range(n)]
    for y, row in enumerate(matrix):
        for x, dark in enumerate(row):
            light[y + quiet][x + quiet] = not dark
    draw = light if dark_background else [[not v for v in row] for row in light]
    if n % 2:
        draw.append([dark_background] * n)
    lines = []
    for y in range(0, len(draw), 2):
        top, bottom = draw[y], draw[y + 1]
        lines.append("".join("█" if t and b else "▀" if t else "▄" if b else " " for t, b in zip(top, bottom)))
    return "\n".join(lines)


def to_png(matrix, path, scale=8, quiet=4):
    """Write a black-on-white PNG (for tests and for showing the code on another screen)."""
    import struct
    import zlib
    n = (len(matrix) + 2 * quiet) * scale
    rows = []
    for y in range(n):
        my = y // scale - quiet
        line = bytearray([0])
        for x in range(n):
            mx = x // scale - quiet
            dark = 0 <= my < len(matrix) and 0 <= mx < len(matrix) and matrix[my][mx]
            line.append(0 if dark else 255)
        rows.append(bytes(line))

    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", n, n, 8, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))

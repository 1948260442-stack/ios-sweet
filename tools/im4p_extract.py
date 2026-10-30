#!/usr/bin/env python3
"""Extract the payload of an .im4p (or DER-wrapped .im4p) to a raw file.

The iPhone X device tree ships as `DeviceTree.d22ap.im4p`, which is an ASN.1 DER
structure:

    SEQUENCE {
        IA5String  "IM4P"
        IA5String  "dtre"
        IA5String  description
        OCTET STRING payload        <- the matching ADT
        SEQUENCE { ... }            (signature-ish trailer, ignore)
    }

`ipsw img4 im4p extract` does the same thing; this avoids the Go dependency.

  im4p_extract.py DeviceTree.d22ap.im4p out.adt
"""
import sys


def tlv(buf, i):
    tag = buf[i]
    i += 1
    length = buf[i]
    i += 1
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(buf[i:i + n], 'big')
        i += n
    return tag, buf[i:i + length], i + length


def payload_of(data):
    # DER-wrapped form (what Apple ships inside an IPSW).
    if data[:1] == b'\x30':
        tag, seq, _ = tlv(data, 0)
        if tag == 0x30:
            i, octets = 0, []
            while i < len(seq):
                t, v, i = tlv(seq, i)
                if t == 0x04:
                    octets.append(v)
            if octets:
                return octets[0]
    # Bare IM4P: "IM4P" <len> <type> <desc_len> <desc> <data_len> <data>.
    if data[:4] == b'IM4P':
        i = 8
        i += 4                                     # type ("dtre")
        dlen = int.from_bytes(data[i:i + 4], 'big')
        i += 4 + dlen
        rest = len(data) - i
        v4 = int.from_bytes(data[i:i + 4], 'big')
        if v4 == rest - 4:
            i += 4
        else:
            i += 3
        return data[i:]
    raise SystemExit('unknown container: not DER/IM4P')


def maybe_decompress(payload):
    """Newer device trees are LZFSE-compressed ("bvx2" magic)."""
    if payload[:4] != b'bvx2':
        return payload
    try:
        import lzfse
    except ImportError:
        raise SystemExit('payload is lzfse-compressed: pip install lzfse')
    return lzfse.decompress(payload)


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    data = open(argv[1], 'rb').read()
    payload = maybe_decompress(payload_of(data))
    open(argv[2], 'wb').write(payload)
    print('%s: %d bytes -> %s (%d bytes, magic %s)'
          % (argv[1], len(data), argv[2], len(payload), payload[:4].hex()))


if __name__ == '__main__':
    main(sys.argv)

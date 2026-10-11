#!/usr/bin/env python3
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "upstream").resolve()


def replace(path, pairs, required=True):
    p = root / path
    if not p.exists():
        print(f"missing file: {p}")
        if required:
            sys.exit(1)
        return
    text = p.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in text:
            print(f"pattern not found in {path}: {old!r}")
            if required:
                sys.exit(1)
            continue
        text = text.replace(old, new)
    p.write_text(text, encoding="utf-8")
    print(f"patched {path}")


replace(
    "core/internal/protocol/http.go",
    [
        ('RequestHeaderAuth        = "Hysteria-Auth"', 'RequestHeaderAuth        = "Zivpnudp-Auth"'),
        ('ResponseHeaderUDPEnabled = "Hysteria-UDP"', 'ResponseHeaderUDPEnabled = "Zivpnudp-UDP"'),
        ('CommonHeaderCCRX         = "Hysteria-CC-RX"', 'CommonHeaderCCRX         = "Zivpnudp-CC-RX"'),
        ('CommonHeaderPadding      = "Hysteria-Padding"', 'CommonHeaderPadding      = "Zivpnudp-Padding"'),
    ],
)

replace(
    "core/server/server.go",
    [
        (
            "r.Method == http.MethodPost && r.Host == protocol.URLHost && r.URL.Path == protocol.URLPath",
            'r.Method == http.MethodPost && (r.URL.Path == protocol.URLPath || r.Header.Get(protocol.RequestHeaderAuth) != "")',
        ),
    ],
    required=False,
)

print("compat patch applied")

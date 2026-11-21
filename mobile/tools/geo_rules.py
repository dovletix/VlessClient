#!/usr/bin/env python3
"""Turns Xray's geoip.dat / geosite.dat into the sing-box rule-sets the phone app bundles.

The same categories as the Windows app (Core/GeoDat.cs, Settings.cs):
  geoip-ru.json            geoip "ru"
  geosite-ru.json          geosite category-ru, tld-ru, available-only-in-ru, yandex, vk, mailru
  geosite-ru-blocked.json  geosite blocked-in-ru
Output is sing-box "source" rule-sets (version 3); CI compiles them to .srs with `sing-box rule-set compile`.

usage: geo_rules.py <geoip.dat> <geosite.dat> <out dir>
"""
import ipaddress
import json
import os
import sys

GEOIP = ["ru"]
GEOSITE = ["category-ru", "tld-ru", "available-only-in-ru", "yandex", "vk", "mailru"]
BLOCKED = ["blocked-in-ru"]


def varint(b, p):
    r = s = 0
    while True:
        x = b[p]
        p += 1
        r |= (x & 0x7F) << s
        if x < 0x80:
            return r, p
        s += 7


def skip(b, p, wt):
    if wt == 0:
        return varint(b, p)[1]
    if wt == 1:
        return p + 8
    if wt == 2:
        n, p = varint(b, p)
        return p + n
    if wt == 5:
        return p + 4
    raise ValueError("unsupported wire type %d" % wt)


def entries(path, codes):
    """Yields the raw bytes of field 2 (CIDR / Domain messages) of every entry whose code is in codes."""
    want = {c.lower() for c in codes}
    b = open(path, "rb").read()
    p = 0
    while p < len(b):
        tag, p = varint(b, p)
        wt = tag & 7
        if tag >> 3 != 1 or wt != 2:
            p = skip(b, p, wt)
            continue
        n, p = varint(b, p)
        end = p + n
        q = p
        match = False
        while q < end:
            t, q = varint(b, q)
            w, f = t & 7, t >> 3
            if f == 1 and w == 2:
                l, q = varint(b, q)
                match = b[q:q + l].decode("utf-8").lower() in want
                q += l
                if not match:
                    break
            elif f == 2 and w == 2 and match:
                l, q = varint(b, q)
                yield b[q:q + l]
                q += l
            else:
                q = skip(b, q, w)
        p = end


def fields(m):
    p = 0
    while p < len(m):
        t, p = varint(m, p)
        w, f = t & 7, t >> 3
        if w == 0:
            v, p = varint(m, p)
            yield f, v
        elif w == 2:
            l, p = varint(m, p)
            yield f, m[p:p + l]
            p += l
        else:
            p = skip(m, p, w)


def cidrs(path, codes):
    out = []
    for m in entries(path, codes):
        ip, prefix = None, 0
        for f, v in fields(m):
            if f == 1 and isinstance(v, bytes):
                ip = v
            elif f == 2 and isinstance(v, int):
                prefix = v
        if ip is not None and len(ip) in (4, 16):
            out.append("%s/%d" % (ipaddress.ip_address(ip), prefix))
    return out


def domains(path, codes):
    dom, suf, kw, rx = [], [], [], []
    for m in entries(path, codes):
        typ, val = 0, None
        for f, v in fields(m):
            if f == 1 and isinstance(v, int):
                typ = v
            elif f == 2 and isinstance(v, bytes):
                val = v.decode("utf-8")
        if not val:
            continue
        if typ == 0:
            kw.append(val)
        elif typ == 1:
            rx.append(val)
        elif typ == 2:
            dom.append(val)
            suf.append("." + val)
        else:
            dom.append(val)
    rule = {}
    if dom:
        rule["domain"] = dom
    if suf:
        rule["domain_suffix"] = suf
    if kw:
        rule["domain_keyword"] = kw
    if rx:
        rule["domain_regex"] = rx
    return rule


def write(out, name, rule):
    with open(os.path.join(out, name + ".json"), "w", encoding="utf-8") as f:
        json.dump({"version": 3, "rules": [rule] if rule else []}, f, ensure_ascii=False)


def main():
    geoip, geosite, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    ip = cidrs(geoip, GEOIP)
    site = domains(geosite, GEOSITE)
    blocked = domains(geosite, BLOCKED)
    write(out, "geoip-ru", {"ip_cidr": ip} if ip else None)
    write(out, "geosite-ru", site)
    write(out, "geosite-ru-blocked", blocked)
    n = lambda r: sum(len(v) for k, v in r.items() if k != "domain_suffix")
    print("geo: %d RU networks, %d RU domains, %d blocked-in-RU domains" % (len(ip), n(site), n(blocked)))
    if not ip or not site:
        sys.exit("geo: the databases have no Russian data, refusing to ship empty rule-sets")


if __name__ == "__main__":
    main()

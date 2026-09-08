#!/usr/bin/env python3
"""Classify mitm URL dump for apk-domain-batch.

Prints JSON for the Agent (does NOT write CSV). Agent chooses main/valuable
domains and evidence IDs, then calls model_ui.ps1 record.

Usage:
  python classify_capture.py <urls.txt>
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter, OrderedDict
from urllib.parse import urlparse, parse_qs, unquote

NOISE_SUB = (
    "google", "googleapis", "gstatic", "firebase", "crashlytics", "facebook",
    "bugly", "umeng", "jpush", "igexin", "getui", "sentry", "baidu.com",
    "amap.com", "cloudflare", "adobe.com", "mozilla.org", "microsoft.com",
    "publicsuffix", "unicode.org", "slf4j", "w3.org", "apache.org",
    "doubleclick", "applovin", "adjust.com", "appsflyer", "ip.sb",
    "doh.pub", "dns-query", "openinstall", "deepinstall",
)

# host pattern -> label
VALUABLE_HOST_RULES = [
    (re.compile(r"\.oss-accelerate\.aliyuncs\.com$", re.I), "aliyun-oss-accelerate"),
    (re.compile(r"\.oss-[a-z0-9-]+\.aliyuncs\.com$", re.I), "aliyun-oss"),
    (re.compile(r"\.aliyuncs\.com$", re.I), "aliyun"),
    (re.compile(r"\.amazonaws\.com$", re.I), "aws-s3"),
    (re.compile(r"\.s3\.[a-z0-9.-]+\.amazonaws\.com$", re.I), "aws-s3"),
    (re.compile(r"\.zos\.ctyun\.cn$", re.I), "ctyun-zos"),
    (re.compile(r"\.myqcloud\.com$", re.I), "qcloud-cos"),
    (re.compile(r"\.cos\.[a-z0-9.-]+\.myqcloud\.com$", re.I), "qcloud-cos"),
    (re.compile(r"\.cloudfront\.net$", re.I), "cloudfront"),
]


def is_noise_host(h: str) -> bool:
    hl = h.lower()
    return any(n in hl for n in NOISE_SUB)


def classify_host(h: str) -> str | None:
    for rx, label in VALUABLE_HOST_RULES:
        if rx.search(h):
            return label
    return None


def extract_ids(url: str) -> list[str]:
    ids: list[str] = []
    try:
        u = urlparse(url)
    except Exception:
        return ids
    host = (u.hostname or "").lower()
    path = unquote(u.path or "")
    qs = parse_qs(u.query or "")

    # OSS / S3 style: bucket in subdomain
    m = re.match(
        r"^([a-z0-9][a-z0-9-]{2,62})\.(oss(?:-accelerate)?(?:-[a-z0-9-]+)?\.aliyuncs\.com)$",
        host,
        re.I,
    )
    if m:
        ids.append(f"aliyun_bucket={m.group(1)}")
        ids.append(f"aliyun_endpoint={m.group(2)}")

    m = re.match(r"^([a-z0-9][a-z0-9.-]+)\.s3\.([a-z0-9-]+)\.amazonaws\.com$", host, re.I)
    if m:
        ids.append(f"s3_bucket={m.group(1)}")
        ids.append(f"s3_region={m.group(2)}")
    m = re.match(r"^([a-z0-9][a-z0-9.-]+)\.s3\.amazonaws\.com$", host, re.I)
    if m:
        ids.append(f"s3_bucket={m.group(1)}")

    m = re.match(r"^([a-f0-9]{8,})\.([a-z0-9-]+\.zos\.ctyun\.cn)$", host, re.I)
    if m:
        ids.append(f"ctyun_bucket={m.group(1)}")
        ids.append(f"ctyun_endpoint={m.group(2)}")

    # object key / file id in path
    for part in path.strip("/").split("/"):
        if not part:
            continue
        if re.fullmatch(r"[a-f0-9]{16,}\.(dat|bin|txt|json|apk|zip)", part, re.I):
            ids.append(f"object={part}")
        elif re.fullmatch(r"[a-f0-9]{32}", part, re.I):
            ids.append(f"path_md5={part}")
        elif re.fullmatch(r"[0-9a-f-]{36}", part, re.I):
            ids.append(f"uuid={part}")

    # DoH / DNS-over-HTTPS queried names (often real C2 / business)
    for key in ("name", "dns"):
        if key in qs and qs[key]:
            ids.append(f"doh_name={qs[key][0][:120]}")

    # deepinstall / openinstall app codes in host or path
    m = re.search(r"api2-([a-z0-9]+)\.", host, re.I)
    if m:
        ids.append(f"deepinstall_app={m.group(1)}")
    m = re.search(r"/android/([a-z0-9]+)/", path, re.I)
    if m:
        ids.append(f"install_appcode={m.group(1)}")

    return ids


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    if len(sys.argv) < 2:
        print("usage: classify_capture.py <urls.txt>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
    except OSError as e:
        print(json.dumps({"error": str(e)}))
        return 1

    host_cnt: Counter[str] = Counter()
    valuable: OrderedDict[str, dict] = OrderedDict()
    evidence: OrderedDict[str, None] = OrderedDict()
    business: Counter[str] = Counter()
    samples: dict[str, list[str]] = {}

    url_re = re.compile(r"https?://[^\s]+", re.I)
    for line in lines:
        m = url_re.search(line)
        if not m:
            continue
        url = m.group(0).rstrip("),;\"'")
        try:
            host = (urlparse(url).hostname or "").lower()
        except Exception:
            continue
        if not host or re.fullmatch(r"\d+\.\d+\.\d+\.\d+", host):
            continue
        host_cnt[host] += 1
        samples.setdefault(host, [])
        if len(samples[host]) < 3:
            samples[host].append(url)

        label = classify_host(host)
        if label:
            if host not in valuable:
                valuable[host] = {"label": label, "count": 0, "urls": []}
            valuable[host]["count"] += 1
            if len(valuable[host]["urls"]) < 3:
                valuable[host]["urls"].append(url)
        elif not is_noise_host(host):
            business[host] += 1

        for eid in extract_ids(url):
            evidence[eid] = None

    # suggest main: prefer non-noise business by count, else first valuable
    main = "(none)"
    if business:
        main = business.most_common(1)[0][0]
    elif valuable:
        main = next(iter(valuable.keys()))

    out = {
        "urls_file": path,
        "line_count": len(lines),
        "suggested_main": main,
        "business_hosts": [{"host": h, "count": c, "sample_urls": samples.get(h, [])}
                           for h, c in business.most_common(20)],
        "valuable_hosts": [
            {"host": h, "label": v["label"], "count": v["count"], "sample_urls": v["urls"]}
            for h, v in valuable.items()
        ],
        "evidence_ids": list(evidence.keys())[:80],
        "all_hosts": [f"{h}({c})" for h, c in host_cnt.most_common(40)],
        "noise_skipped_hint": "bugly/umeng/jpush/ip.sb/doh/openinstall 等已降权",
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

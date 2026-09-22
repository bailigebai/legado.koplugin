"""Build a separate, minimal four-source sample from the user's 260114 collection.

The original input stays unchanged. No login, headers, or JavaScript is copied.
See docs/live-sources-2026-09-08.md for the observed rule corrections.
"""

import argparse
import json
from pathlib import Path
from urllib.parse import urldefrag


ADAPTATIONS = {
    "https://www.yingyuxiaoshuo.com": {},
    "http://www.yetianlian.net": {
        # ponytail: these two tested templates have 12 recent links before the main catalog.
        # Recheck the source selector when the site's catalog layout changes.
        "ruleToc": {"chapterList": ".listmain dd:nth-child(n+15)"},
        "ruleContent": {"nextContentUrl": ""},
    },
    "https://so.ihuaben.com": {
        "ruleToc": {"chapterList": "#hbListChaptersWrap a", "chapterName": "text",
                    "chapterUrl": "href", "nextTocUrl": ""},
    },
    "http://www.rulianshi.org": {
        "ruleToc": {"chapterList": ".listmain dd:nth-child(n+15)"},
    },
}


def adapt(collection):
    sources = {urldefrag(source["bookSourceUrl"])[0]: source for source in collection}
    output = []
    for url, rules in ADAPTATIONS.items():
        source = sources[url]
        item = {key: source[key] for key in (
            "bookSourceUrl", "bookSourceName", "bookSourceType", "searchUrl",
        ) if key in source}
        for field in ("ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent"):
            item[field] = {key: value for key, value in source.get(field, {}).items() if value}
            item[field].update(rules.get(field, {}))
        item.update(enabled=True, enabledExplore=False, bookSourceGroup="KOReader live sample")
        output.append(item)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-json", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = adapt(json.loads(args.source_json.read_text(encoding="utf-8-sig")))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as destination:
        json.dump(result, destination, ensure_ascii=False, indent=2)
        destination.write("\n")
    print(f"Created {len(result)} adapted sources: {args.output}")


if __name__ == "__main__":
    main()

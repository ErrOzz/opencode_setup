#!/usr/bin/env python3
"""Read-only helper for the RouterAI model list. It never writes any config file.

Commands:
  search  <words>   compact table of matching models
  show    <id>      full details of one model (prices, modalities, parameters, description)
  snippet <id> ...  ready-to-paste OpenCode model entries

Options:
  --output N   output limit for new models (default 32000)
  --no-pro     do not add the "pro" variant even if a -pro sibling exists
  --url URL    models endpoint (default: RouterAI public API)

Standard library only, Python 3.8+.
"""

import argparse
import json
import math
import sys
import urllib.request
from datetime import datetime, timezone

# ---- Settings -------------------------------------------------------------
DEFAULT_URL = "https://routerai.ru/api/v1/models"
# Input types added to every model, even if the API does not list them
ALWAYS_INPUT = ["file"]
# Order of input types in the snippet; unknown types go last
INPUT_ORDER = ["text", "image", "file", "audio", "video"]
# Effort levels assumed when the API lists reasoning_effort (the API does not report the levels)
EFFORT_LEVELS = ["low", "medium", "high"]
# Suffix of the sibling model that is the same model with reasoning mode "pro"
PRO_SUFFIX = "-pro"
# Part of the snippet that marks the variant; the API does not carry it
PRO_VARIANT = '{ "id": "pro", "body": { "reasoning": { "mode": "pro" } } }'
# Vendors whose models need compatibility.cacheFormat to enable request caching
# through the OpenAI-compatible gateway (matched by the id prefix, "~" aliases included)
CACHE_FORMAT_BY_VENDOR = {"anthropic": "anthropic"}
MAX_ROWS = 40
DOT = "\u00b7"  # middle dot
RUBLE = "\u20bd"  # ruble sign


# ---- Helpers --------------------------------------------------------------
def get_models(url):
    # Some sites reject the default Python user agent
    req = urllib.request.Request(url, headers={"User-Agent": "routerai-skill/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body).get("data", [])


def price_per_million(per_token):
    return float(per_token or 0) * 1_000_000


def format_price(value):
    # Below 10 keep one decimal, otherwise round half away from zero to an integer
    if value < 10:
        text = "%.1f" % (math.floor(value * 10 + 0.5) / 10)
        return text[:-2] if text.endswith(".0") else text
    return str(int(math.floor(value + 0.5)))


def price_text(model):
    pricing = model.get("pricing") or {}
    return "%s/%s" % (
        format_price(price_per_million(pricing.get("prompt"))),
        format_price(price_per_million(pricing.get("completion"))),
    )


def short_name(model):
    name = model.get("name")
    if not name:
        return model["id"]
    # Drop the vendor prefix such as "OpenAI: "
    head, sep, tail = name.partition(":")
    if sep and 0 < len(head) <= 30 and tail.startswith(" ") and tail.strip():
        return tail.strip()
    return name


def input_modalities(model):
    return list((model.get("architecture") or {}).get("input_modalities") or [])


def output_modalities(model):
    return list((model.get("architecture") or {}).get("output_modalities") or [])


def input_types(model):
    types = []
    for t in input_modalities(model) + ALWAYS_INPUT:
        if t and t not in types:
            types.append(t)
    known = [t for t in INPUT_ORDER if t in types]
    other = [t for t in types if t not in INPUT_ORDER]
    return known + other


def json_str(value):
    return json.dumps(value, ensure_ascii=False)


def json_array(items):
    return "[" + ", ".join(json_str(i) for i in items) + "]"


def find_model(models, model_id):
    wanted = model_id.lower()
    for m in models:
        if m["id"].lower() == wanted:
            return m
    return None


def pro_sibling(model, models):
    return find_model(models, model["id"] + PRO_SUFFIX)


def pro_base(model, models):
    if model["id"].endswith(PRO_SUFFIX):
        return find_model(models, model["id"][: -len(PRO_SUFFIX)])
    return None


def format_date(model):
    created = model.get("created")
    if not created:
        return "-"
    return datetime.fromtimestamp(int(created), tz=timezone.utc).strftime("%Y-%m-%d")


def warn(text):
    # Notes go to stderr so they are never pasted into the config by accident
    print("WARNING: " + text, file=sys.stderr)


# ---- Commands -------------------------------------------------------------
def new_snippet(model, models, output_limit, no_pro):
    params = model.get("supported_parameters") or []
    has_tools = "tools" in params
    has_reasoning = "reasoning" in params
    has_effort = "reasoning_effort" in params

    outputs = output_modalities(model) or ["text"]
    name = "%s %s %s %s" % (short_name(model), DOT, price_text(model), RUBLE)

    # The "pro" variant is added only when a sibling model "<id>-pro" exists in the API list
    pro = None if no_pro else pro_sibling(model, models)

    caps = '    "tools": %s, "input": %s, "output": %s' % (
        "true" if has_tools else "false",
        json_array(input_types(model)),
        json_array(outputs),
    )

    lines = [json_str(model["id"]) + ": {", '  "name": ' + json_str(name) + ",", '  "capabilities": {']
    if has_reasoning:
        reasoning = '{ "supported": true }'
        if has_effort:
            reasoning = '{ "supported": true, "effort": %s }' % json_array(EFFORT_LEVELS)
        lines.append(caps + ",")
        lines.append('    "reasoning": ' + reasoning)
    else:
        lines.append(caps)
    lines.append("  },")
    limit = '  "limit": { "context": %d, "output": %d }' % (int(model.get("context_length") or 0), output_limit)
    # Optional blocks after "limit"; each block is a list of lines, commas are added between blocks
    blocks = []
    if pro:
        blocks.append(['  "variants": [', "    " + PRO_VARIANT, "  ]"])
    cache_format = CACHE_FORMAT_BY_VENDOR.get(model["id"].lstrip("~").split("/")[0])
    if cache_format:
        blocks.append(['  "compatibility": { "cacheFormat": %s }' % json_str(cache_format)])
    lines.append(limit + ("," if blocks else ""))
    for i, block in enumerate(blocks):
        if i < len(blocks) - 1:
            block[-1] += ","
        lines += block
    lines.append("}")

    base = pro_base(model, models)
    if base:
        warn("%s is the pro sibling of %s. Prefer the base model with the pro variant." % (model["id"], base["id"]))
    if pro:
        if price_text(model) != price_text(pro):
            warn(
                "Price differs: %s = %s, %s = %s. The pro variant bills at the base price; verify before use."
                % (model["id"], price_text(model), pro["id"], price_text(pro))
            )
        warn(
            'Variant "pro" added because %s exists. Check with "show %s" that it is the same model with reasoning mode pro.'
            % (pro["id"], pro["id"])
        )
    return "\n".join(lines)


def run_search(models, words):
    terms = [t for w in words for t in w.split()]
    hits = []
    for m in models:
        hay = ("%s %s" % (m.get("id") or "", m.get("name") or "")).lower()
        if all(t.lower() in hay for t in terms):
            hits.append(m)
    hits.sort(key=lambda m: int(m.get("created") or 0), reverse=True)

    print("%d model(s) found" % len(hits))
    if not hits:
        return
    row = "{:<40} {:>8}  {:<14} {:<20} {:<10} {}"
    print(row.format("id", "context", "in/out per 1M", "input", "created", "flags"))
    for m in hits[:MAX_ROWS]:
        params = m.get("supported_parameters") or []
        flags = []
        if "tools" in params:
            flags.append("tools")
        if "reasoning" in params:
            flags.append("reasoning")
        base = pro_base(m, models)
        if base:
            flags.append("pro-of:" + base["id"])
        elif pro_sibling(m, models):
            flags.append("has-pro")
        ctx = "%dk" % round(int(m.get("context_length") or 0) / 1000)
        print(row.format(m["id"], ctx, price_text(m), ",".join(input_modalities(m)), format_date(m), " ".join(flags)))
    if len(hits) > MAX_ROWS:
        print("... %d more, refine the query" % (len(hits) - MAX_ROWS))


def show_model(model):
    p = model.get("pricing") or {}
    print("id:          " + model["id"])
    print("name:        " + str(model.get("name")))
    print("created:     " + format_date(model))
    print("context:     " + str(model.get("context_length")))
    print("input:       " + ", ".join(input_modalities(model)))
    print("output:      " + ", ".join(output_modalities(model)))
    print(
        "price per 1M tokens (RUB): prompt %s, completion %s, cache read %s, cache write %s"
        % (
            format_price(price_per_million(p.get("prompt"))),
            format_price(price_per_million(p.get("completion"))),
            format_price(price_per_million(p.get("input_cache_read"))),
            format_price(price_per_million(p.get("input_cache_write"))),
        )
    )
    if p.get("web_search") is not None:
        print("web search:  %s per request" % p["web_search"])
    print("parameters:  " + ", ".join(model.get("supported_parameters") or []))
    print("description: " + str(model.get("description")))


# ---- Main -----------------------------------------------------------------
def main():
    # Keep UTF-8 output even on a Windows console with a legacy code page
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(description="Read-only helper for the RouterAI model list.")
    parser.add_argument("command", choices=["search", "show", "snippet"])
    parser.add_argument("query", nargs="*", help="search words, or model ids for show/snippet")
    parser.add_argument("--output", type=int, default=32000)
    parser.add_argument("--no-pro", action="store_true")
    parser.add_argument("--url", default=DEFAULT_URL)
    args = parser.parse_args()

    try:
        models = get_models(args.url)
    except Exception as exc:  # network, HTTP and JSON errors all end the run the same way
        print("Cannot read %s: %s" % (args.url, exc), file=sys.stderr)
        return 1

    if args.command == "search":
        run_search(models, args.query)
        return 0

    ids = [i for q in args.query for i in q.split()]
    if not ids:
        print("Usage: routerai.py %s <model id> [...]" % args.command, file=sys.stderr)
        return 1

    failed = False
    parts = []
    for model_id in ids:
        model = find_model(models, model_id)
        if model is None:
            print("Model not found: %s. Try: routerai.py search <words>" % model_id, file=sys.stderr)
            failed = True
            continue
        if args.command == "show":
            show_model(model)
        else:
            parts.append(new_snippet(model, models, args.output, args.no_pro))
    if parts:
        print("\n\n".join(parts))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

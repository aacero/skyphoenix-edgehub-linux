#!/usr/bin/env python3
"""Register the Xeneon Edge Pro purchase webhook on Lemon Squeezy.

This automates the part that's genuinely better as code - pointing Lemon Squeezy's
`order_created` event at your deployed mint service, with the signing secret. The
product itself (name, price, description, image, tax category) you create once in
the Lemon Squeezy dashboard: it needs human input anyway and the dashboard is the
right place for it. See docs/LICENSING.md.

Nothing is created without --apply (dry-run by default). The API key is read from
the environment, never a flag (it would land in shell history):

    export LEMONSQUEEZY_API_KEY=...            # Settings -> API in the dashboard
    export LEMONSQUEEZY_WEBHOOK_SECRET=...      # a strong random string YOU pick;
                                                # give the SAME value to the service
    python3 scripts/setup-lemonsqueezy.py \\
        --url https://your-service.example.com/webhook            # dry-run
    python3 scripts/setup-lemonsqueezy.py --url https://... --apply

The secret you pass here MUST equal the LEMONSQUEEZY_WEBHOOK_SECRET in the mint
service's environment, or every real webhook will be rejected as unsigned.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.lemonsqueezy.com/v1"


def api(path, key, method="GET", body=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {key}",
            "Accept": "application/vnd.api+json",
            "Content-Type": "application/vnd.api+json",
        },
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        sys.exit(f"Lemon Squeezy API {e.code} on {method} {path}:\n{detail}")


def main():
    ap = argparse.ArgumentParser(description="Register the Xeneon Edge Pro webhook.")
    ap.add_argument("--url", required=True, help="the deployed mint service URL (…/webhook)")
    ap.add_argument("--store", help="store id (default: your first/only store)")
    ap.add_argument("--apply", action="store_true", help="actually create it (default: dry-run)")
    args = ap.parse_args()

    key = os.environ.get("LEMONSQUEEZY_API_KEY")
    secret = os.environ.get("LEMONSQUEEZY_WEBHOOK_SECRET")
    if not key:
        sys.exit("LEMONSQUEEZY_API_KEY is not set (Dashboard → Settings → API).")
    if not secret:
        sys.exit("LEMONSQUEEZY_WEBHOOK_SECRET is not set (pick a strong random string).")

    # Verify the key + resolve the store.
    stores = api("/stores", key)["data"]
    if not stores:
        sys.exit("No stores on this account - create one in the dashboard first.")
    store_id = args.store or stores[0]["id"]
    store_name = next((s["attributes"]["name"] for s in stores if s["id"] == store_id), "?")
    print(f"Store: {store_name} (id {store_id})")

    # Already registered for this URL?
    hooks = api(f"/webhooks?filter[store_id]={store_id}", key).get("data", [])
    existing = next((h for h in hooks if h["attributes"]["url"] == args.url), None)

    payload = {
        "data": {
            "type": "webhooks",
            "attributes": {
                "url": args.url,
                "events": ["order_created"],
                "secret": secret,
            },
            "relationships": {
                "store": {"data": {"type": "stores", "id": str(store_id)}}
            },
        }
    }

    if existing:
        print(f"A webhook for {args.url} already exists (id {existing['id']}).")
        print("Events:", existing["attributes"]["events"])
        if not args.apply:
            print("\nDry-run: would UPDATE its secret + events. Re-run with --apply.")
            return
        payload["data"]["id"] = existing["id"]
        api(f"/webhooks/{existing['id']}", key, "PATCH", payload)
        print("Updated.")
        return

    if not args.apply:
        print(f"\nDry-run: would CREATE an order_created webhook → {args.url}")
        print("Re-run with --apply to create it.")
        return

    created = api("/webhooks", key, "POST", payload)
    print(f"Created webhook id {created['data']['id']} → {args.url} (order_created).")
    print("\nNext: create the 'Xeneon Edge Pro' product in the dashboard (price, "
          "description, image), and point the app's 'Get Pro' button at its URL.")


if __name__ == "__main__":
    main()

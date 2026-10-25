#!/usr/bin/env python3
"""Minimal App Store Connect API helper used by CI.

Reads ASC_KEY_ID, ASC_ISSUER_ID and the .p8 key path (ASC_KEY_PATH) from the
environment. Never prints key material.

  asc.py apps                       list apps (name, bundle id, id)
  asc.py find-app "Trivia Clash"    print bundle id of the best matching app, or nothing
  asc.py latest-build <app-id>      print the highest uploaded build number for the app
  asc.py ensure-bundle-id <id> <name>  register an iOS bundle identifier if missing
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    with open(os.environ["ASC_KEY_PATH"], "r", encoding="utf-8") as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def get(path: str, params: dict | None = None) -> dict:
    url = f"{API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def post(path: str, body: dict) -> dict:
    req = urllib.request.Request(f"{API}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def apps() -> list[dict]:
    out, data = [], get("/apps", {"limit": 200, "fields[apps]": "name,bundleId,sku"})
    for a in data.get("data", []):
        out.append({"id": a["id"], "name": a["attributes"]["name"], "bundleId": a["attributes"]["bundleId"]})
    return out


def norm(s: str) -> str:
    return "".join(ch for ch in s.lower() if ch.isalnum())


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "apps"
    if cmd == "apps":
        for a in apps():
            print(f"{a['name']}\t{a['bundleId']}\t{a['id']}")
    elif cmd == "find-app":
        want = norm(sys.argv[2])
        for a in apps():
            if want in norm(a["name"]) or want in norm(a["bundleId"]):
                print(f"{a['bundleId']}\t{a['id']}")
                return
    elif cmd == "latest-build":
        data = get("/builds", {"filter[app]": sys.argv[2], "sort": "-uploadedDate", "limit": 20,
                               "fields[builds]": "version"})
        versions = [int(b["attributes"]["version"]) for b in data.get("data", [])
                    if b["attributes"]["version"].isdigit()]
        print(max(versions) if versions else 0)
    elif cmd == "ensure-bundle-id":
        ident, name = sys.argv[2], sys.argv[3]
        found = get("/bundleIds", {"filter[identifier]": ident, "limit": 5}).get("data", [])
        if any(b["attributes"]["identifier"] == ident for b in found):
            print(f"bundle id {ident}: already registered")
            return
        post("/bundleIds", {"data": {"type": "bundleIds",
                                     "attributes": {"identifier": ident, "name": name, "platform": "IOS"}}})
        print(f"bundle id {ident}: registered")
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()

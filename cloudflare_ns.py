#!/usr/bin/env python3
"""
Cloudflare DNS batch creator
- Creates pairs of records per your spec:
  A:   <word>ir.<domain>  -> <ip>   (proxied on/off)
  NS:  <word>.<domain>    -> <word>ir.<domain>  (proxied = False)
- Checks existence before creating.
- If API token has account-level access, lists zones and lets user pick.
"""

import requests
import random
import sys
import getpass
import time

API_BASE = "https://api.cloudflare.com/client/v4"

WORD_LIST = [
    "behaviour","history","picture","monster","network","science","project","example",
    "country","quantum","virtual","library","factory","process","control","message",
    "feature","journey","problem","product","natural","freedom","capital","energy",
    "pattern","resource","traffic","venture","dynamic","battery","dialogue","shelter",
    "language","strategy","purpose","interface","security","release","command","context",
    "support","document","solution","triangle","balance","distance","function","delivery",
    "economy","priority","announce","campaign","category","computer","developer",
    "mountain","question","research","snapshot","umbrella","constant","instance","decoder",
    "terminal","service","boundary","velocity","horizon","duration","entropy","elegance",
    "scenario","synergy","optimize","resonance","archive","fortune","harmonic","inspire"
]

def headers_for_auth(auth_type, api_key, email=None):
    if auth_type == 'token':
        return {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
    else:
        if not email:
            raise ValueError("Global API Key requires user email as well.")
        return {
            "X-Auth-Email": email,
            "X-Auth-Key": api_key,
            "Content-Type": "application/json"
        }

def list_zones(auth_type, api_key, email=None, per_page=50):
    h = headers_for_auth(auth_type, api_key, email)
    zones = []
    page = 1
    while True:
        resp = requests.get(f"{API_BASE}/zones", headers=h, params={"page": page, "per_page": per_page})
        if resp.status_code == 401 or not resp.ok:
            return {"success": False, "status": resp.status_code, "body": resp.json()}
        body = resp.json()
        zones.extend(body.get("result", []))
        if page * per_page >= body.get("result_info", {}).get("total_count", len(zones)):
            break
        page += 1
    return {"success": True, "zones": zones}

def find_dns_records(auth_type, api_key, zone_id, name=None, rtype=None, email=None):
    h = headers_for_auth(auth_type, api_key, email)
    params = {}
    if name:
        params["name"] = name
    if rtype:
        params["type"] = rtype
    resp = requests.get(f"{API_BASE}/zones/{zone_id}/dns_records", headers=h, params=params)
    if not resp.ok:
        return {"success": False, "status": resp.status_code, "body": resp.json()}
    return {"success": True, "records": resp.json().get("result", [])}

def create_dns_record(auth_type, api_key, zone_id, record_type, name, content, proxied=False, ttl=1, email=None):
    h = headers_for_auth(auth_type, api_key, email)
    payload = {
        "type": record_type,
        "name": name,
        "content": content,
        "ttl": ttl
    }
    if record_type in ("A", "AAAA", "CNAME"):
        payload["proxied"] = bool(proxied)

    resp = requests.post(f"{API_BASE}/zones/{zone_id}/dns_records", headers=h, json=payload)
    return {"ok": resp.ok, "status": resp.status_code, "body": resp.json()}

def colored(text, color_code=96):
    return f"\033[{color_code}m{text}\033[0m"

def choose_domain_interactive(zones):
    print("\nAvailable zones (pick one by number):")
    for i, z in enumerate(zones, start=1):
        print(f" {i}. {z.get('name')} (id: {z.get('id')})")
    while True:
        choice = input("Enter the number of the domain to use: ").strip()
        if not choice.isdigit():
            print("Please enter a valid number.")
            continue
        idx = int(choice) - 1
        if 0 <= idx < len(zones):
            return zones[idx]
        print("Number out of range.")

def main():
    print("Cloudflare DNS batch creator\n")

    auth_type = ""
    while auth_type not in ("token", "global"):
        auth_type = input("Select authentication type ('token' or 'global', recommended: token): ").strip().lower()

    api_key = getpass.getpass("Enter API token / key: ").strip()

    email = None
    if auth_type == "global":
        email = input("Enter account email (required for Global API Key): ").strip()

    print("\nFetching domain list (if the token has access)...")

    zones_res = list_zones(auth_type, api_key, email=email)
    zone = None

    if zones_res.get("success"):
        zones = zones_res["zones"]

        if not zones:
            print("Token is valid but no zones were returned.")
            zone = None

        elif len(zones) == 1:
            zone = zones[0]
            print(f"Only one domain found: {colored(zone.get('name'))}")

        else:
            zone = choose_domain_interactive(zones)
            print(f"Selected domain: {colored(zone.get('name'))}")

    else:
        print("Failed to retrieve zones (token may not have zone:read permission).")

        manual = input("Do you want to manually enter the zone id? (y/N): ").strip().lower()

        if manual == "y":
            zid = input("Enter zone id: ").strip()
            zname = input("Enter domain name (example: domain.ir): ").strip()
            zone = {"id": zid, "name": zname}
        else:
            print("A valid zone id or a token with proper permissions is required. Exiting.")
            sys.exit(1)

    domain = zone.get("name")
    zone_id = zone.get("id")

    server_ip = input("\nEnter the server IPv4 address (example: 1.2.3.4): ").strip()

    while True:
        n_raw = input("How many record pairs should be created (example: 5): ").strip()
        if n_raw.isdigit() and int(n_raw) > 0:
            n = int(n_raw)
            break
        print("Please enter a valid positive number.")

    prox_choice = ""
    while prox_choice not in ("y", "n"):
        prox_choice = input("Enable Cloudflare proxy for A records by default? (y/N): ").strip().lower() or "n"

    default_proxied = (prox_choice == "y")

    candidates = WORD_LIST

    created_ns = []
    created_pairs = 0

    print(f"\nProcessing generated words ({len(candidates)} words)...\n")

    for word in candidates:

        if created_pairs >= n:
            break

        sub = f"{word}ir"
        a_name = f"{sub}.{domain}"
        ns_name = f"{word}.{domain}"
        ns_target = a_name

        a_check = find_dns_records(auth_type, api_key, zone_id, name=a_name, rtype="A", email=email)
        ns_check = find_dns_records(auth_type, api_key, zone_id, name=ns_name, rtype="NS", email=email)

        a_exists = (a_check.get("success") and len(a_check.get("records", [])) > 0)
        ns_exists = (ns_check.get("success") and len(ns_check.get("records", [])) > 0)

        if a_exists or ns_exists:
            print(f"Skipped (already exists): {a_name} (A exists: {a_exists}), {ns_name} (NS exists: {ns_exists})")
            continue

        create_a = create_dns_record(auth_type, api_key, zone_id, "A", a_name, server_ip, proxied=default_proxied, email=email)

        if not create_a["ok"]:
            print(f"Error creating A record {a_name}: {create_a['status']} {create_a.get('body')}")
            continue

        create_ns = create_dns_record(auth_type, api_key, zone_id, "NS", ns_name, ns_target, proxied=False, email=email)

        if not create_ns["ok"]:
            print(f"Error creating NS record {ns_name}: {create_ns['status']} {create_ns.get('body')}")
            print(f"Warning: A record was created but NS failed for {a_name}")
            continue

        print(f"Created: A {a_name} -> {server_ip} (Proxy {'on' if default_proxied else 'off'}); NS {ns_name} -> {ns_target}")

        created_ns.append(ns_name)
        created_pairs += 1

        time.sleep(0.2)

    if created_pairs < n:
        print(f"\nWarning: only {created_pairs} of {n} requested record pairs were created (duplicates may exist).")
    else:
        print(f"\nSuccess: {created_pairs} record pairs created.")

    if created_ns:
        print("\nList of created NS records:")
        for ns in created_ns:
            print(ns)
    else:
        print("\nNo NS records were created.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelled — bye.")
        sys.exit(0)

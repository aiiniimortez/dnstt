#!/usr/bin/env python3

import requests
import getpass
import sys
import ipaddress

API_BASE = "https://api.cloudflare.com/client/v4"


def headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }


def list_zones(token):
    r = requests.get(f"{API_BASE}/zones", headers=headers(token))
    r.raise_for_status()
    return r.json()["result"]


def choose_zone(zones):

    print("\nAvailable zones:")

    for i, z in enumerate(zones):
        print(f"{i+1}. {z['name']}")

    while True:

        c = input("Select domain number: ").strip()

        if c.isdigit() and 1 <= int(c) <= len(zones):
            return zones[int(c)-1]

        print("Invalid selection.")


def get_all_dns_records(token, zone_id):

    records = []
    page = 1
    per_page = 100

    while True:

        r = requests.get(
            f"{API_BASE}/zones/{zone_id}/dns_records",
            headers=headers(token),
            params={"page": page, "per_page": per_page}
        )

        r.raise_for_status()

        data = r.json()

        records.extend(data["result"])

        info = data.get("result_info")

        if not info:
            break

        if page >= info.get("total_pages", 1):
            break

        page += 1

    return records


def update_record(token, zone_id, record_id, name, ip, ttl=1, proxied=False):

    payload = {
        "type": "A",
        "name": name,
        "content": ip,
        "ttl": ttl,
        "proxied": proxied
    }

    r = requests.put(
        f"{API_BASE}/zones/{zone_id}/dns_records/{record_id}",
        headers=headers(token),
        json=payload
    )

    try:
        r.raise_for_status()
    except Exception:
        return False

    return True


def is_valid_ipv4(ip):

    try:
        ipaddress.IPv4Address(ip)
        return True
    except Exception:
        return False


def main():

    print("Cloudflare NS+A batch scanner\n")

    token = getpass.getpass("Enter API Token: ").strip()

    zones = list_zones(token)

    zone = choose_zone(zones)

    domain = zone["name"]
    zone_id = zone["id"]

    print(f"\nUsing domain: {domain}\n")

    print("Fetching all DNS records...\n")

    records = get_all_dns_records(token, zone_id)

    a_records = {}
    ns_records = []

    for r in records:

        if r["type"] == "A":
            a_records.setdefault(r["name"], []).append(r)

        if r["type"] == "NS":
            ns_records.append(r)

    found_pairs = []

    for ns in ns_records:

        ns_name = ns["name"]

        if not ns_name.endswith("." + domain):
            continue

        sub = ns_name.replace("." + domain, "")

        if not sub:
            continue

        a_name = f"{sub}ir.{domain}"

        a_recs = a_records.get(a_name, [])

        if a_recs:

            ips = [r["content"] for r in a_recs]

            print(f"{ns_name} -> {a_name} -> {', '.join(ips)}")

            for rec in a_recs:

                found_pairs.append({
                    "ns": ns_name,
                    "record": rec
                })

    if not found_pairs:
        print("\nNo matching NS records found.")
        return

    print(f"\nFound {len(found_pairs)} matching records.\n")

    change = input("Do you want to change the IP of their A records? (y/N): ").lower()

    if change != "y":
        return

    all_records = [x["record"] for x in found_pairs]

    unique_ips = sorted(set(rec["content"] for rec in all_records))

    print("\nAvailable IPs found:\n")

    for i, ip in enumerate(unique_ips, 1):
        print(f"{i}. {ip}")

    while True:

        choice = input("\nSelect the IP number you want to replace: ").strip()

        if choice.isdigit() and 1 <= int(choice) <= len(unique_ips):
            old_ip = unique_ips[int(choice)-1]
            break

        print("Invalid selection.")

    recs_with_old = [x for x in found_pairs if x["record"]["content"] == old_ip]

    max_available = len(recs_with_old)

    print(f"\nFound {max_available} records with IP {old_ip}")

    while True:

        num = input(f"How many records do you want to change? (1-{max_available}): ").strip()

        if num.isdigit() and 1 <= int(num) <= max_available:
            num = int(num)
            break

        print("Invalid number.")

    while True:

        new_ip = input("Enter NEW IP: ").strip()

        if is_valid_ipv4(new_ip):
            break

        print("Invalid IPv4 format.")

    updated = 0
    changed_ns = []

    print("\nUpdating records...\n")

    for item in recs_with_old[:num]:

        rec = item["record"]
        ns_name = item["ns"]

        ok = update_record(
            token,
            zone_id,
            rec["id"],
            rec["name"],
            new_ip,
            rec.get("ttl", 1),
            rec.get("proxied", False)
        )

        if ok:
            updated += 1
            changed_ns.append(ns_name)
            print(f"Updated {rec['name']} -> {new_ip}")

    print(f"\nDone. Updated {updated} records.\n")

    if changed_ns:

        print("NS records affected:\n")

        for ns in changed_ns:
            print(ns)


if __name__ == "__main__":
    main()

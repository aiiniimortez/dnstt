#!/usr/bin/env python3

import requests
import sys
import getpass

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


def headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }


def list_zones(token):
    r = requests.get(f"{API_BASE}/zones", headers=headers(token))
    return r.json()["result"]


def choose_zone(zones):
    print("\nAvailable zones:")
    for i,z in enumerate(zones):
        print(f"{i+1}. {z['name']}")

    while True:
        c = input("Select domain number: ").strip()
        if c.isdigit() and 1 <= int(c) <= len(zones):
            return zones[int(c)-1]


def get_dns_records(token, zone_id, rtype=None, name=None):

    params={}

    if rtype:
        params["type"]=rtype
    if name:
        params["name"]=name

    r=requests.get(
        f"{API_BASE}/zones/{zone_id}/dns_records",
        headers=headers(token),
        params=params
    )

    return r.json()["result"]


def update_record(token, zone_id, record_id, name, ip):

    payload={
        "type":"A",
        "name":name,
        "content":ip,
        "ttl":1,
        "proxied":False
    }

    r=requests.put(
        f"{API_BASE}/zones/{zone_id}/dns_records/{record_id}",
        headers=headers(token),
        json=payload
    )

    return r.ok


def main():

    print("Cloudflare NS scanner\n")

    token=getpass.getpass("Enter API Token: ")

    zones=list_zones(token)

    zone=choose_zone(zones)

    domain=zone["name"]
    zone_id=zone["id"]

    print(f"\nUsing domain: {domain}\n")

    found_ns=[]

    for word in WORD_LIST:

        ns_name=f"{word}.{domain}"

        records=get_dns_records(token,zone_id,"NS",ns_name)

        if records:
            found_ns.append(word)
            print(ns_name)

    if not found_ns:
        print("\nNo matching NS records found.")
        sys.exit()

    print(f"\nFound {len(found_ns)} matching NS records.")

    change=input("\nDo you want to change the IP of their A records? (y/N): ").lower()

    if change!="y":
        return

    new_ip=input("Enter new IP: ").strip()

    updated=0

    for word in found_ns:

        a_name=f"{word}ir.{domain}"

        a_records=get_dns_records(token,zone_id,"A",a_name)

        if not a_records:
            continue

        rec=a_records[0]

        ok=update_record(
            token,
            zone_id,
            rec["id"],
            a_name,
            new_ip
        )

        if ok:
            updated+=1
            print(f"Updated {a_name}")

    print(f"\nDone. Updated {updated} A records.")


if __name__=="__main__":
    main()

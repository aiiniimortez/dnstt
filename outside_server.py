#!/usr/bin/env python3

import subprocess
from flask import Flask, Response

app = Flask(__name__)

UUID_FILE = "/etc/dn_monitor_uuids"


def load_allowed_uuids():
    try:
        with open(UUID_FILE) as f:
            return {line.strip() for line in f if line.strip()}
    except Exception:
        return set()


@app.route("/")
def index():
    return "outside_server running\n"


@app.route("/<uuidv>/restart_dntm_router", methods=["GET", "POST"])
def restart_router(uuidv):

    allowed = load_allowed_uuids()

    if uuidv not in allowed:
        return Response("forbidden\n", status=403)

    try:
        subprocess.run(
            ["systemctl", "enable", "dnstm-dnsrouter.service"],
            timeout=10
        )

        res = subprocess.run(
            ["systemctl", "restart", "dnstm-dnsrouter.service"],
            timeout=10,
            capture_output=True,
            text=True
        )

        if res.returncode == 0:
            return Response("ok", status=200)
        else:
            return Response(
                f"failed\n{res.stdout}\n{res.stderr}\n",
                status=500
            )

    except Exception as e:
        return Response(f"error: {e}\n", status=500)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

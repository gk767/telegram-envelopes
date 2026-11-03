#!/usr/bin/env python3
"""Pair a second Simulator with an already provisioned chat, without sharing operator credentials."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from configure_envelope_simulator import private_json


def read_json(path):
    return json.loads(path.read_text())


def export_receiver(operator, setup, account, port, out):
    if account != setup["recipientId"] or account == setup["accountId"]:
        raise ValueError("recipient must match the peer of the open sender chat")
    token = operator["accounts"].get(str(account))
    if not token or not 1024 <= port <= 65535:
        raise ValueError("provision this peer first and use a valid tunnel port")
    config = {"serverURL": f"http://localhost:{port}", "accounts": {str(account): token}}
    # Never overwrite an existing private file, including the operator's file.
    with os.fdopen(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        json.dump(config, stream)


def install_receiver(documents, setup, config):
    account = str(setup["accountId"])
    accounts = config["accounts"]
    if set(accounts) != {account} or not isinstance(accounts[account], str) or not accounts[account]:
        raise ValueError("receiver file must contain only the currently logged-in account")
    url = config["serverURL"]
    port = url.removeprefix("http://localhost:")
    if not url.startswith("http://localhost:") or not port.isascii() or not port.isdigit() or not 1024 <= int(port) <= 65535:
        raise ValueError("expected a local tunnel URL")
    destination = documents / "telegram-envelopes-demo.json"
    installed = read_json(destination) if destination.exists() else {"serverURL": url, "accounts": {}}
    if installed["serverURL"] != url or installed["accounts"].get(account, accounts[account]) != accounts[account]:
        raise ValueError("a different wallet is configured; refusing to replace it")
    installed["accounts"].update(accounts)
    private_json(destination, installed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--bundle", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("identity")
    export = commands.add_parser("export")
    export.add_argument("--operator", type=Path, required=True)
    export.add_argument("--recipient-id", type=int, required=True)
    export.add_argument("--out", type=Path, required=True)
    export.add_argument("--port", type=int, default=18787)
    install = commands.add_parser("install")
    install.add_argument("--receiver", type=Path, required=True)
    args = parser.parse_args()
    try:
        data = subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, args.bundle, "data"], text=True)
        documents = Path(data.strip()) / "Documents"
        setup_file = documents / "telegram-envelopes-setup.json"
        if not setup_file.exists():
            parser.error("open the Envelope form in the test chat first")
        setup = read_json(setup_file)
        if args.command == "identity":
            print(f'Current Telegram account ID: {setup["accountId"]}')
        elif args.command == "export":
            export_receiver(read_json(args.operator), setup, args.recipient_id, args.port, args.out)
            print("Saved one recipient configuration.")
        else:
            install_receiver(documents, setup, read_json(args.receiver))
            print("Receiver wallet connected. Reopen the chat.")
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()

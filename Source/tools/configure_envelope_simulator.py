#!/usr/bin/env python3
"""Provision the current Simulator chat in the local demo ledger. No real funds."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from envelope_demo_server import Ledger, SCALE, USDT_SCALE


def private_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, indent=2)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True, help="Private operator token file outside Git")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("port must be between 1024 and 65535")
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, args.bundle, "data"], text=True).strip())
    documents = container / "Documents"
    setup_file = documents / "telegram-envelopes-setup.json"
    if not setup_file.is_file():
        parser.error("open the new Envelope form in a private chat first, then run this tool again")
    setup = json.loads(setup_file.read_text())
    sender, recipient = setup["accountId"], setup["recipientId"]
    if any(type(value) is not int or not 0 < value < 2**56 for value in (sender, recipient)) or sender == recipient:
        parser.error("open a normal private chat's Envelope form first")
    url = f"http://localhost:{args.port}"
    configuration = {"serverURL": url, "accounts": {}}
    if args.config.exists():
        configuration = json.loads(args.config.read_text())
        if configuration.get("serverURL") != url or not isinstance(configuration.get("accounts"), dict):
            parser.error("operator configuration belongs to another service")
    ledger = Ledger(args.database)
    # Provisioning is performed by this local operator tool, never by HTTP clients.
    # Existing tokens and balances are preserved, and every existing token is checked.
    for account, balance, balance_usdt in [(sender, 1000 * SCALE, 1000 * USDT_SCALE), (recipient, 0, 0)]:
        token = configuration["accounts"].get(str(account))
        if token:
            with ledger.connection() as db:
                row = db.execute("SELECT token_hash FROM accounts WHERE id=?", (account,)).fetchone()
                if row is None or row["token_hash"] != ledger.digest(token):
                    parser.error("saved token does not match ledger; refusing to reset the account")
        else:
            token = ledger.provision(account, balance, balance_usdt)
            configuration["accounts"][str(account)] = token
            private_json(args.config, configuration)
    # Only the currently logged-in sender's token is installed into this client.
    # The second identity's token stays with the operator until recipient testing.
    destination = documents / "telegram-envelopes-demo.json"
    installed_accounts = {}
    if destination.exists():
        installed = json.loads(destination.read_text())
        if installed.get("serverURL") != url:
            parser.error("client configuration belongs to another service; refusing to overwrite it")
        installed_accounts = {account: token for account, token in installed.get("accounts", {}).items()
                              if configuration["accounts"].get(account) == token}
    installed_accounts[str(sender)] = configuration["accounts"][str(sender)]
    private_json(destination, {"serverURL": url, "accounts": installed_accounts})
    print("Simulator demo wallet connected. Reopen the Envelope form. Tokens were not printed; existing balances were preserved.")


if __name__ == "__main__":
    main()

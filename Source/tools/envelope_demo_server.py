#!/usr/bin/env python3
"""Local TON/USDT-envelope demo ledger. Standard library only; never moves cryptocurrency.

Provision test account tokens with `provision`, then run `serve`. Telegram user ids
are bound to tokens by the trusted demo operator, not asserted by HTTP clients.
For a remote demo put this behind HTTPS; the default listener is loopback only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

SCALE = 1_000_000_000
USDT_SCALE = 1_000_000
SCALES = {"TON": SCALE, "USDT": USDT_SCALE}
BALANCE_COLUMNS = {"TON": "balance", "USDT": "balance_usdt"}
MAX_AMOUNT = 1_000_000 * SCALE
MAX_BALANCE = 1_000_000_000 * SCALE


class DemoError(Exception):
    def __init__(self, code, status=400):
        self.code, self.status = code, status


class Ledger:
    def __init__(self, path):
        self.path = str(path)
        with self.connection() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS accounts (
                    id INTEGER PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
                    balance INTEGER NOT NULL CHECK(balance >= 0),
                    balance_usdt INTEGER NOT NULL DEFAULT 0 CHECK(balance_usdt >= 0))""")
            db.execute("""CREATE TABLE IF NOT EXISTS envelopes (
                    id TEXT PRIMARY KEY, submission TEXT NOT NULL,
                    sender INTEGER NOT NULL REFERENCES accounts(id),
                    recipient INTEGER NOT NULL REFERENCES accounts(id),
                    amount INTEGER NOT NULL CHECK(amount > 0), message TEXT NOT NULL,
                    state TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL,
                    currency TEXT NOT NULL DEFAULT 'TON' CHECK(currency IN ('TON', 'USDT')),
                    UNIQUE(sender, submission))""")
            # One transaction preserves existing TON balances/references. Existing
            # accounts receive no new funds as a side effect of schema migration.
            if "balance_usdt" not in {row["name"] for row in db.execute("PRAGMA table_info(accounts)")}:
                db.execute("ALTER TABLE accounts ADD COLUMN balance_usdt INTEGER NOT NULL DEFAULT 0 CHECK(balance_usdt >= 0)")
            if "currency" not in {row["name"] for row in db.execute("PRAGMA table_info(envelopes)")}:
                db.execute("ALTER TABLE envelopes ADD COLUMN currency TEXT NOT NULL DEFAULT 'TON' CHECK(currency IN ('TON', 'USDT'))")
        os.chmod(self.path, 0o600)

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=15, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def digest(token):
        return hashlib.sha256(token.encode()).hexdigest()

    def provision(self, account, balance, balance_usdt=1000 * USDT_SCALE):
        if (type(account) is not int or not 0 < account < 2**56
                or type(balance) is not int or not 0 <= balance <= MAX_BALANCE
                or type(balance_usdt) is not int or not 0 <= balance_usdt <= 1_000_000_000 * USDT_SCALE):
            raise DemoError("invalid_account")
        token = secrets.token_urlsafe(32)
        with self.connection() as db:
            # Never silently reset a provisioned account or its balance.
            if db.execute("SELECT 1 FROM accounts WHERE id=?", (account,)).fetchone():
                raise DemoError("account_already_provisioned")
            db.execute("INSERT INTO accounts (id, token_hash, balance, balance_usdt) VALUES (?, ?, ?, ?)", (account, self.digest(token), balance, balance_usdt))
        return token

    @staticmethod
    def expire(db, now):
        rows = db.execute("SELECT * FROM envelopes WHERE state='sent' AND expires<=?", (now,)).fetchall()
        for row in rows:
            column = BALANCE_COLUMNS[row["currency"]]
            db.execute(f"UPDATE accounts SET {column}={column}+? WHERE id=?", (row["amount"], row["sender"]))
            db.execute("UPDATE envelopes SET state='expired' WHERE id=?", (row["id"],))

    @staticmethod
    def view(row, account):
        return dict(id=row["id"], senderId=row["sender"], recipientId=row["recipient"],
                    amountUnits=row["amount"] if account == row["sender"] or row["state"] == "opened" else None,
                    currency=row["currency"], state=row["state"], message=row["message"], createdAt=row["created"], expiresAt=row["expires"])

    def handle(self, token, method, path, body, now=None):
        now = int(time.time()) if now is None else now
        url = urlsplit(path)
        query = parse_qs(url.query, keep_blank_values=True)
        path = url.path
        with self.connection() as db:
            auth = db.execute("SELECT id FROM accounts WHERE token_hash=?", (self.digest(token),)).fetchone()
            if auth is None:
                raise DemoError("unauthorized", 401)
            account = auth["id"]
            self.expire(db, now)
            if method == "GET" and path == "/v1/wallet":
                currencies = query.get("currency", ["TON"])
                if len(currencies) != 1 or currencies[0] not in SCALES:
                    raise DemoError("invalid_currency")
                currency = currencies[0]
                column = BALANCE_COLUMNS[currency]
                return {"balanceUnits": db.execute(f"SELECT {column} FROM accounts WHERE id=?", (account,)).fetchone()[0], "currency": currency}
            if method == "POST" and path == "/v1/envelopes":
                recipient, amount, message = body.get("recipientId"), body.get("amountUnits"), body.get("message", "")
                currency = body.get("currency", "TON")
                if not isinstance(currency, str) or currency not in SCALES:
                    raise DemoError("invalid_currency")
                column = BALANCE_COLUMNS[currency]
                if type(recipient) is not int or recipient == account or not db.execute("SELECT 1 FROM accounts WHERE id=?", (recipient,)).fetchone():
                    raise DemoError("invalid_recipient")
                if type(amount) is not int or not 0 < amount <= 1_000_000 * SCALES[currency]:
                    raise DemoError("invalid_amount")
                if not isinstance(message, str) or len(message) > 200:
                    raise DemoError("message_too_long")
                try:
                    submission = str(uuid.UUID(body.get("submissionId", "")))
                except (ValueError, TypeError, AttributeError):
                    raise DemoError("invalid_submission") from None
                existing = db.execute("SELECT * FROM envelopes WHERE sender=? AND submission=?", (account, submission)).fetchone()
                if existing:
                    if (existing["recipient"], existing["amount"], existing["message"], existing["currency"]) != (recipient, amount, message, currency):
                        raise DemoError("submission_conflict", 409)
                    return self.view(existing, account)
                debit = db.execute(f"UPDATE accounts SET {column}={column}-? WHERE id=? AND {column}>=?", (amount, account, amount))
                if debit.rowcount != 1:
                    raise DemoError("insufficient_balance", 409)
                envelope_id = str(uuid.uuid4())
                db.execute("INSERT INTO envelopes (id, submission, sender, recipient, amount, message, state, created, expires, currency) VALUES (?, ?, ?, ?, ?, ?, 'sent', ?, ?, ?)",
                           (envelope_id, submission, account, recipient, amount, message, now, now + 86400, currency))
                return self.view(db.execute("SELECT * FROM envelopes WHERE id=?", (envelope_id,)).fetchone(), account)
            parts = path.strip("/").split("/")
            if len(parts) not in (3, 4) or parts[:2] != ["v1", "envelopes"]:
                raise DemoError("not_found", 404)
            row = db.execute("SELECT * FROM envelopes WHERE id=?", (parts[2],)).fetchone()
            if row is None or account not in (row["sender"], row["recipient"]):
                raise DemoError("not_found", 404)
            column = BALANCE_COLUMNS[row["currency"]]
            if method == "GET" and len(parts) == 3:
                return self.view(row, account)
            if method != "POST" or len(parts) != 4:
                raise DemoError("not_found", 404)
            if parts[3] == "claim":
                if account != row["recipient"]:
                    raise DemoError("forbidden", 403)
                if row["state"] == "sent":
                    credit = db.execute(f"UPDATE accounts SET {column}={column}+? WHERE id=? AND {column}<=?", (row["amount"], account, 1_000_000_000 * SCALES[row["currency"]] - row["amount"]))
                    if credit.rowcount != 1:
                        raise DemoError("balance_limit", 409)
                    db.execute("UPDATE envelopes SET state='opened' WHERE id=?", (row["id"],))
                # Repeated claims return the existing receipt without crediting again.
            elif parts[3] == "cancel":
                if account != row["sender"]:
                    raise DemoError("forbidden", 403)
                if row["state"] == "sent":
                    db.execute(f"UPDATE accounts SET {column}={column}+? WHERE id=?", (row["amount"], account))
                    db.execute("UPDATE envelopes SET state='cancelled' WHERE id=?", (row["id"],))
            else:
                raise DemoError("not_found", 404)
            receipt = self.view(db.execute("SELECT * FROM envelopes WHERE id=?", (row["id"],)).fetchone(), account)
            if parts[3] == "claim":
                # Only the transaction which credited this recipient can celebrate.
                receipt["openedNow"] = row["state"] == "sent"
            return receipt


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        try:
            authorization = self.headers.get("Authorization", "")
            if not authorization.startswith("Bearer ") or len(authorization) > 256:
                raise DemoError("unauthorized", 401)
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 8192:
                raise DemoError("invalid_body")
            body = json.loads(self.rfile.read(length)) if length else {}
            if not isinstance(body, dict):
                raise DemoError("invalid_body")
            result = self.server.ledger.handle(authorization[7:], self.command, self.path, body)
            status = 200
        except DemoError as error:
            status, result = error.status, {"error": error.code}
        except (ValueError, UnicodeDecodeError):
            status, result = 400, {"error": "invalid_body"}
        except Exception:
            status, result = 500, {"error": "internal"}
        data = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass  # No tokens, account IDs, message bodies or amounts in request logs.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    provision = commands.add_parser("provision")
    provision.add_argument("--account", type=int, required=True)
    provision.add_argument("--balance-ton", type=int, default=1000)
    provision.add_argument("--balance-usdt", type=int, default=1000)
    provision.add_argument("--config-out", type=Path)
    provision.add_argument("--server-url", default="http://localhost:8787")
    serve = commands.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    ledger = Ledger(args.database)
    if args.command == "provision":
        configuration = {"serverURL": args.server_url, "accounts": {}}
        if args.config_out and args.config_out.exists():
            configuration = json.loads(args.config_out.read_text())
            if configuration.get("serverURL") != args.server_url or not isinstance(configuration.get("accounts"), dict):
                parser.error("existing configuration has another serverURL or invalid accounts")
        token = ledger.provision(args.account, args.balance_ton * SCALE, args.balance_usdt * USDT_SCALE)
        if args.config_out:
            configuration["accounts"][str(args.account)] = token
            descriptor = os.open(args.config_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                json.dump(configuration, stream, indent=2)
            os.chmod(args.config_out, 0o600)
            print(f"Saved account token to {args.config_out}")
        else:
            print(json.dumps({str(args.account): token}))
    else:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
        server.ledger = ledger
        print(f"TON/USDT demo ledger: http://{args.host}:{args.port} (simulated funds only)", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()


if __name__ == "__main__":
    main()

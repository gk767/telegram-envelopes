import concurrent.futures
import json
import sqlite3
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer

from envelope_demo_server import DemoError, Handler, Ledger, SCALE, USDT_SCALE


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "ledger.sqlite"
        self.ledger = Ledger(self.path)
        self.tokens = {1: self.ledger.provision(1, 1000 * SCALE), 2: self.ledger.provision(2, 0, 0), 3: self.ledger.provision(3, 0, 0)}

    def tearDown(self):
        self.temp.cleanup()

    def request(self, account, method, path, body=None, now=100):
        return self.ledger.handle(self.tokens[account], method, path, body or {}, now=now)

    def create(self, **changes):
        body = dict(recipientId=2, amountUnits=15 * SCALE, message="Enjoy!", submissionId=str(uuid.uuid4()))
        body.update(changes)
        return self.request(1, "POST", "/v1/envelopes", body), body

    def balance(self, account, now=100, currency="TON"):
        return self.request(account, "GET", "/v1/wallet?currency=" + currency, now=now)["balanceUnits"]

    def test_usdt_is_independent_and_preserves_six_decimal_units(self):
        amount = 15 * USDT_SCALE + 1
        envelope, body = self.create(currency="USDT", amountUnits=amount)
        path = "/v1/envelopes/" + envelope["id"]
        self.assertEqual(envelope["currency"], "USDT")
        self.assertEqual(self.balance(1), 1000 * SCALE)
        self.assertEqual(self.balance(1, currency="USDT"), 1000 * USDT_SCALE - amount)
        self.assertIsNone(self.request(2, "GET", path)["amountUnits"])
        self.assertEqual(self.request(1, "POST", "/v1/envelopes", body)["id"], envelope["id"])
        for _ in range(3):
            receipt = self.request(2, "POST", path + "/claim")
            self.assertEqual((receipt["currency"], receipt["amountUnits"]), ("USDT", amount))
        self.assertEqual(self.balance(2), 0)
        self.assertEqual(self.balance(2, currency="USDT"), amount)
        self.ledger = Ledger(self.path)
        self.assertEqual(self.balance(2, currency="USDT"), amount)

    def test_currency_bound_idempotency_and_usdt_refunds(self):
        envelope, body = self.create(currency="USDT", amountUnits=15 * USDT_SCALE)
        other_currency = dict(body, currency="TON")
        with self.assertRaisesRegex(DemoError, "submission_conflict"):
            self.request(1, "POST", "/v1/envelopes", other_currency)
        path = "/v1/envelopes/" + envelope["id"]
        for _ in range(2):
            self.assertEqual(self.request(1, "POST", path + "/cancel")["state"], "cancelled")
        self.assertEqual(self.request(1, "POST", "/v1/envelopes", body)["state"], "cancelled")
        expired, expired_body = self.create(currency="USDT", amountUnits=USDT_SCALE)
        self.assertEqual(self.request(1, "POST", "/v1/envelopes", expired_body, now=86500)["state"], "expired")
        self.assertEqual(self.balance(1, now=86500, currency="USDT"), 1000 * USDT_SCALE)
        self.assertEqual(self.balance(1, now=86500), 1000 * SCALE)

    def test_unsupported_currency_and_usdt_limits_do_not_debit(self):
        for currency in ["GRAM", "USD", "usdt", "", None, [], True]:
            with self.assertRaisesRegex(DemoError, "invalid_currency"):
                self.create(currency=currency, amountUnits=1)
        for endpoint in ["/v1/wallet?currency=GRAM", "/v1/wallet?currency=", "/v1/wallet?currency=TON&currency=USDT"]:
            with self.assertRaisesRegex(DemoError, "invalid_currency"):
                self.request(1, "GET", endpoint)
        with self.assertRaisesRegex(DemoError, "invalid_amount"):
            self.create(currency="USDT", amountUnits=1_000_000 * USDT_SCALE + 1)
        self.assertEqual(self.balance(1), 1000 * SCALE)
        self.assertEqual(self.balance(1, currency="USDT"), 1000 * USDT_SCALE)

    def test_old_schema_migrates_once_without_changing_ton_balances(self):
        old_path = Path(self.temp.name) / "legacy.sqlite"
        sender_token, receiver_token = "legacy-sender", "legacy-receiver"
        envelope_id, submission_id = str(uuid.uuid4()), str(uuid.uuid4())
        with sqlite3.connect(old_path) as db:
            db.executescript("""
                CREATE TABLE accounts (id INTEGER PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, balance INTEGER NOT NULL CHECK(balance>=0));
                CREATE TABLE envelopes (id TEXT PRIMARY KEY, submission TEXT NOT NULL,
                    sender INTEGER NOT NULL REFERENCES accounts(id), recipient INTEGER NOT NULL REFERENCES accounts(id),
                    amount INTEGER NOT NULL CHECK(amount>0), message TEXT NOT NULL, state TEXT NOT NULL,
                    created INTEGER NOT NULL, expires INTEGER NOT NULL, UNIQUE(sender, submission));
            """)
            db.execute("INSERT INTO accounts VALUES (?, ?, ?)", (101, Ledger.digest(sender_token), 985 * SCALE))
            db.execute("INSERT INTO accounts VALUES (?, ?, ?)", (102, Ledger.digest(receiver_token), 0))
            db.execute("INSERT INTO envelopes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (envelope_id, submission_id, 101, 102, 15 * SCALE, "Legacy", "sent", 100, 86500))
        for _ in range(2):
            ledger = Ledger(old_path)
            self.assertEqual(ledger.handle(sender_token, "GET", "/v1/wallet", {}, now=100), {"balanceUnits": 985 * SCALE, "currency": "TON"})
            self.assertEqual(ledger.handle(sender_token, "GET", "/v1/wallet?currency=USDT", {}, now=100)["balanceUnits"], 0)
            receipt = ledger.handle(receiver_token, "POST", "/v1/envelopes/" + envelope_id + "/claim", {}, now=100)
            self.assertEqual(receipt["currency"], "TON")
            self.assertEqual(ledger.handle(receiver_token, "GET", "/v1/wallet", {}, now=100)["balanceUnits"], 15 * SCALE)

    def test_send_claim_and_persistence(self):
        envelope, _ = self.create()
        path = "/v1/envelopes/" + envelope["id"]
        self.assertEqual(self.balance(1), 985 * SCALE)
        self.assertIsNone(self.request(2, "GET", path)["amountUnits"])
        self.assertEqual(self.request(2, "POST", path + "/claim")["amountUnits"], 15 * SCALE)
        self.ledger = Ledger(self.path)
        self.assertEqual(self.request(2, "POST", path + "/claim")["state"], "opened")
        self.assertEqual(self.balance(2), 15 * SCALE)

    def test_parallel_duplicate_sends_and_claims(self):
        body = dict(recipientId=2, amountUnits=15 * SCALE, message="", submissionId=str(uuid.uuid4()))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            sent = list(executor.map(lambda _: self.request(1, "POST", "/v1/envelopes", body), range(20)))
            self.assertEqual(len({item["id"] for item in sent}), 1)
            path = "/v1/envelopes/" + sent[0]["id"] + "/claim"
            receipts = list(executor.map(lambda _: self.request(2, "POST", path), range(20)))
            self.assertEqual(sum(receipt["openedNow"] for receipt in receipts), 1)
            self.assertTrue(all(receipt["state"] == "opened" for receipt in receipts))
        self.assertEqual(self.balance(1), 985 * SCALE)
        self.assertEqual(self.balance(2), 15 * SCALE)

    def test_cancel_and_claim_race_conserves_balance(self):
        envelope, _ = self.create()
        path = "/v1/envelopes/" + envelope["id"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            a = executor.submit(self.request, 1, "POST", path + "/cancel")
            b = executor.submit(self.request, 2, "POST", path + "/claim")
            a.result(), b.result()
        final = self.request(1, "GET", path)
        self.assertIn(final["state"], ("opened", "cancelled"))
        self.assertEqual(self.balance(1) + self.balance(2), 1000 * SCALE)
        self.assertEqual(self.balance(2), 15 * SCALE if final["state"] == "opened" else 0)

    def test_expiry_refunds_once_and_prevents_claim(self):
        envelope, _ = self.create()
        path = "/v1/envelopes/" + envelope["id"]
        for _ in range(3):
            self.assertEqual(self.request(2, "POST", path + "/claim", now=86500)["state"], "expired")
        self.assertEqual(self.balance(1, now=86500), 1000 * SCALE)
        self.assertEqual(self.balance(2, now=86500), 0)

    def test_authentication_ownership_and_replay(self):
        envelope, body = self.create()
        path = "/v1/envelopes/" + envelope["id"]
        for account, method, endpoint in [(1, "POST", path + "/claim"), (2, "POST", path + "/cancel"), (3, "GET", path)]:
            with self.assertRaises(DemoError):
                self.request(account, method, endpoint)
        with self.assertRaises(DemoError):
            self.ledger.handle("forged", "GET", "/v1/wallet", {})
        body["amountUnits"] += 1
        with self.assertRaisesRegex(DemoError, "submission_conflict"):
            self.request(1, "POST", "/v1/envelopes", body)
        self.assertEqual(self.balance(1), 985 * SCALE)

    def test_invalid_amounts_and_insufficient_balance_do_not_debit(self):
        for amount in [0, -1, True, "15", 1.5, 10**30, 1001 * SCALE]:
            with self.assertRaises(DemoError):
                self.create(amountUnits=amount)
        with self.assertRaises(DemoError):
            self.create(recipientId=1)
        with self.assertRaises(DemoError):
            self.create(recipientId=999)
        self.assertEqual(self.balance(1), 1000 * SCALE)

    def test_http_end_to_end(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.ledger = self.ledger
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"

        def http(account, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            request = urllib.request.Request(base + path, data=data, headers={"Authorization": "Bearer " + self.tokens[account], "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.load(response)
        try:
            envelope = http(1, "/v1/envelopes", dict(recipientId=2, amountUnits=15 * SCALE, message="", submissionId=str(uuid.uuid4())))
            path = "/v1/envelopes/" + envelope["id"]
            self.assertIsNone(http(2, path)["amountUnits"])
            self.assertEqual(http(2, path + "/claim", {})["amountUnits"], 15 * SCALE)
            http(2, path + "/claim", {})
            self.assertEqual(http(2, "/v1/wallet")["balanceUnits"], 15 * SCALE)
            usdt = http(1, "/v1/envelopes", dict(recipientId=2, amountUnits=12 * USDT_SCALE + 345678, currency="USDT", message="", submissionId=str(uuid.uuid4())))
            self.assertEqual(http(1, "/v1/wallet?currency=USDT")["balanceUnits"], 1000 * USDT_SCALE - 12 * USDT_SCALE - 345678)
            http(2, "/v1/envelopes/" + usdt["id"] + "/claim", {})
            self.assertEqual(http(2, "/v1/wallet?currency=USDT")["balanceUnits"], 12 * USDT_SCALE + 345678)
            self.assertEqual(http(2, "/v1/wallet")["balanceUnits"], 15 * SCALE)
            with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                urllib.request.urlopen(base + path, timeout=5)
            unauthorized.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()

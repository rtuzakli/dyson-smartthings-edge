"""Offline tests for tools/dyson_credentials.py. Run: python3 test/test_dyson_credentials.py"""
import base64
import builtins
import json
import os
import socket
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import dyson_credentials as dc  # noqa: E402

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes  # noqa: E402


def encrypt_like_dyson(obj):
    plain = json.dumps(obj).encode()
    pad = 16 - len(plain) % 16
    plain += bytes([pad]) * pad
    enc = Cipher(algorithms.AES(dc.CRED_KEY), modes.CBC(dc.CRED_IV)).encryptor()
    return base64.b64encode(enc.update(plain) + enc.finalize()).decode()


CREDS = {"serial": "AB1-EU-CDE2345F", "apPasswordHash": "abc/def+ghi=="}


class DecryptTest(unittest.TestCase):
    def test_round_trip(self):
        self.assertEqual(dc.decrypt_credentials(encrypt_like_dyson(CREDS)), CREDS)

    def test_openssl_fallback(self):
        encrypted = encrypt_like_dyson(CREDS)
        real_import = builtins.__import__

        def no_cryptography(name, *a, **kw):
            if name.startswith("cryptography"):
                raise ImportError(name)
            return real_import(name, *a, **kw)

        with mock.patch("builtins.__import__", side_effect=no_cryptography):
            self.assertEqual(dc.decrypt_credentials(encrypted), CREDS)


class ManifestTest(unittest.TestCase):
    def test_v2_shape(self):
        devs = dc.parse_manifest([{"Name": "Living room", "Serial": "S1", "ProductType": "358K", "LocalCredentials": "x"}])
        self.assertEqual(devs, [{"name": "Living room", "serial": "S1", "type": "358K", "credentials": "x"}])

    def test_v3_shape(self):
        devs = dc.parse_manifest([{"name": "Living room", "serialNumber": "S1", "type": "358K",
                                   "connectedConfiguration": {"mqtt": {"localBrokerCredentials": "y",
                                                                       "mqttRootTopicLevel": "358K"}}}])
        self.assertEqual(devs, [{"name": "Living room", "serial": "S1", "type": "358K", "credentials": "y"}])

    def test_robot_without_mqtt(self):
        self.assertIsNone(dc.parse_manifest([{"serialNumber": "R1", "type": "276"}])[0]["credentials"])


# Reply captured from a 358K (2026-11-07), serial, id and addresses replaced: PTR "358_AB1-EU-CDE2345F", SRV, TXT, A 192.168.1.50, two AAAA.
DYSON_MDNS_REPLY = bytes.fromhex(
    "0000840000010001000000050b5f6479736f6e5f6d717474045f746370056c6f63616c00000c0001c00c000c00010000000a"
    "0016133335385f4142312d45552d4344453233343546c00cc034002100010000000a001500000000075b0c41314232433344"
    "3445354636c01dc034001000010000000a001c1b5365727669636520666f72204142312d45552d4344453233343546c05c00"
    "0100010000000a0004c0a80132c05c001c00010000000a0010fe800000000000000000000000000001c05c001c0001000000"
    "0a0010fd000000000000000000000000000001")


class MdnsTest(unittest.TestCase):
    def test_real_reply(self):
        self.assertEqual(dc.parse_mdns(DYSON_MDNS_REPLY), {"AB1-EU-CDE2345F": "192.168.1.50"})

    def test_truncated_reply_raises(self):
        with self.assertRaises((ValueError, Exception)):
            dc.parse_mdns(DYSON_MDNS_REPLY[:60])


PROFILE = os.path.join(os.path.dirname(__file__), "..", "profiles", "dyson-358k.yml")

def read(path, mode="r"):
    with open(path, mode, **({} if "b" in mode else {"encoding": "utf-8"})) as f:
        return f.read()



def defaults(path):
    """{preference name: default value} read from a profile."""
    out, name = {}, None
    for line in read(path).split("\n"):
        line = line.strip()
        if line.startswith("name:"):
            name = line.split(":", 1)[1].strip()
        elif line.startswith("default:") and name:
            out[name] = json.loads(line.split(":", 1)[1].strip())
    return out


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "dyson-358k.yml")
        with open(PROFILE, encoding="utf-8") as src, open(self.path, "w", encoding="utf-8") as dst:
            dst.write(src.read())

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_defaults_change(self):
        before = read(self.path).split("\n")
        changed = dc.update_profile(self.path, {"ipAddress": "10.0.0.9", "serialNumber": "AB-1",
                                                "productType": "527", "localPassword": 'p"w\\x'})
        self.assertEqual(sorted(changed), ["ipAddress", "localPassword", "productType", "serialNumber"])
        after = read(self.path).split("\n")
        diff = [(a, b) for a, b in zip(before, after) if a != b]
        self.assertEqual(len(before), len(after))
        self.assertEqual(len(diff), 4)
        self.assertTrue(all(b.strip().startswith("default:") for _, b in diff))
        self.assertEqual(defaults(self.path), {"ipAddress": "10.0.0.9", "serialNumber": "AB-1",
                                               "productType": "527", "localPassword": 'p"w\\x'})

    def test_missing_preference(self):
        with self.assertRaises(ValueError):
            dc.update_profile(self.path, {"noSuchPref": "x"})


class FlowTest(unittest.TestCase):
    def fake_api(self, manifest_v2=None, status="ACTIVE", manifest_v3=None):
        calls = []

        def request(host, method, path, params=None, body=None, token=None):
            calls.append((method, path, body, token))
            if path == dc.PATH_PROVISION:
                return "5.0.21061"
            if path == dc.PATH_USER_STATUS:
                return {"accountStatus": status}
            if path == dc.PATH_EMAIL_REQUEST:
                return {"challengeId": "ch-1"}
            if path == dc.PATH_EMAIL_VERIFY:
                return {"token": "tok", "tokenType": "Bearer"}
            if path == "/v2/provisioningservice/manifest" and manifest_v2 is not None:
                return manifest_v2
            if path == "/v3/manifest" and manifest_v3 is not None:
                return manifest_v3
            raise dc.DysonError(f"{method} {path} -> HTTP 404")
        return request, calls

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = os.path.join(self.tmp.name, "dyson-358k.yml")
        with open(PROFILE, encoding="utf-8") as src, open(self.out, "w", encoding="utf-8") as dst:
            dst.write(src.read())

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, request, argv):
        out = []
        argv = argv + ["--profile", self.out]
        with mock.patch.object(dc, "request", request), \
                mock.patch.object(dc, "find_ips", return_value={"S1": "192.168.1.50"}), \
                mock.patch.object(dc, "check_mqtt", return_value=(True, "")), \
                mock.patch("getpass.getpass", return_value="pw"), \
                mock.patch("builtins.input", return_value="123456"), \
                mock.patch("builtins.print", side_effect=lambda *a, **k: out.append(" ".join(map(str, a)))):
            rc = dc.main(argv)
        return rc, "\n".join(out)

    def test_login_sends_otp_and_password_to_verify(self):
        request, calls = self.fake_api(manifest_v2=[{"Serial": "S1", "ProductType": "358K",
                                                     "LocalCredentials": encrypt_like_dyson(CREDS)}])
        rc, out = self.run_main(request, ["--email", "a@b.c", "--json", "--update-profile", "--include-password"])
        self.assertEqual(rc, 0)
        self.assertNotIn(CREDS["apPasswordHash"], out, "password never printed")
        verify = [c for c in calls if c[1] == dc.PATH_EMAIL_VERIFY][0]
        self.assertEqual(verify[2], {"email": "a@b.c", "password": "pw", "challengeId": "ch-1", "otpCode": "123456"})
        manifest_call = [c for c in calls if c[1] == "/v2/provisioningservice/manifest"][0]
        self.assertEqual(manifest_call[3], "Bearer tok")
        self.assertEqual(defaults(self.out), {"ipAddress": "192.168.1.50", "serialNumber": "S1",
                                              "productType": "358K", "localPassword": CREDS["apPasswordHash"]})
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o600, "profile with password is owner-only")

    def test_v3_manifest_used_first(self):
        v3 = [{"serialNumber": "S3", "type": "358K", "connectedConfiguration": {
            "mqtt": {"localBrokerCredentials": encrypt_like_dyson(CREDS)}}}]
        request, calls = self.fake_api(manifest_v2=[{"Serial": "S1", "LocalCredentials": encrypt_like_dyson(CREDS)}],
                                       manifest_v3=v3)
        rc, _ = self.run_main(request, ["--email", "a@b.c", "--update-profile"])
        self.assertEqual(rc, 0)
        self.assertEqual(defaults(self.out)["serialNumber"], "S3")
        self.assertNotIn("/v2/provisioningservice/manifest", [c[1] for c in calls])

    def test_falls_back_to_v2_manifest(self):
        v3 = [{"serialNumber": "S3", "type": "358K", "connectedConfiguration": {
            "mqtt": {"localBrokerCredentials": encrypt_like_dyson(CREDS)}}}]
        request, _ = self.fake_api(manifest_v2=None, manifest_v3=v3)
        ip_before = defaults(self.out)["ipAddress"]
        rc, out = self.run_main(request, ["--email", "a@b.c", "--update-profile"])
        self.assertEqual(rc, 0)
        saved = defaults(self.out)
        self.assertEqual((saved["serialNumber"], saved["ipAddress"]), ("S3", ip_before))  # IP not found: kept

    def test_password_not_written_by_default(self):
        request, _ = self.fake_api(manifest_v2=[{"Serial": "S1", "ProductType": "358K",
                                                 "LocalCredentials": encrypt_like_dyson(CREDS)}])
        rc, out = self.run_main(request, ["--email", "a@b.c", "--update-profile"])
        self.assertEqual(rc, 0)
        self.assertEqual(defaults(self.out)["localPassword"], "password")
        self.assertEqual(defaults(self.out)["serialNumber"], "S1")
        self.assertNotIn(CREDS["apPasswordHash"], read(self.out))

    def test_default_shows_qr_and_leaves_profile(self):
        request, _ = self.fake_api(manifest_v2=[{"Serial": "S1", "ProductType": "358K",
                                                 "LocalCredentials": encrypt_like_dyson(CREDS)}])
        before = read(self.out)
        png = os.path.join(self.tmp.name, "pw.png")
        rc, out = self.run_main(request, ["--email", "a@b.c", "--png", png])
        self.assertEqual(rc, 0)
        self.assertEqual(read(self.out), before, "profile untouched by default")
        self.assertIn("█", out, "QR drawn")
        self.assertNotIn(CREDS["apPasswordHash"], out, "password never printed")
        self.assertEqual(stat.S_IMODE(os.stat(png).st_mode), 0o600, "PNG owner-only")
        self.assertTrue(read(png, "rb").startswith(b"\x89PNG"))

    def test_several_devices_need_serial(self):
        request, _ = self.fake_api(manifest_v2=[{"Serial": "S1", "ProductType": "358K", "LocalCredentials": encrypt_like_dyson(CREDS)},
                                                {"Serial": "S2", "ProductType": "358K", "LocalCredentials": encrypt_like_dyson(CREDS)}])
        with mock.patch("sys.stderr"):
            rc, _ = self.run_main(request, ["--email", "a@b.c"])
        self.assertEqual(rc, 1)
        rc, _ = self.run_main(request, ["--email", "a@b.c", "--update-profile", "--serial", "S2"])
        self.assertEqual(rc, 0)
        self.assertEqual(defaults(self.out)["serialNumber"], "S2")

    def test_serial_filter_miss(self):
        request, _ = self.fake_api(manifest_v2=[{"Serial": "S1", "LocalCredentials": encrypt_like_dyson(CREDS)}])
        with mock.patch("sys.stderr"):
            rc, _ = self.run_main(request, ["--email", "a@b.c", "--serial", "NOPE"])
        self.assertEqual(rc, 1)

    def test_inactive_account(self):
        request, _ = self.fake_api(status="UNREGISTERED")
        with mock.patch("sys.stderr"):
            rc, _ = self.run_main(request, ["--email", "a@b.c"])
        self.assertEqual(rc, 1)


class TemplateTest(unittest.TestCase):
    TEMPLATE = os.path.join(os.path.dirname(__file__), "..", "templates", "dyson-358k.yml")

    def test_template_has_placeholders(self):
        self.assertEqual(defaults(self.TEMPLATE), dc.PLACEHOLDERS)

    @unittest.skipUnless(os.path.exists(PROFILE), "no local profile (fresh clone)")
    def test_template_matches_profile(self):
        def body(path):
            return [l for l in read(path).split("\n")
                    if not l.lstrip().startswith(("default:", "#"))]
        self.assertEqual(body(self.TEMPLATE), body(PROFILE),
                         "profile changed: run python3 tools/dyson_credentials.py --export-template")

    def test_fresh_clone_creates_profile(self):
        with tempfile.TemporaryDirectory() as d:
            target = os.path.join(d, "dyson-358k.yml")
            self.assertTrue(dc.ensure_profile(target, self.TEMPLATE))
            self.assertFalse(dc.ensure_profile(target, self.TEMPLATE))
            dc.update_profile(target, {"serialNumber": "S9", "localPassword": "pw"})
            self.assertEqual(defaults(target)["serialNumber"], "S9")

    def test_export_strips_secrets(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "t", "dyson-358k.yml")
            dc.export_template(PROFILE if os.path.exists(PROFILE) else self.TEMPLATE, out)
            self.assertEqual(defaults(out), dc.PLACEHOLDERS)
            self.assertTrue(read(out).startswith("# Template"))


class RateLimitTest(unittest.TestCase):
    def test_429_explained(self):
        err = dc.urllib.error.HTTPError("https://x", 429, "Too Many Requests", {}, None)
        err.read = lambda: b"error code: 1015"
        with mock.patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(dc.DysonError) as ctx:
                dc.request("https://x", "POST", "/v3/userregistration/email/auth", body={})
        self.assertIn("rate-limiting", str(ctx.exception))
        self.assertIn("1015", str(ctx.exception))

    def test_app_user_agent(self):
        self.assertTrue(dc.HEADERS["User-Agent"].startswith("DysonLink/"))


class LocalTest(unittest.TestCase):
    def test_mdns_details(self):
        self.assertEqual(dc.parse_mdns_details(DYSON_MDNS_REPLY), [
            {"serial": "AB1-EU-CDE2345F", "type_prefix": "358", "ip": "192.168.1.50", "host": "A1B2C3D4E5F6"}])

    def _broker(self, rc):
        import threading
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)

        def serve():
            conn, _ = srv.accept()
            conn.recv(1024)
            conn.sendall(bytes([0x20, 2, 0, rc]))
            conn.close()
            srv.close()
        threading.Thread(target=serve, daemon=True).start()
        return srv.getsockname()[1]

    def test_check_mqtt(self):
        self.assertEqual(dc.check_mqtt("127.0.0.1", "S", "p", port=self._broker(0)), (True, ""))
        ok, why = dc.check_mqtt("127.0.0.1", "S", "p", port=self._broker(5))
        self.assertFalse(ok)
        self.assertIn("refused", why)

    def test_qr_matrix(self):
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
        import qr
        m = qr.encode("x" * 88)
        self.assertEqual((len(m), len(m[0])), (37, 37))
        finder = [row[0:7] for row in m[0:7]]
        self.assertTrue(all(finder[0]) and all(finder[6]) and finder[3][3] and not finder[1][1])
        with self.assertRaises(ValueError):
            qr.encode("x" * 107)


if __name__ == "__main__":
    unittest.main()

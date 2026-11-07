#!/usr/bin/env python3
"""Get your Dyson's local MQTT password from your Dyson account and show it as a QR code.

Logs in to the Dyson cloud with email, password and the one-time code Dyson emails you, decrypts the
device's local broker credentials, finds the device on the local network (mDNS) and checks the
password by logging in to it. Then shows the password as a QR code: scan it with the phone, copy
the text and paste it into SmartThings > the Dyson device > Settings > Local MQTT password.
The driver keeps it on the hub; it never goes into the driver package.

Contacts the Dyson API (appapi.cp.dyson.com) and the local network. Never prints the password as text.

    python3 tools/dyson_credentials.py --email you@example.com --country TR
    python3 tools/dyson_credentials.py --email you@example.com --png password.png   # QR as an image
    python3 tools/dyson_credentials.py --email you@example.com --update-profile     # developer: profile defaults
"""
import argparse
import base64
import getpass
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_HOSTS = {"global": "https://appapi.cp.dyson.com", "china": "https://appapi.cp.dyson.cn"}
# Identify as the Dyson app, like libdyson-rest does; Dyson's Cloudflare front rate-limits other clients
# (HTTP 429, "error code: 1015").
DEFAULT_USER_AGENT = "DysonLink/205298 Darwin/27.0.0"
HEADERS = {"User-Agent": DEFAULT_USER_AGENT, "Content-Type": "application/json"}
PATH_PROVISION = "/v1/provisioningservice/application/Android/version"
PATH_USER_STATUS = "/v3/userregistration/email/userstatus"
PATH_EMAIL_REQUEST = "/v3/userregistration/email/auth"
PATH_EMAIL_VERIFY = "/v3/userregistration/email/verify"
# v3 is what current clients use; v2 is the long-standing one. Both shapes are parsed.
PATH_MANIFESTS = ("/v3/manifest", "/v2/provisioningservice/manifest")

# Dyson encrypts LocalCredentials with this fixed AES-256-CBC key and a zero IV (as libdyson does).
CRED_KEY = bytes(range(1, 33))
CRED_IV = bytes(16)


class DysonError(Exception):
    pass


def request(host, method, path, params=None, body=None, token=None):
    url = host + path + ("?" + urllib.parse.urlencode(params) if params else "")
    headers = dict(HEADERS)
    if token:
        headers["Authorization"] = token
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode("utf-8", "replace")
        if e.code == 429:
            raise DysonError(f"{method} {path} -> HTTP 429 ({detail.strip()}): Dyson's server is rate-limiting "
                             "this network. Wait 15-30 minutes before trying again; every new try extends the "
                             "block.") from None
        raise DysonError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
    except urllib.error.URLError as e:
        raise DysonError(f"{method} {path} -> {e.reason}") from None
    return json.loads(raw) if raw else None


def _aes_cbc_decrypt(data):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        out = subprocess.run(
            ["openssl", "enc", "-d", "-aes-256-cbc", "-nopad", "-K", CRED_KEY.hex(), "-iv", CRED_IV.hex()],
            input=data, capture_output=True, check=True)
        return out.stdout
    decryptor = Cipher(algorithms.AES(CRED_KEY), modes.CBC(CRED_IV)).decryptor()
    return decryptor.update(data) + decryptor.finalize()


def decrypt_credentials(local_credentials):
    """Return the decrypted credentials dict, e.g. {"serial": ..., "apPasswordHash": ...}."""
    plain = _aes_cbc_decrypt(base64.b64decode(local_credentials))
    pad = plain[-1] if plain else 0
    if 1 <= pad <= 16 and plain.endswith(bytes([pad]) * pad):
        plain = plain[:-pad]
    return json.loads(plain.decode("utf-8"))


def parse_manifest(manifest):
    """Normalise v2 and v3 manifest entries to dicts with name, serial, type, credentials."""
    devices = []
    for d in manifest or []:
        mqtt = ((d.get("connectedConfiguration") or {}).get("mqtt") or {})
        devices.append({
            "name": d.get("Name") or d.get("name") or "",
            "serial": d.get("Serial") or d.get("serialNumber") or "",
            "type": d.get("ProductType") or mqtt.get("mqttRootTopicLevel") or d.get("type") or "",
            "credentials": d.get("LocalCredentials") or mqtt.get("localBrokerCredentials"),
        })
    return devices


MDNS_SERVICE = "_dyson_mqtt._tcp.local"
MDNS_GROUP = ("224.0.0.251", 5353)


def _read_name(buf, off):
    """Read a DNS name at off (with compression). Returns name, offset after it."""
    labels, end, hops = [], None, 0
    while True:
        if off >= len(buf):
            raise ValueError("name runs past packet")
        length = buf[off]
        if length == 0:
            off += 1
            break
        if length & 0xC0 == 0xC0:
            if off + 1 >= len(buf):
                raise ValueError("bad pointer")
            if end is None:
                end = off + 2
            off = ((length & 0x3F) << 8) | buf[off + 1]
            hops += 1
            if hops > 20:
                raise ValueError("pointer loop")
            continue
        labels.append(buf[off + 1:off + 1 + length].decode("utf-8", "replace"))
        off += 1 + length
    return ".".join(labels), (end if end is not None else off)


def parse_mdns_details(packet):
    """Devices in one mDNS reply: [{serial, type_prefix, ip, host}]. Dyson names its service
    "<type>_<serial>" (e.g. "358_AB1-EU-CDE2345F"); the SRV target is a 12-character id
    ("A1B2C3D4E5F6"), the same id newer models put in their Wi-Fi name."""
    qd, an, ns, ar = struct.unpack("!4H", packet[4:12])
    off = 12
    for _ in range(qd):
        _, off = _read_name(packet, off)
        off += 4
    instances, hosts, addresses = [], [], []
    for _ in range(an + ns + ar):
        _, off = _read_name(packet, off)
        rtype, _cls, _ttl, rdlen = struct.unpack("!HHIH", packet[off:off + 10])
        off += 10
        if rtype == 12:  # PTR -> service instance
            instance, _ = _read_name(packet, off)
            first = instance.split(".", 1)[0]
            if "_" in first:
                instances.append(first.split("_", 1))
        elif rtype == 33 and rdlen > 6:  # SRV -> target host
            target, _ = _read_name(packet, off + 6)
            hosts.append(target.split(".", 1)[0])
        elif rtype == 1 and rdlen == 4:  # A
            addresses.append(socket.inet_ntoa(packet[off:off + 4]))
        off += rdlen
    return [{"serial": serial, "type_prefix": prefix, "ip": addresses[0] if addresses else None,
             "host": hosts[0] if hosts else None} for prefix, serial in instances]


def parse_mdns(packet):
    """Return {serial: ipv4} from one mDNS reply. Dyson names its service "<type>_<serial>"."""
    return {d["serial"]: d["ip"] for d in parse_mdns_details(packet) if d["ip"]}


def find_devices(timeout=3.0):
    """Ask the local network for Dyson brokers. Returns parse_mdns_details() entries."""
    found = {}
    for packet in _mdns_replies(timeout):
        for d in parse_mdns_details(packet):
            found[d["serial"]] = d
    return list(found.values())


def _mdns_replies(timeout):
    query = b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    for part in MDNS_SERVICE.split("."):
        query += bytes([len(part)]) + part.encode()
    query += b"\x00" + struct.pack("!HH", 12, 1)
    replies = []
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(0.5)
        sock.sendto(query, MDNS_GROUP)
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                continue
            try:
                parse_mdns_details(data)
            except (ValueError, struct.error):
                continue
            replies.append(data)
    except OSError:
        pass
    finally:
        sock.close()
    return replies


def find_ips(timeout=3.0):
    """Ask the local network for Dyson brokers. Returns {serial: ipv4}; empty if none answer."""
    query = b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    for part in MDNS_SERVICE.split("."):
        query += bytes([len(part)]) + part.encode()
    query += b"\x00" + struct.pack("!HH", 12, 1)
    found = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(0.5)
        sock.sendto(query, MDNS_GROUP)
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                continue
            try:
                found.update(parse_mdns(data))
            except (ValueError, struct.error):
                continue
    except OSError:
        pass
    finally:
        sock.close()
    return found


# --- Local check --------------------------------------------------------------------------------

def check_mqtt(ip, serial, password, port=1883, timeout=5.0):
    """Log in to the Dyson's local broker. Returns (True, "") or (False, reason)."""
    def s(v):
        b = v.encode()
        return struct.pack("!H", len(b)) + b
    body = s("MQTT") + bytes([4, 0xC2]) + struct.pack("!H", 30) + s("credentials-check") + s(serial) + s(password)
    n, length = len(body), bytearray()
    while True:
        d, n = n % 128, n // 128
        length.append(d | (0x80 if n else 0))
        if not n:
            break
    try:
        with socket.create_connection((ip, port), timeout=timeout) as sock:
            sock.sendall(bytes([0x10]) + bytes(length) + body)
            reply = sock.recv(4)
            sock.sendall(b"\xe0\x00")
    except OSError as e:
        return False, f"cannot reach {ip}:{port} ({e})"
    if len(reply) < 4 or reply[0] != 0x20:
        return False, "no MQTT answer"
    if reply[3] != 0:
        return False, f"login refused (code {reply[3]}: wrong serial or password)"
    return True, ""


ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# The real profile holds the device's password and is git-ignored; the committed template has
# placeholders. The driver treats them as "not set": password "password" keeps the device offline.
DEFAULT_PROFILE = os.path.join(ROOT, "profiles", "dyson-358k.yml")
TEMPLATE = os.path.join(ROOT, "templates", "dyson-358k.yml")
TEMPLATE_HEADER = ("# Template with placeholder device values (committed). tools/dyson_credentials.py creates\n"
                   "# profiles/dyson-358k.yml (git-ignored, holds the password) from it.\n")
PLACEHOLDERS = {"ipAddress": "0.0.0.0", "serialNumber": "SERIAL", "productType": "auto", "localPassword": "password"}
# profile preference name -> device field
PROFILE_PREFS = {"ipAddress": "ip", "serialNumber": "serial", "productType": "model", "localPassword": "password"}


def _yaml_quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def update_profile(path, values):
    """Set the `default:` of each preference in values ({preference name: value}) and keep every
    other line as it is. Returns the names changed. Raises ValueError if a preference is missing."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip() == "preferences:")
    except StopIteration:
        raise ValueError(f"{path} has no preferences section") from None
    current, changed = None, []
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if re.match(r"^\s*- title:", line):
            current = None
        m = re.match(r"^\s*name:\s*(\S+)\s*$", line)
        if m:
            current = m.group(1)
            continue
        m = re.match(r"^(\s*)default:", line)
        if m and current in values:
            lines[i] = f"{m.group(1)}default: {_yaml_quote(values[current])}"
            changed.append(current)
            current = None
    missing = [k for k in values if k not in changed]
    if missing:
        raise ValueError(f"{path}: no default to update for {', '.join(missing)}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return changed


def export_template(profile, template):
    """Copy the profile to the template with the four device values replaced by placeholders."""
    with open(profile, encoding="utf-8") as src:
        text = src.read()
    if text.startswith("#"):
        text = TEMPLATE_HEADER + text.split("\n", 1)[1]
    os.makedirs(os.path.dirname(template), exist_ok=True)
    with open(template, "w", encoding="utf-8") as dst:
        dst.write(text)
    update_profile(template, PLACEHOLDERS)


def ensure_profile(profile, template):
    """Create the profile from the template if it does not exist (fresh clone). Returns True if created."""
    if os.path.exists(profile):
        return False
    with open(template, encoding="utf-8") as src, open(profile, "w", encoding="utf-8") as dst:
        dst.write(src.read())
    return True


def login(host, email, country, password_prompt, otp_prompt):
    request(host, "GET", PATH_PROVISION)
    status = request(host, "POST", PATH_USER_STATUS, params={"country": country}, body={"email": email})
    if (status or {}).get("accountStatus") != "ACTIVE":
        raise DysonError(f"account status for {email}: {status}")
    challenge = request(host, "POST", PATH_EMAIL_REQUEST, params={"country": country, "culture": "en-US"},
                        body={"email": email})
    challenge_id = (challenge or {}).get("challengeId")
    if not challenge_id:
        raise DysonError(f"no challengeId in reply: {challenge}")
    password = password_prompt()
    otp = otp_prompt()
    auth = request(host, "POST", PATH_EMAIL_VERIFY, body={
        "email": email, "password": password, "challengeId": challenge_id, "otpCode": otp})
    token = (auth or {}).get("token")
    if not token:
        raise DysonError("login failed: no token in reply")
    return f"{auth.get('tokenType', 'Bearer')} {token}"


def fetch_devices(host, token):
    errors = []
    for path in PATH_MANIFESTS:
        try:
            manifest = request(host, "GET", path, token=token)
        except DysonError as e:
            errors.append(str(e))
            continue
        devices = parse_manifest(manifest)
        if devices:
            return devices
        errors.append(f"GET {path} -> no devices")
    raise DysonError("; ".join(errors))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--email", help="Dyson account email (prompted if omitted)")
    ap.add_argument("--country", default="TR", help="account country code, e.g. TR, GB, DE (default TR)")
    ap.add_argument("--region", choices=sorted(API_HOSTS), default="global")
    ap.add_argument("--serial", help="the device to use if the account has several")
    ap.add_argument("--png", metavar="FILE", help="also save the password QR code as a PNG image (owner-only)")
    ap.add_argument("--light-terminal", action="store_true", help="draw the QR code for a light terminal background")
    ap.add_argument("--update-profile", action="store_true",
                    help="developer: write serial, model and IP as defaults into the profile")
    ap.add_argument("--profile", default=DEFAULT_PROFILE, help="profile to update (default profiles/dyson-358k.yml)")
    ap.add_argument("--json", action="store_true", help="also print the found values as JSON")
    ap.add_argument("--include-password", action="store_true",
                    help="with --update-profile: also write the password (one install only; it goes into the package)")
    ap.add_argument("--user-agent", default=DEFAULT_USER_AGENT, help="User-Agent sent to the Dyson API")
    ap.add_argument("--template", default=TEMPLATE, help="placeholder profile (default templates/dyson-358k.yml)")
    ap.add_argument("--export-template", action="store_true",
                    help="only refresh the template from the profile, without the device values (no login)")
    args = ap.parse_args(argv)

    if args.export_template:
        try:
            export_template(args.profile, args.template)
        except (OSError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        print(f"Wrote {args.template} from {args.profile} with placeholder device values.")
        return 0

    HEADERS["User-Agent"] = args.user_agent
    host = API_HOSTS[args.region]
    email = args.email or input("Dyson account email: ").strip()
    try:
        token = login(
            host, email, args.country.upper(),
            password_prompt=lambda: getpass.getpass("Dyson account password: "),
            otp_prompt=lambda: input(f"Code Dyson emailed to {email}: ").strip(),
        )
        devices = fetch_devices(host, token)
    except DysonError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    ips = find_ips()
    rows = []
    for dev in devices:
        if args.serial and dev["serial"] != args.serial:
            continue
        row = {"name": dev["name"], "serial": dev["serial"], "model": dev["type"],
               "ip": ips.get(dev["serial"]), "password": None}
        if dev["credentials"]:
            try:
                row["password"] = decrypt_credentials(dev["credentials"]).get("apPasswordHash")
            except (ValueError, KeyError, subprocess.CalledProcessError) as e:
                row["error"] = f"could not decrypt credentials: {e}"
        else:
            row["error"] = "no local credentials (device without a local MQTT broker?)"
        rows.append(row)

    if args.serial and not rows:
        print(f"error: no device with serial {args.serial}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps([{k: ("<hidden>" if k == "password" and v else v) for k, v in r.items()} for r in rows],
                         indent=2, ensure_ascii=False))
    usable = [r for r in rows if r["password"]]
    if not usable:
        print("error: no device with local credentials: " + "; ".join(r.get("error", "") for r in rows), file=sys.stderr)
        return 1
    if len(usable) > 1:
        serials = ", ".join(r["serial"] for r in usable)
        print(f"error: the account has several devices ({serials}); pick one with --serial", file=sys.stderr)
        return 1
    dev = usable[0]
    if dev["ip"]:
        ok, why = check_mqtt(dev["ip"], dev["serial"], dev["password"])
        print(("Checked: logged in to the Dyson at " + dev["ip"] + " with this password.") if ok
              else f"warning: the password did not work on the Dyson at {dev['ip']}: {why}")
    show_password_qr(args, dev)
    if args.update_profile:
        return write_device(args, dev)
    return 0


def show_password_qr(args, dev):
    """Show the password as a QR code (and optionally save it as PNG); never as text."""
    import qr
    matrix = qr.encode(dev["password"])
    print(f"\n{dev['name'] or '(unnamed)'}: serial {dev['serial']}, model {dev['model']}, "
          f"IP {dev['ip'] or 'not found on this network'}\n")
    print(qr.to_terminal(matrix, dark_background=not args.light_terminal))
    if args.png:
        qr.to_png(matrix, args.png)
        os.chmod(args.png, 0o600)
        print(f"\nAlso saved as {args.png} (only you can read it; delete it when done).")
    print("\nScan this with the phone camera, copy the text, then in SmartThings open the Dyson device >")
    print("Settings > Local MQTT password and paste it. Keep it private: it gives local control of the Dyson.")


def write_device(args, dev):
    """Write the device values into the profile and report."""
    values = {pref: dev[field] for pref, field in PROFILE_PREFS.items() if dev[field]}
    if not args.include_password:
        values["localPassword"] = PLACEHOLDERS["localPassword"]
    try:
        if ensure_profile(args.profile, args.template):
            print(f"Created {args.profile} from {args.template}.")
        changed = update_profile(args.profile, values)
        os.chmod(args.profile, 0o600)  # holds the password: owner only
    except (OSError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"\n{dev['name'] or '(unnamed)'}")
    print(f"  Serial number : {dev['serial']}")
    print(f"  Model         : {dev['model']}")
    print(f"  IP address    : {dev['ip'] or 'not found on this network (profile IP left as it was)'}")
    print("  MQTT password : " + ("written to the profile" if args.include_password else
                                  "not written (the hub keeps it; use --include-password on a new hub)"))
    print(f"\nUpdated {', '.join(changed)} in {args.profile}. Reinstall the driver to use them.")
    if args.include_password:
        print("The password is now in the profile and goes into the driver package. After one install, run the tool "
              "again without --include-password and reinstall, so the package no longer carries it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

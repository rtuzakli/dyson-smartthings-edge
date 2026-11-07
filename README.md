# Dyson Humidify+Cool local SmartThings Edge driver

A SmartThings Edge driver for the Dyson Purifier Humidify+Cool (product type 358K). It runs on the
SmartThings hub and talks to the Dyson's local MQTT broker on port 1883. It does not use the Dyson
cloud or the internet.

Source and issues: https://github.com/rtuzakli/dyson-smartthings-edge

**Tested with:** Dyson Purifier Humidify+Cool, product type 358K. Scan nearby also adds other Dyson
models it finds on the network, but they are untested: their fields and functions (for example heating
on Hot+Cool models) may differ, and some rows may stay empty.

Current version: **0.1.20** (`src/driver_version.lua`; the hub log shows it as
`dyson: driver 0.1.20 connected to ...`). For a release, bump that file and, if the app layout
changed, create a new device configuration (see "Capabilities and presentations").

## What the colors mean

**Activity** (what the Dyson is doing now):

| Row | 🟢 | 🟡 | 🔴 | ⚪ | 🔵 |
| --- | --- | --- | --- | --- | --- |
| Purifier | fan running, air goes through the filter | on, fan paused (Auto, air is clean) | stopped by a problem, see Attention | off | |
| Humidifier | humidifying | on, waiting (target humidity reached) | stopped by a problem, e.g. water tank removed | humidification off | deep clean running |
| Night mode | on | | | off | |

**Air Quality** (Dyson's own scales, as in the MyDyson app):

| Row | 🟢 Good | 🟡 Fair | 🟠 Poor | 🔴 Very poor | 🟣 Extremely poor | ⚫ Severe |
| --- | --- | --- | --- | --- | --- | --- |
| PM2.5 (µg/m³) | 0–35 | 36–53 | 54–70 | 71–150 | 151–250 | 251+ |
| PM10 (µg/m³) | 0–50 | 51–75 | 76–100 | 101–350 | 351–420 | 421+ |
| TVOC (Dyson index 0–10) | 0–3 | 4–6 | 7–8 | 9–10 | | |
| NO₂ (Dyson index 0–10) | 0–3 | 4–6 | 7–8 | 9–10 | | |
| Formaldehyde (mg/m³) | 0–0.097 | 0.098–0.245 | 0.246–0.490 | 0.491+ | | |
| Air quality | the worst of the five rows above | | | | | |

**Attention** has no ball: it appears only when something needs you (e.g. "Water tank removed",
"Enter the local MQTT password in Settings") and is hidden otherwise.

## Compared with the default (Matter) integration

The MyDyson app can share the Dyson with SmartThings over Matter (Dyson app > Smart home > Matter
code, then SmartThings > Add device > Scan QR code). SmartThings then uses its built-in Matter
driver. Compared on the Purifier Humidify+Cool (358K):

| | Built-in Matter driver | This driver |
| --- | --- | --- |
| Setup | scan a QR code | Scan nearby + paste the password from a QR code (needs a computer once) |
| Runs locally on the hub | yes | yes |
| Power, fan mode, fan speed | ✅ | ✅ |
| Oscillation | on/off | 45°, 90°, Breeze, Custom angles |
| Humidifier on/off, Auto, target | ❌ | ✅ |
| Water tank and other warnings | ❌ | ✅ (Attention) |
| What the Dyson is doing now | ❌ | ✅ (Activity) |
| Temperature, humidity, PM2.5, PM10 | ✅ | ✅ |
| TVOC, NO₂ | level only | level and number |
| Formaldehyde | value shown as 0.000 | ✅ |
| Air quality colors per reading | ❌ | ✅ |
| Airflow direction, sleep timer, deep clean, water hardness, continuous monitoring | ❌ | ✅ |
| Filter life | HEPA and carbon, with reset | HEPA, with reset |
| Device name | "Purifier Hot+Cool De-NOx" (wrong model) | "Dyson Humidify+Cool" |

For a purifier-only Dyson, Matter is the easier choice; for a Humidify+Cool, the humidifier is
only available with this driver.

## Contents

```text
config.yml                 Driver name, packageKey, permissions (lan, discovery)
profiles/dyson-358k.yml    Device profile with your device values and password (git-ignored)
templates/dyson-358k.yml   The same profile with placeholder values (committed)
src/init.lua               SmartThings side: lifecycle, connection loop, events, commands
src/dyson.lua              Dyson protocol: topics, state parsing, levels, command payloads, mDNS pick
src/mqtt.lua               Minimal MQTT 3.1.1 client (QoS 0), socket injected for testing
src/driver_version.lua     Driver version string
capabilities/              Custom capabilities oscillationAngle, activity, autoHumidity, targetHumidity, airQuality, attention
presentation/              Current device configuration (app layout): input and server reply
tools/dyson_credentials.py Gets the MQTT password from your Dyson account and shows it as a QR code
tools/qr.py                Small stdlib-only QR code encoder used by the tool
test/unit_test.lua         Offline unit tests of dyson.lua and mqtt.lua (plain Lua 5.3)
test/init_test.lua         init.lua against a fake SmartThings runtime, Dyson broker and clock
test/live_test.lua         Talks to a real Dyson from your computer
test/test_dyson_credentials.py  Offline tests for the credentials tool
```

## Prerequisites

- **SmartThings CLI v3.** It needs Node 22, so load it through nvm first:

  ```bash
  source ~/.nvm/nvm.sh && nvm use 22
  npm install -g @smartthings/cli    # once
  smartthings --version              # 3.x
  ```

  The first command that calls the API opens a browser to sign in.

- **Docker**, to run the Lua tests. The host has no Lua installation. The tests use the `alpine`
  image and install Lua packages inside it.

- **The Dyson's local MQTT password.** This is the decrypted local broker password (Dyson calls it
  `apPasswordHash`), not your Wi-Fi or Dyson account password. Get it with the tool below.

## Adding a Dyson

1. **Install the driver** on the hub (channel invite, or `edge:drivers:package` for development).
2. **SmartThings app > Add device > Scan nearby.** The driver finds every Dyson on the network over
   mDNS and adds one device per Dyson, with its serial in the network id (`dyson:<type>:<serial>`),
   so a second scan never duplicates a device. The model is detected at the first connect: the
   driver asks for the state on `<type>K`, `<type>E`, `<type>M` and `<type>` and keeps the one the
   Dyson answers on.
3. **Get the password** on a computer (once per Dyson):

   ```bash
   python3 tools/dyson_credentials.py --email you@example.com --country TR
   ```

   It asks for the Dyson account password and the code Dyson emails you, finds the Dyson on the
   network, checks the password by logging in to it, and shows it as a **QR code** on the terminal.
   It never prints the password as text. `--png FILE` also saves the QR code as an image (owner-only),
   and `--light-terminal` is for terminals with a light background.
4. **Scan the QR code with the phone camera**, copy the text, then open the Dyson device in
   SmartThings > Settings > Local MQTT password and paste it.

Until the password is set, the Attention section says "Enter the local MQTT password in
Settings". A wrong password shows "Local MQTT password is wrong". Serial number and Product type
stay `SERIAL` and `auto`; set them only to pin a Dyson or if model detection fails.

### Where the MQTT password lives

- The setting you paste it into, in your SmartThings account (private to it).
- A copy on the hub: the driver keeps the last real password in a persisted device field
  (`mqtt_password`), so the profile itself carries only the placeholder `password`.
- Never in the driver package: `profiles/dyson-358k.yml` holds only placeholders.

### Developer options

- `--update-profile` writes serial, model and IP as profile defaults; with `--include-password` also
  the password. That puts the password into the driver package, so use it for one install only (the
  hub keeps a copy), then run the tool again with `--update-profile` but without `--include-password`
  and reinstall.
- `profiles/dyson-358k.yml` is git-ignored and readable only by you; `templates/dyson-358k.yml`
  (placeholders `0.0.0.0`, `SERIAL`, `auto`, `password`) is committed. On a fresh clone the tool
  creates the profile from the template. After changing the profile, refresh the template:
  `python3 tools/dyson_credentials.py --export-template`. A test fails if the two drift apart.
- `HTTP 429 ... error code: 1015` means Dyson's Cloudflare front is rate-limiting your network: wait
  15-30 minutes, each try extends the block. The tool sends the Dyson app's User-Agent
  (`DysonLink/...`, as libdyson-rest does); `--user-agent` overrides it.
- Other options: `--serial` if the account has several Dysons, `--profile`, `--json` (password hidden),
  `--region china`. It needs Python 3 and either the `cryptography` package or the `openssl` command.

## Your IDs

The development commands below use these shell variables. Fill in your own values:

```bash
HUB=<hub-id>          # smartthings devices -j: the device with "type": "HUB"
HUB_IP=<hub-ip>       # the hub's address on your network (router or SmartThings app > Hub > Information)
CHANNEL=<channel-id>  # smartthings edge:channels (create one with edge:channels:create)
DRIVER=<driver-id>    # smartthings edge:drivers (after the first package upload)
DEVICE=<device-id>    # smartthings devices (the Dyson, after Scan nearby)
```

## SmartThings CLI cheat sheet

Run these from the repository root.

### Build and install the driver

```bash
smartthings edge:drivers:package . --channel $CHANNEL --hub $HUB
```

This uploads a new driver version, assigns it to the channel and installs it on the hub. The hub
restarts the driver and the device reconnects within a few seconds. The device keeps its ID and
history. Do not remove and re-add the device after an update: that creates a new device ID,
loses the history graphs and breaks routines. To build a zip without uploading it, use
`smartthings edge:drivers:package . -b dyson.zip`.

### Watch the driver log

```bash
smartthings edge:drivers:logcat $DRIVER --hub-address $HUB_IP
```

The driver's own lines start with `dyson:`. After a connect you should see
`dyson: driver <version> connected to <ip> (mDNS)`. Press Ctrl+C to stop.

### Inspect and control the device

```bash
smartthings devices:status $DEVICE -j                    # all current attribute values
smartthings devices:commands $DEVICE main:refresh:refresh # re-request state and re-send all values
smartthings devices:commands $DEVICE main:switch:on       # <component>:<capability>:<command> [args]
smartthings devices:history $DEVICE                      # recent events
```

### Drivers, channels and hubs

```bash
smartthings edge:drivers:installed --hub $HUB             # drivers on the hub, with versions
smartthings edge:drivers:uninstall $DRIVER --hub $HUB     # removes the driver and its devices
smartthings edge:channels:enroll $HUB --channel $CHANNEL  # once per hub
```

### Capabilities and presentations

The app's layout comes from the device configuration (`vid`) named in the profile's `metadata`.
The CLI has no update or delete for device configurations; every change makes a new `vid`.
To change the layout, edit `presentation/device_config.json`, then:

```bash
smartthings presentation:device-config:create -j -i presentation/device_config.json \
  > presentation/created_device_config.json
# put its presentationId into metadata.vid in profiles/dyson-358k.yml, then reinstall
```

To start from the platform's default layout for a profile instead, use
`smartthings presentation:device-config:generate <profile-id> -j`.

Rows can depend on another value with `visibleCondition`. Set `hideOnUnmatch: true` to hide the
row; without it the server stores `false` and the row is only greyed out. Current rules:
fan speed is hidden while the fan mode is `auto`, and the angle setting is shown only while the
oscillation mode is `Custom`.

Custom capabilities:

```bash
smartthings capabilities:create -j -i capabilities/<name>.json
smartthings capabilities:presentation:create <capability-id> -j -i capabilities/pres_<name>.json
smartthings capabilities <capability-id> -j               # show a definition
smartthings capabilities:presentation <capability-id> -j  # show how the app renders it
```

### Virtual devices for UI experiments

To see how the app renders a value without touching the real device, create a virtual device on
the same profile and send it events:

```bash
cat > vd.json <<EOF
{"name": "Test", "owner": {"ownerType": "LOCATION", "ownerId": "<location-id>"},
 "deviceProfileId": "<profile-id>"}
EOF
smartthings virtualdevices:create -j -i vd.json
echo '[{"component":"main","capability":"nitrogenDioxideMeasurement",
        "attribute":"nitrogenDioxide","value":0.08,"unit":"ppm"}]' > ev.json
smartthings virtualdevices:events <virtual-device-id> -j -i ev.json
smartthings devices:delete <virtual-device-id>            # clean up afterwards
```

`smartthings locations` lists location IDs. `smartthings devices:status $DEVICE -j` shows the
profile ID. Events must be a JSON array passed with `-i`.

## Testing

### 1. Unit tests (offline, seconds)

```bash
docker run --rm -v "$PWD":/w:ro -w /w alpine sh -c \
  "apk add -q lua5.3 lua5.3-cjson && luac5.3 -p src/*.lua && lua5.3 test/unit_test.lua &&
   lua5.3 test/init_test.lua &&
   for f in src/*.lua; do luac5.3 -l -p \$f | grep -oE '_ENV \"[A-Za-z_]+\"' | sort -u; done"
```

Prints `UNIT OK` and `INIT OK`. `unit_test.lua` covers MQTT packets, Dyson state parsing, air quality levels, command payloads, oscillation rules and mDNS selection. `init_test.lua` loads the real `init.lua` with fake `st.*` modules, a fake broker and a fake clock, and checks connecting, events, re-sends, command payloads (monitoring keeps power on, Custom carries a range), the tank warning, a missing hub attribute and dead-link detection. The global-name list must show only Lua built-ins.

The credentials tool has its own offline tests (decryption, both manifest formats, the login
flow against a fake API, a real Dyson mDNS reply, the profile update on a copy of the real profile):

```bash
python3 test/test_dyson_credentials.py
```

### 2. Live test against the Dyson (from your computer)

```bash
docker run --rm --network host \
  -e DYSON_IP=192.168.1.50 -e DYSON_SERIAL=AB1-EU-CDE2345F -e DYSON_TYPE=358K -e DYSON_PW='<password>' \
  -v "$PWD":/w:ro -w /w alpine sh -c \
  "apk add -q lua5.3 lua5.3-socket lua5.3-cjson && lua5.3 test/live_test.lua"
```

This connects to the Dyson with the same `mqtt.lua` and `dyson.lua` the hub uses, requests state
and sensor data, and prints every derived value. It ends with `LIVE OK`. The Dyson accepts
several clients at once, so the hub stays connected while this runs.

### 3. On the hub

1. Install: `smartthings edge:drivers:package . --channel $CHANNEL --hub $HUB`.
2. In a second terminal, run `logcat` (see above) and check for `dyson: connected to ... (mDNS)`
   and no `session crashed` or `connect ... failed` lines.
3. Run `smartthings devices:status $DEVICE -j` and compare the values with the Dyson app.
4. Change something in the SmartThings app (fan speed, oscillation, humidifier) and check that
   the Dyson follows. Change it on the Dyson and check that the app follows.

## Behaviour notes

- **Finding the Dyson.** On every connect the driver looks for `_dyson_mqtt._tcp` over mDNS and
  picks the record whose name contains the serial (the 358K announces `358_<serial>`). If that
  fails it uses the last address that worked, then the optional IP preference. A DHCP
  reservation is no longer required.
- **Updates.** State changes arrive as pushed messages. Sensor data and faults are requested every 60 s.
  All values are re-sent 30 s and 2 min after connecting (SmartThings can drop events right after an
  update) and then hourly.
- **Device page.** From the top: **Attention** (custom `attention`; a plain message such as "Water tank
  removed", hidden while there is no problem), **Activity** (custom `activity`; Purifier, Humidifier,
  Night mode as balls: 🟢 running, 🟡 on but waiting, 🔴 stopped by a warning, ⚪ off, 🔵 deep clean),
  **Air Quality** (custom `airQuality`; Air quality, PM2.5, PM10, TVOC, NO₂, Formaldehyde as balls in
  Dyson's colours 🟢 🟡 🟠 🔴 🟣 ⚫), SmartThings' own rows, then the controls. The **Humidifier**
  section has the on/off switch, an **Auto** picker that reads e.g. "On (40%)" (custom `autoHumidity`; a picker, because the app ignores
  custom text on switches) and,
  only while Auto is off, a **Target** slider (custom `targetHumidity`).
  The app shows short state values two per row in large type, ignores line breaks and cuts text
  after two lines, and the driver cannot change the font size, so values are kept very short
  (`right_now`, `warning_text`, `level_ball` in `src/dyson.lua`).
- **Text on controls.** A `toggleSwitch` always shows the app's own On/Off. A `list` (picker) shows the
  current value through `state.alternatives`, which the server requires, so every possible text must be
  listed there (`pres_auto_humidity.json` lists "On (0%)" to "On (100%)").
- **Changing a custom capability.** The hub caches capability definitions. After adding attributes to an existing capability, the hub kept the old definition and every new attribute event failed. Create a new capability instead, and create a new device configuration: the server stores the capability presentation inside the configuration, and an unchanged configuration keeps its old `vid`.
- **Offline detection.** After each command the driver also asks for the state, which the Dyson always answers. No reply within 10 s, or no traffic for 35 s, counts as a dead link: the device goes offline in the app and the driver reconnects.
- **Warnings.** Besides `ercd`/`wacd` in the state, the Dyson publishes a fault report on `<type>/<serial>/status/faults` (`CURRENT-FAULTS`, about 90 entries, each `OK` or `FAIL`). The driver asks for it on connect, every 60 s and after every state change. `FAULT_TEXT`, `WARNING_TEXT` and `ERROR_TEXT` in `src/dyson.lua` turn entries into text; unknown ones show as "Dyson warning <key>" or "Dyson error <key>". Confirmed: `product-warnings.tnkp` = water tank removed. From the key names only: `tnke` tank empty, `fltr` filter, `cldu` deep clean due.
- **TVOC value.** Dyson's 0-10 VOC index is sent in µg/m³, mapped onto the UBA indoor guide bands so
  each Dyson level lands in its band (`voc_ugm3` in `src/dyson.lua`). Not a real concentration.
- **NO2 value.** Dyson reports NO2 as a 0-10 index, but the app draws its own bar for
  `nitrogenDioxideMeasurement` and treats the value as ppm. The driver sends index x 0.025 so the
  bar color matches the Dyson level. The ppm number in the app is therefore not a real
  concentration. See `NO2_PPM_PER_INDEX` in `src/dyson.lua`.
- **Air quality levels.** Each reading is banded with the scale shown in the MyDyson app (`BANDS`
  in `src/dyson.lua`). The overall level is the worst of PM2.5, PM10, VOC, NO2 and HCHO, like the
  Dyson app. Dyson's six levels (Good to Severe) map in order to the six SmartThings
  `airQualityHealthConcern` values (good to hazardous).
- **App limits.** The SmartThings app decides which readings get bars and history graphs. Custom
  capabilities get neither.

## Pitfalls

- `config.yml` needs `permissions: lan: {}` for sockets. Permissions cannot change on an existing
  driver; changing them needs a new `packageKey`, which is a new driver.
- The profile name passed to `try_create_device` must match the profile's `name:` field.
- Do not name a module in `src/` after a SmartThings library module. A `src/version.lua` hid the
  platform's `version` module and crashed the driver at start (`st/driver.lua:1124: attempt to
  compare number with nil`).
- Renaming the profile: the driver moves existing devices once with `try_update_metadata` and
  remembers it in the persisted `profile` field. The device's internal `name` keeps the old
  profile name; that is cosmetic.
- **Password:** keep the real password out of `profiles/dyson-358k.yml` except for one install on a new
  hub (see "Where the MQTT password lives"); driver versions uploaded with it stay stored on
  SmartThings. Never create a channel invite while a password is in the profile.

# signal_landline_registration

A guided shell script for registering a **landline number** with Signal via
[`bbernhard/signal-cli-rest-api`](https://github.com/bbernhard/signal-cli-rest-api)
in a Home Assistant environment.

Landline registration requires two separate API calls (SMS attempt first,
then voice call) plus a captcha token for each — a process that is easy to
get wrong manually. This script handles the timing, token stripping, and
error detection automatically.

## Requirements

- Home Assistant with the **Signal Messenger** add-on
  (`bbernhard/signal-cli-rest-api`) installed
- Add-on must be running in **`normal` mode** during registration
  (switch back to `json-rpc` after registration is complete)
- `curl` available in the terminal (standard in HA SSH add-on)
- A Chrome browser on the **same IP address** as the HA host to solve the
  captcha (Firefox and VPNs are known to cause captcha failures)

## Installation

Copy the script to a location accessible from your HA terminal.
A suitable location is:

```
/config/scripts/signal_registration_helper.sh
```

Do **not** place it inside the add-on config directory
(`/addon_configs/1315902c_signal_messenger/`) — that directory belongs to
the add-on and should not contain unrelated files.

## Configuration

Edit the top of the script before running:

```bash
HA_IP="homeassistant"   # hostname or IP of your HA host
API_PORT="8080"         # TCP port of the Signal Messenger add-on (normal mode)
PHONE=""                # optional: pre-fill your landline number (+49...)
DEBUG=false             # set to true for verbose HTTP status output
```

## Usage

**Before running:** switch the Signal Messenger add-on to `normal` mode:

> HA → Settings → Add-ons → Signal Messenger → Configuration → Mode: `normal` → Restart

Then run the script from the HA terminal:

```bash
bash /config/scripts/signal_registration_helper.sh
```

The script guides you through five steps:

1. **SMS attempt** — expected to fail for landlines (no SMS possible)
2. **Wait 60 seconds** — required by Signal before a voice attempt
3. **Voice call** — Signal calls your landline with a 6-digit code
4. **Enter verification code** — from the call
5. **Verify registration** — confirms the number is registered

**After successful registration:** switch the add-on back to `json-rpc` mode:

> HA → Settings → Add-ons → Signal Messenger → Configuration → Mode: `json-rpc` → Restart

## Captcha instructions

When prompted for a captcha:

1. Open in Chrome: `https://signalcaptchas.org/registration/generate.html`
2. Solve the captcha
3. When Chrome asks to open Signal — click **Cancel**
4. Right-click the **"Open Signal"** link → **Copy link address**
5. Paste the complete link into the script (with or without the leading
   `signalcaptcha://` — the script strips it automatically)

> **Important:** You need a fresh captcha token for both Step 1 and Step 3.
> Tokens expire quickly. Have the terminal ready before solving the captcha.

## Error handling

| HTTP code | Meaning | Action |
|---|---|---|
| 200 / empty | Success | Continue |
| 400 (Step 1) | No SMS for landline — expected | Continue to voice |
| 400 (Step 3) | Captcha expired or wrong format | Get fresh captcha, retry |
| 429 | Rate limited by Signal | Wait 48–72 hours, do not retry |
| 502 | Signal server unavailable | Wait a few minutes, retry |
| 0 | Add-on not reachable | Check add-on status and port |

## Notes

- The script uses a temporary file (`mktemp`) to capture HTTP status codes
  from curl without subshell variable scoping issues. The file is
  automatically removed on exit via `trap`.
- Rate limiting is per phone number on Signal's servers. Previous failed
  attempts with the same number count toward the limit regardless of
  which tool was used.
- The add-on's `data/accounts.json` may contain leftover entries from
  previous failed registration attempts. These can be safely removed
  (with the add-on stopped) by editing `accounts.json` to
  `{"accounts":[],"version":2}` and deleting the corresponding number
  subdirectories.


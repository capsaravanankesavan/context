---
name: luci-thrift-helper
description: >
  Execute Luci (and other Capillary service) thrift calls via the in-house API Tester app
  at apitester.capillary.in. Accepts a service method + params in natural language or raw JSON,
  builds the curl payload, fires the request, and presents parsed results with stats fields
  highlighted. Use this skill whenever the user wants to call a Luci thrift method, check
  coupon series stats, issue/redeem/revoke coupons, or inspect any getCouponConfiguration
  response on any cluster. Trigger on /luci-thrift-helper or any request like "call
  getCouponConfiguration for series X", "check numTotal on uscrm", "hit the thrift API for...".
---

# Luci Thrift Helper

Execute Capillary thrift API calls via apitester.capillary.in — securely, without exposing
session cookies to the model.

---

## Step 0 — Cookie check (always first)

Before building any payload, verify the cookie is available using Bash:

```bash
COOKIE=$(cat ~/.capillary/apitester_cookies 2>/dev/null)
if [ -z "$COOKIE" ]; then
  COOKIE="${APITESTER_COOKIE}"
fi
if [ -z "$COOKIE" ]; then
  echo "COOKIE_MISSING"
fi
```

If the output is `COOKIE_MISSING`, stop and show the user this one-time setup guide:

```
One-time setup — store your apitester.capillary.in session cookie:

Option A — env var (add to ~/.zshrc or ~/.bash_profile):
  export APITESTER_COOKIE='<paste your full cookie string here>'
  source ~/.zshrc   # or open a new terminal

Option B — file (recommended, survives shell restarts):
  mkdir -p ~/.capillary
  echo '<paste your full cookie string here>' > ~/.capillary/apitester_cookies
  chmod 600 ~/.capillary/apitester_cookies

To get your cookie string:
  1. Open https://apitester.capillary.in in Chrome
  2. DevTools (F12) → Network tab → click any request
  3. Request Headers → find "Cookie:" → copy the entire value

After setting up, re-run your command.
```

**Security rule:** Never echo, log, print, or include the cookie value in any response text
sent to the model. It is read by Bash at execution time only.

---

## Step 1 — Identify method, cluster, and params

### Supported methods and their required params

| Method | Service | Required | Optional |
|--------|---------|----------|----------|
| `getCouponConfiguration` | `LuciService` | `orgId`, `couponSeriesId` | `storeUnitId`, `includeExpired`, `uploadInfoRequired` |
| `getAllCouponConfigurations` | `LuciService` | `orgId` | `seriesCodes[]`, `couponSeriesIds[]`, `limit`, `offset` |
| `issueCoupon` | `LuciService` | `orgId`, `couponSeriesId`, `userId`, `billId` | `storeUnitId` |
| `redeemCoupon` | `LuciService` | `orgId`, `couponCode`, `userId`, `billId`, `storeUnitId` | `shouldCommit` |
| `revokeCoupon` | `LuciService` | `orgId`, `couponCode` | |
| `getCouponDetails` | `LuciService` | `orgId`, `couponCode` | |

For any unlisted method, accept a raw JSON `jsonref` payload from the user and wrap it.

### Clusters

| Short name | Use for |
|-----------|---------|
| `uscrm` | US production |
| `nightly_cc` | Nightly / QA (default if not specified) |
| `incrm` | India production |
| `sgcrm` | Singapore production |
| `eucrm` | EU production |
| `crm-staging-new` | Staging |

Default to `nightly_cc` if the user does not specify a cluster.

---

## Step 2 — Build the payload

Construct the `--data-raw` JSON string. Use a unique `requestId` each call
(format: `claude_<epoch_seconds>`). Get epoch via Bash: `date +%s`.

**Payload structure:**
```json
{
  "request": "thriftLoad",
  "module": "luci",
  "cluster": "<cluster>",
  "service": "<ServiceName>",
  "method": "<methodName>",
  "requiredParams": false,
  "jsonref": {
    "request": {
      "requestId": "claude_<epoch>",
      <...method params...>
    }
  }
}
```

**Example — getCouponConfiguration:**
```json
{
  "request": "thriftLoad",
  "module": "luci",
  "cluster": "uscrm",
  "service": "LuciService",
  "method": "getCouponConfiguration",
  "requiredParams": false,
  "jsonref": {
    "request": {
      "requestId": "claude_1749500000",
      "orgId": 2000000,
      "couponSeriesId": 811192,
      "includeProductInfo": false,
      "includeExpired": false,
      "uploadInfoRequired": false,
      "includeUnclaimed": false
    }
  }
}
```

---

## Step 3 — Execute the curl

Run the request in a single Bash block, reading the cookie at execution time.
Never interpolate the cookie value into the skill instructions or response text.

```bash
COOKIE=$(cat ~/.capillary/apitester_cookies 2>/dev/null)
if [ -z "$COOKIE" ]; then
  COOKIE="${APITESTER_COOKIE}"
fi
PAYLOAD='<constructed JSON payload>'
curl -s 'https://apitester.capillary.in/apitest_app/thriftHelper' \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'X-Requested-With: XMLHttpRequest' \
  -H 'User-Agent: claude-luci-helper' \
  -H 'Origin: https://apitester.capillary.in' \
  -H 'Referer: https://apitester.capillary.in/apitest_app/thriftHelper.html' \
  -b "$COOKIE" \
  --data-raw "$PAYLOAD"
```

---

## Step 4 — Parse and present results

### Status check
- If `"status": "pass"` → success
- If `"status": "fail"` or no status → show the error message prominently

### Stats fields to extract and highlight (when present)

Pull these out of the response and present them in a clean table:

| Field | What it means |
|-------|--------------|
| `numTotal` | Total codes ever uploaded (TC = NONE + USER_ID), decrements on revoke |
| `num_uploaded_total` | Total upload supply ledger (UTC) — should equal numTotal when bug-free |
| `num_uploaded_nonIssued` | Available NONE pool (UC) — unissued NONE codes |
| `num_issued` | Issued coupons (IC − RIC + blueprint) |
| `num_redeemed` | Redeemed coupons (RC − RRC + blueprint) |
| `latestIssualTime` | Last issue timestamp — convert epoch ms → human-readable |
| `latestRedemptionTime` | Last redemption timestamp — convert epoch ms → human-readable |

**Epoch conversion (ms):** divide by 1000 and format as `YYYY-MM-DD HH:MM:SS UTC`.

### Exception fields
If an `ex` field is present in the response, highlight:
- `ex.errorCode`
- `ex.errorMsg`

### Pool invariant check (when numTotal and num_issued are present)
Automatically compute and show:
```
Pool (numTotal − num_issued) = X
num_uploaded_nonIssued (UC)  = Y
Match: ✅ / ❌
```

### TC vs UTC gap (upload bug signal)
When both `numTotal` and `num_uploaded_total` are present:
```
numTotal (TC)              = X
num_uploaded_total (UTC)   = Y
Gap (TC − UTC)             = Z  ← non-zero means USER_ID uploads not counted in UTC (FR-014 bug)
```

### Output format

Always output ALL of the following sections in order — never truncate or omit any section:

```
## Result — <method> on <cluster>
**Status:** pass ✅ / fail ❌

### Key Stats
| Field | Value |
...

### Invariant Checks
Pool match: ✅/❌
TC−UTC gap: Z (note if non-zero)

### Full Raw Response
<print the complete, untruncated raw response string here — every field, no ellipsis, no summarising>
```

**The full raw response must be printed in its entirety.** Do not use `...` placeholders,
do not summarise fields, do not collapse it into a `<details>` block. The user needs to
read every field directly in the response. Paste the complete JSON/message string verbatim.

---

## Edge cases

- **Array response** (e.g., `getAllCouponConfigurations` returns a list): show stats for each
  series in a compact table; full raw response in the collapsible section.
- **HTTP error / no JSON back**: show the raw response and suggest checking cookie freshness.
- **Session expired** (response contains "login" or "session"): tell the user to refresh the
  cookie using the setup instructions above.
- **User provides raw JSON payload**: skip Steps 1–2, use the provided payload directly in Step 3.

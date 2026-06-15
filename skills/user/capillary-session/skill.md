# Capillary Session Refresh

Refresh session credentials for Capillary in-house tools (API Tester cookie, MySQL session)
by reading live network request headers from an open browser tab — no manual copy-paste needed.

## Security Rules

- NEVER echo, log, print, or include any credential value (cookie string, password) in any
  response text. Credentials are read from the browser or clipboard at execution time only.
- After writing a credential file, confirm with: "Cookie updated in `~/.capillary/{file}`" — nothing more.
- Do NOT display partial cookie values, lengths, or any substring.

---

## Invocation

`/capillary-session [target]`

Targets:
| Invocation | What it refreshes | Output file |
|---|---|---|
| `/capillary-session` (default) | apitester.capillary.in cookie | `~/.capillary/apitester_cookies` |
| `/capillary-session apitester` | apitester.capillary.in cookie | `~/.capillary/apitester_cookies` |
| `/capillary-session mysql uscrm_dbmaster_1` | MySQL session command | `~/.capillary/mysql_uscrm_dbmaster_1` |

---

## Execution — apitester cookie (default)

### Method A — Chrome MCP (automated, preferred)

Use ToolSearch to load the Chrome MCP network tool schema, then:

1. Use `mcp__Claude_in_Chrome__read_network_requests` (or `mcp__Control_Chrome__*` equivalent)
   to list recent network requests from the active browser tab.

2. Filter for requests to `apitester.capillary.in` — specifically the `thriftHelper` endpoint.
   If no matching request found, instruct the user:
   > "No thriftHelper request found in the browser. Open apitester.capillary.in → Thrift Helper,
   > make any API call (e.g. click 'Validate JSON And Make Call'), then re-run `/capillary-session`."

3. Extract the `Cookie:` header value from the matched request. Do NOT display it.

4. Write to file via Bash — pass the value through an env variable, never inline in the command:
   ```bash
   # Value is passed as an env var COOKIE_VAL — never echo it
   printf '%s' "$COOKIE_VAL" > ~/.capillary/apitester_cookies
   chmod 600 ~/.capillary/apitester_cookies
   echo "WRITE_OK"
   ```

5. If output is `WRITE_OK`, respond: "Cookie updated in `~/.capillary/apitester_cookies`."

### Method B — Clipboard fallback (if Chrome MCP unavailable)

If Chrome MCP tools are unavailable or return no result, instruct the user:

> "Chrome MCP not available. To refresh manually:
> 1. Open apitester.capillary.in → DevTools (F12) → Network
> 2. Make any Thrift Helper call
> 3. Click the `thriftHelper` request → Headers → find `Cookie:` → copy the full value
> 4. Run: `pbpaste > ~/.capillary/apitester_cookies && chmod 600 ~/.capillary/apitester_cookies`"

Then ask: "Or paste the cookie value here and I'll write it for you." If the user pastes it,
write it via the env-var Bash pattern above — NEVER echo it back.

---

## Execution — MySQL session (mysql target)

MySQL session files contain the full `mysql -h ... -u ... -p...` command string.
These expire daily and must be renewed from the in-house session tool.

If the user invokes `/capillary-session mysql {identifier}`:

1. Instruct the user:
   > "Open the in-house session tool → MySQL → select cluster `{cluster}` → copy the connection command."

2. Ask the user to paste the command. Write it via Bash:
   ```bash
   printf '%s' "$MYSQL_CMD_VAL" > ~/.capillary/mysql_{identifier}
   chmod 600 ~/.capillary/mysql_{identifier}
   echo "WRITE_OK"
   ```

3. Confirm: "MySQL session updated in `~/.capillary/mysql_{identifier}`."

---

## Credential file inventory

| File | Used by | Expires |
|------|---------|---------|
| `~/.capillary/apitester_cookies` | `/luci-thrift-helper` | Browser session |
| `~/.capillary/mysql_uscrm_dbmaster_1` | `/mysqldb-query` | Daily |
| `~/.capillary/mysql_uscrm_dbmaster_2` | `/mysqldb-query` | Daily |
| `~/.capillary/mysql_eucrm_dbmaster_1` | `/mysqldb-query` | Daily |
| `~/.capillary/mysql_incrm_dbmaster_1` | `/mysqldb-query` | Daily |

Add rows as new shards are provisioned.

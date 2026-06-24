# Redis Query

Query a Capillary Redis server via the redis-go-proxy using a stored credential file.
Auto-detects Java-serialized Spring cache values and decodes them to human-readable output.

---

## Security Rule

NEVER echo, log, print, or include the contents of the credential file or the auth token
in any response text. The credential file is read by Bash at execution time only.

---

## Destructive / Write Command Rule — ABSOLUTE, NO EXCEPTIONS

This skill is **strictly READ-ONLY**. The following rules apply unconditionally:

**NEVER execute any of these commands via Bash, under any circumstances, even if the user explicitly asks:**

- Write: `SET`, `SETEX`, `SETNX`, `SETRANGE`, `MSET`, `MSETNX`, `GETSET`, `GETDEL`, `GETEX`
- Delete: `DEL`, `UNLINK`, `EXPIRE`, `EXPIREAT`, `PEXPIRE`, `PEXPIREAT`, `PERSIST`
- Flush: `FLUSHDB`, `FLUSHALL`
- Increment/Decrement: `INCR`, `INCRBY`, `INCRBYFLOAT`, `DECR`, `DECRBY`
- List/Set/Hash writes: `LPUSH`, `RPUSH`, `LSET`, `LINSERT`, `LPOP`, `RPOP`, `SADD`, `SREM`,
  `ZADD`, `ZREM`, `HSET`, `HMSET`, `HDEL`
- Rename / Move: `RENAME`, `RENAMENX`, `MOVE`, `COPY` (with REPLACE), `RESTORE`
- Pub/Sub: `PUBLISH`
- Admin: `DEBUG`, `CONFIG SET`, `SAVE`, `BGSAVE`, `BGREWRITEAOF`, `SHUTDOWN`, `SLAVEOF`
- Script: `EVAL`, `EVALSHA`, `SCRIPT LOAD`
- Any command not in the explicit READ-ONLY allowed list below

**Allowed read-only commands (exhaustive list):**
`GET`, `MGET`, `GETRANGE`, `STRLEN`, `EXISTS`, `TYPE`, `TTL`, `PTTL`,
`KEYS`, `SCAN`, `HSCAN`, `SSCAN`, `ZSCAN`,
`HGET`, `HMGET`, `HGETALL`, `HKEYS`, `HVALS`, `HEXISTS`, `HLEN`,
`LRANGE`, `LLEN`, `LINDEX`,
`SMEMBERS`, `SCARD`, `SISMEMBER`, `SMISMEMBER`, `SRANDMEMBER`,
`ZRANGE`, `ZREVRANGE`, `ZRANGEBYSCORE`, `ZREVRANGEBYSCORE`, `ZCARD`, `ZSCORE`, `ZRANK`,
`OBJECT ENCODING`, `OBJECT IDLETIME`, `OBJECT FREQ`,
`DEBUG OBJECT` (read-only info only), `DUMP`, `INFO` (read-only sections)

**If the user asks to execute a write or destructive command:**
1. Refuse to execute it via Bash.
2. State clearly: "This skill is read-only. Write/destructive commands cannot be executed here."
3. If the operation is a cache eviction that is legitimately needed, generate the command in a
   code block and tell the user to run it manually in their terminal or via the ops tooling.

This rule exists because Luci Redis counters are the live source of truth for coupon statistics
in production. Any accidental write or delete corrupts live customer-facing data with no
automatic recovery path.

---

## Credential File

Location: `~/.capillary/redis_{cluster}_{servername}`

Format mirrors the MySQL credential naming: `cluster` is the short cluster name, `servername`
is the Redis sentinel/instance name (e.g. `coupons-sentinel`).

**Luci uses Redis database 10 (db10).** The skill always appends `-n 10` at execution time —
do NOT put `-n` in the credential file itself to avoid conflict.

The file stores the **full redis-cli connection prefix** — everything except the actual command and db number:

```
redis-cli -h redis-go-proxy.uscrm.cctools.capillarytech.com -p 9031 -a "coupons-sentinel:TOKEN..."
```

Examples:
| File | Connects to |
|------|-------------|
| `~/.capillary/redis_uscrm_coupons-sentinel` | US production — coupons-sentinel |
| `~/.capillary/redis_eucrm_coupons-sentinel` | EU production — coupons-sentinel |
| `~/.capillary/redis_incrm_coupons-sentinel` | India production — coupons-sentinel |
| `~/.capillary/redis_sgcrm_coupons-sentinel` | Singapore production — coupons-sentinel |

**When the token refreshes:** overwrite the file with the new `redis-cli ...` command.
The token format is `{servername}:TOKEN` as the `-a` argument.

**Setup instructions (one-time or after token refresh):**
```
mkdir -p ~/.capillary
echo 'redis-cli -h redis-go-proxy.uscrm.cctools.capillarytech.com -p 9031 -a "coupons-sentinel:NEW_TOKEN"' \
  > ~/.capillary/redis_uscrm_coupons-sentinel
chmod 600 ~/.capillary/redis_uscrm_coupons-sentinel
```

Default target: `uscrm_coupons-sentinel`

---

## Invocation

`/redis-query [{cluster}_{servername}] <COMMAND KEY>`

- Target identifier is optional; defaults to `uscrm_coupons-sentinel`
- If the first word matches `*crm*_*` or `stage-*_*`, treat it as the target and strip it from the command
- Command is any read-only Redis command: `GET`, `TTL`, `TYPE`, `KEYS`, `SCAN`, `HGETALL`, `LRANGE`, `SMEMBERS`, `ZRANGE`

Examples:
- `/redis-query GET "cs_2000101_712348_ic"`
- `/redis-query TTL "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsRegistryKey:2000101"`
- `/redis-query KEYS "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsRegistryKey:*"`  ← auto-converted to --scan
- `/redis-query uscrm_coupons-sentinel KEYS "cs_2000101_712348_*"`  ← auto-converted to --scan
- `/redis-query eucrm_coupons-sentinel GET "cs_2000101_712348_ic"`
- `/redis-query TYPE "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsRegistryKey:2000101"`

---

## Execution Steps

### Step 1 — Parse target and command

If the first word matches `*crm*_*` or `stage-*_*`, treat it as the target identifier
(`{cluster}_{servername}`) and strip it from the command.
Otherwise default to `uscrm_coupons-sentinel`.

### Step 2 — Check credential file

```bash
if [ ! -s ~/.capillary/redis_{cluster}_{servername} ]; then
  echo "CRED_MISSING"
fi
```

If missing, show:
```
No credential file at ~/.capillary/redis_{cluster}_{servername}.
Create it with the full redis-cli connection command (host + port + auth token).
Example:
  echo 'redis-cli -h redis-go-proxy.uscrm.cctools.capillarytech.com -p 9031 -a "coupons-sentinel:TOKEN"' \
    > ~/.capillary/redis_uscrm_coupons-sentinel
  chmod 600 ~/.capillary/redis_uscrm_coupons-sentinel
```

### Step 3 — Command whitelist check (MANDATORY — block before executing)

Extract the first token of the command (uppercased) and check it against the allowed list.

**If the command is NOT in the allowed list below: STOP. Do not execute. Say:**
> "This skill is read-only. `{COMMAND}` is not permitted. Only these commands are allowed: GET, MGET, TTL, PTTL, TYPE, EXISTS, STRLEN, KEYS, SCAN, HSCAN, SSCAN, ZSCAN, HGET, HMGET, HGETALL, HKEYS, HVALS, HEXISTS, HLEN, LRANGE, LLEN, LINDEX, SMEMBERS, SCARD, SISMEMBER, ZRANGE, ZREVRANGE, ZRANGEBYSCORE, ZCARD, ZSCORE, ZRANK, OBJECT, DUMP."

**`FLUSHDB` and `FLUSHALL` are unconditionally refused — do not execute them even if the user
explicitly requests it, even for "just this cluster", "just this keyspace", or "just one db".**
These commands wipe all keys in scope and cannot be undone.

This check applies **even if the user explicitly asks** to run a blocked command. No exceptions.

**`KEYS` → `SCAN` auto-conversion (MANDATORY):**
- **Never execute `KEYS` in Bash.** `KEYS` blocks Redis for its full O(N) duration (can be 800ms+
  on a loaded cluster) and directly causes >100ms latency alerts.
- **Auto-convert every `KEYS pattern` invocation to `--scan --pattern`** at execution time.
  Tell the user: "Converting KEYS → SCAN to avoid blocking Redis."
- The `--scan --pattern` flag on redis-cli iterates internally and outputs one key per line —
  functionally equivalent to KEYS but non-blocking.
- `KEYS` remains in the allowed-command whitelist only so the user can type it; the skill
  always executes the `--scan` equivalent.

### Step 4 — Execute

Luci uses **Redis database 10 (db10)**. Always pass `-n 10` — this is hardcoded by the skill
and must not be omitted, changed, or overridden.

**CRITICAL — credential file quoting and glob expansion:**

The credential file stores the redis-cli command with a quoted `-a` argument:
```
redis-cli -h host -p 9031 -a "coupons-sentinel:TOKEN"
```

Using `$(cat cred_file)` passes those quotes **literally** to the shell, breaking auth.
Using `eval` without including the Redis command inside the string lets zsh glob-expand `*`
patterns as filenames before redis-cli sees them.

**Always use this pattern — include the entire redis command inside the `eval` string:**

```bash
# Single key — plain value
eval "$(cat ~/.capillary/redis_{cluster}_{servername}) --no-auth-warning -n 10 GET 'KEY'"

# Single key — raw bytes (for binary / FstCodec values)
eval "$(cat ~/.capillary/redis_{cluster}_{servername}) --no-auth-warning -n 10 --raw GET 'KEY'"

# Pattern scan — use --scan --pattern (NEVER KEYS — it blocks Redis)
# redis-cli iterates the cursor internally; outputs one key per line
eval "$(cat ~/.capillary/redis_{cluster}_{servername}) --no-auth-warning -n 10 --scan --pattern 'cs_2000000_804261_*'"

# Multi-line commands (HGETALL, SCAN, MGET) — same pattern
eval "$(cat ~/.capillary/redis_{cluster}_{servername}) --no-auth-warning -n 10 MGET 'key1' 'key2'"
```

The single quotes around keys inside the eval string prevent zsh from expanding `*` as a
filename glob before the string is passed to redis-cli.

**For binary values (FstCodec / Java-serialized) where you need the raw bytes in Python,
use `subprocess` directly — do NOT redirect eval output to a file (it fails in zsh):**

```python
import subprocess
cred = open('/Users/saravanankesavan/.capillary/redis_{cluster}_{servername}').read().strip()

def redis_raw(key):
    cmd = f'{cred} --no-auth-warning -n 10 --raw GET \'{key}\''
    r = subprocess.run(cmd, shell=True, capture_output=True)
    return r.stdout.rstrip(b'\n')

def redis_str(args):
    cmd = f'{cred} --no-auth-warning -n 10 {args}'
    r = subprocess.run(cmd, shell=True, capture_output=True)
    return r.stdout.decode(errors='replace').strip()
```

### Step 5 — Detect and decode value type

Use Python subprocess to fetch and decode. The full decoder handles three value types:

```python
import subprocess, struct, datetime

cred = open('/Users/saravanankesavan/.capillary/redis_{cluster}_{servername}').read().strip()

def redis_raw(key):
    r = subprocess.run(f'{cred} --no-auth-warning -n 10 --raw GET \'{key}\'',
                       shell=True, capture_output=True)
    return r.stdout.rstrip(b'\n')

def decode_value(raw, key=''):
    if not raw:
        print("(nil) — key does not exist")
        return

    # 1. Java standard serialization (starts with AC ED)
    if raw[:2] == b'\xac\xed':
        print(f"[Java serialized — {len(raw)} bytes]")
        decode_java_object(raw)
        return

    # 2. FstCodec Date (RBucket<Date>) — always 11 bytes, epoch ms at bytes[3:11] little-endian
    #    Used for lit (LastIssueTime) and lsct (LastStatisticsCalculationTime)
    if len(raw) == 11:
        ms = struct.unpack('<q', raw[3:11])[0]
        if 1_577_836_800_000 < ms < 1_893_456_000_000:
            dt = datetime.datetime.utcfromtimestamp(ms / 1000.0)
            print(f"[FstCodec Date] {ms} ms → {dt.strftime('%Y-%m-%d %H:%M:%S')} UTC")
            return

    # 3. Plain string / RAtomicLong number
    try:
        print(raw.decode('utf-8'))
    except Exception:
        print(f"[Binary {len(raw)} bytes]: {raw.hex()}")
```

---

## Value Encoding Reference

| Encoding | Detection | Used by |
|----------|-----------|---------|
| Plain UTF-8 string (RAtomicLong) | `raw.decode('utf-8')` succeeds, numeric | `ic`, `uc`, `tc`, `utc`, `rc`, `ric`, `rrc`, `iipc` |
| FstCodec `Date` (RBucket<Date>) | exactly 11 bytes; epoch ms at `raw[3:11]` little-endian | `lit`, `lsct` |
| Java standard serialization | starts with `\xac\xed` | `MIDNIGHT_EXPIRING_CACHE_NAME` keys |

**FstCodec Date decode (always 11 bytes):**
```python
ms = struct.unpack('<q', raw[3:11])[0]   # little-endian long at offset 3
dt = datetime.datetime.utcfromtimestamp(ms / 1000.0)
```

---

## Java Deserialization

When a value starts with `\xac\xed\x00\x05` (Java serialization magic bytes), run the
full inline decoder below. This handles all known Luci Spring cache objects.

Execute this full Python block inline via Bash:

```python
import struct, datetime, sys

def decode_java_object(data):
    # Extract class name from serialized stream
    # Format: \xac\xed\x00\x05 TC_OBJECT(0x73) TC_CLASSDESC(0x72) [2-byte len] [class name]
    pos = 4
    class_name = "unknown"
    try:
        if pos < len(data) and data[pos] == 0x73:  # TC_OBJECT
            pos += 1
        if pos < len(data) and data[pos] == 0x72:  # TC_CLASSDESC
            pos += 1
            name_len = struct.unpack('>H', data[pos:pos+2])[0]
            pos += 2
            class_name = data[pos:pos+name_len].decode('utf-8', errors='replace')
            print(f"Class: {class_name}")
    except Exception as e:
        print(f"Class extraction error: {e}")

    # Dispatch to known decoders
    if 'StatsHistoryRegistryEntity' in class_name:
        decode_registry_entity(data)
    elif 'Long' in class_name or 'Integer' in class_name:
        decode_boxed_number(data)
    else:
        print(f"[Unknown class — showing raw hex]")
        print(data.hex())

def decode_registry_entity(data):
    """
    Decode StatsHistoryRegistryEntity fields:
    id (Integer), orgId (Integer), isActive (Boolean), 
    snapShotDate (Date), createdOn (Date), tableName (String)
    """
    print("\nStatsHistoryRegistryEntity — decoded")

    # Extract Java Date epoch millis: marker pattern w\x08 (TC_BLOCKDATA, 8 bytes) before each Date field
    import re
    dates = []
    for m in re.finditer(b'\x77\x08', data):
        p = m.start() + 2
        if p + 8 <= len(data):
            epoch_ms = struct.unpack('>q', data[p:p+8])[0]
            if 1_000_000_000_000 < epoch_ms < 2_000_000_000_000:  # sanity: between 2001 and 2033
                dates.append(epoch_ms)

    # Extract Integer values (TC_VALUE for int fields — 4 bytes after \x49 in known positions)
    # Strategy: scan for known int-like values (id=7xxx, orgId=2000xxx)
    integers = []
    for i in range(4, len(data) - 4):
        if data[i-1] in (0x00, 0x01):  # common prefix before int
            val = struct.unpack('>i', data[i:i+4])[0]
            if 1 < val < 10_000_000:
                integers.append((i, val))

    # Extract Boolean: byte 0x00 or 0x01 after field marker
    is_active = None
    act_pos = data.find(b'isActive')
    if act_pos >= 0:
        # Look for boolean byte shortly after field name
        for off in range(act_pos + 8, min(act_pos + 30, len(data))):
            if data[off] in (0x00, 0x01):
                is_active = bool(data[off])
                break

    # Fallback: look for \x01 after xp (serialized boolean true marker)
    if is_active is None:
        bp = data.find(b'xp\x01')
        if bp >= 0:
            is_active = True
        bp2 = data.find(b'xp\x00')
        if bp2 >= 0 and (is_active is None or bp2 < bp):
            is_active = False

    # Extract String tableName: last t\x00\x2C or t\x00\x?? pattern
    table_name = None
    for m in re.finditer(b'\x74\x00', data):
        p = m.start() + 2
        if p + 1 <= len(data):
            slen = data[p]
            if 5 < slen < 100 and p + 1 + slen <= len(data):
                candidate = data[p+1:p+1+slen].decode('utf-8', errors='replace')
                if '.' in candidate and 'stats_history' in candidate.lower():
                    table_name = candidate

    # Display
    print(f"{'Field':<20} {'Value':<40}")
    print("-" * 60)

    if dates:
        utc_field = ['snapShotDate', 'createdOn']
        for i, epoch_ms in enumerate(dates[:2]):
            dt_utc = datetime.datetime.utcfromtimestamp(epoch_ms / 1000.0)
            dt_cdt = dt_utc - datetime.timedelta(hours=5)
            label = utc_field[i] if i < len(utc_field) else f'date[{i}]'
            print(f"{label:<20} {str(dt_utc) + ' UTC':<40}  ({str(dt_cdt)} CDT)")
    else:
        print("(no Date fields decoded)")

    # Print id, orgId from integers — pick the two most plausible values
    id_candidates = [(pos, v) for pos, v in integers if 1000 <= v <= 99999]
    org_candidates = [(pos, v) for pos, v in integers if 1_000_000 <= v <= 9_999_999]
    if id_candidates:
        print(f"{'id':<20} {id_candidates[0][1]}")
    if org_candidates:
        print(f"{'orgId':<20} {org_candidates[0][1]}")

    print(f"{'isActive':<20} {is_active}")
    if table_name:
        print(f"{'tableName':<20} {table_name}")
    else:
        print(f"{'tableName':<20} (not decoded — see raw hex)")

def decode_boxed_number(data):
    # Java Long/Integer boxed type: value is 4 or 8 bytes after header
    try:
        # Long: 8 bytes starting at offset ~30-40 depending on class desc length
        for i in range(10, min(50, len(data) - 8)):
            val = struct.unpack('>q', data[i:i+8])[0]
            if 0 <= val < 10_000_000_000:
                print(f"Value (Long): {val}")
                return
    except Exception:
        pass
    print(f"Raw hex: {data.hex()}")

with open('/tmp/luci_redis_val.bin', 'rb') as f:
    data = f.read()

if data.endswith(b'\n'):
    data = data[:-1]

if not data:
    print("(nil) — key does not exist")
elif data[:2] == b'\xac\xed':
    print(f"[Java serialized — {len(data)} bytes]")
    decode_java_object(data)
else:
    try:
        text = data.decode('utf-8')
        print(text)
    except Exception:
        print(f"[Binary {len(data)} bytes]: {data.hex()}")
```

Save this script to `/tmp/luci_redis_decode.py` and run it with `python3 /tmp/luci_redis_decode.py`.

---

## Known Redis Key Patterns in Luci

| Pattern | Type | Description |
|---------|------|-------------|
| `cs_{orgId}_{seriesId}_{fieldCode}` (numeric fields) | RAtomicLong — plain UTF-8 number | `ic`, `uc`, `tc`, `utc`, `rc`, `ric`, `rrc`, `iipc` |
| `cs_{orgId}_{seriesId}_{fieldCode}` (date fields) | RBucket<Date> — FstCodec, 11 bytes | `lit`, `lsct` — epoch ms at raw[3:11] little-endian |
| `cs_{orgId}_{seriesId}_{entityId}_{fieldCode}` | RAtomicLong — plain UTF-8 number | Entity-level stats counter |
| `MIDNIGHT_EXPIRING_CACHE_NAME:{YYYY-MM-DD}::statsRegistryKey:{orgId}` | Java serialized (`\xac\xed`) | Cached `StatsHistoryRegistryEntity` (blueprint table + snapshot date) |
| `MIDNIGHT_EXPIRING_CACHE_NAME:{YYYY-MM-DD}::statsHistoryPerKey:{orgId}_{seriesId}_{field}_{entityType}_{entityId}` | Java serialized Long (`\xac\xed`) | Cached `getHistoricalValue()` result |
| `lock_{orgId}_{seriesId}_{entity}` | Redisson lock | Mutex for stats counters |

Field codes: `ic` (IssuedCount), `uc` (UploadedCount), `tc` (TotalCount), `utc` (UploadedTotalCount),
`rc` (RedeemedCount), `ric` (RevokedIssuedCount), `rrc` (ReactivatedRedemptionCount), `iipc` (IssueInProgressCount),
`lit` (LastIssueTime — FstCodec Date), `lsct` (LastStatisticsCalculationTime — FstCodec Date)

---

## Output Format

```
## Redis — {COMMAND} on {cluster}
**Key:** {key}
**Type:** string / Java-serialized / nil

### Value
{decoded value or table for Java objects}

### Metadata
TTL: {seconds} ({human-readable if >0, "no expiry" if -1, "key missing" if -2})
```

For `KEYS` / `SCAN` results:
- Display as a numbered list
- Show count at top: `Found N keys matching "{pattern}"`
- If 0 keys found, say so explicitly

For Java-serialized values:
- Always show the decoded table first
- Then offer: "Run `/redis-query TTL {key}` to check expiry"

---

## Common Workflows

### Check stats counter for a series
```
/redis-query GET "cs_2000101_712348_ic"
/redis-query GET "cs_2000101_712348_uc"
/redis-query GET "cs_2000101_712348_tc"
```

### Check midnight cache registry entry
```
/redis-query GET "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsRegistryKey:2000101"
/redis-query TTL "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsRegistryKey:2000101"
```

### Check getHistoricalValue cache
```
/redis-query GET "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsHistoryPerKey:2000101_712348_ic_SERIES_-1"
```

### List all stats keys for an org+series
```
/redis-query KEYS "cs_2000101_712348_*"
```
Executes as: `--scan --pattern 'cs_2000101_712348_*'`

### Check if midnight cache was refreshed today
```
/redis-query KEYS "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsRegistryKey:*"
```
Executes as: `--scan --pattern 'MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::statsRegistryKey:*'`

### List all midnight cache keys for an org (e.g. post-enablement audit)
```
/redis-query KEYS "MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::*2000101*"
```
Executes as: `--scan --pattern 'MIDNIGHT_EXPIRING_CACHE_NAME:2026-06-18::*2000101*'`

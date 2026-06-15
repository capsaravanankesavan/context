# MySQL DB Query

Run a SQL query against a Capillary MySQL DB server/shard using a stored session credential file.
Deployment is managed via facets.ai. DB schema files are in `cc-stack-crm` (submodule at
`src/test/resources/cc-stack-crm`), organised by DB server.

## Security Rule

NEVER echo, log, print, or include the contents of the credential file or any part of
the MySQL connection string (host, user, password) in any response text. The file is
read by Bash at execution time only.

## DML / DDL Hard Rule — NO EXCEPTIONS

**NEVER execute any INSERT, UPDATE, DELETE, DROP, ALTER, CREATE, TRUNCATE, or any other
DDL/DML statement via Bash.** This skill is READ-ONLY.

If the user asks for data modifications (UPDATE, INSERT, DELETE, schema changes):
1. **Generate the SQL statement** and present it clearly in a code block
2. **Tell the user:** "Run this via the hotswap app — it requires approval before execution."
3. **Do NOT execute it** via `$(cat ~/.capillary/mysql_*) --batch -e "..."` under any circumstances.

This rule exists because all production data changes must go through the hotswap approval workflow.
No exceptions — not even for test data, test series, or test orgs.

## Safety Rules (enforce on EVERY query — no exceptions)

**Proxy row limit:** The MySQL proxy enforces a hard 1000-row cap. Never issue a query
that could return or scan unbounded rows. Every SELECT must have either:
- A narrow WHERE clause on an indexed column (confirmed from schema), OR
- An explicit `LIMIT` clause

**No full-table loads:** Never run `SELECT * FROM table` or `SELECT COUNT(*) FROM table`
without a WHERE clause. These load the entire table and will hit the proxy limit or
cause performance issues in production.

**Index-first rule (mandatory before writing any query):**
Before constructing any query, read the schema file for every table being queried from:
```
/Users/saravanankesavan/sara/wsdetail/Luci/src/test/resources/cc-stack-crm/schema/
```
Schema is kept current via git submodule updates — always read it, never rely on memory.

Extract the `KEY` and `UNIQUE KEY` definitions to determine safe filter columns.
If the intended WHERE columns are not indexed, warn the user and suggest an indexed alternative
before executing.

## DB Server Types

| Server | Sharded? | Used by | Schema folder | DB name |
|--------|----------|---------|---------------|---------|
| `dbmaster` | Yes — `dbmaster1`, `dbmaster2`, … | Luci, core app data | `schema/dbmaster/` | `luci` |
| `meta` | No | API gateway, shard manager (shard policy, org→shard mapping) | `schema/meta/` | `meta` |
| `solutions` | No | Rewards / sol-rewards-core | `schema/solutions/` | `solutions` |

**Note:** The credential file does not include a database name. Always prepend `USE {db_name};`
to queries. For dbmaster → `USE luci;`, for meta → `USE meta;`, for solutions → `USE solutions;`.

**Finding an org's shard:** Look up the org in the facets.ai data studio → shard manager →
MySQL shard policy → note the shard number → use the matching `dbmaster_{shard}` credential.

## Credential Files

Location: `~/.capillary/mysql_{cluster}_{server}_{shard}`

Format:
- `cluster` = cluster short name (e.g. `uscrm`, `eucrm`, `incrm`, `stage-ei`)
- `server` = DB server name: `dbmaster`, `meta`, `solutions`
- `shard` = shard number for sharded servers (e.g. `1`, `2`); omit for non-sharded servers

Examples:
| File | What it connects to |
|------|---------------------|
| `~/.capillary/mysql_uscrm_dbmaster_1` | uscrm cluster, dbmaster server, shard 1 |
| `~/.capillary/mysql_uscrm_dbmaster_2` | uscrm cluster, dbmaster server, shard 2 |
| `~/.capillary/mysql_uscrm_meta`       | uscrm cluster, meta server (non-sharded) |
| `~/.capillary/mysql_uscrm_solutions`  | uscrm cluster, solutions server (non-sharded) |
| `~/.capillary/mysql_eucrm_dbmaster_1` | eucrm cluster, dbmaster server, shard 1 |
| `~/.capillary/mysql_incrm_dbmaster_1` | incrm cluster, dbmaster server, shard 1 |

Each file contains the complete mysql command from the in-house session tool, e.g.:

```
mysql -h mysql-go-proxy-v2.uscrm.cctools.capillarytech.com --port 9001 -u dbmaster1/saravanan.kesavan -pXXXXX -A
```

## Invocation

`/mysqldb-query [{cluster}_{server}_{shard}] <sql>`

- Target identifier is optional; defaults to `uscrm_dbmaster_1`
- For non-sharded servers omit the shard suffix: `uscrm_meta`, `uscrm_solutions`

Examples:
- `/mysqldb-query SELECT COUNT(*) FROM coupons_issued WHERE org_id=2000000 AND coupon_series_id=811192`
- `/mysqldb-query uscrm_dbmaster_2 SELECT COUNT(*) FROM coupons_issued WHERE org_id=50076`
- `/mysqldb-query eucrm_dbmaster_1 SELECT * FROM coupon_upload WHERE org_id=1234 LIMIT 10`
- `/mysqldb-query uscrm_meta SELECT * FROM shard_manager WHERE org_id=2000000`
- `/mysqldb-query uscrm_solutions SELECT COUNT(*) FROM rewards WHERE org_id=2000000`

## Execution Steps

### Step 1 — Parse target
- If the first word matches `*crm*_*` or `stage-*_*`, treat it as the target identifier and strip it from the SQL
- Otherwise default to `uscrm_dbmaster_1`

### Step 2 — Check credential file
```bash
if [ ! -s ~/.capillary/mysql_{identifier} ]; then
  echo "CRED_MISSING"
fi
```
If missing: "No credential file at `~/.capillary/mysql_{identifier}`.
Check the org's shard in facets.ai data studio, then paste today's session command into that file and retry."

### Step 3 — Read schema and validate query safety (mandatory)

For every table referenced in the SQL, read its schema file:
```
/Users/saravanankesavan/sara/wsdetail/Luci/src/test/resources/cc-stack-crm/schema/{server_folder}/{table_name}.sql
```

Extract all `KEY`, `UNIQUE KEY`, and `PRIMARY KEY` definitions.

Check the query's WHERE clause:
- **Safe:** WHERE columns are a leading prefix of an existing index → proceed
- **Unsafe — no index:** Warn the user: "Column `{col}` on `{table}` has no index — this will full-scan the table. Suggest filtering on `{indexed_col}` instead." Do NOT execute without user confirmation.
- **Unsafe — missing LIMIT:** If the query could return many rows and has no LIMIT, add `LIMIT 100` and note it was added for safety.
- **Unsafe — no WHERE at all:** Refuse to run. Tell the user: "Query has no WHERE clause and would load the full table. Add a WHERE on an indexed column first."

Show the user a one-line safety note before executing:
> `Index used: {index_name} on ({columns}) — query is safe to run.`

### Step 4 — Determine database name
- `dbmaster` → `USE luci;`
- `meta` → `USE meta;`
- `solutions` → `USE solutions;`

### Step 5 — Execute
```bash
$(cat ~/.capillary/mysql_{identifier}) --batch -e "USE {db_name}; {SQL}"
```

### Step 6 — Present results
- ≤20 rows → markdown table
- >20 rows → raw tabular output with row count header
- Always show total row count
- Never show the connection string
- If result hits exactly 1000 rows, warn: "Result may be truncated at proxy limit (1000 rows). Add a narrower filter or LIMIT clause."

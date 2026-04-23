# CloudFlare API gotchas

Each entry has paid for itself at least once in live apply runs. They're
documented in script comments at the site of the guard, and consolidated
here so loading `cloudflare-write` surfaces the whole set without making
an agent grep the tree.

When you hit a surprising CF error, check here first. When you *write*
a new guard into a script, add it here too — otherwise the next agent
re-learns it.

## 1. Pages `per_page` cap is 10

**Symptom.** Any `GET /accounts/:id/pages/projects` (or its
deployments sub-resource) returns CF code `8000024` "Invalid list
options provided" when `per_page >= 11`.

**Root cause.** The Pages API is stricter than the rest of CF —
most list endpoints accept up to 1000, Pages silently caps at 10.
`_lib.sh`'s `cf_api_paginated` defaults to `per_page=50`, which
works everywhere else and fails here.

**Guard.** Pages-touching scripts set `CF_PAGE_SIZE=10` (either
exported globally in the script or scoped to a single
`cf_api_paginated` call) before every Pages list endpoint hit:

- `cf-pages.sh` ([scripts/cf-pages.sh](../../cloudflare/scripts/cf-pages.sh)) — exports
- `cf-pages-project-create.sh` — exports
- `cf-pages-deployment-delete.sh` — scoped per-call
- `cf-pages-deployments-purge.sh` — scoped per-call

Every other list endpoint can keep the library default. If you add a
new Pages-touching script, set the override before each call or the
pagination walker will 8000024 on the first request.

## 2. Pages subdomain auto-suffixing

**Symptom.** Create-project response returns `"subdomain":
"foo-72d.pages.dev"` when you asked for `foo`. Subsequent scripts
that hard-code `NAME.pages.dev` as the upstream or verification URL
hit CF 522 / NXDOMAIN.

**Root cause.** `foo.pages.dev` was taken by CF's platform pool.
CF mints a randomized suffix rather than failing the create. The
`subdomain` field in the create response is authoritative — the
project's canonical hostname is whatever it says, not the name you
asked for. This has hit both `culture-72d.pages.dev` and
`afi-bn9.pages.dev` in this account.

**Guard.** Always read the `subdomain` field from the create
response and feed it forward. After-the-fact recovery:

```sh
bash .claude/skills/cloudflare/scripts/cf-pages.sh --json \
  | jq -r '.result[] | select(.name == "foo") | .subdomain'
```

The sub-site pattern recipe
([references/subpath-site-pattern.md](subpath-site-pattern.md))
orders the steps deliberately — Pages project first, *then* render
the Worker with the real subdomain — for exactly this reason.

## 3. Workers multipart uploads match parts by `filename`

**Symptom.** `PUT /accounts/:id/workers/scripts/:name` returns code
`10021` "Uncaught Error: No such module: worker.js" on an otherwise
well-formed multipart body.

**Root cause.** `curl -F "worker.js=@/path/to/afi-proxy.js"` emits
`Content-Disposition: form-data; name="worker.js"; filename="afi-proxy.js"`
— the `filename` attribute defaults to the source path's basename.
CF's module resolver keys off the `filename`, not the form-field
`name`, so `main_module: "worker.js"` can't find a matching part.

**Guard.** Every `-F` in `cf-worker-create.sh` ([scripts/cf-worker-create.sh](../scripts/cf-worker-create.sh))
carries an explicit `;filename=...` override so the filename is
independent of the source path:

```sh
-F "metadata=@$meta_tmp;type=application/json;filename=metadata.json"
-F "$part_name=@$from_file;type=$part_ct;filename=$part_name"
```

Removing either `filename=` re-triggers 10021 on every live apply.
The commit adding the fix (9f2feeb) includes a tall comment at the
upload site; leave it there for the next reader.

## 4. Workers subdomain endpoint is POST, not PUT

**Symptom.** `PUT /accounts/:id/workers/scripts/:name/subdomain`
returns code `10405` "Method not allowed for this authentication
scheme" — misleading: the auth is fine, the method is wrong.

**Root cause.** Unlike `PUT /workers/scripts/:name` (the upload
endpoint), the subdomain sub-resource is POST-only. CF's error
message blames auth because the method rejector runs after
authentication; a better message would say "405".

**Guard.** The subdomain block in `cf-worker-create.sh` uses
`cf_api ... -X POST` and a comment right above it documents this
so nobody re-derives it.

## 5. Workers `.workers.dev` subdomain default is DISABLED via API

**Symptom.** A freshly uploaded Worker is unreachable at
`NAME.<account>.workers.dev` even though a dashboard-created
counterpart (e.g. `agex-proxy`) is.

**Root cause.** `PUT /accounts/:id/workers/scripts/:name` leaves the
subdomain attribute at its API default, which is `enabled: false`.
The dashboard (and `wrangler`) default it to `true`. Two Workers
with identical upload payloads can diverge on this flag.

**Guard.** `cf-worker-create.sh` follows every successful upload
with a POST to `/subdomain` carrying
`{enabled: true, previews_enabled: false}`, matching the live
`agex-proxy` / `citation-cli-proxy` state. `--no-workers-dev`
suppresses the second POST for internal Workers that should only
run on their Workers routes.

## 6. Zone-scoped tokens must cover ALL AgentCulture zones

**Symptom.** `POST /zones/:id/workers/routes` (or any other
zone-level write) returns code `10000` "Authentication error" even
for a zone whose write scope you think you granted.

**Root cause.** CF's zone-scope enforcement is all-or-nothing at the
token-permission layer. A write token scoped to a *subset* of
AgentCulture zones often returns 10000 for the zones it should
permit, because CF's permission check runs at organization-scope
granularity first. The error is shaped like an auth problem, not a
permissions problem, which makes it easy to chase the wrong rabbit.

**Guard.** Mint write tokens with **All zones from AgentCulture**
for any zone-level Edit permission (Single Redirect, DNS, Workers
Routes). `docs/SETUP.md` §1.5 lists every scope in one place so a
fresh token covers the whole surface.

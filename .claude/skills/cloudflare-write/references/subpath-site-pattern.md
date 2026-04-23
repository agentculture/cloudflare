# Sub-path site pattern on `culture.dev`

**Problem.** We want several independent sites served under the same
apex — `culture.dev/agex`, `culture.dev/citation-cli`, `culture.dev/afi`
— each owned by a different repo / team, deployed independently,
with their own PR preview URLs. They can't all sit on `culture.dev`
itself (that's the main Jekyll site), and we don't want them at the
apex of their own sub-domains (Discord / docs sharing is cleaner
when everything is `culture.dev/*`).

**Shape we settled on.** Three resources per sub-site:

1. A **Direct Upload Pages project** named `NAME` — owns the actual
   site content, gets a per-branch preview URL
   `https://{branch}.NAME.pages.dev` for free, and is driven by the
   consumer repo's deploy workflow (not by CF's GitHub integration).
2. A **Worker** named `NAME-proxy` — intercepts traffic under
   `/NAME` and `/NAME/*`, strips the `/NAME` prefix, and fetches from
   `https://NAME.pages.dev`. Same-origin redirect `Location` headers
   are rewritten back under `/NAME/*` so link navigation stays within
   the culture.dev/NAME namespace.
3. A **Workers route** `culture.dev/NAME*` → `NAME-proxy` — binds the
   Worker to the traffic.

All three are small, independent, and owned by this repo's
`cloudflare-write` skill. `agex`, `citation-cli`, and `afi` are all
deployed this way; `zehut` and `shushu` will be next.

## Why Direct Upload and not GitHub-connected Pages?

CF's GitHub-connected Pages builds the site on CF infrastructure.
We'd rather the consumer repo's own CI build the site, attach its
own caching / secrets / versioning, and then upload the finished
bundle via `wrangler pages deploy`. Direct Upload removes CF from
the build path and keeps the GitHub ↔ CF coupling to a single
`CLOUDFLARE_API_TOKEN` secret.

## Why a proxy Worker instead of a CNAME?

`NAME.pages.dev` serves at the **root** (`/`). A CNAME / DNS record
alone can't rewrite the URL prefix — a link to `/about` on the site
would end up at `culture.dev/about`, not `culture.dev/NAME/about`.
The Worker does the prefix-strip on the way upstream and
prefix-re-add on same-origin redirects coming back. Without it,
every link on the sub-site would have to be manually prefixed with
`/NAME` and navigation would still break on 3xx responses from
upstream.

## Render-and-deploy recipe (for a hypothetical `foo` sub-site)

Tooling: the three scripts in `cloudflare-write/scripts/` plus the
template at `cloudflare-write/templates/subpath-proxy.js`.

### 1. Create the Pages project first (to learn the real subdomain)

```sh
# Dry-run first — inspect the POST body:
bash .claude/skills/cloudflare-write/scripts/cf-pages-project-create.sh \
  foo --direct-upload --compatibility-date=2026-04-20
# Commit:
bash .claude/skills/cloudflare-write/scripts/cf-pages-project-create.sh \
  foo --direct-upload --compatibility-date=2026-04-20 --apply
```

Match the `--compatibility-date` to whatever the existing sub-sites
use (as of 2026-04-23: `2026-04-20`, verified on `agex-proxy`). Pin
it — don't let CF choose a default that can drift.

**Gotcha — subdomain auto-suffixing.** The apply output's
`**subdomain:**` field is the real `*.pages.dev` hostname. It is
usually `foo.pages.dev`, but CF auto-suffixes any name that collides
with the platform pool: `culture` got `culture-72d.pages.dev`, `afi`
got `afi-bn9.pages.dev`. **Record whatever the apply prints** —
don't assume `foo.pages.dev`. You'll wire that exact hostname into
the proxy Worker in the next step.

Alternative (read-only) way to recover the subdomain later:

```sh
bash .claude/skills/cloudflare/scripts/cf-pages.sh --json \
  | jq -r '.result[] | select(.name == "foo") | .subdomain'
```

### 2. Render the proxy Worker source (using the real subdomain)

```sh
mkdir -p /tmp/foo-provision
# Use the subdomain from step 1's apply output, NOT a guess:
sed -e 's/__SUBPATH__/foo/g' \
    -e 's|__UPSTREAM__|https://REAL-SUBDOMAIN|g' \
    .claude/skills/cloudflare-write/templates/subpath-proxy.js \
    > /tmp/foo-provision/foo-proxy.js
```

Two placeholders, both double-underscored to keep sed substitution
unambiguous: `__SUBPATH__` and `__UPSTREAM__`.

### 3. Upload the proxy Worker

```sh
# Dry-run:
bash .claude/skills/cloudflare-write/scripts/cf-worker-create.sh \
  foo-proxy --from-file=/tmp/foo-provision/foo-proxy.js \
  --compatibility-date=2026-04-20
# Commit:
bash .claude/skills/cloudflare-write/scripts/cf-worker-create.sh \
  foo-proxy --from-file=/tmp/foo-provision/foo-proxy.js \
  --compatibility-date=2026-04-20 --apply
```

### 4. Create the Workers route

```sh
bash .claude/skills/cloudflare-write/scripts/cf-workers-route-create.sh \
  culture.dev 'culture.dev/foo*' foo-proxy                  # dry
bash .claude/skills/cloudflare-write/scripts/cf-workers-route-create.sh \
  culture.dev 'culture.dev/foo*' foo-proxy --apply
```

Single-quote the pattern so the shell's glob expansion doesn't eat
the `*`.

### 5. Hand the consumer repo the deploy secrets

The consumer's docs workflow needs two GitHub Actions secrets on
its repo:

- `CLOUDFLARE_API_TOKEN` — an Account · Cloudflare Pages · Edit token
- `CLOUDFLARE_ACCOUNT_ID`

These are out-of-band from this skill (GH-side, not CF-side). Use
`gh secret set CLOUDFLARE_API_TOKEN -R agentculture/<repo>` once
the token is minted.

### 6. Verify

Use the read-only `cloudflare` skill:

```sh
bash .claude/skills/cloudflare/scripts/cf-pages.sh
bash .claude/skills/cloudflare/scripts/cf-workers.sh
bash .claude/skills/cloudflare/scripts/cf-workers-routes.sh
```

After the consumer's first deploy, probe the three URL shapes:

- `https://foo.pages.dev/` → the raw Pages site
- `https://culture.dev/foo/` → served via `foo-proxy`
- `https://{branch}.foo.pages.dev/` → per-branch preview
  (needed by PR-preview links in the consumer's docs workflow)

## Token-scope checklist

The write token (kept in `.env` under `CLOUDFLARE_API_TOKEN` during
apply) must carry:

- Account · Cloudflare Pages · Edit
- Account · Workers Scripts · Edit
- Zone · Workers Routes · Edit — **All zones from AgentCulture**
  (zone-level scopes on a subset fail with code 10000; see
  `memory/zone_ids.md`)

Swap back to the read-only token when the apply is done.

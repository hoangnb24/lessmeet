# Lessmeet legal hosting

Cloudflare Workers static assets, separate from the existing `meetless-website`.
The zone API confirmed `2m0r.com` belongs to account
`6031f1f85e189c44fb3bcd150ca65920`. No backend, payment links, cookies,
analytics scripts, uploaded recordings or credentials belong in this directory.
Only `public/` is uploaded. Draft legal documents remain outside the asset root.

## Current state

Prepared, NOT deployed. `/privacy` and `/terms` intentionally return 404 rather
than serving a support page as a valid legal document. Do not put these URLs in
the app until real reviewed policies are published and verified over HTTPS.

## Verification

From the repository root:

```sh
npx --yes wrangler@4.136.3 deploy --config website/wrangler.jsonc --dry-run
npx --yes wrangler@4.136.3 dev --config website/wrangler.jsonc --local
```

## Before deployment

1. Resolve the publication checklists in `docs/legal/PRIVACY_DRAFT.md` and
   `docs/legal/TERMS_DRAFT.md`; get operator approval and effective date.
   Never turn draft text into a promise of deletion, retention, or provider
   behavior without an implemented process and verified account settings.
2. Add reviewed static `privacy.html` and `terms.html`; update the support page.
3. Verify the exact hostname's DNS records in Cloudflare. Current Wrangler
   OAuth can read zone metadata and Workers custom domains, but its DNS-record
   GET returned 403. Do not overwrite any existing record/site to fix a conflict.
4. Deploy explicitly with the pinned command above without `--dry-run`.
   This creates/updates only `lessmeet-legal` and its exact custom hostname.
   Do not enable a paid plan or change other domains. `workers.dev` and preview
   URLs are disabled. Cloudflare handles custom-domain DNS/certificate setup:
   https://developers.cloudflare.com/workers/configuration/routing/custom-domains/
5. Verify certificate validity, HTTPS 200 on `/privacy` and `/terms`, correct
   approved content, security headers, and 404 on unknown paths before installing
   legal URLs into app public configuration. `www.lessmeet.2m0r.com` is the only
   requested hostname; no apex or additional alias is configured implicitly.

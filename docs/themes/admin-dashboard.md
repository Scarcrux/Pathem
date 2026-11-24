# Marketplace review dashboard

The first dashboard is a private local web app for a catalog maintainer. It uses the same Swift validator, review history, and snapshot publisher as Pathem. Creators submit through the proposed Git pull-request workflow or provide a submission JSON to a maintainer for local review.

1. Import a submission into the pending queue and inspect its screenshot, attribution, license, and downloadable Pathem theme package.
2. Record approval, rejection, or a request for changes with a required note. A corrected submission uses a higher revision. Approval does not change the published snapshot.
3. Compare the live revision with approved candidates. Explicitly publish a snapshot or withdraw an entry with a note. Withdrawal becomes visible to clients on the next snapshot publication.
4. Download creator-facing feedback for the corresponding submission thread. The review store and notes remain private.

The dashboard listens on loopback and authenticates a single reviewer configured by the operator. A hosted multi-reviewer service would need a private identity provider and a stable reviewer-to-account mapping. The dashboard only writes the configured snapshot file. Publishing that file to a public host remains a deployment step.

## Run locally

Build the existing catalog tool first. Use a private directory for the review state
and a separate path for the snapshot that can be copied to the catalog host.

```sh
lockf -k /tmp/commandem-swift-build.lock make build
mkdir -p -m 700 .build/theme-admin-state
python3 tools/theme-admin/server.py \
  --catalog-tool .build/debug/pathem-theme-catalog \
  --store .build/theme-admin-state/reviews.json \
  --snapshot .build/theme-admin-state/catalog.json \
  --reviewer 'Catalog maintainer'
```

Enter a local password at the terminal prompt. Visit the loopback address printed by
the server and sign in as `reviewer` with that password. Import either sample from
[gallery-fixture](gallery-fixture/) to try a review. The username is fixed and the audit
label comes from `--reviewer`.

Use **Download theme for Pathem preview** to open the data package in **Settings →
Appearance → Import…**. Use **Download creator feedback** to obtain a text copy of a
decision for the creator's submission thread.

The public listing ID stays fixed across versions and withdrawals. The listing can
display previews, title, summary, creator, license, version, tags, and optional source.
Preview, Install, Update, and Apply keep their distinct meanings in the app. Commandem
and Pathem share this vocabulary. Each product validates and publishes its own artifacts.

Verify the dashboard with `python3 test/theme_admin_e2e.py .build/debug/pathem-theme-catalog`.

## Creator submission and AWS staging

Creators use the **Submit a Pathem theme** issue form in the Pathem GitHub repository.
The public issue links to a fixed revision of the submission JSON. Keep the same listing
ID and increase the revision for a correction or update. The issue is the creator's
status and feedback thread. A maintainer retrieves the submitted file, imports it into
Marketplace Admin, and can post the exported decision back to that issue. Public release
is a separate snapshot publication action. An existing published revision stays visible
until that action replaces or withdraws it.

[The AWS template](../../infra/aws/marketplace.yaml) provisions two private, versioned S3
buckets, a CloudFront endpoint scoped to the approved catalog snapshot, and an
invite-only Cognito reviewer pool with authenticator-app MFA. The main Pathem website
stays on its existing host. The reviewer pool is available for the hosted dashboard
integration. The current local dashboard still runs the macOS Swift validator.

After generating an approved snapshot, an authorized maintainer can publish just that
file to the stack's `CatalogBucket` using key `catalog.json`. Private review notes and
source submissions stay outside the CloudFront origin path.

To provision or update the staging stack from this checkout:

```sh
aws cloudformation deploy --region us-east-1 --stack-name pathem-marketplace \
  --template-file infra/aws/marketplace.yaml
```

Use the stack outputs for the bucket and HTTPS catalog URL. Publish with
`aws s3 cp <approved-snapshot> s3://<CatalogBucket>/catalog.json --content-type application/json --cache-control no-store`.
S3 versioning preserves prior snapshots. The CloudFront origin can read only that key.

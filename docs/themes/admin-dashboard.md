# Marketplace review dashboard

The first dashboard is a private local web app for a catalog maintainer. It uses the same Swift validator, review history, and snapshot publisher as Pathem. Creators use a GitHub issue with their existing GitHub account.

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

## Review runbook

Themes ships in every Pathem build, so a published snapshot is visible to all users
the next time they open the gallery. Approval and publication are separate steps.

1. **Intake.** A creator prepares a submission in **Settings → Appearance → Submit a
   Theme…** and attaches the saved JSON to the **Submit a Pathem theme** GitHub issue.
   They can also link to the file in a permanent GitHub commit or release asset. The
   file and issue are public. The issue is the creator's status and feedback thread.
2. **Import.** Retrieve the submitted file and import it into the dashboard. The
   validator rejects malformed listings, packages, and screenshots before they reach
   the queue.
3. **Inspect.** Check the screenshots, attribution, license, and source. Use
   **Download theme for Pathem preview** and open the package with **Settings →
   Appearance → Import…** to see it in the app.
4. **Decide.** Record approval, rejection, or a request for changes with a note, and
   post the exported feedback to the issue. A correction or update keeps the listing
   ID and uses a higher revision.
5. **Publish.** Generate the snapshot and upload it with the command below. An
   existing published revision stays visible until a snapshot replaces or withdraws it.
6. **Confirm.** Fetch the public catalog URL and check that it lists the expected
   revisions, then open **Themes…** in a release build.

To withdraw a listing, record the withdrawal with a note and publish a new snapshot.
Clients keep installed copies of a withdrawn listing and can still uninstall them.

## Catalog host

[The AWS template](../../infra/aws/marketplace.yaml) provisions two private, versioned S3
buckets, a CloudFront endpoint scoped to the approved catalog snapshot, and an
invite-only Cognito reviewer pool with authenticator-app MFA. The main Pathem website
stays on its existing host. The reviewer pool is available for the hosted dashboard
integration. The current local dashboard still runs the macOS Swift validator.

Release builds read `catalog.json` from that CloudFront endpoint. The URL is compiled
into the app, so the stack's distribution must stay in place across updates. Private
review notes and source submissions stay outside the CloudFront origin path.

To provision or update the stack from this checkout:

```sh
aws cloudformation deploy --region us-east-1 --stack-name pathem-marketplace \
  --template-file infra/aws/marketplace.yaml
```

## Publish

Use the stack outputs for the bucket name. An authorized maintainer publishes just the
approved snapshot to the stack's `CatalogBucket` using key `catalog.json`:

```sh
aws s3 cp <approved-snapshot> s3://<CatalogBucket>/catalog.json \
  --content-type application/json --cache-control "public, max-age=300"
```

The five-minute cache lifetime applies at CloudFront and again in each client's HTTP
cache, so allow up to about ten minutes for a publication or withdrawal to reach
everyone who opens the gallery. S3 versioning preserves prior snapshots, and the CloudFront
origin can read only that key. To roll back, publish the previous snapshot again.

# Licensing - the Pro tier

Xeneon Edge is free and fully functional. **Pro** is a low-cost "supporter" tier
that currently unlocks nine optional colour themes. Nothing functional is
gated: every widget (including the live-data HTTP/JSON and KPI ones), all
presets, custom user widgets, every accessibility feature, and the base themes
stay free. Pro keys are not sold as part of the beta.

## How it works (and why it's private)

A Pro key is an **offline, signed token** - `XE1.<payload>.<signature>` - verified
against a public key compiled into the app (`core/src/license.rs`,
`ISSUER_PUBLIC_KEY`). Verifying a key:

- opens **no socket, reads no file, uses no hardware fingerprint** - the answer is
  identical under `unshare -n`. There is no "phone home" and no activation server.
- **fails soft**: any bad key - empty, garbage, forged, expired, or signed for a
  future format - resolves to the free tier. It never panics and never blocks the
  app.
- is a **sensitive bearer entitlement**: possession of a valid key unlocks Pro,
  and its signed payload contains the holder label and licence id. It is stored
  in owner-only `config.toml`, omitted from logs/diagnostics, and should not be
  posted publicly. The entitlement is recomputed from its signature every time.

The tier flows: config → Rust verifier → `LicenseBridge` (hub) /
`ManagerBackend` (Manager) → QML gates on `license.isPro`. A key pasted in the
Manager while the hub is connected is pushed over the control socket so the hub
persists it (single-writer) and re-gates **live, without a restart**.

## Issuer setup and release attestation

The shipped `ISSUER_PUBLIC_KEY` is armed with the production Ed25519 public key.
The private seed remains outside the repository; anyone with that seed can mint
Pro keys.

1. Generate the issuer keypair **once, ever**:

   ```
   cargo run -q --locked --manifest-path tools/license-tool/Cargo.toml -- keygen
   ```

2. Paste the printed **public key** into `core/src/license.rs` as
   `ISSUER_PUBLIC_KEY`. Commit that public half.

3. Store the printed **private seed** in your password manager (next to the GPG
   signing key). **Never commit it.** Anyone with the seed can mint Pro keys.

Before a release, place a genuine owner-issued Pro key in an absolute,
current-user-owned, owner-only regular file and name it with
`XENEON_TEST_LICENSE_KEY_FILE`. The strict gate rejects a raw key in the process
environment, reads the protected file through a validated no-follow descriptor,
and carries the value through private descriptor 3. It exposes the entitlement
only to the Rust core attestations and requires that it unlock Pro against the
issuer public key embedded in the candidate. Missing, mismatched, or tampered
keys block the release before artifacts are built or signed.

## Selling: Lemon Squeezy (or Gumroad)

Both can auto-deliver a licence key on purchase. Two integration shapes:

- **Simplest:** let the store deliver a purchase, and mint the key yourself from
  the order (manually or via a webhook that calls the mint tool) and e-mail it.
  Fine at low volume.
- **Automated:** deploy the mint webhook (`tools/license-webhook`) and register it
  with `scripts/setup-lemonsqueezy.py`. On every purchase it verifies the webhook
  signature, mints the buyer's key (same signing code as the CLI), and e-mails it.
  The seed lives only in that service's environment - never here, never in CI, and
  never with anyone else. See `tools/license-webhook/README.md`.

Create the product (name, price, description, image) once in the Lemon Squeezy
dashboard - it needs human input and the dashboard is the right place. The price
does not affect the app. Point the app's in-Manager "Get Pro" button at the
product URL.

## Issuing a key

Never put the seed on the command line or in an environment variable. Both are
observable by another process running as the same user. The wrapper accepts only
an absolute path to a current-user, owner-only regular file of at most 256
bytes. It builds the issuer before opening that file, removes the related
variables from the build environment, and then feeds the seed only to the
already-built issuer through stdin:

```
env XENEON_LICENSE_SEED_FILE=/absolute/path/to/xeneon-license-seed \
  ./scripts/mint-license.sh --to "Ada Lovelace <ada@example.com>" --id XE-0007
# → XE1.eyJ0aWVy…
```

The wrapper is the recommended production path. For direct CLI use, build first
and then redirect stdin to the already-built issuer. This direct form does not
perform the wrapper's ownership, type, permission, symlink, or size checks:

```
cargo build -q --locked --manifest-path tools/license-tool/Cargo.toml \
  --bin xeneon-license
./tools/license-tool/target/debug/xeneon-license \
  mint --seed-stdin --to "Ada Lovelace <ada@example.com>" --id XE-0007 \
  < ~/.secrets/xeneon-license-seed
```

The former `--seed <value>` form is intentionally rejected because no CLI can
hide a secret that its caller has already placed in the process argument list.

Options: `--to <name/email>` and `--id <id>` are required; `--tier` defaults to
`pro`; `--expires` defaults to `never` (a one-time purchase shouldn't silently
expire - pass a Unix timestamp for a subscription).

The buyer pastes the key into **Manager → About → Activate Pro**. It verifies
offline as they type (they see "unlocks Pro for <name>" before committing).

## If the seed ever leaks

Generate a new keypair, ship the new public key in an app update, and every key
signed with the old seed stops verifying (fails soft to free). Re-issue current
customers' keys under the new seed. This is why every key carries an `id` -
support and re-issue.

## What's Pro

The implemented Pro delta is nine optional colour themes. Presets and custom
user widgets do not have a licence gate. Any future expansion would require a
separately documented product decision and release; this page does not promise
or advertise an unimplemented entitlement.

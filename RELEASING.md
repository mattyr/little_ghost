# Releasing LittleGhost

LittleGhost releases use a version tag, RubyGems Trusted Publishing, generated GitHub release notes, and versioned documentation rebuilt from the same commit. The release workflow stores no RubyGems API token.

## One-time setup

Create a GitHub environment named `release` and restrict it to tags matching `v*`.

Create an active tag ruleset for `v*` that restricts updates and deletions with
no bypass actors. Leave tag creation allowed. A release tag is immutable once
it is pushed.

Create a `cloudflare-pages` environment and allow Documentation workflow
deployments from `main` and tags matching `v*`. Add these environment secrets:

- `CLOUDFLARE_ACCOUNT_ID`: the account that owns `littleghostai.org`.
- `CLOUDFLARE_API_TOKEN`: a scoped token with Cloudflare Pages edit access for
  that account. Do not use a global API key.

Create the Cloudflare Pages project `littleghostai-docs` with `main` as its
production branch, attach `littleghostai.org` as its custom domain, and enable
Functions fail-open for preview and production. The workflow verifies this
configuration and repairs fail-open, but deliberately does not create the
project, domain, secrets, DNS, or redirects.

Create permanent Cloudflare Bulk Redirects from the exact hosts
`www.littleghostai.org` and `littleghostai-docs.pages.dev` to
`https://littleghostai.org`, preserving the path and query string. Do not match
preview subdomains such as `*.littleghostai-docs.pages.dev`. Proxy the `www`
DNS record through Cloudflare so its redirect is applied. The workflow checks
both aliases on paths that bypass the Pages Function before every production
deployment.

The GitHub-created `github-pages` environment must allow deployments from
`main` and tags matching `v*`. This is a one-time repository setting;
documentation and release runs do not modify environment policies.

Cloudflare Pages serves the canonical `https://littleghostai.org` site and
performs HTML/Markdown content negotiation. GitHub Pages uses GitHub Actions as
a static mirror. Each documentation deployment rebuilds Edge and every stable
released version from the repository's published release tags. The generated
site is disposable and is never committed to a branch.

Run `bundle exec rake site:serve_all` to build and browse the same versioned site locally. The task uses the GitHub CLI to discover published releases, rebuilds them in parallel from their tags, and serves the result at `http://127.0.0.1:4000/`. Set `PORT` to use another port, or `DOCS_BUILD_JOBS` to tune build concurrency.

Register a trusted publisher for the existing `little_ghost` gem on RubyGems.org with these values:

- Repository owner: `mattyr`
- Repository name: `little_ghost`
- Workflow filename: `release.yml`
- Environment: `release`

Leave the workflow repository fields empty. The workflow lives in the LittleGhost repository.

All gem owners must have multi-factor authentication enabled. Published gem metadata requires MFA and restricts the push host to `https://rubygems.org`.

Add the release maintainer's SSH public key to GitHub as a **signing key**, then
configure `user.signingkey` with the path to the same public key:

```sh
git config user.signingkey ~/.ssh/id_ed25519.pub
```

The release doctor checks that the configured key appears among the
authenticated GitHub user's public SSH signing keys before creating a tag.

## Publish a version

From a clean, current `main` branch, prepare and merge the version pull request:

```sh
bundle exec rake "release:prepare_pr[0.2.0]"
```

The task creates `release-0.2.0`, updates `LittleGhost::VERSION`, its public assertion, and `Gemfile.lock`, and then runs the complete local release gate. It commits and pushes those files, opens a draft pull request labeled `enhancement`, waits for its checks, verifies the exact release commit and file set, marks it ready, and squash-merges that commit. Finally, it confirms the merge, returns to `main`, fast-forwards the checkout, and deletes the local release branch.

If any command fails, the task stops at that point and leaves the branch and working tree intact for inspection. It never bypasses branch protection.

Publish the prepared version with a separate, deliberate command:

```sh
bundle exec rake release:publish
```

The publish task validates that `origin` is this repository, fetches remote state, requires a clean `main` exactly matching `origin/main`, and runs the release doctor. It creates the required SSH-signed version tag, pushes that tag, verifies its exact object and commit with GitHub, finds the matching GitHub Actions release run, and watches it to completion. Keep this irreversible publication step separate from pull-request preparation.

If the tag push succeeds but workflow discovery or watching is interrupted, run `bundle exec rake release:publish` again. The task recognizes the same verified local and remote tag, does not recreate or push it, and resumes watching the workflow for that tag commit. It refuses mismatched, lightweight, unverified, or wrong-commit tags.

The tag starts the release workflow. Repository permissions control who can push it, and the workflow requires GitHub to report a valid tag signature before verifying the version and membership in `main`. Immediately before trusted publishing, it confirms that the remote tag is still the exact verified tag object and commit. It then reruns the complete gate, publishes through RubyGems OIDC, verifies the served package, and creates the GitHub Release. RubyGems checksum verification tolerates bounded API propagation delays while retaining complete package-equivalence checks.

After the GitHub Release exists, the release workflow dispatches the separate Documentation workflow. The release does not wait for documentation publication. Documentation independently rebuilds Edge and every stable released version, then refuses to deploy if either the successful `main` source or published release set changed during the build. It validates a unique Cloudflare preview, rechecks source freshness and canonical aliases, deploys and verifies the canonical site, and only then publishes the identical static artifact to the GitHub Pages mirror.

The documentation root is Edge and follows every successful `main` build. Its version selector lists stable releases from newest to oldest. Each build discovers published stable releases, verifies their automated publication, annotated tags, and `main` ancestry, then recreates each site from its release commit. The operation is idempotent: the same source set produces a fresh disposable site, with no generated branch to maintain. Prerelease tags rely on Edge and do not add a versioned documentation site.

GitHub generates the release notes from merged pull requests. The `enhancement`, `bug`, and `documentation` labels group the notes; every other pull request appears under **Other changes**. Prerelease gem versions produce prerelease GitHub Releases but do not add a versioned documentation site.

## Verify a release

The release workflow must finish all three jobs successfully:

- `validate` proves the source, package, and site are releasable.
- `publish` verifies the gem on RubyGems and creates the matching GitHub Release with the published gem and checksum attached.
- `verify-release` confirms RubyGems and the GitHub Release assets expose the expected content.

The independently dispatched Documentation workflow publishes Edge and stable version URLs. Its status is visible as a separate workflow run. The `publish-cloudflare` job must succeed before the `publish-site` mirror job begins.

Confirm the version on RubyGems, the generated GitHub Release notes, Edge at the documentation root, and the released version in the selector and permanent version URL. For an explicit edge check, read the current deployment marker and run the same verification scripts as CI:

```sh
deployment="$(curl --fail --silent --show-error https://littleghostai.org/deployment.json)"
scripts/verify-documentation-edge \
  https://littleghostai.org \
  "$(jq --raw-output .source_sha <<< "$deployment")" \
  "$(jq --raw-output .deployment_id <<< "$deployment")"
scripts/verify-documentation-aliases
```

## Recover a partial release

Rerun the failed workflow from GitHub Actions. When RubyGems already contains the version, the workflow builds the tag again and compares the complete gem specification and packaged file digests with the published artifact before continuing. Existing GitHub Release assets are replaced with the verified RubyGems artifact and checksum.

For a documentation failure, inspect `publish-cloudflare` first. A missing
project, custom domain, environment secret, or alias redirect must be repaired
in Cloudflare before rerunning; a Pages rollback cannot repair account-level
DNS or Bulk Redirect state. If canonical post-deploy verification fails, the
workflow rolls Pages back to the previous production deployment when one
exists and does not update the GitHub Pages mirror. On the first deployment,
there is no rollback target, so verify the one-time setup and rerun after the
cause is fixed. The public `deployment.json` identifies the exact workflow
attempt and successful `main` SHA currently being served; it contains no
credentials.

Gem versions are immutable. Fix a bad published release with a new version instead of moving or replacing its tag. Bundler release tasks refuse local invocation and accept only the expected version tag inside the trusted GitHub Actions publishing step.

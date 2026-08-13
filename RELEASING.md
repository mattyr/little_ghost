# Releasing LittleGhost

LittleGhost releases use a version tag, RubyGems Trusted Publishing, generated GitHub release notes, and documentation built from the same commit. The release workflow stores no RubyGems API token.

## One-time setup

Create a GitHub environment named `release` and restrict it to tags matching `v*`.

Create an active tag ruleset for `v*` that restricts updates and deletions with
no bypass actors. Leave tag creation allowed. A release tag is immutable once
it is pushed.

The GitHub-created `github-pages` environment must also allow tags matching `v*`. This is a one-time repository setting; release runs do not modify environment policies.

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

The tag starts the release workflow. Repository permissions control who can push it, and the workflow requires GitHub to report a valid tag signature before verifying the version and membership in `main`. Immediately before trusted publishing, it confirms that the remote tag is still the exact verified tag object and commit. It then reruns the complete gate, publishes through RubyGems OIDC, verifies the served package, creates the GitHub Release, deploys the website and API documentation from that tag, and checks every public release surface. RubyGems checksum verification tolerates bounded API propagation delays while retaining complete package-equivalence checks.

GitHub generates the release notes from merged pull requests. The `enhancement`, `bug`, and `documentation` labels group the notes; every other pull request appears under **Other changes**. Prerelease gem versions produce prerelease GitHub Releases and a prerelease version badge on the documentation site.

## Verify a release

The workflow must finish all four jobs successfully:

- `validate` proves the source, package, and site are releasable.
- `publish` verifies the gem on RubyGems and creates the matching GitHub Release with the published gem and checksum attached.
- `deploy-pages` makes the released documentation public.
- `verify-release` confirms RubyGems, the GitHub Release assets, the website, and the API documentation expose the released version.

Confirm the version on RubyGems, the generated GitHub Release notes, and the version badge on both the website and API documentation.

## Recover a partial release

Rerun the failed workflow from GitHub Actions. When RubyGems already contains the version, the workflow builds the tag again and compares the complete gem specification and packaged file digests with the published artifact before continuing. Existing GitHub Release assets are replaced with the verified RubyGems artifact and checksum.

Gem versions are immutable. Fix a bad published release with a new version instead of moving or replacing its tag. Bundler release tasks refuse local invocation and accept only the expected version tag inside the trusted GitHub Actions publishing step.

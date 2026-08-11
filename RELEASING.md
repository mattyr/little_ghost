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

1. Prepare the version on a clean pull-request branch. This updates `LittleGhost::VERSION`, its public assertion, and `Gemfile.lock` together:

   ```sh
   bundle exec rake "release:prepare[0.1.1]"
   ```

2. Run the local gate:

   ```sh
   bundle exec rake test
   bundle exec standardrb --no-fix
   bundle exec rake site:check
   bundle exec rake package:check
   git diff --check
   ```

3. Merge the version pull request and update the local `main` branch.
4. Fetch the remote state and run the release doctor. It fails when the worktree is dirty, `HEAD` differs from `origin/main`, the tag exists, RubyGems already contains the version, or the configured SSH signing key is not registered with GitHub:

   ```sh
   git fetch origin main --tags
   bundle exec rake release:doctor
   ```

5. Create a signed tag whose name exactly matches `v#{LittleGhost::VERSION}`.
   The task forces SSH signing and fails when Git cannot create the signature:

   ```sh
   version="$(ruby -Ilib -rlittle_ghost/version -e 'print LittleGhost::VERSION')"
   bundle exec rake release:tag
   git push origin "v${version}"
   ```

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

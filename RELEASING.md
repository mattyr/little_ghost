# Releasing LittleGhost

LittleGhost releases use a version tag, RubyGems Trusted Publishing, generated GitHub release notes, and documentation built from the same commit. The release workflow stores no RubyGems API token.

## One-time setup

Create a GitHub environment named `release` and restrict it to tags matching `v*`.

Register a trusted publisher for the existing `little_ghost` gem on RubyGems.org with these values:

- Repository owner: `mattyr`
- Repository name: `little_ghost`
- Workflow filename: `release.yml`
- Environment: `release`

Leave the workflow repository fields empty. The workflow lives in the LittleGhost repository.

All gem owners must have multi-factor authentication enabled. Published gem metadata requires MFA and restricts the push host to `https://rubygems.org`.

## Publish a version

1. Update `LittleGhost::VERSION` in `lib/little_ghost/version.rb` on a pull-request branch.
2. Run the local gate:

   ```sh
   bundle exec rake test
   bundle exec standardrb --no-fix
   bundle exec rake site:check
   bundle exec rake package:check
   git diff --check
   ```

3. Merge the version pull request and update the local `main` branch.
4. Create an annotated tag whose name exactly matches `v#{LittleGhost::VERSION}`:

   ```sh
   version="$(ruby -Ilib -rlittle_ghost/version -e 'print LittleGhost::VERSION')"
   git tag -a "v${version}" -m "Version ${version}"
   git push origin "v${version}"
   ```

The tag starts the release workflow. It verifies that the tag matches the gem version and belongs to `main`, reruns the complete gate, publishes through RubyGems OIDC, verifies the served package, creates the GitHub Release, and deploys the website and API documentation from that tag.

GitHub generates the release notes from merged pull requests. The `enhancement`, `bug`, and `documentation` labels group the notes; every other pull request appears under **Other changes**. Prerelease gem versions produce prerelease GitHub Releases and a prerelease version badge on the documentation site.

## Verify a release

The workflow must finish all three jobs successfully:

- `validate` proves the source, package, and site are releasable.
- `publish` verifies the gem on RubyGems and creates the matching GitHub Release with the published gem and checksum attached.
- `deploy-pages` makes the released documentation public.

Confirm the version on RubyGems, the generated GitHub Release notes, and the version badge on both the website and API documentation.

## Recover a partial release

Rerun the failed workflow from GitHub Actions. When RubyGems already contains the version, the workflow builds the tag again and compares the complete gem specification and packaged file digests with the published artifact before continuing. Existing GitHub Release assets are replaced with the verified RubyGems artifact and checksum.

Gem versions are immutable. Fix a bad published release with a new version instead of moving or replacing its tag. Local `rake release` remains available as a Bundler task, but the supported publishing path is the tag-triggered workflow.

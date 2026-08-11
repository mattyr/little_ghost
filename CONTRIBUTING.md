# Contributing to LittleGhost

Thanks for helping LittleGhost grow. Focused issues, documentation improvements,
bug fixes, and new ideas are all welcome.

Participation in this project follows our [Code of Conduct](CODE_OF_CONDUCT.md).
Please share security vulnerabilities through a
[private security report](SECURITY.md).

## Development

LittleGhost requires Ruby 3.3 or newer. Install the dependencies with:

```sh
bundle install
```

Keep changes focused, cover behavior changes with tests, and update adjacent
documentation when public behavior changes.

Run the local checks before opening a pull request:

```sh
bundle exec rake test
bundle exec standardrb --no-fix
git diff --check
```

## Pull requests

Use a clear, reader-facing title and describe what changed and why. Include the
automated checks that passed and any manual verification that remains useful.

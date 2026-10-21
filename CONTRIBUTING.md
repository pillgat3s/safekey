# Contributing

SafeKey is published so that anyone can read what it does with their keys.
It is maintained by one person, and for now it is **not accepting pull
requests**: keeping the whole codebase under a single copyright holder is
what lets it ship on the App Store under the GPL without a contributor
agreement, and reviewing crypto changes properly takes more time than a
small project has.

What is welcome:

- **Bug reports and security findings.** For anything security-relevant,
  follow [SECURITY.md](SECURITY.md) rather than opening a public issue.
- **Issues** describing a problem you hit, with the platform and version. Keep
  real secrets out of them.
- **Reading the code critically** and telling us where the comments and the
  behaviour disagree.

If you want to build it yourself, the README has the commands. The UI tests
run against an isolated vault, so they never touch a real one.

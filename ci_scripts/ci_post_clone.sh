#!/bin/sh
#
# Xcode Cloud runs this right after cloning the repository and before it
# looks for the project to build. SafeKey.xcodeproj is generated from
# project.yml and never committed, so a fresh clone has no project until this
# script makes one — the same `xcodegen generate` a local build runs.
#
set -e
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

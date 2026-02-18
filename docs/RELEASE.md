# Release and Versioning Guide

This document explains how to publish a new version and make in-app update checks work.

## Versioning strategy

Use semantic versioning:

- `MAJOR.MINOR.PATCH`
- Example: `1.0.0`

## Where version lives

macOS app version/build are set in Xcode project build settings:

- `MARKETING_VERSION` -> user-visible version (example `1.0.0`)
- `CURRENT_PROJECT_VERSION` -> build number (example `12`)

Keep Git tag aligned with `MARKETING_VERSION`.

## Pre-release checklist

- Ensure backend starts cleanly.
- Build macOS app from Xcode.
- Verify onboarding flow.
- Verify search/upload/settings shortcuts.
- Verify LLM cloud/local config in Settings.
- Verify update check from menu and Settings.

## Publish a release

1. Commit and push final code.

```bash
git push origin main
```

2. Create and push tag.

```bash
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

3. Create GitHub release.

- Open: `https://github.com/daniel-trachtenberg/archive-plugin/releases`
- Click `Draft a new release`
- Select tag `v1.0.0`
- Add title and release notes
- Attach distributable assets if needed
- Publish release

Important:

- Do not leave it as draft if you want update checks to find it.
- If marked `Pre-release`, GitHub latest-release behavior may differ from your expectations.

## How update checks work

The app checks:

1. `GET /repos/<owner>/<repo>/releases/latest`
2. If no release exists, it falls back to latest tag

If neither release nor tags exist, users see a friendly "no published release yet" message.

## Release notes template

Recommended sections:

- Highlights
- New features
- Fixes
- Breaking changes
- Migration notes

## Optional: GitHub CLI workflow

```bash
gh release create v1.0.0 \
  --title "v1.0.0" \
  --notes "Release notes here"
```

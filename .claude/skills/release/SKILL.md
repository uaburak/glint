---
name: release
description: Publish a new Glint version end to end — version number, Turkish release notes, signed and notarized DMG, commits, pushes, GitHub release, verification. Use when the user asks for a new version or release ("yeni sürüm çıkar", "sürüm yayınla", "release et", "güncelleme çıkar").
---

# Glint release

The user wants releases handled completely; don't hand them steps. Installed copies read
`https://github.com/uaburak/glint/releases/latest/download/appcast.xml` (Sparkle), so a
release is only live once the GitHub release carrying the DMG **and** `appcast.xml` is the latest.

## 1. What goes in

- `git status`: finished app changes that are still uncommitted belong in this release. Commit
  them first in the repo's style (`feat:` / `fix:` …, English, a short why-focused body, the
  Co-Authored-By trailer). Leave unrelated scratch alone (`Tools/GlassLab/`, the `main` binary at
  the root). If something looks half-done, ask before shipping it.
- Work happens on `V2`; `main` is kept identical to it. If the branch isn't `V2`, ask.
- Last release: `git describe --tags --abbrev=0` (or `gh release view --repo uaburak/glint`).

## 2. Version and notes

- The user may name the version. Otherwise: any `feat:` since the last tag → minor (1.0 → 1.1),
  only fixes → patch (1.1 → 1.1.1). The build number is handled by the script.
- Write the notes in Turkish, for users, not developers: what changed for them, grouped under
  `#### Yeni` / `#### Düzeltmeler`, from `git log <last tag>..HEAD`. No commit hashes. Save to
  `build/release-notes-<version>.md` (build/ is git-ignored). Sparkle shows them as Markdown.

## 3. Build

```bash
Tools/release.sh <version> build/release-notes-<version>.md
```

Run it in the background (archive + notarization take a few minutes). It checks the setup first,
sets MARKETING_VERSION and bumps CURRENT_PROJECT_VERSION, signs with Developer ID, notarizes and
staples the DMG, signs it for Sparkle and writes `build/release/<version>/appcast.xml` with the
earlier entries kept. On failure it puts the version back. Common failures:
- Developer ID certificate expired (the current one ends **2027-02-01**): the user makes a new one
  in Xcode › Settings › Apple Accounts › Manage Certificates › + › Developer ID Application.
- Notary profile `glint-notary` missing/invalid: the user reruns
  `xcrun notarytool store-credentials glint-notary --apple-id koc_bilal@icloud.com --team-id Q6GDNC3V8B`
  with a fresh app-specific password.
- Update key missing from the login keychain: stop. Never generate a new one — installed copies
  would reject every future update. It has to be imported from the user's backup.

## 4. Commit and push

```bash
git add Glint.xcodeproj/project.pbxproj
git commit -m "release: Glint <version> (<build>)" -m "Co-Authored-By: …"
git push origin V2
git push origin V2:main     # only when origin/main is an ancestor of HEAD; otherwise ask
```

Run each as its own command (the permission rules in `.claude/settings.local.json` match these
exact commands).

## 5. Publish

```bash
gh release create v<version> build/release/<version>/Glint-<version>.dmg build/release/<version>/appcast.xml \
  --repo uaburak/glint --target main --title "Glint <version>" --notes-file build/release-notes-<version>.md
```

`gh` lives in `~/.local/bin`. If it says it isn't logged in, the user runs `gh auth login` once
(GitHub.com, HTTPS, browser). Don't mark it pre-release: GitHub's "latest" skips those, and the
feed URL follows "latest".

## 6. Verify from outside, then report

- `curl -sL https://github.com/uaburak/glint/releases/latest/download/appcast.xml` is 200 and its
  first item is the new version.
- Download the enclosure URL, `sign_update --verify <dmg> <edSignature>` passes
  (`build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`), and with a
  quarantine flag `spctl --assess --type open --context context:primary-signature` says
  "Notarized Developer ID".
- Tell the user in Turkish: the version, what's in it, the release link, and that installed
  copies pick it up at their next daily check (or right away via "Güncellemeleri Denetle…").

## What and why

<!-- What does this change, and why? Link the issue it fixes ("Fixes #123"). -->

## How it was tested

<!-- Tests added or changed, commands run, and for UI work an off-screen snapshot:
     swift run arclight snapshot Examples/<example>.arclight --out ui.png -->

## Checklist

- [ ] `swift build -Xswiftc -warnings-as-errors` builds with no warnings
- [ ] `swift test` passes
- [ ] `Scripts/verify.sh` passes, or the differences are explained above
- [ ] `swift format lint --strict -r Sources Tests Scripts Package.swift` reports nothing
- [ ] Refactors don't change behaviour; behaviour changes and bug fixes are in their own commits
- [ ] `docs/scene-format.md` regenerated (`swift run arclight docs --out docs/scene-format.md`) if the schema changed
- [ ] CHANGELOG.md updated under "Unreleased" for user-visible changes

By opening this pull request, I agree that my contribution is licensed under the project's license, the
[GNU General Public License v3.0](https://github.com/xndrpr/arclight/blob/main/LICENSE) (inbound = outbound).
No CLA or DCO sign-off is needed.

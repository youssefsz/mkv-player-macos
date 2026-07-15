## Summary

Describe the user-visible result and why the change is needed.

## Validation

- [ ] `swift test --package-path Packages/PlayerCore`
- [ ] `swift test --package-path Packages/MPVKit`
- [ ] MKVPlayer scheme tests in Xcode or with `xcodebuild`
- [ ] Relevant playback fixtures or manual scenarios exercised
- [ ] Light and dark appearance checked for UI changes
- [ ] Keyboard and VoiceOver behavior checked for UI changes

List any checks that do not apply and explain why.

## Screenshots

Include before-and-after images for visual changes. Use synthetic media and do
not expose personal files, paths, or playback history.

## Release impact

Note changes to dependencies, entitlements, sandbox access, supported formats,
update behavior, or release documentation. Write `None` when there is no impact.

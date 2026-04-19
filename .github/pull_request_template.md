## What does this change?

<!-- One paragraph summary -->

## Motivation

<!-- Why is this change needed? Link to any relevant issues with "Closes #123" -->

## Release Note

<!-- For feat: and fix: PRs, write the changelog entry here in prose style.
     Format: **Bold title** — Problem, what changed, why it matters.
     This is copied into CHANGELOG.md at release time.
     For chore/test/docs PRs, write "N/A". -->

## Testing

<!-- How was this tested? Which test targets cover it? -->
<!-- Note: BaseChatCoreTests and BaseChatUITests run in CI. Hardware-dependent tests (BaseChatBackendsTests, BaseChatE2ETests) run locally. -->

## Sabotage evidence (regression-test PRs only)

<!-- For any PR adding a regression test: temporarily revert the fix / break the
     code path under test, confirm the new test goes RED, then re-apply the fix
     and confirm GREEN. Paste the diff and red-run log (or link to a comment
     that contains them). Exempt: pure refactors, docs-only PRs, dep bumps. -->

- [ ] N/A (not a regression-test PR)
- [ ] Reverted the fix / broke the path under test
- [ ] Confirmed the new test went RED (log pasted or linked below)
- [ ] Re-applied the fix and confirmed GREEN

## Checklist

- [ ] Tests added or updated for new behaviour
- [ ] Public API changes have `///` doc comments
- [ ] No hardcoded secrets, API keys, or personal data
- [ ] Breaking change? (if yes, describe migration path below)

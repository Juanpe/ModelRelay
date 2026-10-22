## 🎯 What

<!-- One or two sentences on the change. Link the issue if there is one: Fixes #123 -->

## 🤔 Why

<!-- The problem it solves, or the workflow it enables. -->

## 🧪 How it was tested

<!-- New or updated tests, and anything verified by hand (live models, MLX, devices). -->

## ✅ Checklist

- [ ] `make format` and `make check-style` pass.
- [ ] `env -u RELAY_LIVE swift test -Xswiftc -warnings-as-errors` passes.
- [ ] Behavior is tested through `ScriptedModel` / `StubProtocol`, without live services or keys.
- [ ] Public API changes are documented, and the relevant guide is updated.
- [ ] User-facing changes are in `CHANGELOG.md` under `Unreleased`.
- [ ] Breaking changes (API, behavior, Codable or platform) are called out with a migration.
- [ ] No credentials, private data or prompts with user content in code, fixtures or logs.

## 📣 Notes for review

<!-- Optional: trade-offs, follow-ups or anything reviewers should look at first. -->

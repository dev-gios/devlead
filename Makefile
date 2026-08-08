.PHONY: test

# Wired so gate-check.sh detects a test runner for this repo. Without a
# Makefile, its detection chain (package.json -> Makefile -> go.mod ->
# pyproject.toml) finds nothing here and silently skips the test gate.
#
# Recipe lines MUST start with a TAB. A merge that resolves these lines with
# spaces breaks the target with "missing separator", and takes the QA gate
# down with it — which is exactly what happened landing the five-PR chain.
#
# The suites are sandboxed: they override $HOME to a throwaway /tmp directory,
# inject state roots, and intercept `gh` and `systemctl` with fakes on $PATH.
test:
	bash test/unit-run-state.sh
	bash test/unit-branch-deps.sh
	bash test/unit-envelope-merge-mode.sh
	bash test/unit-publish-manifest.sh
	bash test/unit-sweep-loop.sh
	bash test/unit-loop-units.sh
	bash test/smoke-outcomes.sh
	bash test/smoke-pinned-release.sh

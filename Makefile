.PHONY: test

# Wired so gate-check.sh detects a test runner for this repo. Without a
# Makefile, its detection chain (package.json -> Makefile -> go.mod ->
# pyproject.toml) finds nothing here and silently skips the test gate.
#
# Both suites are fully sandboxed: they override $HOME to a throwaway /tmp
# directory and intercept `gh` and `systemctl` with fakes on $PATH.
test:
	bash test/unit-run-state.sh	
    bash test/unit-branch-deps.sh
    bash test/unit-envelope-merge-mode.sh
    bash test/smoke-outcomes.sh
    bash test/smoke-pinned-release.sh
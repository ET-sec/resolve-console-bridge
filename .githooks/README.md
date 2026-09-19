# .githooks

Three git hooks this repository installs through `core.hooksPath`. They move the secret boundary
from continuous integration onto the laptop: on a public repository a pushed branch is already
public, so a scan that only runs after the push runs too late.

| Hook | What it refuses |
|---|---|
| `pre-commit` | staged changes carrying a secret or a sanitization tripwire (gitleaks, default rules plus this repo's), Lua that does not compile, markdown containing em or en dashes (house style) |
| `commit-msg` | a commit whose author or co-author is not an approved identity |
| `pre-push` | any unpushed commit carrying a secret, and any commit in the push range by an unapproved identity |

Install with `git config core.hooksPath .githooks` and `brew install gitleaks` (or your platform's
package). The approved identity list lives outside the code: `.githooks/authors.allow` locally
(gitignored) and the `AUTHORSHIP_ALLOW` repository variable in CI, so no personal address lives in
the tree. The two public GitHub no-reply addresses that the web merge button and Actions use are
the only ones named in the scripts.
The same rule is checked by `scripts/repo/check_authorship.sh` and the `authorship-guard` workflow,
so the laptop and the pipeline enforce it identically.

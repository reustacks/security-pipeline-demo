# Security Pipeline Demo

A CI/CD security pipeline built with GitHub Actions. It checks for secrets, vulnerable dependencies, and insecure code patterns on every push and pull
request.

The Flask API in this repo is deliberately small. It's there to give the
pipeline something to scan.

---

## What the pipeline does

Five jobs run in parallel on every push and pull request:

| Job | Tool | Catches | Blind to |
|---|---|---|---|
| `test` | pytest | Broken functionality | Security issues |
| `secrets-scan` | Gitleaks | Committed credentials, including in git history | Logic flaws |
| `dependency-scan` | pip-audit | Known CVEs in third-party packages | Bugs in first-party code |
| `sast` | Semgrep | Insecure patterns in source code | Runtime and config issues |
| `iac-scan` | Checkov, `terraform fmt`, `terraform validate` | Misconfigured infrastructure, malformed or invalid Terraform | Application-level issues |

Each tool covers different ground and they don't overlap much. A secrets scanner
won't find a SQL injection. A SAST tool won't tell you a dependency you pinned
six months ago now has a published CVE.

`test` is in there because a patched dependency that breaks the app isn't
actually a fix.

### A few notes on the config

**`fetch-depth: 0` on the secrets scan.** The default checkout only pulls the
latest commit. Secrets often sit in history, and a key that was committed then
deleted is still in the git objects. Full history is needed for the scan to mean anything.

**Three Semgrep rule packs** (`p/default`, `p/python`, `p/flask`).
Framework-specific rules catch things the generic ones miss. The Flask pack is what found the host-binding issue below.

**Semgrep runs in its own container** via `container: image: semgrep/semgrep`,
so the tool is already installed and there's no setup step to go wrong.

---

## What it caught

I didn't plant any vulnerabilities. Everything below came up on the scanners'
first run against normal starter code, which honestly makes a better case for running them than a planted bug would.

### 1. Eight unpinned GitHub Actions (Semgrep)

**Rule:** `yaml.github-actions.security.github-actions-mutable-action-tag`

Every action was referenced by tag: `actions/checkout@v4`,
`actions/setup-python@v5`, `gitleaks/gitleaks-action@v2`.

Tags are movable. Whoever controls an action's repo can repoint `v4` at
different code, and every workflow using that tag will pull it and run it with a `GITHUB_TOKEN` in scope. This has happened for real: `tj-actions/changed-files`,
`trivy-action`, and `kics-github-action` were all compromised this way.

**Fix:** pinned every action to a full 40-character commit SHA, which can't be
moved. I kept the version comments (`# v4`) so Dependabot can still tell what
version a SHA is and open update PRs.

```yaml
# Before
- uses: actions/checkout@v4

# After
- uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
```

I pulled the SHAs from the GitHub API rather than copying them out of a blog
post:

```bash
gh api repos/actions/checkout/git/ref/tags/v4 --jq .object.sha
```

Worth noting the first thing this security pipeline found was a problem with the
security pipeline.

### 2. Three CVEs in pinned dependencies (pip-audit)

```
Name    Version  ID                Fix Versions
flask   3.0.3    PYSEC-2026-2151   3.1.3
pytest  8.2.0    PYSEC-2026-1845   9.0.3
```

Both were pinned at versions that were fine when I wrote them and had advisories
published by the time the pipeline ran. There's no version you can pick that
stays safe, which is the whole reason to have a scanner running on every push.

**Fix:** bumped to the patched versions, then re-ran the tests to check the
upgrade hadn't broken anything. Flask 3.0 to 3.1 and pytest 8 to 9 are big
enough jumps that this wasn't guaranteed.

### 3. Flask bound to all network interfaces (Semgrep)

**Rule:** `python.flask.security.audit.app-run-param-config.avoid_app_run_with_bad_host`

```python
app.run(debug=False, host="0.0.0.0", port=5000)
```

`0.0.0.0` binds to every network interface, so the dev server is reachable from
the local network instead of just localhost.

**Fix:** default to `127.0.0.1` and require an environment variable to widen it.
The insecure option is still there for cases that need it, but you have to
choose it on purpose now.

```python
host = os.environ.get("FLASK_HOST", "127.0.0.1")
app.run(debug=False, host=host, port=5000)
```

---

## Pipeline history

| Commit | Result |
|---|---|
| Initial commit: Flask app + starter CI | Pass. Baseline with tests and Gitleaks only |
| Add pip-audit and Semgrep | **Fail.** 8 SAST findings, 3 CVEs |
| Pin actions to SHAs, patch CVEs | **Fail.** Down to 1 finding |
| Bind Flask to localhost | Pass. All four jobs green |

![Pipeline failing](docs/pipeline-failing.png)

![Pipeline passing](docs/pipeline-passing.png)

---

## Infrastructure as Code

The pipeline also scans the Terraform in `terraform/`, which sets up a KMS key, two S3 buckets (one for data, one for access logs), and the IAM role and policy the app would run under. I wrote it deliberately misconfigured at first, then hardened it against Checkov using the same catch-fix-verify pattern as the app.

### 26 findings down to 0

Checkov started at 26 failures. Most were the usual things: turn on bucket versioning, block public access, replace a wildcard KMS policy with specific actions. Three I left alone on purpose, and wrote up why in `.checkov.yml`:

| Check | What it wants | Why I skipped it |
|---|---|---|
| `CKV2_AWS_62` | S3 event notifications | Nothing's listening. No Lambda or SQS queue to notify |
| `CKV_AWS_144` | Cross-region replication | No disaster recovery requirement here, and it costs money for nothing |
| `CKV_AWS_145` | KMS on the log bucket | That bucket gets written to constantly. AES256 is fine and KMS would add a per-request charge for no real gain |

One gotcha: `CKV2_*` checks are graph checks, and they ignore inline `#checkov:skip` comments. They only listen to the config file, which is why the exceptions live in `.checkov.yml` instead of next to the resources.

### Checkov passed a file Terraform wouldn't touch

At one point `terraform/main.tf` had `aws_kms_key "s3"` defined twice, a real block plus a leftover five-line stub from an earlier edit. Checkov only checks for misconfigurations, it doesn't check whether the HCL is even valid, so it passed the file clean and `iac-scan` stayed green. The duplicate merged into `main`. Terraform itself has no such patience:

---

## Why these tools

**Semgrep over CodeQL.** CodeQL does deeper dataflow analysis and would find
more. I went with Semgrep for faster feedback and because the rule packs are
readable YAML, which matters more for a project meant to demonstrate the
pipeline than to secure a big codebase. On a real Python service I'd run both.

**pip-audit over just Dependabot.** Dependabot opens PRs but doesn't fail a
build. pip-audit is a gate, so a vulnerable dependency can't merge quietly. They
work well together: Dependabot for the fix, pip-audit for the enforcement.

**Gitleaks over TruffleHog.** Both are fine. Gitleaks had the simpler Actions
integration and less config to get working at this size.

---

## Limitations

- **False positives happen.** SAST flags patterns, not exploits, so some
  findings are unreachable code paths. Triaging that is real work and I haven't
  had to do much of it yet at this scale.
- **pip-audit fails on any published CVE**, even in code paths the app never
  touches. Right default, but noisy.
- **SHA pins don't update themselves.** Without Dependabot this gets stale fast.
- **All static analysis.** No DAST, no container scanning. Different ground.

---

## Running locally

```bash
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
pytest -v
python app.py
```

Endpoints: `/`, `/health`, `/users/<username>`.

---

## Branch protection

All five checks have to pass before anything merges into `main`. No direct pushes either. I confirmed this by trying to push straight to main and getting bounced:


![Branch protection rejection](docs/branch-protection-rejection.png)

---

## Next steps

- [ ] Dependabot config for dependency and action updates
- [ ] SARIF upload so findings show in the Security tab instead of only in logs

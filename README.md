# ci-pipelines

One CI/CD pipeline for every repository. A repository adds a single short workflow file and
gets:

- **CI:** install, format check, lint, typecheck, test and build, for Node.js (npm), Python,
  Java (Maven) and plain HTML sites, detected automatically.
- **Security:** a secret scan of new commits, dependency review on pull requests, and CodeQL
  code scanning.
- **CD:** deploys to GitHub Pages, Firebase Hosting, or S3 with CloudFront. Deploys run only
  after CI and security pass.

The logic lives here once, as [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows).
Fixes made here reach every repository that calls `@v1`.

```
push / pull request
        │
        ├── CI ─────────── build and test ── build artifact ──┐
        └── Security ───── secrets · dependencies · CodeQL ───┤
                                                              ▼
                                       Deploy (main, or dev/uat/main)
                                       Pages · Firebase · S3 + CloudFront
```

## Add it to a repository

The quickest way opens a pull request that adds the pipeline:

```sh
scripts/adopt.sh <owner/repo> <template>          # for example: Abbbtle/mini-amazon github-pages
scripts/adopt.sh <owner/repo> <template> --dry-run   # look first; pushes nothing
```

The script:
- finds the project folder;
- adds `.github/workflows/pipeline.yml` from the template;
- adds a Dependabot config if the repository has none;
- for `github-pages`, switches Pages to publish from GitHub Actions;
- opens the pull request against `dev` if that branch exists, otherwise against the default branch.

The pull request's checks are the pipeline's first run.

To do it by hand, copy a template into the repository as `.github/workflows/pipeline.yml`. Then
set `working-directory` if the project is not at the top of the repository.

| Template | Deploys |
| --- | --- |
| [`ci-only`](templates/ci-only.yml) | Nothing; checks only. |
| [`github-pages`](templates/github-pages.yml) | `main` to GitHub Pages. |
| [`firebase`](templates/firebase.yml) | Pull requests to preview channels, `main` to the live site. |
| [`aws-s3`](templates/aws-s3.yml) | `dev`, `uat` and `main` to their own S3 (and CloudFront) sites. |

Each template also runs weekly, to catch newly published vulnerabilities in code that has not
changed. In branch protection or rulesets, require the checks **CI / Build and test** and
**Security / Secret scan**.

## CI: `ci.yml`

What runs depends on the detected stack:

| Stack | Detected by | Runs |
| --- | --- | --- |
| Node.js | `package.json` | `npm ci`, then each of `format:check lint typecheck test build` that the project defines |
| Python | `pyproject.toml`, `requirements.txt`, `setup.py` or `*.py` | Installs dependencies, then compiles every file, runs ruff, mypy (if configured) and pytest (if there are tests) |
| Java | `pom.xml` | `mvn verify` (or `./mvnw`) |
| Static | `*.html` | Checks for an `index.html`; the folder itself is the site |

All checks run even when an earlier one fails, so one run shows every problem. The job summary
lists each check's result.

Python lint without a ruff config reports only real errors: syntax errors and undefined names.
To have the full ruff rules apply, add a `[tool.ruff]` section.

| Input | Default | Purpose |
| --- | --- | --- |
| `working-directory` | `.` | Project folder inside the repository. |
| `stack` | `auto` | `node`, `python`, `java` or `static` to skip detection. |
| `node-version` | `.nvmrc`, `.node-version`, else `24` | Node.js version. |
| `python-version` | `.python-version`, else `3.14` | Python version. |
| `java-version` | `21` | Temurin JDK version. |
| `scripts` | `format:check lint typecheck test build` | npm scripts to run, in order. Missing ones are skipped. |
| `build-args` | | Added to `npm run build`, for example `--base=/repo/`. |
| `build-env` | | Non-secret `KEY=VALUE` lines exported to every step, for example `VITE_` settings. |
| `build-output` | `dist`, `build` or `out`; `target/*.jar`; the whole folder for static | What to keep as the build artifact. |
| `artifact-name` | `build` | Name of that artifact; set it when calling `ci.yml` twice in one workflow. |
| `postgres-version` | | Starts PostgreSQL (for example `18`) and sets `DATABASE_URL` and `TEST_DATABASE_URL`. |
| `extra-command` | | A last shell command for project-specific checks. |
| `runs-on` | `ubuntu-24.04` | Runner, for example `ubuntu-24.04-arm`. |
| `timeout-minutes` | `20` | Job time limit. |

Secret `build-secrets` takes `KEY=VALUE` lines like `build-env`, with the values masked in logs.
Outputs are `stack` and `artifact-name`. `artifact-name` is empty when nothing was kept.

## Security: `security.yml`

The caller grants `contents: read`, `security-events: write` and `actions: read`.

- **Secret scan:** [gitleaks](https://github.com/gitleaks/gitleaks) scans the commits a pull
  request or push adds, and the whole history on scheduled and manual runs. Found values are
  redacted in the log and summary. Treat a real finding as leaked: rotate the secret, then remove
  it. List a false positive in `.gitleaksignore` by the fingerprint the scan prints.
- **Dependency review:** on pull requests, fails when a change adds a dependency with a known
  vulnerability at or above `fail-on-severity` (default `high`). It needs the repository's
  dependency graph (**Settings > Code security**). Without the graph, the job warns and skips.
  `adopt.sh` switches the graph on.
- **CodeQL:** analyses the languages of the repository's files (JavaScript/TypeScript, Python,
  Java/Kotlin, Go, Ruby, C#), plus the workflows themselves. Results appear under
  **Security > Code scanning**. If a repository has CodeQL *default setup* switched on, switch it
  off, or set `codeql-languages: none`; the two cannot both upload.

| Input | Default | Purpose |
| --- | --- | --- |
| `secret-scan` | `true` | Run gitleaks. |
| `fail-on-severity` | `high` | `low`, `moderate`, `high` or `critical`. |
| `codeql-languages` | `auto` | Comma-separated list, `auto`, or `none`. |
| `runs-on` | `ubuntu-24.04` | Runner. |

## Deploy: GitHub Pages, `deploy-pages.yml`

Setup: in **Settings > Pages**, set **Source** to **GitHub Actions** (`adopt.sh` does this).
The caller grants `pages: write` and `id-token: write`.

A site served from `<user>.github.io/<repo>/` lives under the repository name. Vite builds need
that name as their base path, which the template passes through `build-args`. Remove that line
for a custom domain.

| Input | Default | Purpose |
| --- | --- | --- |
| `artifact-name` | required | Usually `${{ needs.ci.outputs.artifact-name }}`. |
| `spa-fallback` | `false` | Serve `index.html` for unknown paths, for client-side routing. |

## Deploy: Firebase Hosting, `deploy-firebase.yml`

Setup: run `firebase init hosting:github` once in the project. It creates a service account and
stores its key as a `FIREBASE_SERVICE_ACCOUNT_<PROJECT>` repository secret. If you use it,
rename the secret in the template, or let `adopt.sh` find it. The caller grants `contents: read`,
`checks: write` and `pull-requests: write`.

`channel: live` publishes the site. An empty `channel` deploys a preview for the pull request
and comments its address there.

| Input | Default | Purpose |
| --- | --- | --- |
| `artifact-name` | required | Usually `${{ needs.ci.outputs.artifact-name }}`. |
| `working-directory` | `.` | Folder with `firebase.json`. |
| `public-dir` | `dist` | The folder `firebase.json` serves (`hosting.public`). |
| `project-id` | from `.firebaserc` | Firebase project. |
| `channel` | `live` | `live`, or empty for a preview channel. |
| `expires` | `7d` | Preview lifetime. |
| `target` | | Hosting target, for projects with several sites. |
| `environment` | `production` or `preview` | GitHub environment name. |

The secret `firebase-service-account` is required.

## Deploy: S3 and CloudFront, `deploy-s3.yml`

AWS access uses GitHub's OpenID Connect provider, so no AWS keys are stored in GitHub. Fingerprinted
files in `assets/` are cached for a year and kept after later deploys, so pages still open in
visitors' browsers keep working. Everything else is served with `no-cache`, and CloudFront is
refreshed after each upload.

Each setting can be an input or a GitHub variable. Put the variables on each GitHub environment
(**Settings > Environments > dev / uat / production > Variables**), and one workflow deploys
every stage:

| Input | Variable | Purpose |
| --- | --- | --- |
| `role-arn` | `AWS_DEPLOY_ROLE_ARN` | IAM role to assume (required). |
| `bucket` | `S3_BUCKET` | Bucket name (required). |
| `aws-region` | `AWS_REGION` | Bucket region; default `us-east-1`. |
| `cloudfront-distribution-id` | `CLOUDFRONT_DISTRIBUTION_ID` | Distribution to refresh; skipped when empty. |
| `site-url` | `SITE_URL` | Checked after the deploy; skipped when empty. |
| `environment` | | GitHub environment; default `production`. |
| `prefix` | | Key prefix, for sites that share a bucket. |
| `immutable-dir` | | Long-cached folder; default `assets`. |

AWS setup, once per account: add the identity provider `token.actions.githubusercontent.com`
with audience `sts.amazonaws.com`. Then create one role per stage. The deploy job runs in a
GitHub environment, so the role's trust policy must name that environment:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<owner>/<repo>:environment:production"
        }
      }
    }
  ]
}
```

Give the role only what the deploy uses:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::<bucket>" },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<bucket>/*"
    },
    {
      "Effect": "Allow",
      "Action": ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"],
      "Resource": "arn:aws:cloudfront::<account-id>:distribution/<distribution-id>"
    }
  ]
}
```

## Branch flows

The templates deploy `main`. For a feature branch → `dev` → `uat` → `main` flow:
- list the three branches under `on.push.branches`;
- map each branch to a GitHub environment, as [`aws-s3`](templates/aws-s3.yml) does;
- open pull requests against `dev`.

To make a stage wait for approval before it deploys, add required reviewers to its environment.

## Versions

Repositories call `@v1`. Publishing a release `v1.x.y` moves the `v1` tag to it
([`release.yml`](.github/workflows/release.yml)), so every caller picks up compatible changes. A
change that would break callers, such as a renamed input, goes out as `v2`. Callers then move
when they choose, and Dependabot proposes the update.

Every action used here is pinned to a full commit SHA. Dependabot keeps those up to date.

## Working on this repository

[`self-test.yml`](.github/workflows/self-test.yml) runs on every pull request. It:
- lints the workflows, templates and scripts with actionlint and shellcheck;
- runs `ci.yml` against the projects in [`tests/fixtures`](tests/fixtures), and checks the
  detected stacks and build artifacts;
- runs `security.yml` on this repository.

On `main` it also publishes the Node.js fixture to this repository's GitHub Pages site, and
checks the page and its script load.

#!/usr/bin/env bash
# Adds the shared pipeline to a GitHub repository and opens a pull request for it.
#
# Usage: scripts/adopt.sh <owner/repo> <template> [options]
#
#   template      ci-only, github-pages, firebase or aws-s3 (files in templates/)
#
# Options:
#   --dir <path>      Project folder inside the repository. Default: detected.
#   --base <branch>   Branch the pull request targets. Default: dev if it exists,
#                     otherwise the repository's default branch.
#   --replace <file>  Remove this existing workflow (by file name) because the pipeline
#                     takes over its job. Repeat for several.
#   --dry-run         Show the files that would be added; push nothing.
#   -h, --help        Show this help.
#
# Needs git, gh (signed in) and jq.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
branch=ci/shared-pipeline

usage() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}
die() {
  echo "error: $*" >&2
  exit 1
}

repo=
template=
dir=
base=
replace=()
dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir=${2:?--dir needs a path}; shift 2 ;;
    --base) base=${2:?--base needs a branch}; shift 2 ;;
    --replace) replace+=("$(basename "${2:?--replace needs a workflow file name}")"); shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage ;;
    -*) die "unknown option $1" ;;
    *)
      if [ -z "$repo" ]; then repo=$1
      elif [ -z "$template" ]; then template=$1
      else die "unexpected argument $1"
      fi
      shift
      ;;
  esac
done
if [ -z "$repo" ] || [ -z "$template" ]; then usage 1; fi
template_file="$root/templates/$template.yml"
if [ ! -f "$template_file" ]; then
  choices=()
  for file in "$root"/templates/*.yml; do choices+=("$(basename "$file" .yml)"); done
  die "no template '$template'; choose one of: ${choices[*]}"
fi
for tool in git gh jq; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "Cloning $repo..."
gh repo clone "$repo" "$work/repo" -- --quiet
cd "$work/repo"

if [ -z "$base" ]; then
  if git ls-remote --exit-code --heads origin dev >/dev/null; then
    base=dev
  else
    base=$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name)
  fi
fi
git checkout --quiet -B "$base" "origin/$base"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  die "$repo already has a $branch branch; merge or delete it first"
fi

# The shallowest file with this name, as a folder relative to the repository root.
shallowest() {
  local file
  file=$(find . \( -name .git -o -name node_modules \) -prune -o -type f -name "$1" -print |
    awk -F/ '{ print NF "\t" $0 }' | sort -n | head -1 | cut -f2-)
  if [ -n "$file" ]; then dirname "$file"; fi
}
if [ -z "$dir" ]; then
  # A package.json with a build script wins, since some repositories keep a stray one at the top.
  while IFS= read -r file; do
    if jq -e '.scripts.build' "$file" >/dev/null 2>&1; then
      dir=$(dirname "$file")
      break
    fi
  done < <(find . -name node_modules -prune -o -type f -name package.json -print | sort)
  for marker in package.json pom.xml pyproject.toml requirements.txt setup.py; do
    if [ -n "$dir" ]; then break; fi
    dir=$(shallowest "$marker")
  done
  if [ -z "$dir" ]; then
    if [ -n "$(find . -maxdepth 1 -name '*.py' -print -quit)" ]; then dir=.; else dir=$(shallowest index.html); fi
  fi
  dir=${dir:-.}
fi
dir=${dir#./}
dir=${dir%/}
[ -n "$dir" ] || dir=.
[ -d "$dir" ] || die "folder '$dir' does not exist in $repo"

ecosystem=
if [ -f "$dir/package.json" ]; then ecosystem=npm
elif [ -f "$dir/pom.xml" ]; then ecosystem=maven
elif [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ]; then ecosystem=pip
fi
echo "Project folder: $dir (${ecosystem:-no package manager})"

[ ! -e .github/workflows/pipeline.yml ] || die "$repo already has .github/workflows/pipeline.yml"
for file in ${replace[@]+"${replace[@]}"}; do
  [ -f ".github/workflows/$file" ] || die "$repo has no .github/workflows/$file to replace"
done

git checkout --quiet -b "$branch"
mkdir -p .github/workflows
sed "s|^      working-directory: \.$|      working-directory: $dir|" "$template_file" >.github/workflows/pipeline.yml

secret_note=
if [ "$template" = firebase ]; then
  # Reuse a service account secret that `firebase init hosting:github` created earlier: its
  # workflows name it, and listing secrets needs admin rights the token may lack.
  secret=$(grep -rhoE --exclude=pipeline.yml 'secrets\.FIREBASE_SERVICE_ACCOUNT[A-Za-z0-9_]*' .github/workflows 2>/dev/null |
    sed 's/^secrets\.//' | sort -u | head -1 || true)
  if [ -z "$secret" ]; then
    secret=$(gh secret list -R "$repo" --json name --jq '.[].name' 2>/dev/null | grep '^FIREBASE_SERVICE_ACCOUNT' | head -1 || true)
  fi
  if [ -n "$secret" ]; then
    sed -i.bak "s/secrets\.FIREBASE_SERVICE_ACCOUNT }}/secrets.$secret }}/" .github/workflows/pipeline.yml
    rm .github/workflows/pipeline.yml.bak
  else
    secret_note="- [ ] Add a \`FIREBASE_SERVICE_ACCOUNT\` repository secret before merging; previews fail without it."
  fi
fi

# Removed only now, since the Firebase secret lookup above reads the old workflows.
replaced=
for file in ${replace[@]+"${replace[@]}"}; do
  git rm --quiet ".github/workflows/$file"
  replaced+="${replaced:+, }\`$file\`"
done
existing=
for file in .github/workflows/*.yml .github/workflows/*.yaml; do
  if [ -f "$file" ] && [ "$file" != .github/workflows/pipeline.yml ]; then
    existing+="${existing:+, }\`$(basename "$file")\`"
  fi
done

added_dependabot=false
if [ ! -e .github/dependabot.yml ] && [ ! -e .github/dependabot.yaml ]; then
  added_dependabot=true
  {
    echo "# Weekly pull requests for minor and patch updates. Security fixes come separately"
    echo "# through Dependabot security updates (Settings > Code security)."
    echo "version: 2"
    echo "updates:"
    echo "  - package-ecosystem: github-actions"
    echo "    directory: /"
    echo "    schedule:"
    echo "      interval: weekly"
    echo "    groups:"
    echo "      actions:"
    echo "        patterns: ['*']"
    if [ -n "$ecosystem" ]; then
      echo "  - package-ecosystem: $ecosystem"
      echo "    directory: /${dir#.}"
      echo "    schedule:"
      echo "      interval: weekly"
      echo "    open-pull-requests-limit: 5"
      echo "    groups:"
      echo "      minor-and-patch:"
      echo "        update-types: [minor, patch]"
      echo "    ignore:"
      echo "      - dependency-name: '*'"
      echo "        update-types: [version-update:semver-major]"
    fi
  } >.github/dependabot.yml
fi

git add .github
echo
git --no-pager diff --cached --stat
if $dry_run; then
  echo
  git --no-pager diff --cached
  echo
  echo "Dry run: nothing was pushed."
  exit 0
fi

git commit --quiet -m "Add the shared CI/CD pipeline" -m "Builds and tests every change with the reusable workflows from Abbbtle/ci-pipelines, scans for secrets, vulnerable dependencies and code issues, and deploys with the $template template.${replaced:+ Removes ${replaced//\`/}, which the pipeline replaces.}"
git push --quiet -u origin "$branch"

# Dependency review needs the dependency graph; switching on Dependabot alerts switches it on.
if gh api -X PUT "repos/$repo/vulnerability-alerts" >/dev/null 2>&1; then
  echo "Dependabot alerts and the dependency graph are on."
else
  echo "warning: could not switch on Dependabot alerts; dependency review is skipped until the dependency graph is on (Settings > Code security)." >&2
fi

if [ "$template" = github-pages ]; then
  if gh api "repos/$repo/pages" >/dev/null 2>&1; then
    gh api -X PUT "repos/$repo/pages" -f build_type=workflow >/dev/null
  else
    gh api -X POST "repos/$repo/pages" -f build_type=workflow >/dev/null
  fi
  echo "GitHub Pages now publishes from GitHub Actions."
fi

body=$(
  cat <<EOF
Adds the shared pipeline from [Abbbtle/ci-pipelines](https://github.com/Abbbtle/ci-pipelines) using the \`$template\` template, for the project in \`$dir\`.

- **CI:** installs dependencies and runs the project's own format, lint, typecheck, test and build steps.
- **Security:** secret scan of new commits, dependency review on pull requests and CodeQL analysis.
$(case "$template" in
    github-pages) echo "- **Deploy:** publishes \`main\` to GitHub Pages." ;;
    firebase) echo "- **Deploy:** previews each pull request on a Firebase channel and publishes \`main\` to the live site." ;;
    aws-s3) echo "- **Deploy:** publishes \`dev\`, \`uat\` and \`main\` to their own S3 sites." ;;
  esac)
$($added_dependabot && echo "- **Dependabot:** weekly minor and patch updates for actions${ecosystem:+ and $ecosystem packages}.")
$([ -z "$replaced" ] || echo "- **Replaces:** $replaced, whose job the pipeline now does.")

The checks on this pull request are the pipeline's first run.
$(if [ -n "$existing" ] || [ -n "$secret_note" ]; then
    echo
    echo "### Before merging"
    [ -z "$secret_note" ] || echo "$secret_note"
    [ -z "$existing" ] || echo "- [ ] Remove any of these existing workflows that the pipeline replaces: $existing"
  fi)
EOF
)
gh pr create --repo "$repo" --base "$base" --head "$branch" --title "Add the shared CI/CD pipeline" --body "$body"

# Git & GitHub CLI Workflow Playbook

A chronological, practical guide to Git and GitHub CLI (`gh`) workflows, branching strategies, commit squashing, and remote management based on real-world development sessions.

---

## Table of Contents
1. [Local Inspection, Staging & Conventional Commits](#1-local-inspection-staging--conventional-commits)
2. [GitHub CLI (`gh`), Remotes & Fork Setup](#2-github-cli-gh-remotes--fork-setup)
3. [Modernizing the Default Branch (`master` → `main`)](#3-modernizing-the-default-branch-master--main)
4. [Feature Branching & Pull Requests via CLI](#4-feature-branching--pull-requests-via-cli)
5. [Inspecting Remote Branches & Cherry-Picking](#5-inspecting-remote-branches--cherry-picking)
6. [Feature Branch Lifecycle & Direct Merging](#6-feature-branch-lifecycle--direct-merging)
7. [History Cleanup, Safe Squashing & Rebase (Option A)](#7-history-cleanup-safe-squashing--rebase-option-a)
8. [Best Practices & Golden Rules](#8-best-practices--golden-rules)

---

## 1. Local Inspection, Staging & Conventional Commits

Always inspect working tree state and diffs before committing to avoid staging unintended files, temporary logs, or credentials.

```bash
# 1. Check working directory status and review the last 5 commits in compact form
git status && git log -n 5 --oneline

# 2. Inspect unstaged changes across all modified files before staging
git diff

# 3. Inspect changes for a specific file or directory
git diff ui/qml/widgets/SystemsWidget.qml

# 4. Stage specific files (never use a blind `git add .` to avoid committing junk/secrets)
git add ui/qml/widgets/SystemsWidget.qml tests/ui/tst_systems_net.qml

# 5. Commit using the Conventional Commits specification (feat, fix, docs, chore, etc.)
git commit -m "fix(systems): correct PillButton properties, URL normalization, and scope bindings"
```

> **Why Conventional Commits?**  
> Formatting commits as `type(scope): message` makes automated changelog generation, semantic versioning, and log filtering (`git log --grep="^feat"`) effortless.

---

## 2. GitHub CLI (`gh`), Remotes & Fork Setup

Managing GitHub remotes and repositories directly from the terminal without context-switching to a web browser.

```bash
# 1. Verify GitHub CLI authentication, active account, and token permissions
gh auth status

# 2. Inspect currently configured remote repository URLs
git remote -v

# 3. Check all local and remote tracking branches
git branch -a

# 4. List repositories under your account
gh repo list aacero --limit 10

# 5. Create a new public GitHub repository directly from the command line
gh repo create aacero/skyphoenix-edgehub-linux --public \
  --description "Xeneon Edge Linux Hub - Dashboard, metrics, and widgets for secondary displays"

# 6. Repoint your local 'origin' remote from the old upstream to your new GitHub fork using SSH
git remote set-url origin git@github.com:aacero/skyphoenix-edgehub-linux.git
```

---

## 3. Modernizing the Default Branch (`master` → `main`)

Renaming the default branch locally and synchronizing GitHub default branch settings.

```bash
# 1. Rename the local 'master' branch to 'main'
git branch -m master main

# 2. Push 'main' to GitHub and set it as the upstream tracking branch (-u)
git push -u origin main

# 3. Update the default branch setting on GitHub so PRs and clones target 'main'
gh repo edit aacero/skyphoenix-edgehub-linux --default-branch main

# 4. Delete the deprecated 'master' branch from the GitHub remote
git push origin --delete master
```

---

## 4. Feature Branching & Pull Requests via CLI

Complete GitHub Pull Request lifecycle (create, review, merge, sync) from the command line.

```bash
# 1. Create and switch to a feature branch
git checkout -b feat/systems-widget main

# 2. Push the feature branch to GitHub and set up remote tracking
git push -u origin feat/systems-widget

# 3. Open a Pull Request from the CLI with a formatted markdown title and body
gh pr create --repo aacero/skyphoenix-edgehub-linux \
  --base main \
  --head feat/systems-widget \
  --title "feat: add Systems monitoring widget for Prometheus node_exporter" \
  --body "## Overview
Adds a native first-party Systems widget (SystemsWidget.qml)..."

# 4. Merge the Pull Request on GitHub using standard merge commit
gh pr merge 1 --merge --repo aacero/skyphoenix-edgehub-linux

# 5. Switch back to main and pull the merged changes locally
git checkout main && git pull origin main
```

---

## 5. Inspecting Remote Branches & Cherry-Picking

Investigating upstream changes, isolating individual commits, and cherry-picking specific patches.

```bash
# 1. View commits on a remote branch that are NOT yet on your current main branch
git log main..origin/feat/auto-cycle-screens --oneline

# 2. Inspect commit metadata and changed file statistics for a specific hash
git show 5b8c8c2 --stat

# 3. Compare changes between two specific commit hashes
git diff 5b8c8c2 74d4786 -- ui/ tests/ manager/

# 4. Create and switch to a new branch from main
git checkout -b feat/auto-cycle-screens main

# 5. Apply a specific historical commit onto the current branch
git cherry-pick 5b8c8c2

# 6. Abort an in-progress cherry-pick if merge conflicts occur and clean slate is desired
git cherry-pick --abort
```

---

## 6. Feature Branch Lifecycle & Direct Merging

For fast-moving features or solo-maintained repositories where code review is self-contained.

```bash
# 1. Create a feature branch for Grafana from main
git checkout -b feat/grafana-integration main

# 2. Stage new files, tests, assets, and documentation together
git add assets/icons/grafana.svg assets/icons.qrc manager/manager.qrc \
        ui/qml.qrc ui/qml/WidgetCatalog.qml ui/qml/WidgetConfigSchema.qml \
        ui/qml/widgets/GrafanaWidget.qml tests/ui/tst_grafana.qml docs/widgets/grafana.md README.md

# 3. Commit with a clear summary
git commit -m "feat: add native Grafana / Prometheus time-series vector chart widget"

# 4. Push the feature branch to GitHub
git push -u origin feat/grafana-integration

# 5. Fast-forward merge the feature branch into main and push
git checkout main && git merge feat/grafana-integration && git push origin main
```

---

## 7. History Cleanup, Safe Squashing & Rebase (Option A)

How to turn messy iterative "WIP", "fix typo", "tweak layout" commits into clean, semantic milestone commits without risking code loss.

```bash
# 1. Create a safety backup branch before doing any history rewriting
git branch main-backup main

# 2. Create a clean branch starting at the upstream fork point (e.g. 94e4668)
git checkout -b main-clean 94e4668

# 3. Squash an entire feature branch (e.g. 8 iterative commits) into ONE clean milestone commit
git merge --squash 4c13e0b && \
git commit -m "feat(systems): add multi-node Prometheus node_exporter fleet monitor widget"

# 4. Cherry-pick each subsequent milestone feature in chronological order
git cherry-pick 405b741 # Screen cycling
git cherry-pick 4a5b9c8 # Double-tap / double-click expand
git cherry-pick a186393 # Grafana / Prometheus widget
git cherry-pick e38ccbc # Branding removal & fork attribution

# 5. SAFETY CHECK: Verify that the squashed branch has ZERO file differences against the original main
git diff main main-clean
# (Returns empty output — proving 100% byte-for-byte code identity!)

# 6. Point local 'main' to the cleaned branch
git checkout main && git reset --hard main-clean && git branch -D main-clean

# 7. Safely push rewritten history to GitHub using --force-with-lease
git push --force-with-lease origin main

# 8. Clean up temporary and merged feature branches (locally and on remote)
git branch -D main-backup feat/systems-widget feat/grafana-integration
git push origin --delete feat/systems-widget feat/grafana-integration
```

---

## 8. Best Practices & Golden Rules

1. **`git merge --squash <branch/commit>`**:
   Collapses all commits from a branch or range into your working directory as a single staged changeset. This lets you craft one crisp, high-quality commit message instead of cluttering history with minor fixes.

2. **`git diff branchA branchB` Verification**:
   Always run `git diff main main-clean` before finalizing a rebase/squash. If the output is empty, you have mathematical proof that not a single byte of code was lost or altered during history rewriting.

3. **`--force-with-lease` vs `--force`**:
   Never use raw `-f` / `--force`. `--force-with-lease` checks if anyone else has pushed commits to the remote branch first; if so, it refuses the push, preventing accidental overwrites.

4. **Specific Staging (`git add <files>`)**:
   Avoid `git add .` or `git add -A` when creating feature commits. Explicitly named files prevent secrets, build artifacts, or unrelated scratch files from entering git history.

# Rewrite atomi/workspace template — composable additive folders with resolver-based merging
- **ID**: 86exbkmub
- **Status**: in progress
- **Priority**: none
- **URL**: https://app.clickup.com/t/86exbkmub

## Description

Spec: Rewrite atomi/workspace template — composable additive folders with resolver-based merging

Summary

Rewrite the atomi/workspace CyanPrint template from a monolithic conditional generator to a composable additive architecture. Instead of one giant template with if/else branches, the template produces output by combining independent folders (base/, docker/, helm/, secret/) that each contribute files. Resolvers merge overlapping files (CLAUDE.md, .gitignore, ci.yaml, nix files) from multiple folders into a single output. This spec covers: fixing a nix resolver conflict in base shells.nix, implementing the remaining secret folder, adding test coverage for all feature combinations, and committing a documentation fix for Infisical CLI syntax.

Verification Evidence

VE1: preCommitPackages in base shells.nix is redundant

What was checked: templates/base/nix/shells.nix, templates/base/nix/env.nix, templates/base/nix/packages.nix
CONFIRMED: env.nix groups all pre-commit hook packages (treefmt, gitlint, shellcheck, sg, actionlint, go-task, pre-commit) into the lint array. shells.nix uses with env; and references lint in all three shells (default, ci, releaser). The separate preCommitPackages parameter adds those same packages a second time.
Why it matters: The atomi/nix resolver's mergeShells function throws on mismatched function argument lists. Base had 5 args (pkgs, packages, env, shellHook, preCommitPackages), but helm's shells.nix has 4 args. When both folders are selected, the resolver crashes.

VE2: Helm's shells.nix has the correct 4-arg signature

What was checked: templates/helm/nix/shells.nix
CONFIRMED: Uses { pkgs, packages, env, shellHook }: (4 args, no preCommitPackages). This is the correct target signature.

VE3: Base shells.nix fix affects all existing snapshot fixtures

What was checked: cyan.yaml resolver config — nix/shells.nix is in the atomi/nix resolver's file list. All 4 existing test cases enable cyan/nix/basic: yes, so all generate nix output including shells.nix.
CONFIRMED: Removing preCommitPackages changes the generated shells.nix for every test case. All 4 existing snapshot directories must be regenerated.

VE4: Secret folder files did not exist before this work

What was checked: templates/secret/ was empty before implementation
CONFIRMED: cyan/index.ts already had the if (secret) branch — only the template files were missing.

VE5: Infisical CLI run command does not propagate secrets to parent shell

What was checked: Infisical CLI documentation. infisical run [options] -- [command] runs a subprocess with injected secrets. Running infisical run --env=dev without a trailing command exits immediately — secrets are not exported to the calling shell.
CONFIRMED: The original infisical.md documentation showed bare infisical run --env=dev which is misleading. Correct usage is infisical run --env=dev -- <command>. The secrets.sh script's bare infisical run --env=dev line is acceptable as a one-shot fetch (login happens on the line above), but the documentation must show the subprocess syntax for actual usage.

VE6: Resolver wiring works correctly

What was checked: atomi/json-yaml with arrayStrategy: concat merges CI/CD jobs from multiple folders. atomi/md merges CLAUDE.md H1 sections. atomi/ignore merges .gitignore ###  sections with deduplication. atomi/nix merges nix files.
CONFIRMED: All resolvers are configured in cyan.yaml and produce correct output for base+docker and base+docker+helm combinations.

VE7: Existing tests pass before any new work

What was checked: cyanprint test template . — 4/4 tests pass (base_only, base_llm, no_llm_docker, docker_only)
CONFIRMED: Baseline is clean.

Requirements

Functional Requirements

FR1: Fix base shells.nix parameter count (nix resolver compatibility)

Problem: templates/base/nix/shells.nix has a 5-arg function signature (pkgs, packages, env, shellHook, preCommitPackages) but templates/helm/nix/shells.nix has 4 args. The atomi/nix resolver's mergeShells requires all shells.nix files to have matching argument lists. When both base and helm are selected, the resolver throws.

Fix: Remove the redundant preCommitPackages parameter from templates/base/nix/shells.nix. The packages it provided are already included via env.lint (which is imported with with env;).

Change parameter list from { pkgs, packages, env, shellHook, preCommitPackages }: to { pkgs, packages, env, shellHook }:
Remove preCommitPackages from all three buildInputs lists:
default: system ++ main ++ lint ++ dev ++ preCommitPackages → system ++ main ++ lint ++ dev
ci: system ++ main ++ lint ++ preCommitPackages → system ++ main ++ lint
releaser: system ++ main ++ lint ++ releaser ++ preCommitPackages → system ++ main ++ lint ++ releaser

This is the ONLY file modified under templates/base/.

FR2: Implement Secret Folder (templates/secret/)

Create the templates/secret/ folder with these files:

scripts/local/secrets.sh:

#!/usr/bin/env bash
set -euo pipefail

INFISICAL_API_URL="https://secrets.atomi.cloud" infisical login
infisical run --env=dev

The bare infisical run --env=dev (no trailing command) is intentional here — it authenticates and exits. Users run commands with secrets via infisical run --env=dev -- <command> in their own shells.

Taskfile.yaml (partial — merged by atomi/json-yaml with arrayStrategy: concat):

version: '3'
includes:
  secret: tasks/Taskfile.secret.yaml
tasks:
  setup:
    cmds:
      - ./scripts/local/secrets.sh

This adds ./scripts/local/secrets.sh to the setup task's cmds array. The arrayStrategy: concat ensures it appends to base's existing setup commands rather than replacing them.

.gitignore:

### Secrets
.env
.env.*
*.tfvars
.infisical.json

Uses ###  section headers for atomi/ignore resolver compatibility. The resolver parses ###  headers as section boundaries and deduplicates patterns across all contributing folders.

docs/developer/standard/infisical.md:
Documents Infisical usage at https://secrets.atomi.cloud. Must show the correct subprocess invocation syntax:

infisical run --env=dev -- <command>

With examples like infisical run --env=dev -- env | grep MY_SECRET and infisical run --env=dev -- pls test. The bare infisical run --env=dev (without -- <command>) does NOT propagate secrets to the parent shell — it only works as a one-shot subprocess wrapper.

CLAUDE.md (only generated when LLM is enabled):

# Secret Management

This project uses Infisical for secret management. Use `pls setup` to authenticate and fetch secrets. See [docs/developer/standard/infisical.md](docs/developer/standard/infisical.md) for details.

Uses #  (H1) section header for atomi/md resolver compatibility. The resolver merges H1 sections from all contributing folders.

.claude/skills/infisical/SKILL.md (only generated when LLM is enabled):
Standard skill format with frontmatter referencing docs/developer/standard/infisical.md.

tasks/Taskfile.secret.yaml: Taskfile partial for secret-related tasks.

No nix files: The secret folder has no nix additions. It does not contribute to packages.nix, env.nix, pre-commit.nix, or shells.nix.

FR3: Regenerate all existing snapshot fixtures

After the shells.nix fix (FR1), every existing snapshot must be regenerated because all test cases enable cyan/nix/basic: yes and therefore generate nix/shells.nix.

Regenerate these 4 snapshot directories:

cyan/fixtures/expected/base_only/
cyan/fixtures/expected/base_llm/
cyan/fixtures/expected/no_llm_docker/
cyan/fixtures/expected/docker_only/

Method: cyanprint test template . --update-snapshots (regenerates all at once).

FR4: Add test cases for remaining feature combinations

Add 5 new test cases to test.cyan.yaml to cover the currently-untested combinations:

[table-embed:1:1 Test Case| 1:2 llm| 1:3 docker| 1:4 helm| 1:5 secret| 1:6 Key verification| 2:1 helm_only | 2:2 yes| 2:3 no| 2:4 yes| 2:5 no| 2:6 Helm chart scaffold, helm CI/CD jobs in ci.yaml/cd.yaml, infra env group, helm hooks (a-helm-lint, a-helm-docs), 9 skills total| 3:1 secret_only | 3:2 yes| 3:3 no| 3:4 no| 3:5 yes| 3:6 secrets.sh script present, gitignore  ### Secrets  section, setup task has secrets.sh via array concat, 8 skills total| 4:1 docker_helm | 4:2 yes| 4:3 yes| 4:4 yes| 4:5 no| 4:6 Merged CI/CD (precommit + docker + helm jobs), both Taskfile includes (docker + helm), both hook sets, 9 skills total| 5:1 all_features | 5:2 yes| 5:3 yes| 5:4 yes| 5:5 yes| 5:6 Everything merged — all CI/CD jobs, all Taskfile includes, all nix hooks, all skills, 10 skills total| 6:1 no_llm_all | 6:2 no| 6:3 yes| 6:4 yes| 6:5 yes| 6:6 All feature CI/CD/scripts/nix present but NO CLAUDE.md and NO  .claude/skills/  from any folder|]
Each test case must include ALL existing validate commands (shell syntax via bash -n, YAML parse via ruby -ryaml -e 'YAML.safe_load(STDIN)', Taskfile structure) PLUS feature-specific assertions.

Skill counts by feature combination (cumulative from base):

Base only (llm=yes): 7 skills (ci-cd-workflows, conventional-commits, linting, semantic-release, service-tree, shell-conventions, taskfile-conventions)
docker: 8 skills (adds docker-push)
secret: 8 skills (adds infisical)
helm: 9 skills (adds helm-push)
all three (docker + helm + secret): 10 skills

Note: docker-push and infisical both add 1 skill each, so docker-only and secret-only both total 8.

FR5: Variable syntax

All CyanPrint template variables use let__x__ syntax, not {{ }} or <%= %>. The varSyntax configuration in cyan/index.ts:

const varSyntax: [string, string][] = [
  ['let__', '__'],       // bare (markdown, yaml)
  ['// let__', '__'],    // TypeScript/JavaScript/C# line comments
  ['# let__', '__'],     // Python/Shell/Nix line comments
];

Variables used by this template: let__platform__, let__service__. Generated output must contain zero unsubstituted let__ markers — validate this in every test case.

FR6: Scope constraint

This requirement defines exactly which files this spec modifies. No ambiguity.

Files this spec MODIFIES or CREATES:

[table-embed:1:1 File(s)| 1:2 Requirement| 1:3 Nature of change| 2:1 templates/base/nix/shells.nix | 2:2 FR1| 2:3 Remove  preCommitPackages  parameter (the only change under  templates/base/ )| 3:1 templates/secret/**  (7 files)| 3:2 FR2| 3:3 New folder created from scratch| 4:1 cyan/fixtures/expected/base_only/** | 4:2 FR3| 4:3 Snapshot regeneration| 5:1 cyan/fixtures/expected/base_llm/** | 5:2 FR3| 5:3 Snapshot regeneration| 6:1 cyan/fixtures/expected/no_llm_docker/** | 6:2 FR3| 6:3 Snapshot regeneration| 7:1 cyan/fixtures/expected/docker_only/** | 7:2 FR3| 7:3 Snapshot regeneration| 8:1 cyan/fixtures/expected/helm_only/** | 8:2 FR4| 8:3 New snapshot directory| 9:1 cyan/fixtures/expected/secret_only/** | 9:2 FR4| 9:3 New snapshot directory| 10:1 cyan/fixtures/expected/docker_helm/** | 10:2 FR4| 10:3 New snapshot directory| 11:1 cyan/fixtures/expected/all_features/** | 11:2 FR4| 11:3 New snapshot directory| 12:1 cyan/fixtures/expected/no_llm_all/** | 12:2 FR4| 12:3 New snapshot directory| 13:1 test.cyan.yaml | 13:2 FR4| 13:3 Add 5 new test case definitions|]
Files this spec does NOT touch (existing files remain read-only):

[table-embed:1:1 File(s)| 1:2 Reason| 2:1 templates/base/**  (all files except  nix/shells.nix )| 2:2 No base changes beyond FR1| 3:1 templates/docker/**  (all files)| 3:2 Docker folder is complete and out-of-scope| 4:1 templates/helm/**  (all files)| 4:2 Helm folder is complete and out-of-scope| 5:1 cyan/index.ts | 5:2 Entry point already handles secret conditional| 6:1 cyan/src/standard.ts | 6:2 Prompts already include secret| 7:1 cyan.yaml | 7:2 Resolver configuration already covers all files| 8:1 cyan/package.json ,  cyan/tsconfig.json | 8:2 No dependency or config changes|]
FR7: CI Runner Standardization

All reusable GitHub Actions workflows in the template must use the nscloud runner:

Runner: nscloud-ubuntu-22.04-amd64-32x64-with-cache (288GB disk)
Cache size: 50gb
Cache tag: nscloud-cache-tag-atomi-nix-store-cache

Non-Functional Requirements

Linting — Applies. All generated YAML must be syntactically valid (verified by ruby -ryaml -e 'YAML.safe_load(STDIN)' in test validate commands). All generated nix files must pass nix-instantiate --parse.
Building — Applies. cyanprint test template . must pass all 9 test cases (4 existing + 5 new). The template itself must compile TypeScript: cd cyan && npx tsc --noEmit.
Unit Testing — Does not apply. CyanPrint templates use snapshot testing as their primary verification mechanism, not traditional unit tests.
Integration Testing — Applies — this IS the primary testing mechanism. The 9 test cases in test.cyan.yaml exercise the full feature combination matrix. Each test runs validate commands against generated output. All must pass.
End-to-End Testing — Does not apply at template-build time. Post-release: verify by running cyan run against a real generated template.
Documentation — Applies. Each template folder contributes documentation: CLAUDE.md sections (H1 headers, merged by atomi/md), docs/developer/standard/*.md files, and skill SKILL.md files. infisical.md must use correct infisical run --env=dev -- <command> subprocess syntax.
Observability — Does not apply. This is a template generator, not a running service.
Invariant Checking — Applies. The following invariants are verified by test validate commands:
All generated YAML is parseable by ruby -ryaml
All shell scripts have #!/usr/bin/env bash shebang and set -euo pipefail
All nix files parse correctly (nix-instantiate --parse)
.gitignore files use ###  section headers (required by atomi/ignore resolver)
CLAUDE.md uses #  (H1) section headers (required by atomi/md resolver)
CI/CD partial YAML files have matching name: and on: structure for the json-yaml resolver
Zero unsubstituted let__ markers in generated output
No flake.nix in generated output (provided by atomi/nix dependency, not this template)
Security — Does not apply. Template generates scaffolding files. No runtime user input handling, authentication, or data processing. The secret folder references Infisical (an external tool) but does not implement authentication itself.
Performance — Does not apply. Template generation is a one-time operation per project creation.
Backwards Compatibility — Applies (breaking change accepted). This is a full rewrite of atomi/workspace. No backwards compatibility with the old template is maintained. Question IDs in prompts will differ, which is acceptable.
Accessibility — Does not apply. No user interface.
Nix Resolver Compatibility — Applies. All nix files in the template must match the format expected by the atomi/nix resolver. Specifically: all shells.nix files across all folders MUST have identical function parameter lists (currently 4 args: pkgs, packages, env, shellHook). The resolver performs argument list matching during shell merging — mismatched lists cause a runtime throw. This is why FR1 exists.
Resolver Merge Order — Applies. The atomi/json-yaml resolver sorts inputs by (layer ASC, template ASC). This means the order of CI/CD jobs in merged files is deterministic. Test snapshots must reflect this order, and the order must be consistent across runs.

Acceptance Criteria

AC1: All 9 test cases pass

cyanprint test template . exits 0 with all 9 test cases passing (4 existing + 5 new)
Each snapshot directory contains exactly the expected files for its feature combination
All validate commands (shell syntax, YAML parse, Taskfile structure, feature assertions) pass

AC2: Base shells.nix has correct 4-arg signature

templates/base/nix/shells.nix parameter list is { pkgs, packages, env, shellHook }:
String preCommitPackages does not appear anywhere in the file
All 4 regenerated existing snapshots (base_only, base_llm, no_llm_docker, docker_only) contain the 4-arg shells.nix

AC3: Secret folder is complete and correct

templates/secret/ contains exactly 7 files: scripts/local/secrets.sh, Taskfile.yaml, .gitignore, docs/developer/standard/infisical.md, CLAUDE.md, .claude/skills/infisical/SKILL.md, tasks/Taskfile.secret.yaml
scripts/local/secrets.sh starts with #!/usr/bin/env bash and has set -euo pipefail
.gitignore contains ### Secrets header section with .env, .env.*, *.tfvars, .infisical.json
docs/developer/standard/infisical.md documents infisical run --env=dev -- <command> subprocess syntax
CLAUDE.md and .claude/skills/ are only present in generated output when llm=yes

AC4: CI/CD job composition is correct per feature combination

helm_only: ci.yaml contains precommit + helm jobs; cd.yaml contains placeholder + helm jobs
docker_helm: ci.yaml contains precommit + docker + helm jobs; cd.yaml contains all three
all_features: ci.yaml contains precommit + docker + helm jobs; cd.yaml contains all three
All generated ci.yaml and cd.yaml are parseable by ruby -ryaml

AC5: Nix composition is correct

helm_only snapshot: nix files include infrautils, infralint, yq packages; infra env group; a-helm-lint and a-helm-docs pre-commit hooks; infra in shell buildInputs
all_features snapshot: all nix packages, hooks, and shells from base + docker + helm merged without conflicts
Every test case that generates nix files passes find . -name '*.nix' -exec nix-instantiate --parse {} >/dev/null +

AC6: Taskfile composition is correct

secret_only: setup task cmds array contains ./scripts/local/secrets.sh (appended via array concat)
helm_only: Taskfile.yaml has helm include entry plus tasks/Taskfile.helm.yaml exists
docker_helm: both docker and helm include entries present in Taskfile.yaml
all_features: all includes (secret, helm, docker) and all task files composed

AC7: Resolver-merged files are correct

CLAUDE.md has H1 sections matching enabled features, and is absent when llm=no
.gitignore has ###  sections from all enabled folders, patterns deduplicated
dependabot.yml has ecosystems matching enabled features (docker adds docker, etc.)

AC8: LLM flag consistently controls skills and CLAUDE.md across ALL folders

When llm=no: no CLAUDE.md and no .claude/skills/ from ANY folder (base, docker, helm, secret)
When llm=yes + all features: exactly 10 skills total (7 base + docker-push + helm-push + infisical)
no_llm_all test case: all feature CI/CD/scripts/nix present, but zero CLAUDE.md files and zero skill directories

AC9: No residual template markers

Every test case's generated output contains zero unsubstituted let__ markers
Every test case's generated output contains zero flake.nix files

Out of Scope

Runtime-specific folders (go/, dotnet/, bun/) — deferred to a future runtime template (TODO 8)
Runtime prompt (select: None/Go/.NET/Bun) — removed from this spec's scope; workspace template currently has no runtime selection
⚡reusable-cyanprint.yaml — may move to atomi/cyan template (TODO 7)
flake.nix scaffold — provided exclusively by the atomi/nix template dependency, not this template
Publishing the template — this spec covers implementation and testing only
Post-release validation — verifying generated templates in real GitHub Actions runs
Exact prose wording in CLAUDE.md or docs — content must be accurate but specific wording is implementation detail
Modifications to docker/ or helm/ template files — those folders are complete and not modified by this spec
Modifications to cyan/index.ts, cyan/src/standard.ts, or cyan.yaml — those are complete and not modified by this spec

Known Tech Debt

These issues exist in the docker and helm template folders. They are known, documented, and assigned severity. They are NOT blocking this spec and MUST NOT be raised as review findings against this spec. They will be addressed in follow-up work.

[table-embed:1:1 ID| 1:2 Severity| 1:3 Folder| 1:4 Issue| 1:5 Impact| 1:6 Resolution Plan| 2:1 TD1| 2:2 HIGH| 2:3 docker| 2:4 templates/docker/infra/Dockerfile  is 0 bytes (empty file)| 2:5 When docker feature is selected, the generated project has an empty Dockerfile —  docker build  will fail at runtime| 2:6 Add a minimal multi-stage Dockerfile scaffold in a follow-up| 3:1 TD2| 3:2 MEDIUM| 3:3 helm| 3:4 Missing per-landscape values files in  templates/helm/infra/root_chart/ | 3:5 pls helm:*  commands that expect per-landscape values files (e.g.  values-dev.yaml ,  values-staging.yaml ) will fail| 3:6 Add per-landscape values scaffolding in a follow-up| 4:1 TD3| 4:2 LOW| 4:3 helm| 4:4 Helm CD script uses  yq  which is not guaranteed on PATH outside the nix shell| 4:5 Running helm CD commands without  direnv allow  first will fail with  command not found: yq | 4:6 Document nix shell requirement or wrap commands in a nix-shell invocation|]
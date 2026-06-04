# Resolution: kloop qng8c4h6 — 3 loops, CONFLICT → patch_downstream

## What Went Wrong

Two issues blocked convergence across 3 iterations. Both relate to the `atomi/nix` resolver's behavior, not template logic errors.

### C1 (CRITICAL): Invalid Nix in fixture `pre-commit.nix`

The `atomi/nix` resolver parses function arguments only from `lines[0]` (single-line balanced-brace matching). The Plan 2 implementation authored `templates/docker/nix/pre-commit.nix` with multi-line function args. The resolver never found the closing `}` on line 0, so `functionArgs` stayed empty. Pretty-print emitted a lone `:` on line 1, producing syntactically invalid Nix in every docker fixture.

**Already fixed in template source**: `templates/docker/nix/pre-commit.nix` now uses single-line args.

### H1 (HIGH): Fixture `shells.nix` first-line alphabetization

The resolver's pretty-printer sorts named function arguments alphabetically (by design). Template source `{ pkgs, packages, env, shellHook }:` becomes fixture output `{ env, packages, pkgs, shellHook }:`. In Nix, named argument order is semantically irrelevant. The spec's AC5 required literal first-line equality between template sources and fixture output — wrong constraint for fixtures.

## What Needs to Change in Plans

### Plan 2 (completed) — no changes needed

Template source fix is applied. No code changes remain.

### Plan 3 (not yet implemented) — ALREADY CONTAINS BOTH CONSTRAINTS

Plan 3 already documents:
1. Single-line nix arg constraint (lines 93–116: "Critical resolver constraint: single-line nix function arg declarations")
2. Order-independent fixture-level AC5 check (lines 221–230: extract arg set and sort before comparing)
3. Source-level AC5 literal match preserved (lines 194–199: `diff` on `head -n1` across all three template sources)

**No amendments needed.** Plan 3 is ready to implement as-is.

### Plan 4 (not yet implemented) — ALREADY CONTAINS BOTH CONSTRAINTS

Plan 4 already documents:
1. Order-independent fixture-level shells.nix check (lines 136–139, 230–235: "order-independent")
2. Forward-compatibility note for single-line nix arg constraint (lines 102–109)
3. Source-level AC5 preserved for prior plans' sources (line 182: "source-level shells.nix literal first-line equality remains enforced")

**No amendments needed.** Plan 4 is ready to implement as-is.

## Affected Spec Sections

- **AC5**: Effectively split into two tiers by Plans 3–4:
  - Source-level: exact literal first-line match across all `nix/shells.nix` template source files (already enforced)
  - Fixture-level: semantic match — same 4 args (`pkgs`, `packages`, `env`, `shellHook`), order-independent (already implemented in plan validators)
- **NFR8 / Domain-specific NFR**: Single-line function arg constraint already documented in Plans 3–4.

## Constraints the Next TTY Must Respect

1. Do NOT change the `atomi/nix` resolver. It is external infrastructure. The template must conform to its constraints.
2. Do NOT modify any template source files from Plan 1 or Plan 2.
3. Implement Plan 3 as-is — no amendments required.
4. Implement Plan 4 as-is after Plan 3 — no amendments required.
5. The ClickUp task for resolver improvements (86exfg8qt) tracks upstream fixes separately — do not reference it in plans.

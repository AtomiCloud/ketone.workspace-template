---
name: documenting-template
description: Document this CyanPrint template into README.MD. Use when the user asks to document the template, write a README, explain how to use the template, or add usage documentation. Reads cyan.yaml and entry point code to generate accurate, artifact-specific docs.
---

# Documenting this Template

## Step 1: Understand the artifact

Read `cyan.yaml` to extract:

- **name**: The template's full identifier (e.g., `username/template-name`)
- **description**: What the template generates
- **tags**: Categories for discoverability
- **build**: Image registry information

### cyan.yaml Dependency Format with Version Pinning

When referencing processors, plugins, resolvers, or templates in `cyan.yaml`, use version pinning for reproducibility:

```yaml
processors:
  - name: cyan/default:1.0.0 # pinned version
  - name: myorg/my-processor:1.2.3

plugins:
  - name: myorg/my-plugin:2.0.0

resolvers:
  - resolver: myorg/my-resolver:1.0.0
    config: {}
    files: ['**/*.json']
```

Omit the version (`:version`) to use the latest version, but advise users that pinning versions ensures reproducible builds.

Read the entry point code (`cyan/index.ts` or equivalent for other languages) to extract:

- All prompt IDs — the `id` parameter in every `i.text(...)`, `i.select(...)`, `i.checkbox(...)`, `i.confirm(...)`, `i.password(...)`, `i.dateSelect(...)` call
- The description/message text for each prompt
- What processors, plugins, and resolvers are declared in the return value — include their names and configs

## Step 2: Generate README.MD

Follow the section template in [reference.md](./reference.md).

The README must include:

1. **Title** — the template name from `cyan.yaml`
2. **Description** — from `cyan.yaml`
3. **Usage** — `cyanprint create {username}/{name}` with a `cyan.yaml` snippet
4. **Prompts** — a table of every prompt ID, its description, and its type. Additionally, generate a Mermaid flowchart showing the deterministic question flow tree based on control flow analysis of the script (if/else branches from i.confirm, i.select, etc.)
5. **Dependencies** — a table with: name, version (from cyan.yaml, package.json, or similar), purpose (what it does), and usage (how the template uses it). Include: language runtime, SDK packages, and all referenced processors/plugins/resolvers
6. **Build and Publish** — build section from cyan.yaml, push command

## Step 3: Write README.MD

Write the generated README.MD to the project root.

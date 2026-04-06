# README.MD Template for CyanPrint Templates

Use this template when generating README.MD files. Replace all `{placeholders}` with actual values extracted from `cyan.yaml` and the entry point code.

---

````markdown
# {artifact-name}

{description}

## Usage

### Run directly

To create a new project from this template:

```bash
cyanprint create {artifact-name}
```
````

### Reference in a parent template

To use this template as a dependency in another CyanPrint template's `cyan.yaml`:

```yaml
templates: [username/template-name]
processors: [cyan/default]
resolvers:
  - resolver: username/resolver-name:1
    config: {}
    files: ['**/*.json']
```

## Prompts

When you run `cyanprint create`, the template will ask the following questions:

{prompts-table}

<!-- Example prompts table format:
| Prompt ID     | Description                        | Type     |
| ------------- | ---------------------------------- | -------- |
| name          | Name of the project                | text     |
| language      | Programming language to use        | select   |
| features      | Features to include                | checkbox |
| use_docker    | Include Docker configuration?      | confirm  |
-->

## Dependencies

| Name   | Version   | Purpose   | Usage                  |
| ------ | --------- | --------- | ---------------------- |
| {name} | {version} | {purpose} | {how-used-in-template} |

<!-- Example:
| Name | Version | Purpose | Usage |
| ---- | ------- | ------- | ----- |
| cyan/default | 1.0.0 | Variable substitution | Processes `{{var}}` in template files |
-->

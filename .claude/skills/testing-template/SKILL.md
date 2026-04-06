---
name: testing-template
description: Test this CyanPrint template. Use when the user asks to write tests, add test cases, update snapshots, or debug template test failures. Covers test.cyan.yaml format with answer_state, deterministic_state, validate commands, and expected output.
---

# Testing this Template

## Step 1: Understand what to test

Read the entry point code (`cyan/index.ts` or equivalent) to find YOUR prompt IDs — the `id` parameter in every `i.text(msg, id)`, `i.select(msg, id, opts)`, `i.checkbox(msg, id, opts)`, `i.confirm(msg, id)`, `i.password(msg, id)`, `i.dateSelect(msg, id)` call.

Also note any `d.get(key, ...)` calls — these keys go in `deterministic_state`.

Determine the template's full registry path (e.g., `myorg/my-template`) — this prefix is used in `answer_state` keys.

## Step 2: Write test.cyan.yaml

Create a `test.cyan.yaml` file in the template root:

```yaml
tests:
  - name: 'basic-test'
    expected:
      type: snapshot
      value:
        path: ./snapshots/basic-test
    answer_state:
      myorg/my-template/project-name:
        type: String
        value: my-project
      myorg/my-template/project-language:
        type: String
        value: TypeScript
      myorg/my-template/include-tests:
        type: Bool
        value: true
    deterministic_state:
      timestamp: '1700000000'
    validate:
      - test -f cyan/index.ts
      - test -f cyan.yaml
```

### answer_state

Keys are `{registry-path}/{prompt-id}`. The value is an object with `type` and `value`:

| IInquirer Call                      | type          | value example      |
| ----------------------------------- | ------------- | ------------------ |
| `i.text(msg, "name")`               | `String`      | `"my-project"`     |
| `i.select(msg, "lang", opts)`       | `String`      | `"TypeScript"`     |
| `i.checkbox(msg, "features", opts)` | `StringArray` | `["docker", "ci"]` |
| `i.confirm(msg, "use_docker")`      | `Bool`        | `true` or `false`  |
| `i.password(msg, "token")`          | `String`      | `"secret"`         |
| `i.dateSelect(msg, "date")`         | `String`      | `"2024-01-15"`     |

The `{registry-path}` prefix matches the template's full name (organization/template-name). Extract prompt IDs from the actual entry point code — do NOT use fictional keys.

### deterministic_state

Maps `d.get(key, ...)` keys to fixed string values for deterministic output:

```yaml
deterministic_state:
  timestamp: '1700000000'
  uuid: '00000000-0000-0000-0000-000000000000'
```

### expected

Declares expected output using a snapshot path. The test runner compares the generated output against files in that directory:

```yaml
expected:
  type: snapshot
  value:
    path: ./snapshots/basic-test
```

### validate

Optional shell commands that run serially after template generation. Each command must exit zero — if any command fails, the test fails. Use these to verify the generated scaffold is complete and functional (e.g., checking that `npm install` succeeds, the dev server starts, or the build completes):

```yaml
validate:
  - test -f package.json
  - test -d src
  - grep -q 'my-project' package.json
```

## Step 3: Run and iterate

```bash
# Run all template tests
cyanprint test template .

# Update snapshots after intentional changes
cyanprint test template . --update-snapshots
```

If tests fail, check that your `answer_state` keys use the correct `{registry-path}/{prompt-id}` format and that types match.

See [reference.md](./reference.md) for a complete example.

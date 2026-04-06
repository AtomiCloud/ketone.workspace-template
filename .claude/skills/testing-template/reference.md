# Template Testing Reference

## test.cyan.yaml Format

```yaml
tests:
  - name: 'test-case-name'
    expected:
      type: snapshot
      value:
        path: ./snapshots/test-case-name
    answer_state:
      myorg/my-template/name:
        type: String
        value: my-project
      myorg/my-template/language:
        type: String
        value: TypeScript
      myorg/my-template/features:
        type: StringArray
        value:
          - docker
          - ci
      myorg/my-template/use_linting:
        type: Bool
        value: true
    deterministic_state:
      timestamp: '1700000000'
      uuid: '00000000-0000-0000-0000-000000000000'
    validate:
      - test -f package.json
      - test -d src
      - grep -q 'my-project' package.json
```

## Complete Example with Multiple Test Cases

This template is published as `myorg/my-template` and prompts for `name`, `language`, `description`, `author`, and `useDocker`:

```yaml
tests:
  - name: 'typescript-basic'
    expected:
      type: snapshot
      value:
        path: ./snapshots/typescript-basic
    answer_state:
      myorg/my-template/name:
        type: String
        value: ts-project
      myorg/my-template/language:
        type: String
        value: TypeScript
      myorg/my-template/description:
        type: String
        value: A TypeScript project
      myorg/my-template/author:
        type: String
        value: testuser
      myorg/my-template/useDocker:
        type: Bool
        value: true
    deterministic_state:
      timestamp: '1700000000'
    validate:
      - test -f tsconfig.json
      - test -f Dockerfile
      - grep -q 'ts-project' package.json

  - name: 'python-minimal'
    expected:
      type: snapshot
      value:
        path: ./snapshots/python-minimal
    answer_state:
      myorg/my-template/name:
        type: String
        value: py-project
      myorg/my-template/language:
        type: String
        value: Python
      myorg/my-template/description:
        type: String
        value: A Python project
      myorg/my-template/author:
        type: String
        value: testuser
      myorg/my-template/useDocker:
        type: Bool
        value: false
    deterministic_state:
      timestamp: '1700000000'
    validate:
      - test -f pyproject.toml
      - test ! -f Dockerfile
```

## Field Reference

### answer_state

Maps `{registry-path}/{prompt-id}` to answer objects. The `type` must match the IInquirer call:

| type          | Used for                                           | value type        |
| ------------- | -------------------------------------------------- | ----------------- |
| `String`      | `i.text`, `i.select`, `i.password`, `i.dateSelect` | string            |
| `StringArray` | `i.checkbox`                                       | list of strings   |
| `Bool`        | `i.confirm`                                        | `true` or `false` |

### deterministic_state

Maps `d.get(key, ...)` keys to fixed string values. All values are strings:

| Code                                              | deterministic_state                            |
| ------------------------------------------------- | ---------------------------------------------- |
| `d.get("timestamp", () => Date.now().toString())` | `timestamp: "1234567890"`                      |
| `d.get("uuid", () => crypto.randomUUID())`        | `uuid: "00000000-0000-0000-0000-000000000000"` |

### expected

Declares how to verify output. Uses `type: snapshot` with a directory path containing expected files:

```yaml
expected:
  type: snapshot
  value:
    path: ./snapshots/test-name
```

The snapshot directory contains the full expected output tree. Updated with `--update-snapshots`.

### validate

Plain shell command strings executed in the generated output directory. Each must exit 0 to pass:

```yaml
validate:
  - test -f file.txt
  - test -d src
  - grep -q 'text' file.txt
```

## Directory Layout

```
template-root/
├── snapshots/
│   ├── typescript-basic/
│   │   ├── cyan/
│   │   ├── cyan.yaml
│   │   └── ... (full expected output)
│   └── python-minimal/
│       └── ... (full expected output)
├── cyan/
│   └── index.ts
├── cyan.yaml
└── test.cyan.yaml
```

## Running Tests

```bash
# Run all test cases
cyanprint test template .

# Update snapshots
cyanprint test template . --update-snapshots
```

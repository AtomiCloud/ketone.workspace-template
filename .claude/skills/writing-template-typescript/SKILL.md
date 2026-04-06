---
name: writing-template-typescript
description: Write or modify CyanPrint template code in TypeScript. Use when the user asks to add prompts, change template logic, modify the entry point, add processors/plugins/resolvers, or change generated output for a TypeScript template. Covers IInquirer question types (text, select, checkbox, confirm, password, dateSelect), processor configuration, and IDeterminism for non-deterministic values.
---

# Writing this Template (TypeScript)

## Entry Point Structure

```typescript
import { StartTemplateWithLambda, type IInquirer, type IDeterminism, type Cyan, GlobType } from '@atomicloud/cyan-sdk';

StartTemplateWithLambda(async (i: IInquirer, d: IDeterminism): Promise<Cyan> => {
  const name = await i.text('Project name', 'name');
  const language = await i.select('Language', 'language', ['TypeScript', 'Python']);

  return {
    processors: [
      {
        name: 'cyan/default',
        files: [
          {
            root: `template/${language.toLowerCase()}`,
            glob: '**/*',
            exclude: [],
            type: GlobType.Template,
          },
        ],
        config: {
          vars: { name, language },
        },
      },
    ],
    plugins: [],
  };
});
```

## IInquirer -- Prompting Users

Six question types are available. Each has a simple form and a Q-form with additional options:

### text -- Free-text input

```typescript
// Simple form
const name = await i.text('What is the project name?', 'project-name');

// Q-form with validation and defaults
const name = await i.textQ({
  message: 'What is the project name?',
  id: 'project-name',
  validate: v => (/^[a-z0-9-]+$/.test(v) ? null : 'Use lowercase letters, numbers, and hyphens'),
  default: 'my-project',
  initial: 'my-project',
});
```

### select -- Single choice

```typescript
// Simple form
const lang = await i.select('What language?', 'language', ['TypeScript', 'Python', 'C#', 'JavaScript']);

// Q-form with labeled choices
const lang = await i.selectQ({
  message: 'What language?',
  id: 'language',
  choices: [
    { value: 'typescript', label: 'TypeScript' },
    { value: 'python', label: 'Python' },
    { value: 'csharp', label: 'C#' },
    { value: 'javascript', label: 'JavaScript' },
  ],
});
```

### checkbox -- Multiple choices

```typescript
// Simple form
const features = await i.checkbox('Which features?', 'features', ['auth', 'logging', 'testing']);

// Q-form
const features = await i.checkboxQ({
  message: 'Which features?',
  id: 'features',
  choices: [
    { value: 'auth', label: 'Authentication' },
    { value: 'logging', label: 'Logging' },
    { value: 'testing', label: 'Testing' },
  ],
});
```

### confirm -- Yes/No

```typescript
// Simple form
const includeTests = await i.confirm('Include tests?', 'include-tests');

// Q-form
const includeTests = await i.confirmQ({
  message: 'Include tests?',
  id: 'include-tests',
  default: true,
  errorMessage: 'Please answer yes or no',
});
```

### password -- Secret input

```typescript
// Simple form
const apiKey = await i.password('Enter API key:', 'api-key');

// Q-form
const apiKey = await i.passwordQ({
  message: 'Enter API key:',
  id: 'api-key',
  confirmation: true,
});
```

### dateSelect -- Date picker

```typescript
// Simple form
const date = await i.dateSelect('Select release date:', 'release-date');

// Q-form
const date = await i.dateSelectQ({
  message: 'Select release date:',
  id: 'release-date',
  min: '2024-01-01',
  max: '2025-12-31',
  validate: v => (v > new Date() ? 'Date must be in the future' : null),
});
```

## IDeterminism -- Deterministic Values

Use `d.get()` for values that are inherently non-deterministic (e.g., timestamps, random strings, UUIDs). User inputs from `i.text()`, `i.select()`, etc. do NOT need wrapping — the test harness provides deterministic answers via `answer_state`.

```typescript
// Only wrap non-deterministic values
const branchName = d.get('branch-name', () => `feat-${Date.now()}`);
const uniqueId = d.get('unique-id', () => crypto.randomUUID());

// User inputs are already deterministic — no d.get() needed
const name = await i.text('Project name', 'name');
const lang = await i.select('Language', 'language', ['TypeScript', 'Python']);
```

### Why Determinism Matters

Each template script is executed multiple times — during generation, testing, and re-generation. Without `d.get()`, values from `Date.now()`, `Math.random()`, `crypto.randomUUID()`, or other non-deterministic sources produce different output each time, breaking snapshot tests.

`d.get()` solves this by generating a value on first execution and storing it. Subsequent executions return the stored value instead of generating a new one.

### When to Use d.get()

Only wrap values that would naturally differ between runs:

- **Use `d.get()`**: `Date.now()`, `Math.random()`, `crypto.randomUUID()`, `new Date()`, or any other non-deterministic source
- **Do NOT wrap**: `i.text()`, `i.select()`, `i.checkbox()`, `i.confirm()`, `i.password()`, `i.dateSelect()` — these are user inputs, and the test harness provides deterministic answers via `answer_state`

**What breaks without it**: Snapshot tests fail because each run produces different output for non-deterministic values. The `cyanprint test --update-snapshots` command will appear to succeed, but subsequent test runs will fail on the now-stale snapshots.

```typescript
// WRONG — non-deterministic across runs
const branchName = `feat-${Date.now()}`;

// CORRECT — stable across runs
const branchName = d.get('branch-name', () => `feat-${Date.now()}`);
```

### How d.get() Works

1. **First execution** (interactive mode): Runs the fallback function, stores the result keyed by the first argument.
2. **Test mode**: Reads directly from `deterministic_state` in `test.cyan.yaml`, ignoring the fallback function entirely.
3. **Re-generation**: Returns the previously stored value, ensuring idempotent output.

## Configuring the Default Processor

The default processor (`cyan/default`) supports these config options:

- `vars`: Template variables for substitution. Supports nested objects. These are substituted using the configured syntax.
- `parser.varSyntax`: Custom delimiter pairs. Pass as array of 2-element arrays, e.g., `[['{{', '}}']]`. **Note**: The actual SDK default is `['var__', '__']`. The meta-template typically injects `{{` `}}` via its own processor config (see the `PromptTemplate` function in this meta-template). When writing a new template, the varSyntax you set here must match the delimiters used in your template files.

**Note**: Globbing is handled automatically by the processor via `fileHelper.resolveAll()`. You don't need to implement file matching yourself.

### Inquirer and GlobType Processing

The processor uses `GlobType` to determine how each file group is handled:

- **GlobType.Template** (0): The processor reads files matching the glob pattern, substitutes `{{var}}` placeholders using `config.vars` and `parser.varSyntax`, then writes the result to the output directory.
- **GlobType.Copy** (1): Files are copied as-is from the source to the output directory with no substitution.

Inquirer prompt results become `config.vars` entries. The `id` parameter of each prompt becomes the variable name used in template files:

```typescript
const name = await i.text('Project name', 'name');
// → available as {{project-name}} in GlobType.Template files
```

```typescript
{
  processors: [
    {
      name: 'cyan/default',
      files: [
        {
          root: 'template/typescript',
          glob: '**/*',
          type: GlobType.Template,  // Process {{var}} substitution
          exclude: [],
        },
        {
          root: 'template/common',
          glob: '**/*',
          type: GlobType.Copy,       // Copy files as-is
          exclude: [],
        },
      ],
      config: {
        vars: {
          username: username,
          name: projectName,
          description: projectDesc,
        },
        parser: {
          varSyntax: [['{{', '}}']],
        },
      },
    },
  ],
  plugins: [],
}
```

## Adding Plugins

```typescript
{
  processors: [...],
  plugins: [
    {
      name: 'username/plugin-name',
      config: { /* plugin-specific config */ },
    },
  ],
}
```

## Adding Resolvers

```typescript
{
  processors: [...],
  plugins: [...],
  resolvers: [
    {
      resolver: 'username/resolver-name:1',
      config: { /* resolver-specific config */ },
      files: ['**/*.json'],
    },
  ],
}
```

## cyan.yaml Artifact Declaration

Every processor, plugin, and resolver referenced in the Cyan return object must also be declared in `cyan.yaml`. Version pinning is supported with `:version` syntax:

```yaml
processors: [cyan/default]
plugins: [username/plugin:1]
resolvers:
  - resolver: username/resolver:1
    config: {}
    files: ['**/*.json']
```

The `processors` and `plugins` fields accept arrays of strings. The `resolvers` field accepts an array of objects because each resolver needs additional `config` and `files` configuration.
```

## Finding Processors, Plugins, and Resolvers

Browse available artifacts:

- **Registry**: https://cyanprint.dev/registry
- **API**: `https://api.zinc.sulfone.raichu.cluster.atomi.cloud/api/v1/`

API endpoints:

- Processors: `/api/v1/Processor`
- Plugins: `/api/v1/Plugin`
- Resolvers: `/api/v1/Resolver`

## Type Definitions

### Cyan

```typescript
interface Cyan {
  processors: CyanProcessor[];
  plugins: CyanPlugin[];
}
```

### CyanProcessor

```typescript
interface CyanProcessor {
  name: string;
  files: CyanGlob[];
  config: unknown;
}
```

### CyanPlugin

```typescript
interface CyanPlugin {
  name: string;
  config: unknown;
}
```

### CyanGlob

```typescript
interface CyanGlob {
  root?: string;
  glob: string;
  exclude: string[];
  type: GlobType;
}
```

### GlobType

```typescript
enum GlobType {
  Template = 0, // Process {{var}} substitution
  Copy = 1, // Copy files as-is
}
```

### IInquirer

```typescript
interface IInquirer {
  text(msg: string, id: string): Promise<string>;
  textQ(options: {
    message: string;
    id: string;
    validate?(v: string): string | null;
    default?: string;
    initial?: string;
  }): Promise<string>;
  select(msg: string, id: string, options: string[]): Promise<string>;
  selectQ(options: { message: string; id: string; choices: { value: string; label: string }[] }): Promise<string>;
  checkbox(msg: string, id: string, options: string[]): Promise<string[]>;
  checkboxQ(options: { message: string; id: string; choices: { value: string; label: string }[] }): Promise<string[]>;
  confirm(msg: string, id: string): Promise<boolean>;
  confirmQ(options: { message: string; id: string; default?: boolean; errorMessage?: string }): Promise<boolean>;
  password(msg: string, id: string): Promise<string>;
  passwordQ(options: { message: string; id: string; confirmation?: boolean }): Promise<string>;
  dateSelect(msg: string, id: string): Promise<string>;
  dateSelectQ(options: {
    message: string;
    id: string;
    min?: string;
    max?: string;
    validate?(v: string): string | null;
  }): Promise<string>;
}
```

### IDeterminism

```typescript
interface IDeterminism {
  get(key: string, origin: () => string): string;
}
```

## Default Processor Config

The `cyan/default` processor accepts this config shape:

```typescript
{
  vars: Record<string, string>,    // Variables for {{var}} substitution
  parser: {
    varSyntax: [string, string][], // Custom delimiters, default [["var__", "__"]], commonly overridden to [["{{", "}}"]]
  },
}
```

# Infisical

Secret management with [Infisical](https://secrets.atomi.cloud).

## Usage

Always use the subprocess form with a trailing `-- ` to propagate secrets to the
command:

```bash
infisical run --env=dev -- env | grep MY_SECRET
infisical run --env=dev -- pls test
```

The bare form `infisical run --env=dev` (without `-- <command>`) does **not** propagate
secrets to the parent shell — secrets are only available inside the Infisical subprocess.
This is a common footgun; always include `-- <command>` when you need secrets in your
current shell environment.

## Setup

Run `pls setup` or [`scripts/local/secrets.sh`](../../../scripts/local/secrets.sh) to authenticate and fetch secrets.

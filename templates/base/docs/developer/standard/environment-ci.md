# Environment CI

The workspace template supplies permanent runner-local k3d lanes for the Diene
environment contract. These lanes are not previews and never allocate ENTEI,
vclusters, provider forks, public DNS, or public certificates.

## Stable checks

`environment-profile-contract` runs without a cluster on every pull request
and protected push. Runtime checks are:

- `environment-ditto-build-local`
- `environment-ditto-target-pull`
- `environment-ditto-vendor` (manual and separately approved only)
- `environment-absol`
- `environment-fleet-independence`
- controller-owned `environment-runner-lifecycle`

Runtime success is insufficient by itself. Branch/release protection must also
require `environment-runner-lifecycle`, which stays pending until the exact
GitHub runner ID and DigitalOcean VM ID are absent. A failed or cancelled job
never becomes green merely because cleanup later succeeds.

## Repository declarations

Participating repositories own only:

```text
.diene/ci/environment-lock.v1.json
.diene/ci/journeys.v1.yaml
.diene/ci/vendors.v1.yaml                 # optional
.diene/ci/runner-pin.v1.json              # accepted controller + image pin
.diene/ci/artifact-producer.sh            # the repository's own publisher
.diene/ci/fixtures/<fixture-id>/manifest.yaml
```

The `.yaml` contracts use the JSON-compatible YAML subset so the runner can
validate them with the pinned `jq` already present in the image. Every one of
them is validated against its real JSON Schema in `schemas/ci/` — with
`check-jsonschema`, resolving cross-file `$ref`s from the local directory so
validation stays offline — **before any `pls` invocation**. A shape check in
`jq` is not schema validation and no longer stands in for one.

Missing journey declarations disable the runtime caller without claiming
coverage; a present invalid declaration is a blocking failure. A required
missing pack is `Fail`; an optional missing pack is `Unavailable`; no
declaration is `NotApplicable/NoDeclaration`. A fixture pack whose bytes drift
from its declared `fixturePack.digest` is `FixturePackDigestMismatch`, not a
silent execution.

### The artifact subject is a same-run handoff

`artifact-producer.sh` is the repository's own publisher. The `artifact-build`
job runs it and validates that the record it emits binds **this** workflow ref,
run ID and run attempt. A checked-in `artifact.v1.json` therefore cannot
satisfy the handoff — it would go stale on the next commit — and a repository
with no producer refuses `ArtifactProducerUnavailable`. CI never derives a
digest from a source tree and never assembles a provenance string from run
metadata: a source-tree hash is not an artifact, and a formatted string is not
an attestation.

### Release boundary

No workspace caller selects or queues a disposable self-hosted runner until the
GitHub-hosted authorization path has accepted the controller/image pin, the
`RunnerProvisionerReady` proof, and the producer. Those refusals happen in
`authorize-runtime` and in the reusable workflow's `contract` job, both on
`ubuntu-24.04`, so a missing prerequisite never costs a VM allocation.

## Trust and subjects

The reusable workflow first validates selectors and immutable subjects on
`ubuntu-24.04`; invalid calls never select a disposable runner.

Its `workflow_call` surface is exactly the ratified `diene-ci-k3d/v1` set:
`lane`, `repository_id`, `repository_key`, `source_sha`, `garden_lock_digest`,
`artifact_digest`, `artifact_provenance_ref`, `artifact_attestation_digest`,
`journey_manifest`, `vendor_manifest`, `action_id` and the four closure
selectors. Nothing else is accepted, and a contract test asserts the input list
has not drifted. In particular the image ref, the producer identity and the
selected-package read identity are **not** inputs — they live inside the
validated same-run subject document, so a caller cannot substitute a subject
the producer never made — and the independence fixture is hard-coded rather
than selected. The base workflow identity is derived inside the workflow from
`github.workflow_ref` and `github.workflow_sha` and must equal the revision
under test, so a substituted or stale workflow identity refuses.

Runtime labels are the fixed four image labels plus one deterministic
job label, and the runner lease must carry **that job's** label — a lease
minted for a sibling lane of the same run is refused. Fork, Dependabot,
unprotected, substituted, mutable, or stale tuples refuse before credentials,
network policy, volume, or substrate mutation.

Garden owns `diene-runtime/v1`. This node never writes that record: after
`pls env up` it discovers the Garden-emitted file by the full immutable owner
tuple (repository ID and key, allocation key, generation key, profile),
validates it, and refuses `RuntimeEvidenceUnavailable` if there is no exact
match.

## Identity and isolation

Each lane derives its own keys:

```text
allocationKey = r<repositoryId>-w<runId>-a<runAttempt>-l<lane>[-v<actionId>]
generationKey = g<first 12 of sourceSha>
receiptId     = <allocationKey>-<generationKey>
```

Parallel lanes of one workflow run therefore never share a receipt, a runtime
directory, or a cleanup selector. Each runtime job additionally carries its own
run-scoped concurrency group
(`k3d-<repositoryId>-<runId>-<runAttempt>-<lane>`, plus `-<actionId>` for the
vendor lane) with `cancel-in-progress: false`, so unrelated runs are never
serialised against each other.

## Trigger matrix

| Lane | Events |
| --- | --- |
| `environment-ditto-build-local` | protected push, authorized dispatch |
| `environment-ditto-target-pull` | protected push, authorized dispatch |
| `environment-absol` | protected push, or dispatch with `release_candidate` |
| `environment-fleet-independence` | protected push, weekly schedule |
| `environment-ditto-vendor` | explicit dispatch only |

The weekly schedule reaches fleet independence and nothing else.

## Lane semantics

- Ditto build-local and target-pull select the same vendor-free journeys and
  both run under a generated host **allowlist**: DNS and the default route are
  denied, so an unlisted system is unreachable by literal IP and by alternate
  DNS alike. Target-pull additionally requires `ArtifactPullReady` to be a
  required, passing leaf and a read identity distinct from the publisher.
- Vendor actions come only from `.diene/ci/vendors.v1.yaml`, currently only
  the ratified K9 demo exception. They use `ci-ditto-vendor`, an exact declared
  egress allowlist, a separate report namespace, and provider absence. The
  `DIENE_VENDOR_CREDENTIAL` secret is scoped to the single execution step — not
  to the job — so checkout and the post-job sweep never see it.
- Absol establishes denial through the ratified
  `pls closure preflight --denied-network` before any Docker volume or k3d
  cluster exists, imports with `pls closure import`, and never releases denial:
  it stays active through teardown.
- Fleet independence is exactly Ditto/build-local with the hard-coded
  `bootstrap-fleet-independence-v1` fixture, in the `ci-ditto` environment.
  Environment secrets are only injected where a workflow references them, and
  this lane references none, so it holds no seed-fetch identity.

## Readiness

Readiness is consumed from the read-only `pls env doctor --profile <p> --json`
and validated against `diene-readiness-v1.schema.json`, which requires all
seventeen contract leaves with explicit outcomes. An empty or truncated leaf
set refuses; it can no longer pass vacuously. `AllocationReady`,
`CastformProdSafetyReady` and `CallbackReady` must be `NotRequired` on every
local lane, and Absol and the independence fixture must report `SeedReady`
`NotRequired`.

## Cleanup and evidence

The egress posture, the receipt, and the EXIT/TERM/INT traps are all
established **before** `pls env up`, so a run cancelled inside the substrate
mutation still converges instead of orphaning a cluster or leaving host denial
applied. Cleanup executes the ratified `pls env down --profile <ditto|absol>`
against the exact runtime file, then releases the egress posture.

The post-job sweep is always parameterized by repository ID, run ID, run
attempt, and opaque receipt ID — the exact four-selector interface, never
widened. Missing, multiple, or mismatched receipts create visible
`CleanupDebt`; no readable prefix, profile, namespace, or broad Docker label
can select a victim. A receipt with no bound runtime file authorises **no**
deletion. Sweeping is idempotent, so the `always()` post-job sweep never issues
a second teardown. `pls env reset` is never automatic.

Reports are emitted for failing runs as well as passing ones and carry
readiness, per-journey outcomes with timings and fixture digests, teardown
transitions, finalizer debt, absence proof, leakage-scan and egress-canary
results, and setup/substrate/readiness/journey/teardown timings. Core reports
use `diene.atomi.cloud/ci-environment-report/v1`; vendor reports use
`diene.atomi.cloud/ci-vendor-report/v1` and cannot carry core readiness or
journey fields. Both are schema-validated before publication.

`DIENE_LEAK_CANARY` is **mandatory** for every runtime report. The lane
generates a per-job tracer that lives only in process memory, and the scanner
checks raw, base64, URL-encoded, JSON-escaped, newline-normalized and
kubeconfig-embedded forms across the report, `$RUNNER_TEMP`, step outputs and
the step summary. An absent canary, an absent search tool, or a positive
finding all suppress the artifact and fail the lane. A lane whose evidence
cannot be published is never green.

Local contract proof:

```sh
./scripts/ci/test-environment-contract.sh
```

It runs in `environment-contract-tests` on every CI run.

## External dependencies still open

These are refusals, not silent gaps. Each names a stable reason code and
resolves the moment the upstream interface lands.

| Blocker | Reason code | Resolves when |
| --- | --- | --- |
| No ratified runtime-free executable render | `ProfileRenderInterfaceUnavailable` | Garden publishes a render command; point `DIENE_PROFILE_RENDER_BIN` at it and the gate becomes executable with no template change. Until then a repository that has declared an environment lock fails this gate. |
| No ratified host-policy verb | `HostPolicyInterfaceUnavailable` | The runner image ships `/opt/diene/bin/diene-host-policy`. `pls` ratifies no network verb, so inventing one here would be a second lifecycle. |
| No ratified closure signature/Rekor verification | `ClosureAttestationInterfaceUnavailable` | Recorded as explicit `Unavailable` coverage in the Absol report; never counted as passed. |
| No ratified exact-set equality probe | `ClosureExactSetInterfaceUnavailable` | Same. |
| No ratified eviction/repull or sibling-denial probe | `PullEvictionInterfaceUnavailable`, `PullSiblingDenialInterfaceUnavailable` | Recorded as explicit `Unavailable` coverage in the target-pull report. |
| No ratified finalizer-quiescence probe | `FinalizerQuiescenceInterfaceUnavailable` | The profile's 90-second local-finalizer window cannot be observed from here, so it is declared unavailable rather than simulated. |

`pls env doctor --profile <p> --json` is the one upstream affordance this node
assumes beyond the literal ratified signature: the ratified command is
read-only, and machine-readable output is required to consume the readiness DAG
at all.

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
minted for a sibling lane of the same run is refused.

The lease the job reads is the runner arm's job-visible projection:
`/run/diene-runner-lease.v1.public.json`, exactly mode `0440`. The private
lease is never job-readable, so any other mode refuses. The job identity holds
`CAP_NET_ADMIN` and is explicitly denied `CAP_SYS_ADMIN`; the preflight proves
both directions — `nft` must work, and `unshare --net` and `nsenter` must
**fail**. Requiring `unshare` to succeed would demand `CAP_SYS_ADMIN` and
contradict the isolation model, so a job that can create or enter a namespace
is refused. Fork, Dependabot,
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
  both run under the `allowlist` posture: DNS and the default route are denied,
  so an unlisted system is unreachable by literal IP and by alternate DNS
  alike. Target-pull additionally requires `ArtifactPullReady` to be a
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
mutation still converges instead of orphaning a cluster. Cleanup executes the
ratified `pls env down --profile <ditto|absol>` against the exact runtime file,
then requests deferred cleanup of the egress posture.

### The host-policy seam

The egress interface is runner-owned and its ABI is exactly two verbs:

```text
diene-host-policy apply   --receipt <id> --allow-file <diene-host-policy/v1>
diene-host-policy release --receipt <id>
```

The lane generates the document; the runner enforces it in the host namespace.
`mode` is the canonical wire enum `allowlist | closure-denied-network`, used
unchanged end to end — emitted in the document, recorded on the receipt, and
reported in the evidence.

**The lane does not choose its own posture.** `authorizedPolicyMode` is derived
by the runner from the root lease's stable job identity and published in the
isolation receipt; the conductor requires exact equality before it will even
validate a document. The lane reads the authorized value and refuses when it
disagrees with what the lane requires, naming both — rather than emitting a
mode that would be rejected, or running under a posture it cannot work in.

The first accepted policy binds `(lease, receipt)`: afterwards only a
byte-identical replay is permitted, and a changed allow set is refused with the
original left standing. A new posture needs a new receipt, so the lane applies
exactly once per receipt.

`release` is **deferred and non-destructive by contract**. It runs as the very
principal the policy constrains, so if it deleted anything a lane could invoke
it with its own known receipt at lane start and restore its own egress.
Deletion belongs solely to the root-owned runner teardown transition. The lane
records `PolicyReleaseRequested:Deferred` and never treats it as proof the
enforcing table is gone.

Lane CIDRs are runner-owned too: they are read from the `0440` isolation
receipt at `$DIENE_ISOLATION_FILE`, never copied into this template as
constants and never re-derived from the runner's path layout. A duplicated
constant is exactly how two arms drift apart.

**Lane CIDRs are local-only inputs, not egress permissions.** The Docker
bridge/pool and the k3s pod/service ranges are validated as lane-local
addresses; they must never become host-forward `accept` rules. A job holds
`CAP_NET_ADMIN`, so it can delete the namespace-local route for a permitted
range and route it through its veth instead — a host that accepted on
destination CIDR alone would then forward it to the default egress, and any
address overlapping an allowed internal range becomes reachable from a
`closure-denied-network` lane. Authorising a CIDR is not the same as proving it
is still the lease-local path it names. Host forwarding therefore admits only
the exact root-authorized external literal endpoints, constrained to the real
egress path; everything else is local by construction or denied.

Lifetime attestation is likewise not the lane's to claim. `apply` proves the
metadata endpoint denied from outside the lane namespace at apply time, which
the lane cannot defeat; that the posture held for the whole lane is evidence
the root-owned teardown produces and the controller-owned
`environment-runner-lifecycle` check carries.

The post-job sweep is always parameterized by repository ID, run ID, run
attempt, and opaque receipt ID — the exact four-selector interface, never
widened. Missing, multiple, or mismatched receipts create visible
`CleanupDebt`; no readable prefix, profile, namespace, or broad Docker label
can select a victim. A receipt with no bound runtime file authorises **no**
deletion. Sweeping is idempotent, so the `always()` post-job sweep never issues
a second teardown. `pls env reset` is never automatic.

### Evidence is published by the runner, not by the job

Runtime lanes do **not** call `actions/upload-artifact`. The enforcing table is
still standing when the runtime step ends — `release` is deferred by contract —
and under a hermetic posture it denies exactly the connections an upload needs,
so an in-job upload could never succeed on a real runner. The lane stages its
scanned report into the root-owned publication channel and the runner lifecycle
owns the sequence: **stage → prove runtime absence → release → upload through a
channel the job can never call.** A job-callable channel would let checkout code
invoke it before absence was proven, so the lane refuses one.

The lane also refuses unless the runner attests that the enforcement is a
boundary at all: `armedBeforeJob` (checkout and setup precede the lane, so a
flow opened there would outlive a later policy), `establishedFlowExemption:
false` (a blanket established/related accept admits any pre-opened flow for the
table's lifetime), and `inputPathCovered` (a forward-only chain never sees
packets delivered locally to the host veth or gateway). These are attestation
checks, not proofs — the corresponding escape probes are privileged and live in
the runner arm's suite.

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

**Every one of these is a hard refusal.** None is recorded as optional
`Unavailable` coverage, and the report schema rejects a `Pass` report that
tries to carry one, so a missing enforcement primitive cannot become green
coverage.

| Blocker | Reason code | Effect |
| --- | --- | --- |
| No runtime-free executable render | `ProfileRenderInterfaceUnavailable` | A repository that has declared an environment lock fails the profile gate. `DIENE_PROFILE_RENDER_BIN` makes it executable with no template change; repos without a lock stay `NotApplicable`/green. |
| No runner host-policy client or isolation receipt | `HostPolicyInterfaceUnavailable` | Every runtime lane refuses. A job holds `CAP_NET_ADMIN`, so any nft table it installs in its own namespace is a cooperative setting it can flush — not a boundary. Enforcement lives in a root-owned host layer the job cannot mutate. |
| No enforceable connected endpoint | `ConnectedEgressInterfaceUnavailable` | The connected Ditto lanes refuse. The enforcement layer denies DNS and admits only literal addresses, so a bare hostname such as `ghcr.io:443` could never be enforced; the template refuses rather than emitting one the conductor would reject, or worse, one it would accept as if enforced. The mechanism exists; the seed and registry literals are a deployment input nobody may synthesise. |
| Enforcement not attested as a boundary | `HostEnforcementIncomplete` | Every runtime lane refuses unless the runner attests `armedBeforeJob`, `establishedFlowExemption: false` and `inputPathCovered`. |
| No root-owned evidence publication channel | `EvidencePublicationInterfaceUnavailable` | Every runtime lane refuses. An in-job upload cannot open its connections under denial, and a job-callable channel could be invoked before runtime absence is proven. |
| No closure signature/certificate/Rekor verification or exact-set equality | `ClosureAttestationInterfaceUnavailable` | Absol refuses; both are mandatory results in the lane table. |
| No real-pull / evict-repull / sibling-denial / pull-secret-ownership / credential-removal proof | `RequiredCoverageUnavailable` | target-pull refuses; all five are required results. |
| No vendor egress proxy or credential broker | `VendorBrokerInterfaceUnavailable` | The vendor lane refuses. nft can express neither SNI nor HTTP methods, and a step-injected secret is live during preflight, substrate creation and readiness, so it is not phase-scoped in any meaningful sense. |
| No captured stdout/stderr/argv/environ staging | `EvidenceLeakageInterfaceUnavailable` | The report refuses. Output streamed to the live GitHub log is already published and cannot be suppressed retroactively, so `leakageScan` is never claimed over a surface that was not actually captured. |
| No finalizer-quiescence probe | `FinalizerQuiescenceInterfaceUnavailable` | The profile's 90-second window cannot be observed from here, so it is declared unavailable rather than simulated. |

`pls env doctor --profile <p> --json` is the one upstream affordance this node
assumes beyond the literal ratified signature: the ratified command is
read-only, and machine-readable output is required to consume the readiness DAG
at all.

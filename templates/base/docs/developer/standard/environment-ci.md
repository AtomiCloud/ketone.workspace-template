# Environment CI

`environment-k3d` and `diene-ci-k3d/v1` are compatibility names. They do not
select k3d. Every runtime invocation owns one anonymous, ephemeral Namespace
instance and uses that instance's built-in, single-node k3s. The ordinary
Actions runner only creates, transfers, invokes, collects, destroys, and proves
absence.

The runtime lanes are:

| Lane | Profile / build mode | Network contract | Report namespace |
| --- | --- | --- | --- |
| `ditto-build-local` | `ditto` / `build-local` | exact connected allowlist | core |
| `ditto-target-pull` | `ditto` / `target-pull` | exact connected allowlist including the immutable registry | core |
| `ditto-vendor` | `ditto` / `build-local` | the selected action's DNS/SNI/port/method declaration | vendor only |
| `absol` | `absol` / `build-local` | hermetic denial | core |
| `fleet-independence` | `ditto` / `build-local` | hermetic denial | core |

Profile rendering remains runtime-free. Eevee and Castform are validated but
not executed here. Namespace ingress, a generated hostname, and public DNS are
never an application address or identity.

## Stable workflow contract

`.github/workflows/⚡reusable-environment-k3d.yaml` retains the
`diene-ci-k3d/v1` call surface:

- common immutable inputs are `lane`, numeric `repository_id`, canonical
  `repository_key`, full `source_sha`, `garden_lock_digest`, and
  `artifact_digest`;
- core, Absol, and independence use only
  `journey_manifest=.diene/ci/journeys.v1.yaml`;
- vendor uses only `vendor_manifest=.diene/ci/vendors.v1.yaml` plus one
  `action_id`;
- target-pull additionally binds the producer's provenance reference and
  attestation digest;
- Absol additionally binds its closure digest, bundle reference, signature
  bundle digest, and trust-root digest; and
- outputs are `subject_digest`, opaque `receipt_id`, and exactly one of
  `core_report_digest|vendor_report_digest`.

The stable runtime job IDs are:

- `environment-ditto-build-local`
- `environment-ditto-target-pull`
- `environment-ditto-vendor`
- `environment-absol`
- `environment-fleet-independence`

`environment-profile-contract` remains the runtime-free gate.
`environment-runner-lifecycle` is a workflow-owned terminal result. It is not
a provider controller, runner lease, or GitHub App check. It has no Namespace
credentials and accepts only the collected proof bound to the exact
repository/source/run/attempt/lane/receipt/cluster tuple.

Top-level permissions are empty. The callers preserve their environment,
permission, timeout, and `k3d-...` concurrency compatibility contracts. The
runtime jobs use the primary
`nscloud-ubuntu-26.04-amd64-16x32` Namespace orchestrator label. GitHub-hosted
contract and lifecycle checks currently use the recorded `ubuntu-24.04`
fallback because the `ubuntu-26.04` hosted label is unavailable in that venue.
A fallback is evidence, never a silent label substitution.

## Protected admission before mutation

Before `nsc create`, the caller and reusable workflow both prove:

- the repository owner is `AtomiCloud`;
- `source_sha` is a full commit reachable from the protected default branch;
- push/schedule refs are protected, dispatch actors have `write|admin`, and
  Dependabot, pull requests, fork/head workflows, and substituted workflow
  identities cannot enter the runtime path;
- the same-run artifact subject binds the repository, workflow, source,
  run/attempt, immutable digest, and mode-specific attestations;
- lane selectors are neither missing nor crossed between core and vendor;
- Absol's complete signed-closure tuple is present and well formed;
- the production duration is exactly `2h`;
- declared journey/vendor manifests and every present production fixture are
  valid, Promotion/Freight objects are complete, duration spellings are
  canonical, and the negative canary is inactive; and
- no Namespace ingress/public endpoint, forbidden cache, seed, or vendor
  capability is attached to a hermetic lane.

An absent journey declaration means explicit `NotApplicable/NoDeclaration`.
Once a repository opts in, every other missing or invalid prerequisite is a
refusal. It never silently removes a blocking runtime check.

The interim network path is restricted to trusted protected refs. If an
untrusted context can reach it, the run refuses before `nsc create`; generated
code and the enforcer are within the temporary trust boundary.

## Exact Namespace lifecycle

`scripts/ci/environment-k3d-run.sh` has separate authority modes:

- `orchestrate` runs on the Actions runner and owns Namespace lifecycle;
- `driver /run/diene-ci` runs as root on the Wolfi guest and owns Garden,
  readiness, journeys, policy probes, and on-instance cleanup;
- `cleanup` is called by an Actions `if: always()` step. It re-proves the
  normal terminal state or recovers only an exact receipt-bound instance after
  an interrupted primary step; and
- `lifecycle <proof.tar>` performs unprivileged terminal proof validation.

There is deliberately no seventh `environment-nsc-lifecycle.sh` entrypoint.
The retained six scripts are the complete public script surface.

The production sequence is:

```text
validate protected trust, immutable subject, closure, declarations and fixtures
  -> materialize the exact egress contract
  -> nsc create --ephemeral --duration 2h --wait_kube_system
       --cidfile <file> --output_json_to <file> --output json
  -> require cidfile == create metadata .cluster_id
  -> bind that exact cluster_id to the run/attempt receipt
  -> nsc instance upload <id> <local> <remote> --mkdir
  -> nsc ssh <id> -T <fixed-command>
  -> run the copied driver against built-in k3s
  -> nsc instance download <id> <remote> <local> --mkdir
  -> verify digest and safely extract the fixed proof archive
  -> nsc destroy --force <exact-id>
  -> nsc list --all -o json and prove that exact .cluster_id is absent
  -> leakage-scan, schema-validate, and seal the terminal proof
```

`nsc list` returning JSON `null` is normalized to `[]`. A successful destroy
exit code without a positive exact-ID absence query is red. Prefix, name,
profile, repository-wide, and label-wide destructive selection is forbidden.
The two-hour TTL is a backstop, not successful cleanup.

The primary EXIT/TERM/INT trap preserves the first failure while attempting
collection, exact destroy, and absence. The later `cleanup` step may close an
exact survivor debt but always returns red for that run; late success cannot
rewrite failure green. A hard runner loss can still bypass Actions cleanup,
which is why any post-TTL survivor is an incident and a fresh run is required.

Only immutable files cross into `/run/diene-ci`, which is mode `0700`:
source archive, driver inputs, artifact subject, egress contract, and the safe
receipt projection. No `NSC_TOKEN`, GitHub token, SSH agent, destroy authority,
vendor credential, kubeconfig body, or other capability is copied. Presence of
an `nsc` executable in a shared Nix shell is not authority; the guest never
invokes it.

## Guest posture and endpoint law

Preflight must prove all of the following before application mutation:

- UID 0 on Wolfi;
- iptables 1.8.x on the `nf_tables` backend (the standalone `nft` program is
  not required);
- admitted k3s `v1.33.1+k3s1`, one Ready node, observed pod CIDR, admitted
  `10.143.0.0/16` service CIDR, and recorded CPU/memory capacity;
- exactly one default StorageClass named `local-path`; and
- no Ingress, Gateway, LoadBalancer Service, external IP, wildcard/LAN/public
  bind, or Namespace-generated application endpoint.

Garden continues to own `diene-runtime/v1`. Its strict consumption view and
opaque `.substrate.kind == "k3d"` remain unchanged compatibility ABI; the CI
receipt/report binds Namespace `cluster_id` separately. The driver calls only
the pinned `pls env up|doctor|down` contracts and never stops platform k3s,
creates nested k3d, uses a shared Docker volume, or runs
`k3s ctr images export`.

Product routing is loopback-only and is verified after readiness. Public-edge
or preview behavior remains outside this SIT.

## Interim egress enforcement

Namespace CLI v0.0.532 has no supported per-instance egress-policy selector.
Tenant/workspace-wide policy mutation is forbidden because concurrent jobs
would race and lose exact-run ownership. The accepted interim is therefore
receipt-scoped, in-guest iptables-nft enforcement and every report must state:

```text
platform per-instance policy pending (support ask #4)
```

This is not final platform enforcement.

Every run:

1. chooses its distinct logical profile before create;
2. freezes declared DNS to literal addresses before policy activation;
3. hooks receipt-scoped host `OUTPUT` and pod `FORWARD` chains;
4. preserves only loopback/local cluster routes and the exact active SSH
   return 4-tuple, never a blanket `ESTABLISHED,RELATED` exception;
5. rejects metadata and undeclared egress, including a flow opened before the
   policy transition;
6. proves hostile metadata/arbitrary HTTPS probes on the host and in an actual
   canary pod; and
7. removes and verifies every IPv4/IPv6 hook, chain, and connected L7
   enforcement receipt during cleanup.

IPv6 forwarding is scoped only to observed IPv6 pod CIDRs. When none exists,
the receipt chain returns unrelated forwarded traffic rather than installing a
host-wide reject.

Connected Ditto lanes must receive an exact JSON allowlist and a checked-in,
repository-relative executable enforcer capable of proving DNS, SNI, port,
HTTP-method, and default-deny boundaries. These are safe deployment variables,
not workflow-call inputs:

- `DIENE_CONNECTED_EGRESS_JSON`
- `DIENE_EGRESS_CANARY_IMAGE` (immutable digest and preloaded)
- `DIENE_EGRESS_L7_ENFORCER_BIN`
- optional `DIENE_EGRESS_PROBE_BIN`
- `DIENE_VENDOR_CREDENTIAL_BROKER_BIN` for vendor only

The enforcer, optional probe adapter, and vendor broker must be regular
executable source files before create and are copied with the pinned commit.
Missing or unprovable connected enforcement is
`ConnectedEgressInterfaceUnavailable`; a missing vendor phase broker is
`VendorBrokerInterfaceUnavailable`. The implementation does not pretend that
metadata-only denial satisfies a connected lane.

The vendor broker issues its mode-0600 credential only after readiness, and
revokes it before terminal reporting. Credential bytes never appear in the
immutable driver input. Provider object IDs are safe evidence; absence or an
exact durable debt record is mandatory. An optional declared action may report
`Unavailable` without blocking only when `required=false`; required actions
remain red.

Absol and fleet-independence attach no shared cache and admit no external
entry. Absol also verifies/imports the signed closure and exact-set equality
under denial before application mutation. This interim is allowed only under
the trusted-ref restriction above.

## Evidence and reports

Core lanes emit `diene.atomi.cloud/ci-environment-report/v1`. Vendor emits
`diene.atomi.cloud/ci-vendor-report/v1` in its separate action namespace. Both
retain their stable result vocabulary and legacy fields while adding Namespace
lifecycle facts.

A green terminal report requires:

- exact cluster ID, Wolfi/k3s/node/capacity evidence;
- create, transfer, SSH, collection, destroy, and absence phase receipts;
- host and actual-pod hostile probes;
- a valid immutable checkpoint predecessor chain ending in a non-resumed
  `final-clean-pass`;
- a collected proof bundle and complete segmented cold timings; and
- a passing leakage scan over raw, base64, URL-encoded, JSON-escaped,
  newline-normalized, and kubeconfig-embedded canaries.

Active failure reports may use `null` for instance facts that were never
learned, but they stay red. Both or neither report digests, a core digest from
vendor, or a vendor digest from core is `ReportNamespaceViolation`.

Candidate artifacts may contain only safe reports, transcripts, timings,
checkpoints, and non-capability receipts. Runtime files, kubeconfig content,
tokens, seed bytes, rendered Secrets, credentials, caches, and cleanup
authority are never published.

## Local verification

`scripts/ci/test-environment-contract.sh` uses a local fake `nsc` implementing
only the measured v0.0.532 surface. It covers exact identity/destroy/absence,
pre-create refusals, SSH and collection loss, destroy failure, signals,
parallel tuple isolation, report namespaces, policy probes/removal, leakage,
checkpoint chains, and forbidden substrate strings.

Run the canonical gates from the generated repository's CI shell:

```bash
./scripts/ci/test-environment-contract.sh
shellcheck scripts/ci/*.sh
actionlint
check-jsonschema --check-metaschema schemas/ci/*.schema.json
```

The shell includes the ordinary Unix/Kubernetes tools used by the driver. It
does not package or invent `nsc`; the Namespace orchestrator image must provide
the pinned CLI and the script records its semantic version.

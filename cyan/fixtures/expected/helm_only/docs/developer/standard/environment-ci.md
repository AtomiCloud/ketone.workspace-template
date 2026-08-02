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
- the declared CI shell selects the release-hash-pinned `nsc` v0.0.532 store
  executable and its recorded executable digest agrees with the immutable
  identity file;
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
  -> require exact nsc v0.0.532 plus release-artifact and executable digests
  -> reject unsafe source names, links, hardlinks, FIFOs, devices and special entries
  -> privately fetch the tagged guest-Nix provenance witness and the separately
     pinned x86_64 installer payload; reject redirects, byte or digest drift
     before nsc create
  -> materialize the exact egress contract
  -> derive the admitted full k3s version and its single Kubernetes feature
     selector from one helper, refusing malformed or unsupported admission
  -> nsc create --ephemeral --duration 2h --enable=kubernetes:1.33
       --wait_kube_system
       --cidfile <file> --output_json_to <file> --output json
  -> require cidfile == create metadata .cluster_id
  -> bind that exact cluster_id to the run/attempt receipt
  -> bind exact nsc version/artifact/executable identity to the receipt
  -> nsc instance upload <id> <local> <remote> --mkdir
  -> nsc ssh <id> -T <fixed-command>
  -> reverify both guest-Nix assets and sidecars, refuse ambient Nix state,
     execute only the pinned installer binary, and enter the pinned Nix shell
  -> verify the separately uploaded fixed validator and repeat source safety
     before constrained extraction into a fresh directory
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

Only immutable files cross into `/run/diene-ci`, which is mode `0700`: source
archive, driver inputs, artifact subject, egress contract, the safe receipt
projection, a separately uploaded fixed archive validator plus checksum, and
the tagged guest-Nix provenance witness, pinned x86_64 installer payload, and
their checksum sidecars.
The outer and remote validators accept only unique normalized relative names
and regular-file/directory members. Collection repeats those checks before
extraction and rejects any unreadable, linked, or special extracted object.
No `NSC_TOKEN`, GitHub token, SSH agent, destroy authority, vendor credential,
kubeconfig body, or other capability is copied. The shared shell may expose
the pinned client binary on the guest, but the driver has no Namespace
authority and never invokes it.

## Pinned guest Nix acquisition and identity

Refined-by the generation-9 direct-binary ruling: the earlier freeze rationale
treated `GuestNixToolchainAbsent` as a prohibition on downloading or installing
Nix. Its fail-closed intent remains binding, but that blanket no-bootstrap
interpretation is superseded. The same diagnostic and exit-64 guard now means
that a fully verified install still failed to expose the required toolchain; it
never permits an ambient or partially identified Nix installation to pass.

The orchestrator acquires two Determinate v3.21.9 artifacts before `nsc
create`. The tagged shell is an unexecuted provenance witness. The
architecture-specific binary is an independently pinned execution trust root.
Each acquisition uses HTTPS with TLS 1.2 or newer, refuses redirects, validates
the expected byte count before the full SHA-256, and atomically publishes a
mode-0600 file only at a fresh, real-directory target; existing objects and
linked publication targets or parents refuse before fetch. Acquisition failure
therefore has no Namespace create side effect. The immutable URLs, byte counts,
and digests have one source of truth in `environment-lib.sh`; the rolling
endpoint, pipe-to-shell forms, alternate package URLs, upstream preference,
force/plan overrides, and unpinned installer paths remain forbidden. Host
acquisition refuses the retired `DIENE_CURL_BIN` channel and invokes `curl`
only after resolving it to a regular executable `/nix/store/*/bin/curl`; fake
downloaders exist only behind an explicit scratch-copy harness seam.

Both assets and their checksum sidecars cross the existing ordered transfer
chain. The fixed POSIX guest template materializes its expected digest and byte
pins only from the centrally validated contract, then requires each asset and
its exact one-line sidecar to match those independent expected values before
either can gain execute permission. An asset and sidecar altered together
cannot self-authorize. The shell witness stays mode `0600` and is never run.
The guest must be exactly `x86_64` and begin with no ambient `nix`, `/nix`, or
`/etc/nix` state. Before the first installer probe, the remote rail fixes its
command `PATH`, captures the actual inherited environment, and refuses every
exported name beginning `NIX`, including all current or future
`NIX_INSTALLER_*`, `NIX_*`, and `NIXPKGS_*` controls. Diagnostics contain names
only. An environment value with an embedded newline followed by a `NIX...=`
shape can cause only a fail-closed over-refusal; it cannot hide a real matching
name. Capture or parse failure is also red.

Both installer invocations run under `env -i` with only fixed `PATH`, private
`HOME`, `TMPDIR`, and `LC_ALL`; only the install invocation adds an empty
`NIX_INSTALLER_DIAGNOSTIC_ENDPOINT`. Raw stdout and stderr remain separate, and
acceptance still requires empty stderr plus the exact 21-byte, one-line stdout
`nix-installer 3.21.9` followed by one newline. The measured argv remains
exactly `install linux --no-confirm --init none`. After installation,
`/etc/nix/nix.conf` must be a readable regular non-link file below a real
`/etc/nix` directory, and its digest must remain unchanged through profile
sourcing. The mandatory profile must be readable and regular and resolve to
`/nix/store/*/etc/profile.d/nix-daemon.sh`. It is sourced unconditionally with
error and unset-variable handling temporarily relaxed; its exact status is
retained and strict handling restored. Missing, dangling, directory,
out-of-store, and nonzero profile states refuse before `nix develop`.

The develop exec deliberately does not use `env -i`, because it must hand the
driver its admitted runtime inputs. Its Nix-family values can only have been
created by the pinned profile after the inherited prefix-wide refusal. Those
profile-created values and PATH are preserved, while `HOME` and
`XDG_CONFIG_HOME` are reset to a private empty tree and `NIX_USER_CONF_FILES`
points to a reviewed empty mode-0600 file. The identity field
`profileSourced:true` means that exact profile returned success.

Preflight independently verifies the fixed
`/nix/var/nix/profiles/default/bin/nix` path before policy or application
mutation. Its raw version result must be exactly the 35-character line `nix
(Determinate Nix 3.21.9) 2.34.8` plus one newline, with empty stderr. The
resolved target must be a regular executable `/nix/store/*/bin/nix`; its digest,
the installed `/nix/nix-installer` digest, and both still-uploaded artifact
digests must agree with the admitted contract.

The private mode-0600 `evidence/guest-nix/environment.txt` records the inherited
boundary result, sorted names (never values) of profile-created `NIX*`
variables, reviewed home/XDG/user-config paths, and the installed `nix.conf`
digest. Capture, parsing, sorting, or publication failure is red. Preflight
validates those fixed fields against the live config and binds the file's
SHA-256 as `environmentDigest`.

One canonical JSON object supplies the schema-free identity proof. The private
`evidence/guest-nix/identity.json` receipt records both artifact identities and
lengths, architecture, direct-binary execution mode, exact argv, installer and
Nix versions, initialization and profile facts, resolved store path and digest,
installed-copy digest, and environment-evidence digest. Preflight embeds that
same object plus the receipt's SHA-256 as
`guestNix.identityReceiptDigest`; removing only that digest must make the two
objects equal exactly, and changing the environment evidence breaks agreement.
The existing `instance-preflight` checkpoint binds the complete preflight
bytes, so the terminal proof carries both private receipts and their
checkpoint-bound digests without expanding the schema-validated CI receipt or
report.

The installer payload remains inside the mandatory outer leakage-scan surfaces;
it has no scan exclusion. Transfer, shell entry, and scan wall-clock remain
measurement items within the two-hour ephemeral-instance TTL. Cleanup is still
only exact Namespace destroy plus positive absence proof: no Nix uninstall step
can mask a lifecycle failure.

## Guest posture and endpoint law

Preflight must prove all of the following before application mutation:

- UID 0 on Wolfi;
- iptables 1.8.x on the `nf_tables` backend (the standalone `nft` program is
  not required);
- the admitted full runtime version, checked independently twice: `k3s
  --version` and the Kubernetes server `gitVersion` must both equal
  `v1.33.1+k3s1`. The create selector `--enable=kubernetes:1.33` is derived from
  that same admitted value, so a platform-default minor cannot pass;
- one Ready node, observed pod CIDR, and recorded CPU/memory capacity;
- the admitted `10.143.0.0/16` service CIDR, read from the one
  `networking.k8s.io/v1` `ServiceCIDR` object named `kubernetes`. Namespace
  exposes neither k3s argv nor a k3s config file on the measured instance, and a
  single ClusterIP or route cannot establish a range, so an unobservable object
  is a precise red rather than an inferred value;
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
   return 4-tuple, never a blanket `ESTABLISHED,RELATED` exception. That tuple
   comes from `SSH_CONNECTION` whenever the variable is set at all. It is then
   the only source: it must be exactly one line of four space-separated numeric
   fields whose client and server are concrete non-wildcard IPv4 addresses,
   whose client port is in range, and whose server port is exactly 22. An empty,
   malformed, wrong-port, or multi-line value refuses and never falls back.
   Only when the variable is completely unset may `/sbin/ss` be read
   numerically, and only a single ESTABLISHED IPv4 TCP socket with a
   concrete local port 22 is admitted; zero, multiple, IPv6, wildcard, or
   wrong-port observations refuse before any chain exists. That read carries no
   `state` filter on purpose, because iproute2 omits the State column whenever
   one is supplied, which would rest the established claim on the argument
   rather than on an observed value.

   On that fallback the literal `/sbin/ss -H -n -t -4` runs **exactly once**
   and its exact stdout is atomically retained as a regular mode-0600
   `orchestration/ss-observation.txt` inside the run's evidence staging tree.
   The parser consumes those retained bytes, so the flow written into the rules
   and the bytes kept in the proof bundle are one observation rather than two
   reads of a table that can change between them. Observation, create, write,
   rename, mode, hash, or bind failure refuses before any chain exists.

   The policy transcript records `orchestrationTupleSource` as
   `ssh-environment` or `kernel-ss` alongside the unchanged
   `orchestrationException: exact-ssh-4-tuple` claim, and binds the observation
   so it is independently checkable rather than merely asserted:
   `orchestrationTuple` (the canonical selected client/server address and port),
   `orchestrationFlowCount` (the measured selected-flow count, exactly one),
   `orchestrationSelectedRow` (the exact observed line the tuple was derived
   from), `orchestrationObservationDigest`, and
   `orchestrationObservationArtifact` — the retained artifact's stable relative
   name for `kernel-ss`, or `null` for `ssh-environment`, where the admitted
   one-line value is itself the whole observation and its digest is the binding.
   A reader can therefore recompute the digest from the proof bundle, find the
   selected row verbatim in the retained bytes, and confirm the exact tuple the
   rules used without re-running the parser. The observation directory must be a
   real driver-owned directory: a symlinked component refuses rather than
   writing same-session evidence outside the tree;
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
- exact `nsc` v0.0.532 release-artifact and executable digests in the receipt
  and report;
- a schema-free guest-Nix identity receipt whose digest agrees with preflight
  and is bound by the `instance-preflight` checkpoint;
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
authority are never published. Every scanned surface must be a completely
readable regular-file/directory tree: grep errors, links, FIFOs, devices,
sockets, and other special objects are
`EvidenceLeakageInterfaceUnavailable`, and stale report/proof outputs are
removed before returning red.

## Local verification

`scripts/ci/test-environment-contract.sh` uses a local fake `nsc` implementing
only the measured v0.0.532 surface. It covers exact identity/destroy/absence,
release/executable identity drift, unsafe archive names and all special member
types, pre-create refusals, remote revalidation, SSH and collection loss,
unreadable/special proof suppression, grep status errors, stale-artifact
removal, destroy failure, signals, parallel tuple isolation, report namespaces,
policy probes/removal, leakage, checkpoint chains, forbidden substrate strings,
and the hostile guest-Nix acquisition/install/identity matrix. It also checks
the collected kernel-socket observation against the digest bound in collected
`policy.json`; production keeps the dual-source socket contract unchanged.

Run the canonical gates from the generated repository's CI shell:

```bash
./scripts/ci/test-environment-contract.sh
shellcheck scripts/ci/*.sh
actionlint
check-jsonschema --check-metaschema schemas/ci/*.schema.json
```

The shell includes the ordinary Unix/Kubernetes tools used by the driver and a
locally declared Namespace CLI derivation. The derivation fixes v0.0.532 by the
official per-platform release archive hash, exports an absolute store path,
and writes a post-fixup executable identity record. The lifecycle refuses any
other version or binary before `nsc create` and records both digests in its
receipt and report.

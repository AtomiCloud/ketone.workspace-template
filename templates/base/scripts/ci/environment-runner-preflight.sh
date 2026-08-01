#!/usr/bin/env bash
# In-guest Namespace posture proof. The orchestrator has already bound the
# exact cidfile/metadata cluster_id before this script runs over that same
# exact-id SSH channel. This script proves the measured Wolfi/root,
# single-node built-in-k3s, storage, network and iptables-nft facts before any
# application or vendor mutation.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/environment-lib.sh"

output=${DIENE_PREFLIGHT_EVIDENCE:-${RUNNER_TEMP:-/tmp}/diene-runner-preflight.json}
while (($#)); do
  case $1 in
    --output)
      output=${2:?preflight output required}
      shift 2
      ;;
    *) diene_die InputContractInvalid "unknown runner-preflight argument $1" ;;
  esac
done

for command in jq stat id ip awk sed grep sha256sum readlink cmp uname; do
  diene_require_command "$command"
done
kubectl_bin=${DIENE_KUBECTL_BIN:-kubectl}
iptables_bin=${DIENE_IPTABLES_BIN:-/sbin/iptables}
ip6tables_bin=${DIENE_IP6TABLES_BIN:-/sbin/ip6tables}
diene_require_command "$kubectl_bin"
diene_require_command "$iptables_bin"
diene_require_command k3s

[[ $(id -u) == 0 ]] ||
  diene_die InstancePostureUnavailable 'Namespace Wolfi driver must run as root'
diene_require_safe_id cluster_id "${DIENE_NSC_CLUSTER_ID:-}"
[[ ${DIENE_CACHE_ATTACHED:-false} =~ ^(true|false)$ ]] ||
  diene_die InstancePostureUnavailable 'cache attachment evidence is invalid'
case ${DIENE_LANE:?} in
  absol | fleet-independence)
    [[ $DIENE_CACHE_ATTACHED == false ]] ||
      diene_die InstancePostureUnavailable "$DIENE_LANE must not attach a shared cache"
    ;;
esac

[[ -r /etc/os-release ]] || diene_die InstancePostureUnavailable '/etc/os-release is absent'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == wolfi ]] || diene_die InstancePostureUnavailable "instance OS is ${ID:-unknown}, expected wolfi"
os_version=${VERSION_ID:-rolling}

iptables_version=$($iptables_bin --version)
[[ $iptables_version == *nf_tables* ]] ||
  diene_die InstancePostureUnavailable 'iptables is not the measured nf_tables backend'
ipv6_disabled=0
[[ ! -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] ||
  read -r ipv6_disabled </proc/sys/net/ipv6/conf/all/disable_ipv6
if [[ $ipv6_disabled != 1 ]]; then
  diene_require_command "$ip6tables_bin"
  [[ $($ip6tables_bin --version) == *nf_tables* ]] ||
    diene_die InstancePostureUnavailable 'ip6tables is not the measured nf_tables backend'
fi

k3s_version=$(k3s --version | awk '/^k3s version / {print $3; exit}') ||
  diene_die InstancePostureUnavailable 'the built-in k3s version is unavailable'
kubernetes_version=$($kubectl_bin version -o json | jq -er '.serverVersion.gitVersion') ||
  diene_die InstancePostureUnavailable 'Kubernetes server version is unavailable'
# Both observations must equal the same admitted full version before any policy
# or application mutation. The k3s binary is not authority for the served
# control plane, so a split runtime is a refusal, not a warning.
diene_require_admitted_k3s_runtime "${DIENE_ADMITTED_K3S_VERSION:-}" \
  "$k3s_version" "$kubernetes_version"

# Refined-by the generation-9 direct-binary ruling: the pre-Nix rail has
# already verified and executed the pinned payload. Re-source the one exact
# profile, then independently bind direct-path runtime identity before any
# policy or application mutation. The canonical receipt is schema-free and is
# packaged with the complete evidence tree.
diene_source_guest_nix_profile "$DIENE_GUEST_NIX_PROFILE"
guest_nix_evidence=$(diene_guest_nix_evidence_dir) || exit $?
guest_nix=$(diene_guest_nix_identity "${DIENE_GUEST_NIX_INPUT:?}" "$guest_nix_evidence" \
  "$DIENE_GUEST_NIX_BIN" "$DIENE_GUEST_NIX_STORE_ROOT" "$DIENE_GUEST_NIX_INSTALLED_COPY" \
  "${DIENE_GUEST_NIX_INSTALLER_PATH:?}" "${DIENE_GUEST_NIX_PAYLOAD_PATH:?}" "$(uname -m)") || exit $?
guest_nix_environment_digest=$(jq -er '.environmentDigest' <<<"$guest_nix") ||
  diene_die GuestNixIdentityUnexpected \
    'guest Nix identity omitted the sanitized environment evidence digest'
diene_require_digest guest-nix-environment-digest "$guest_nix_environment_digest"

nodes=$($kubectl_bin get nodes -o json)
jq -e '
  (.items | length) == 1 and
  (.items[0].status.conditions | any(.type == "Ready" and .status == "True")) and
  (.items[0].spec.podCIDR | type == "string" and length > 0)
' <<<"$nodes" >/dev/null ||
  diene_die InstancePostureUnavailable 'built-in k3s is not one Ready node with an observed pod CIDR'
node_count=$(jq -r '.items | length' <<<"$nodes")
cpu=$(jq -er '.items[0].status.capacity.cpu' <<<"$nodes")
memory=$(jq -er '.items[0].status.capacity.memory' <<<"$nodes")
pod_cidrs=$(jq -c '[.items[0].spec.podCIDRs[]?] | if length == 0 then [.items[0].spec.podCIDR] else . end' <<<"$nodes")

# The admitted service range is read from the one API object the apiserver
# derives from --service-cluster-ip-range. Namespace does not expose k3s argv or
# a k3s config file on the measured instance, and a single ClusterIP or a route
# cannot establish a range, so an unobservable object is a precise red instead
# of an inferred value.
service_cidr=$(diene_observe_admitted_service_cidr "${DIENE_K3S_SERVICE_CIDR:-}")
service_cidrs=$(jq -cn --arg cidr "$service_cidr" '[$cidr]')

storage=$($kubectl_bin get storageclass -o json)
jq -e '
  [.items[] | select(
    .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
    .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")]
  | length == 1 and .[0].metadata.name == "local-path"
' <<<"$storage" >/dev/null ||
  diene_die InstancePostureUnavailable 'the sole default StorageClass is not local-path'

ingress=$($kubectl_bin get ingress -A -o json 2>/dev/null || printf '{"items":[]}\n')
gateways=$($kubectl_bin get gateway -A -o json 2>/dev/null || printf '{"items":[]}\n')
services=$($kubectl_bin get service -A -o json)
jq -e '(.items // []) | length == 0' <<<"$ingress" >/dev/null ||
  diene_die EndpointLawViolation 'Kubernetes ingress exists before workload mutation'
jq -e '(.items // []) | length == 0' <<<"$gateways" >/dev/null ||
  diene_die EndpointLawViolation 'Gateway exists before workload mutation'
jq -e '
  (.items // []) | all(
    .spec.type != "LoadBalancer" and ((.spec.externalIPs // []) | length == 0))
' <<<"$services" >/dev/null ||
  diene_die EndpointLawViolation 'public/external Service exists before workload mutation'

jq -n \
  --arg clusterId "$DIENE_NSC_CLUSTER_ID" --arg osId "$ID" --arg osVersion "$os_version" \
  --arg k3sVersion "$k3s_version" --arg kubernetesVersion "$kubernetes_version" \
  --arg cpu "$cpu" --arg memory "$memory" --arg iptablesVersion "$iptables_version" \
  --argjson nodeCount "$node_count" --argjson podCidrs "$pod_cidrs" \
  --argjson serviceCidrs "$service_cidrs" --argjson ipv6Disabled "$ipv6_disabled" \
  --argjson cacheAttached "$DIENE_CACHE_ATTACHED" --argjson guestNix "$guest_nix" '
  {outcome:"Pass",reasonCode:"NamespaceWolfiBuiltInK3sReady",
   clusterId:$clusterId,identitySource:"cidfile-metadata-exact-id-ssh",
   os:{id:$osId,version:$osVersion,uid:0},
   k3s:{version:$k3sVersion,kubernetesVersion:$kubernetesVersion,nodeCount:$nodeCount,
        capacity:{cpu:$cpu,memory:$memory}},
   network:{podCidrs:$podCidrs,serviceCidrs:$serviceCidrs,ipv6Disabled:($ipv6Disabled == 1),
            namespaceIngress:false,publicBinding:false},
   storage:{defaultClass:"local-path"},
   policyBackend:{mechanism:"iptables",backend:"nf_tables",version:$iptablesVersion},
   guestNix:$guestNix,
   cacheAttached:$cacheAttached,
   platformStatus:"platform per-instance policy pending (support ask #4)"}' |
  diene_write_json "$output"

diene_require_guest_nix_preflight_agreement "$output" "$guest_nix_evidence/identity.json"

printf 'NamespaceInstanceReady: %s\n' "$DIENE_NSC_CLUSTER_ID"

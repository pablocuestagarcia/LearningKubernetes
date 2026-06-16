#!/usr/bin/env bash
#
# Dedicate two worker nodes of the running `cka` cluster to storage.
#
# Use this on a cluster that is ALREADY running (created before the storage
# changes in setup/kind-cka.yaml). It labels and taints the last two workers so
# that BOTH are usable by all storage systems (MinIO + Longhorn):
#   * role label   node-role.cka/role=storage
#   * role label   node-role.kubernetes.io/storage
#   * taint        dedicated=storage:NoSchedule   (keeps general workloads off)
#
# Distribution comes from each storage system spreading across the two nodes
# (MinIO: 4-drive erasure set over 2 nodes; Longhorn: 1 replica per node).
#
# If you recreate the cluster from setup/kind-cka.yaml this is unnecessary —
# the labels and taints are baked into the node definitions.
set -euo pipefail

CONTEXT="${CONTEXT:-kind-cka}"
NODES=("${@:-cka-worker5 cka-worker6}")
# Allow "cka-worker5 cka-worker6" as a single arg or separate args.
read -r -a NODES <<< "${NODES[*]:-cka-worker5 cka-worker6}"

for node in "${NODES[@]}"; do
  echo "Dedicating ${node} to storage..."
  kubectl --context "$CONTEXT" label node "$node" \
    node-role.cka/role=storage \
    node-role.kubernetes.io/storage= --overwrite
  # Drop the old block/object specialisation if present (both nodes are now shared).
  kubectl --context "$CONTEXT" label node "$node" 'storage.lab/type-' 2>/dev/null || true
  kubectl --context "$CONTEXT" taint node "$node" \
    dedicated=storage:NoSchedule --overwrite
done

echo
echo "Storage nodes:"
kubectl --context "$CONTEXT" get nodes -l node-role.kubernetes.io/storage -o wide

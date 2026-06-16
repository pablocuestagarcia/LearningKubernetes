#!/usr/bin/env bash
#
# Manage the CKA practice kind cluster (2 control-plane + 6 workers).
#
# Usage:
#   ./cluster.sh up         # create the cluster
#   ./cluster.sh status     # show nodes
#   ./cluster.sh down       # delete the cluster
#   ./cluster.sh kubeconfig # point kubectl at the cluster
set -euo pipefail

CLUSTER_NAME="cka"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/kind-cka.yaml"

assert_tooling() {
  for tool in kind kubectl docker; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Required tool '$tool' was not found on PATH." >&2
      exit 1
    fi
  done
}

cluster_exists() {
  kind get clusters | grep -qx "$CLUSTER_NAME"
}

assert_tooling

action="${1:-status}"
case "$action" in
  up)
    if cluster_exists; then
      echo "Cluster '$CLUSTER_NAME' already exists. Nothing to do."
    else
      echo "Creating cluster '$CLUSTER_NAME' (2 control-plane + 6 workers)..."
      kind create cluster --config "$CONFIG_FILE"
    fi
    kubectl --context "kind-${CLUSTER_NAME}" get nodes -o wide
    ;;
  down)
    if cluster_exists; then
      echo "Deleting cluster '$CLUSTER_NAME'..."
      kind delete cluster --name "$CLUSTER_NAME"
    else
      echo "Cluster '$CLUSTER_NAME' does not exist."
    fi
    ;;
  status)
    if cluster_exists; then
      kubectl --context "kind-${CLUSTER_NAME}" get nodes -o wide
    else
      echo "Cluster '$CLUSTER_NAME' is not running. Use './cluster.sh up' to create it."
    fi
    ;;
  kubeconfig)
    kind export kubeconfig --name "$CLUSTER_NAME"
    echo "kubeconfig context set to 'kind-${CLUSTER_NAME}'."
    ;;
  *)
    echo "Unknown action '$action'. Use: up | down | status | kubeconfig" >&2
    exit 1
    ;;
esac

#requires -Version 5.1
<#
.SYNOPSIS
    Dedicate two worker nodes of the running `cka` cluster to storage.

.DESCRIPTION
    Use this on a cluster that is ALREADY running (created before the storage
    changes in setup/kind-cka.yaml). It labels and taints the last two workers
    so that BOTH are usable by all storage systems (MinIO + Longhorn):
      * role label   node-role.cka/role=storage
      * role label   node-role.kubernetes.io/storage
      * taint        dedicated=storage:NoSchedule   (keeps general workloads off)

    Distribution comes from each storage system spreading across the two nodes
    (MinIO: 4-drive erasure set over 2 nodes; Longhorn: 1 replica per node).

    If you recreate the cluster from setup/kind-cka.yaml this is unnecessary —
    the labels and taints are baked into the node definitions.
#>
[CmdletBinding()]
param(
    [string]$Context = 'kind-cka',
    [string[]]$Nodes = @('cka-worker5', 'cka-worker6')
)

$ErrorActionPreference = 'Stop'

foreach ($node in $Nodes) {
    Write-Host "Dedicating $node to storage..." -ForegroundColor Cyan
    kubectl --context $Context label node $node `
        node-role.cka/role=storage `
        node-role.kubernetes.io/storage= --overwrite
    # Drop the old block/object specialisation if present (both nodes are now shared).
    kubectl --context $Context label node $node 'storage.lab/type-' 2>$null
    kubectl --context $Context taint node $node `
        dedicated=storage:NoSchedule --overwrite
}

Write-Host "`nStorage nodes:" -ForegroundColor Green
kubectl --context $Context get nodes -l node-role.kubernetes.io/storage -o wide

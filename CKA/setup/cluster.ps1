#requires -Version 5.1
<#
.SYNOPSIS
    Manage the CKA practice kind cluster.

.DESCRIPTION
    Thin wrapper around `kind` to create/delete/inspect the 2 control-plane +
    6 worker cluster defined in kind-cka.yaml.

.EXAMPLE
    ./cluster.ps1 up        # create the cluster
    ./cluster.ps1 status    # show nodes
    ./cluster.ps1 down      # delete the cluster
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'down', 'status', 'kubeconfig')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

$ClusterName = 'cka'
$ConfigFile = Join-Path $PSScriptRoot 'kind-cka.yaml'

function Assert-Tooling {
    foreach ($tool in 'kind', 'kubectl', 'docker') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Required tool '$tool' was not found on PATH."
        }
    }
}

function Test-ClusterExists {
    return (kind get clusters) -contains $ClusterName
}

Assert-Tooling

switch ($Action) {
    'up' {
        if (Test-ClusterExists) {
            Write-Host "Cluster '$ClusterName' already exists. Nothing to do." -ForegroundColor Yellow
        }
        else {
            Write-Host "Creating cluster '$ClusterName' (2 control-plane + 6 workers)..." -ForegroundColor Cyan
            kind create cluster --config $ConfigFile
        }
        kubectl --context "kind-$ClusterName" get nodes -o wide
    }
    'down' {
        if (Test-ClusterExists) {
            Write-Host "Deleting cluster '$ClusterName'..." -ForegroundColor Cyan
            kind delete cluster --name $ClusterName
        }
        else {
            Write-Host "Cluster '$ClusterName' does not exist." -ForegroundColor Yellow
        }
    }
    'status' {
        if (Test-ClusterExists) {
            kubectl --context "kind-$ClusterName" get nodes -o wide
        }
        else {
            Write-Host "Cluster '$ClusterName' is not running. Use './cluster.ps1 up' to create it." -ForegroundColor Yellow
        }
    }
    'kubeconfig' {
        kind export kubeconfig --name $ClusterName
        Write-Host "kubeconfig context set to 'kind-$ClusterName'." -ForegroundColor Green
    }
}

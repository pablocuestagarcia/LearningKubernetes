#requires -Version 5.1
<#
.SYNOPSIS
    Desplegar la PLATAFORMA (apps) sobre el cluster CKA multipass, vía Helm.

.DESCRIPTION
    Segunda fase, después de cluster.ps1. Instala —en orden de dependencia y de
    forma idempotente (helm upgrade --install)— la capa de almacenamiento y
    monitoreo del lab:

      1. local-path-provisioner -> StorageClass por DEFECTO (disco local del nodo).
         Debe ir primero: MinIO la consume. Al marcarla default, MinIO y cualquier
         otro chart pueden omitir 'storageClassName'.
      2. kube-prometheus-stack  -> Prometheus para las gráficas de FreeLens.
      3. MinIO (objetos, S3)     -> usa la StorageClass por defecto (local-path).
      4. Longhorn (bloques) + su StorageClass 'longhorn-block'.

    Helm y kubectl se ejecutan EN EL HOST contra ./kubeconfig (igual que la acción
    'prometheus' de cluster.ps1). Todas las versiones van PINNEADAS para que un
    down/up de mañana reproduzca lo mismo.

.EXAMPLE
    ./cluster.ps1 up                  # 1) infraestructura: VMs + kubeadm + CNI + metrics
    ./stack.ps1 up                    # 2) plataforma: local-path + Prometheus + MinIO + Longhorn
    ./stack.ps1 up -Components minio  # solo MinIO (instala local-path si falta)
    ./stack.ps1 status
    ./stack.ps1 down                  # desinstala la plataforma (NO toca el cluster)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'down', 'status')]
    [string]$Action = 'status',

    # Qué componentes tocar. 'all' = todos. Se pueden combinar: -Components minio,longhorn
    [ValidateSet('all', 'localpath', 'prometheus', 'minio', 'longhorn')]
    [string[]]$Components = @('all'),

    # --- Versiones pinneadas (reproducibilidad) ---
    [string]$LocalPathVersion = 'v0.0.30',
    [string]$PrometheusChartVersion = '86.2.3',   # kube-prometheus-stack
    [string]$MinioChartVersion = '5.4.0',         # minio/minio
    [string]$LonghornVersion = '1.7.2'
)

$ErrorActionPreference = 'Stop'

# --- Rutas (relativas al script, igual que cluster.ps1) ---
$KubeconfigOut    = Join-Path $PSScriptRoot 'kubeconfig'
$PrometheusValues = Join-Path $PSScriptRoot '..\..\monitoring\prometheus\values.yaml'
$MinioValues      = Join-Path $PSScriptRoot '..\..\storage\object\values.yaml'
$LonghornValues   = Join-Path $PSScriptRoot '..\..\storage\block\values.yaml'
$LonghornSc       = Join-Path $PSScriptRoot '..\..\storage\block\storageclass.yaml'
$LocalPathManifest = "https://raw.githubusercontent.com/rancher/local-path-provisioner/$LocalPathVersion/deploy/local-path-storage.yaml"

# ¿Se ha pedido este componente? ('all' los incluye todos)
function Test-Wants([string]$Name) {
    return ($Components -contains 'all') -or ($Components -contains $Name)
}

# helm/kubectl en el host contra ./kubeconfig.
function Assert-Prereqs {
    foreach ($tool in 'helm', 'kubectl') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool no encontrado en el host. Instálalo (winget install Helm.Helm / Kubernetes.kubectl)."
        }
    }
    if (-not (Test-Path $KubeconfigOut)) {
        throw "No existe $KubeconfigOut. Ejecuta antes './cluster.ps1 up'."
    }
    $env:KUBECONFIG = $KubeconfigOut
}

function Add-HelmRepo([string]$Name, [string]$Url) {
    helm repo add $Name $Url 2>$null | Out-Null
}

# 1. local-path-provisioner como StorageClass por defecto.
function Install-LocalPath {
    Write-Host "[localpath] local-path-provisioner $LocalPathVersion (StorageClass default)..." -ForegroundColor Cyan
    kubectl apply -f $LocalPathManifest
    kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
    # Marcar default sin pelear con el escaping de JSON en PowerShell 5.1.
    kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
    Write-Host "[localpath] OK: 'local-path' es la StorageClass por defecto." -ForegroundColor Green
}

# 2. kube-prometheus-stack (recortado; ver monitoring/prometheus/values.yaml).
function Install-Prometheus {
    Write-Host "[prometheus] kube-prometheus-stack $PrometheusChartVersion..." -ForegroundColor Cyan
    Add-HelmRepo 'prometheus-community' 'https://prometheus-community.github.io/helm-charts'
    helm repo update prometheus-community | Out-Null
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
        --version $PrometheusChartVersion --namespace monitoring --create-namespace `
        --values $PrometheusValues --wait --timeout 10m
    Write-Host "[prometheus] OK. En FreeLens -> Settings -> Metrics apunta a:" -ForegroundColor Green
    Write-Host "             monitoring/kube-prometheus-stack-prometheus:9090" -ForegroundColor Green
}

# 3. MinIO distribuido (objetos). Usa la StorageClass por defecto (local-path).
function Install-Minio {
    Write-Host "[minio] minio/minio $MinioChartVersion (objetos, S3)..." -ForegroundColor Cyan
    Add-HelmRepo 'minio' 'https://charts.min.io/'
    helm repo update minio | Out-Null
    helm upgrade --install minio minio/minio --version $MinioChartVersion `
        --namespace minio --create-namespace `
        --values $MinioValues --wait --timeout 10m
    Write-Host "[minio] OK: 2 pods x 2 drives = 4-drive erasure set." -ForegroundColor Green
}

# 4. Longhorn (bloques) + su StorageClass personalizada.
function Install-Longhorn {
    Write-Host "[longhorn] longhorn/longhorn $LonghornVersion (bloques, CSI)..." -ForegroundColor Cyan
    Add-HelmRepo 'longhorn' 'https://charts.longhorn.io'
    helm repo update longhorn | Out-Null
    helm upgrade --install longhorn longhorn/longhorn --version $LonghornVersion `
        --namespace longhorn-system --create-namespace `
        --values $LonghornValues --wait --timeout 15m
    # Longhorn YA crea una SC 'longhorn'; esta añade la personalizada 'longhorn-block'.
    kubectl apply -f $LonghornSc
    Write-Host "[longhorn] OK. SCs: 'longhorn' (auto) + 'longhorn-block' (custom)." -ForegroundColor Green
}

function Show-Status {
    Write-Host "== Helm releases ==" -ForegroundColor Cyan
    helm list -A
    Write-Host "`n== StorageClasses ==" -ForegroundColor Cyan
    kubectl get sc
    foreach ($ns in 'local-path-storage', 'monitoring', 'minio', 'longhorn-system') {
        Write-Host "`n== pods/$ns ==" -ForegroundColor Cyan
        kubectl -n $ns get pods 2>$null
    }
}

# Desinstala en orden INVERSO. Best-effort: un fallo no aborta el resto
# (los comandos nativos con exit !=0 no lanzan excepción en PowerShell).
function Remove-Stack {
    if (Test-Wants 'longhorn') {
        Write-Host "[longhorn] desinstalando..." -ForegroundColor Yellow
        kubectl delete -f $LonghornSc --ignore-not-found
        # Longhorn exige confirmar el borrado mediante un Setting (evita borrados accidentales).
        $tmp = Join-Path $env:TEMP 'lh-confirm.json'
        Set-Content -Path $tmp -Value '{"value":"true"}' -Encoding ascii
        kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag --type=merge --patch-file $tmp 2>$null
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        helm uninstall longhorn -n longhorn-system 2>$null
    }
    if (Test-Wants 'minio') {
        Write-Host "[minio] desinstalando..." -ForegroundColor Yellow
        helm uninstall minio -n minio 2>$null
        # Los PVCs de un StatefulSet NO se borran con helm uninstall.
        kubectl -n minio delete pvc --all 2>$null
    }
    if (Test-Wants 'prometheus') {
        Write-Host "[prometheus] desinstalando..." -ForegroundColor Yellow
        helm uninstall kube-prometheus-stack -n monitoring 2>$null
    }
    if (Test-Wants 'localpath') {
        Write-Host "[localpath] desinstalando..." -ForegroundColor Yellow
        kubectl delete -f $LocalPathManifest --ignore-not-found
    }
    Write-Host "Plataforma desinstalada (el cluster sigue intacto)." -ForegroundColor Green
}

Assert-Prereqs

switch ($Action) {
    'up' {
        # local-path va primero y también si se pide MinIO (lo consume).
        if ((Test-Wants 'localpath') -or (Test-Wants 'minio')) { Install-LocalPath }
        if (Test-Wants 'prometheus') { Install-Prometheus }
        if (Test-Wants 'minio')      { Install-Minio }
        if (Test-Wants 'longhorn')   { Install-Longhorn }
        Write-Host ""
        Show-Status
    }
    'down'   { Remove-Stack }
    'status' { Show-Status }
}

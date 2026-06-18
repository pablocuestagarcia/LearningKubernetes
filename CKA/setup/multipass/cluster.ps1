#requires -Version 5.1
<#
.SYNOPSIS
    Levantar un cluster kubeadm multi-nodo sobre VMs Multipass (Hyper-V).

.DESCRIPTION
    Variante de "VMs reales" del entorno CKA, pensada para correr soluciones que
    necesitan un kernel completo (p. ej. Longhorn, que requiere iSCSI y NO
    funciona sobre kind/WSL2).

    Topología por defecto: 1 control-plane + 2 workers de workloads + 2 data
    nodes dedicados a storage (5 VMs). Los data nodes se etiquetan y taintean
    igual que en la variante kind (node-role.kubernetes.io/storage +
    dedicated=storage:NoSchedule), así que:
      * los values de MinIO/Longhorn de CKA/storage sirven sin cambios;
      * con 2 data nodes hay réplicas de datos reales (1 por nodo);
      * los workers normales quedan libres para las cargas de aplicación.

.EXAMPLE
    ./cluster.ps1 up                       # 1 CP + 2 workers + 2 data nodes
    ./cluster.ps1 up -Workers 3 -DataNodes 3
    ./cluster.ps1 up -WorkerMemory 4G      # workers a 4 GB, CP y data a 2 GB
    ./cluster.ps1 status
    ./cluster.ps1 down
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'down', 'status', 'kubeconfig', 'cni', 'metrics')]
    [string]$Action = 'status',

    [int]$Workers = 2,                 # nodos de workloads (sin taint)
    [int]$DataNodes = 2,               # nodos de datos/storage (label + taint)
    [string]$Image = '24.04',
    [string]$Cpus = '2',
    [string]$Memory = '2G',            # memoria base (control-plane y, por defecto, el resto)
    [string]$WorkerMemory = '',        # memoria de los workers de workloads (vacío = $Memory)
    [string]$DataMemory = '',          # memoria de los data nodes (vacío = $Memory)
    [string]$Disk = '20G',             # disco de CP y workers
    [string]$DataDisk = '30G',         # disco mayor para los data nodes
    [string]$PodCidr = '10.244.0.0/16',

    [ValidateSet('flannel', 'calico', 'cilium')]
    [string]$Cni = 'flannel',          # CNI a instalar (cilium = datapath eBPF)
    [bool]$MetricsServer = $true        # instalar metrics-server (kubectl top / HPA)
)

$ErrorActionPreference = 'Stop'

if ($DataNodes -lt 2 -and $Action -eq 'up') {
    Write-Host "Aviso: con menos de 2 data nodes no hay réplicas de datos." -ForegroundColor Yellow
}

$CpName = 'cka-cp'

# Memoria por rol: si no se pasa override, se usa la base ($Memory).
if (-not $WorkerMemory) { $WorkerMemory = $Memory }
if (-not $DataMemory)   { $DataMemory   = $Memory }

# Especificación de nodos: nombre, rol, disco y memoria.
$NodeSpecs = @()
$NodeSpecs += [pscustomobject]@{ Name = $CpName; Role = 'control-plane'; Disk = $Disk; Memory = $Memory }
1..$Workers   | ForEach-Object { $NodeSpecs += [pscustomobject]@{ Name = "cka-w$_";    Role = 'worker';  Disk = $Disk;     Memory = $WorkerMemory } }
1..$DataNodes | ForEach-Object { $NodeSpecs += [pscustomobject]@{ Name = "cka-data$_"; Role = 'storage'; Disk = $DataDisk; Memory = $DataMemory } }

$WorkerSpecs = $NodeSpecs | Where-Object { $_.Role -ne 'control-plane' }
$DataSpecs   = $NodeSpecs | Where-Object { $_.Role -eq 'storage' }
$CloudInit = Join-Path $PSScriptRoot 'cloud-init.yaml'
$KubeconfigOut = Join-Path $PSScriptRoot 'kubeconfig'

function Assert-Tooling {
    if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
        throw "Multipass no encontrado. Instálalo con: winget install Canonical.Multipass"
    }
}

function Test-VmExists([string]$Name) {
    return (multipass list --format csv | Select-String -Pattern "^$Name,") -ne $null
}

function Get-VmIp([string]$Name) {
    $json = multipass info $Name --format json | ConvertFrom-Json
    return $json.info.$Name.ipv4[0]
}

function Invoke-OnVm([string]$Name, [string]$Cmd) {
    multipass exec $Name -- sudo bash -c $Cmd
}

# Ejecuta un comando en la VM y devuelve $true si su exit code fue 0.
# (Un comando nativo con exit !=0 NO lanza excepción en PowerShell, así que no se
#  puede usar try/catch para detectar fallos: hay que mirar $LASTEXITCODE.)
function Test-OnVm([string]$Name, [string]$Cmd) {
    multipass exec $Name -- sudo bash -c $Cmd 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# kubectl en el control-plane usando el admin.conf.
# OJO: el parámetro NO puede llamarse $Args (variable automática de PowerShell).
function Invoke-Kubectl([string]$CmdArgs) {
    Invoke-OnVm $CpName "KUBECONFIG=/etc/kubernetes/admin.conf kubectl $CmdArgs"
}

# Exporta el admin.conf del control-plane al host.
# Usa 'multipass transfer' (escribe el fichero directamente): canalizar la salida
# de 'multipass exec' a Set-Content se cuelga en Windows con ficheros grandes.
function Export-Kubeconfig {
    Invoke-OnVm $CpName 'cp /etc/kubernetes/admin.conf /home/ubuntu/admin.conf && chown ubuntu:ubuntu /home/ubuntu/admin.conf'
    if (Test-Path $KubeconfigOut) { Remove-Item $KubeconfigOut -Force }
    multipass transfer "${CpName}:/home/ubuntu/admin.conf" $KubeconfigOut 2>$null
    Invoke-OnVm $CpName 'rm -f /home/ubuntu/admin.conf'
    Write-Host "kubeconfig escrito en: $KubeconfigOut" -ForegroundColor Green
    Write-Host "Úsalo con:  `$env:KUBECONFIG = '$KubeconfigOut'" -ForegroundColor Green
}

# Instala el CNI elegido (-Cni). Todo se ejecuta en el control-plane.
function Install-Cni {
    Write-Host "Instalando CNI: $Cni..." -ForegroundColor Cyan
    switch ($Cni) {
        'flannel' {
            # La red por defecto de Flannel coincide con $PodCidr (10.244.0.0/16).
            Invoke-Kubectl 'apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml'
        }
        'calico' {
            # Operador Tigera + recurso Installation con NUESTRO CIDR.
            Invoke-Kubectl 'create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml'
            $calico = @'
cat <<'EOF' >/tmp/calico-installation.yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: __PODCIDR__
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f /tmp/calico-installation.yaml
'@
            Invoke-OnVm $CpName $calico.Replace('__PODCIDR__', $PodCidr)
        }
        'cilium' {
            # Datapath eBPF. Se instala con la CLI de Cilium (auto-detecta kubeadm).
            $cilium = @'
set -e
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -sL --fail https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz -o /tmp/cilium.tgz
tar -C /usr/local/bin -xzf /tmp/cilium.tgz
KUBECONFIG=/etc/kubernetes/admin.conf cilium install --set ipam.operator.clusterPoolIPv4PodCIDRList=__PODCIDR__
'@
            Invoke-OnVm $CpName $cilium.Replace('__PODCIDR__', $PodCidr)
        }
    }
}

# Instala metrics-server (kubectl top, HPA). En kubeadm los kubelets usan certs
# serving autofirmados, así que hay que añadir --kubelet-insecure-tls.
function Install-MetricsServer {
    Write-Host "Instalando metrics-server..." -ForegroundColor Cyan
    Invoke-Kubectl 'apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml'
    # El patch JSON se pasa en base64 para evitar el mangling de comillas dobles
    # de PowerShell 5.1 al cruzar al proceso nativo (multipass -> bash).
    $patch = '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patch))
    Invoke-OnVm $CpName "echo $b64 | base64 -d >/tmp/ms-patch.json && KUBECONFIG=/etc/kubernetes/admin.conf kubectl patch -n kube-system deployment metrics-server --type=json --patch-file /tmp/ms-patch.json"
}

Assert-Tooling

switch ($Action) {
    'up' {
        # 1. Lanzar VMs con la preparación de cloud-init
        foreach ($spec in $NodeSpecs) {
            if (Test-VmExists $spec.Name) {
                Write-Host "VM $($spec.Name) ya existe, se omite." -ForegroundColor Yellow
            }
            else {
                Write-Host "Lanzando VM $($spec.Name) [$($spec.Role)] (mem $($spec.Memory), disk $($spec.Disk))..." -ForegroundColor Cyan
                multipass launch $Image --name $spec.Name --cpus $Cpus --memory $spec.Memory --disk $spec.Disk --cloud-init $CloudInit
            }
        }

        # 2. Esperar a que cloud-init termine en todas
        foreach ($spec in $NodeSpecs) {
            Write-Host "Esperando a cloud-init en $($spec.Name)..." -ForegroundColor Cyan
            multipass exec $spec.Name -- cloud-init status --wait | Out-Null
        }

        # 3. kubeadm init en el control-plane (si no está ya inicializado)
        $cpIp = Get-VmIp $CpName
        $initialized = Test-OnVm $CpName 'test -f /etc/kubernetes/admin.conf'
        if (-not $initialized) {
            Write-Host "kubeadm init en $CpName ($cpIp)..." -ForegroundColor Cyan
            Invoke-OnVm $CpName "kubeadm init --pod-network-cidr=$PodCidr --apiserver-advertise-address=$cpIp"
        }

        # 4. CNI (seleccionable con -Cni: flannel | calico | cilium)
        Install-Cni

        # 5. Unir los workers (de workloads y data nodes)
        $join = (Invoke-OnVm $CpName 'kubeadm token create --print-join-command' | Where-Object { $_ -match 'kubeadm join' } | Select-Object -Last 1).Trim()
        foreach ($spec in $WorkerSpecs) {
            $alreadyJoined = Test-OnVm $spec.Name 'test -f /etc/kubernetes/kubelet.conf'
            if ($alreadyJoined) {
                Write-Host "$($spec.Name) ya está unido, se omite." -ForegroundColor Yellow
            }
            else {
                Write-Host "Uniendo $($spec.Name) al cluster..." -ForegroundColor Cyan
                Invoke-OnVm $spec.Name $join
            }
        }

        # 6. Roles de nodo
        #    - workers de workloads: label informativo node-role.kubernetes.io/worker
        #    - data nodes: label de storage + taint para dedicarlos
        foreach ($spec in $WorkerSpecs) {
            if ($spec.Role -eq 'storage') {
                Invoke-Kubectl "label node $($spec.Name) node-role.cka/role=storage node-role.kubernetes.io/storage= --overwrite"
                Invoke-Kubectl "taint node $($spec.Name) dedicated=storage:NoSchedule --overwrite"
            }
            else {
                Invoke-Kubectl "label node $($spec.Name) node-role.cka/role=worker node-role.kubernetes.io/worker= --overwrite"
            }
        }

        # 6b. metrics-server (kubectl top / HPA)
        if ($MetricsServer) { Install-MetricsServer }

        # 7. Exportar kubeconfig al host
        Write-Host ""
        Export-Kubeconfig
        Write-Host "`nData nodes (storage): $($DataSpecs.Name -join ', ')" -ForegroundColor Green
        Write-Host ""
        Invoke-Kubectl 'get nodes -o wide --show-labels'
    }
    'down' {
        foreach ($spec in $NodeSpecs) {
            if (Test-VmExists $spec.Name) {
                Write-Host "Eliminando VM $($spec.Name)..." -ForegroundColor Cyan
                multipass delete $spec.Name
            }
        }
        multipass purge
        if (Test-Path $KubeconfigOut) { Remove-Item $KubeconfigOut }
    }
    'status' {
        multipass list
        if (Test-VmExists $CpName) { Invoke-Kubectl 'get nodes -o wide' }
    }
    'kubeconfig' {
        Export-Kubeconfig
    }
    'cni' {
        # Instala el CNI -Cni en un cluster ya existente.
        Install-Cni
    }
    'metrics' {
        # Instala metrics-server en un cluster ya existente.
        Install-MetricsServer
    }
}

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

    [ValidateRange(0, 20)]
    [int]$Workers = 2,                 # nodos de workloads (sin taint); 0 = ninguno
    [ValidateRange(0, 20)]
    [int]$DataNodes = 2,               # nodos de datos/storage (label + taint); 0 = ninguno
    [string]$Image = '24.04',
    [string]$Cpus = '2',
    [string]$Memory = '2G',            # memoria base (control-plane y, por defecto, el resto)
    [string]$WorkerMemory = '',        # memoria de los workers de workloads (vacío = $Memory)
    [string]$DataMemory = '',          # memoria de los data nodes (vacío = $Memory)
    [string]$Disk = '20G',             # disco de CP y workers
    [string]$DataDisk = '30G',         # disco mayor para los data nodes
    [string]$PodCidr = '10.244.0.0/16',

    [ValidateSet('flannel', 'calico', 'cilium', 'none')]
    [string]$Cni = 'flannel',          # CNI a instalar (cilium = eBPF; none = no instalar)
    [bool]$MetricsServer = $true,       # instalar metrics-server (kubectl top / HPA)
    [bool]$Bootstrap = $true            # $false = solo crear/preparar las VMs (practicar kubeadm a mano)
)

$ErrorActionPreference = 'Stop'

if ($Action -eq 'up') {
    if ($DataNodes -eq 0) {
        Write-Host "Aviso: -DataNodes 0 -> sin nodos de storage; los labs de MinIO/Longhorn no podrán programarse." -ForegroundColor Yellow
    }
    elseif ($DataNodes -lt 2) {
        Write-Host "Aviso: con menos de 2 data nodes no hay réplicas de datos." -ForegroundColor Yellow
    }
}

$CpName = 'cka-cp'

# Memoria por rol: si no se pasa override, se usa la base ($Memory).
if (-not $WorkerMemory) { $WorkerMemory = $Memory }
if (-not $DataMemory)   { $DataMemory   = $Memory }

# Especificación de nodos: nombre, rol, disco y memoria.
# Nota: en PowerShell `1..0` NO es vacío, es @(1,0); por eso se guarda con un if
# para que -Workers 0 / -DataNodes 0 creen realmente cero nodos de ese tipo.
$NodeSpecs = @()
$NodeSpecs += [pscustomobject]@{ Name = $CpName; Role = 'control-plane'; Disk = $Disk; Memory = $Memory }
if ($Workers -gt 0) {
    1..$Workers | ForEach-Object { $NodeSpecs += [pscustomobject]@{ Name = "cka-w$_"; Role = 'worker'; Disk = $Disk; Memory = $WorkerMemory } }
}
if ($DataNodes -gt 0) {
    1..$DataNodes | ForEach-Object { $NodeSpecs += [pscustomobject]@{ Name = "cka-data$_"; Role = 'storage'; Disk = $DataDisk; Memory = $DataMemory } }
}

$WorkerSpecs = $NodeSpecs | Where-Object { $_.Role -ne 'control-plane' }
$DataSpecs   = $NodeSpecs | Where-Object { $_.Role -eq 'storage' }
$ProvisionScript = Join-Path $PSScriptRoot 'provision-node.sh'
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

# Transfiere y ejecuta provision-node.sh dentro de la VM (idempotente).
# Aprovisionar por exec (en vez de --cloud-init en el launch) evita que el daemon
# de Multipass en Windows se cuelgue esperando a un cloud-init largo.
function Install-NodePrereqs([string]$Name) {
    multipass transfer $ProvisionScript "${Name}:/tmp/provision-node.sh"
    if ($LASTEXITCODE -ne 0) { throw "No se pudo transferir el script de aprovisionamiento a $Name." }
    multipass exec $Name -- sudo bash /tmp/provision-node.sh
    if ($LASTEXITCODE -ne 0) { throw "Fallo aprovisionando $Name. Revisa la salida de arriba." }
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
    if ($Cni -eq 'none') {
        Write-Host "CNI: ninguno (-Cni none). Los nodos quedaran 'NotReady' hasta que instales uno." -ForegroundColor Yellow
        Write-Host "  Instala uno luego con:  ./cluster.ps1 cni -Cni flannel|calico|cilium" -ForegroundColor Yellow
        return
    }
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
        # 1. Lanzar las VMs base (sin cloud-init).
        #    Se lanzan de una en una con --timeout para que un arranque lento no
        #    bloquee, y con una pausa entre VMs: lanzar varias muy seguidas puede
        #    dejar wedged al daemon de Multipass con el driver Hyper-V.
        for ($i = 0; $i -lt $NodeSpecs.Count; $i++) {
            $spec = $NodeSpecs[$i]
            if (Test-VmExists $spec.Name) {
                Write-Host "VM $($spec.Name) ya existe, se omite." -ForegroundColor Yellow
                continue
            }
            Write-Host "Lanzando VM $($spec.Name) [$($spec.Role)] (mem $($spec.Memory), disk $($spec.Disk))..." -ForegroundColor Cyan
            # Lanzar la VM base SIN cloud-init: el launch solo espera al arranque
            # (rápido), no a una instalación larga. El aprovisionamiento va aparte.
            multipass launch $Image --name $spec.Name --cpus $Cpus --memory $spec.Memory --disk $spec.Disk --timeout 300
            if ($LASTEXITCODE -ne 0) {
                throw "Fallo al lanzar $($spec.Name). Si el daemon quedó colgado: reinicia el servicio (PowerShell admin) con 'Restart-Service Multipass -Force', luego 'multipass delete --all --purge' y reintenta. Ver readme.md (Troubleshooting)."
            }
            if ($i -lt $NodeSpecs.Count - 1) { Start-Sleep -Seconds 5 }
        }

        # 2. Aprovisionar cada nodo (containerd, kubeadm/kubelet, open-iscsi...)
        #    vía exec, con reintentos y progreso visible.
        foreach ($spec in $NodeSpecs) {
            Write-Host "Aprovisionando $($spec.Name) (containerd, kubeadm, open-iscsi)..." -ForegroundColor Cyan
            Install-NodePrereqs $spec.Name
        }

        # 2b. Modo "preparar y parar": VMs listas (containerd, kubeadm, kubelet,
        #     open-iscsi...) pero SIN bootstrap, para practicar kubeadm a mano.
        if (-not $Bootstrap) {
            $cpIp = Get-VmIp $CpName
            Write-Host "`n=== VMs preparadas. Bootstrap omitido (-Bootstrap `$false). ===" -ForegroundColor Green
            Write-Host "Practica kubeadm tú mismo:" -ForegroundColor Green
            Write-Host "  1) En el control-plane:" -ForegroundColor Green
            Write-Host "       multipass shell $CpName" -ForegroundColor Gray
            Write-Host "       sudo kubeadm init --pod-network-cidr=$PodCidr --apiserver-advertise-address=$cpIp" -ForegroundColor Gray
            Write-Host "       mkdir -p `$HOME/.kube && sudo cp /etc/kubernetes/admin.conf `$HOME/.kube/config && sudo chown `$(id -u):`$(id -g) `$HOME/.kube/config" -ForegroundColor Gray
            Write-Host "  2) Instala un CNI (p. ej. Flannel):" -ForegroundColor Green
            Write-Host "       kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" -ForegroundColor Gray
            Write-Host "  3) Token de join:  sudo kubeadm token create --print-join-command" -ForegroundColor Green
            Write-Host "     Y en cada worker ($($WorkerSpecs.Name -join ', ')):  multipass shell <nodo>  ->  sudo kubeadm join ..." -ForegroundColor Gray
            Write-Host "  4) Trae el kubeconfig al host:  ./cluster.ps1 kubeconfig" -ForegroundColor Green
            Write-Host "`nNodos preparados: $($NodeSpecs.Name -join ', ')" -ForegroundColor Green
            return
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

        # 6b. metrics-server (kubectl top / HPA). Sin CNI no tendría red -> se omite.
        if ($MetricsServer -and $Cni -ne 'none') { Install-MetricsServer }
        elseif ($MetricsServer -and $Cni -eq 'none') {
            Write-Host "metrics-server omitido (sin CNI). Instálalo tras el CNI con: ./cluster.ps1 metrics" -ForegroundColor Yellow
        }

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

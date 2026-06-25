# CKA setup — variante Multipass (VMs reales)

Cluster **kubeadm multi-nodo sobre VMs Ubuntu** (Multipass + Hyper-V). Es la
variante a usar cuando necesitas un **kernel Linux completo**: a diferencia de
kind (que comparte el kernel WSL2 sin iSCSI), aquí `open-iscsi` funciona, así
que **Longhorn corre sin problemas**.

> Pensada como complemento a la variante [kind](../) — kind sigue siendo lo
> rápido para el día a día; esta es para almacenamiento que exige kernel real.

## Por qué esta variante

| | kind (../) | Multipass (esta) |
| --- | --- | --- |
| Nodos | contenedores (kernel WSL2 compartido) | VMs Ubuntu (kernel propio) |
| Arranque | segundos | minutos |
| Longhorn / iSCSI | ❌ (kernel sin `iscsi_tcp`) | ✅ |
| MinIO distribuido | ✅ | ✅ |
| Alineado con el examen CKA | medio | **alto** (kubeadm real) |

## Topología

Por defecto **5 VMs**: 1 control-plane + 2 workers de workloads + 2 data nodes
dedicados a storage (~10 GB RAM):

| VM | Rol | Label | Taint |
| --- | --- | --- | --- |
| `cka-cp` | control-plane | — | (los de kubeadm) |
| `cka-w1`, `cka-w2` | workloads | `node-role.kubernetes.io/worker` | ninguno |
| `cka-data1`, `cka-data2` | **data nodes** | `node-role.kubernetes.io/storage` | `dedicated=storage:NoSchedule` |

Los **data nodes** quedan *dedicados*: el taint mantiene fuera las cargas
generales y solo los sistemas de storage (que toleran el taint) se programan ahí.
Con 2 data nodes hay **réplicas de datos reales** (1 por nodo: Longhorn
`numberOfReplicas: 2`, MinIO 2 drives/nodo). Como el label y el taint son los
mismos que en la variante kind, los values de [../../storage](../../storage)
sirven **sin cambios**.

Parametrizable:

```powershell
./cluster.ps1 up -Workers 3 -DataNodes 3   # más workers / data nodes
./cluster.ps1 up -DataDisk 50G             # discos de datos más grandes
./cluster.ps1 up -WorkerMemory 4G          # workers a 4 GB; CP y data a 2 GB
./cluster.ps1 up -Memory 3G                # 3 GB a TODOS los nodos (~15 GB total)
```

Memoria por rol: `-Memory` es la base (control-plane y, salvo override, el resto).
`-WorkerMemory` y `-DataMemory` la ajustan por rol (vacío = `-Memory`). Ejemplo:
`-WorkerMemory 4G` deja workers a 4 GB y CP+data a 2 GB → 2 + 4·2 + 2·2 = **14 GB**.

## Prerequisitos

- **Hyper-V** habilitado (ya lo está si usas WSL2).
- **Multipass**: `winget install Canonical.Multipass`

## Uso

```powershell
./cluster.ps1 up          # lanza las VMs, kubeadm init/join, CNI, metrics y labels/taints
./cluster.ps1 status      # estado de VMs y nodos
./cluster.ps1 kubeconfig  # reescribe ./kubeconfig
./cluster.ps1 cni         # (re)instala el CNI -Cni en un cluster existente
./cluster.ps1 metrics     # instala metrics-server en un cluster existente
./cluster.ps1 down        # destruye las VMs
```

> `cluster.ps1` solo monta la **infraestructura** (VMs + kubeadm + CNI +
> metrics-server). La **plataforma** (StorageClass, Prometheus, MinIO, Longhorn)
> se despliega aparte con [stack.ps1](#plataforma-stackps1). Ver el
> [runbook de recreación](#recrear-el-lab-en-dos-comandos).

Tras `up`, apunta kubectl al cluster:

```powershell
$env:KUBECONFIG = "$PWD\kubeconfig"
kubectl get nodes -o wide
kubectl top nodes          # requiere metrics-server (se instala por defecto)
```

### Elegir CNI

```powershell
./cluster.ps1 up -Cni flannel   # por defecto; VXLAN sencillo
./cluster.ps1 up -Cni calico    # operador Tigera; NetworkPolicies (útil para CKS)
./cluster.ps1 up -Cni cilium    # datapath eBPF (CLI de Cilium)
```

| CNI | Instalación | Notas |
| --- | --- | --- |
| `flannel` | manifest | ligero, VXLAN, sin NetworkPolicy nativa |
| `calico` | operador Tigera + `Installation` con el CIDR del cluster | NetworkPolicy completa, BGP/VXLAN |
| `cilium` | CLI de Cilium (`cilium install`) | eBPF; base para kube-proxy replacement, Hubble |
| `none` | no instala nada | nodos `NotReady`; instálalo tú (práctica) |

Sin CNI (para instalarlo tú o practicar kubeadm): `./cluster.ps1 up -Cni none`
(los nodos quedan `NotReady` hasta que instales uno con `./cluster.ps1 cni -Cni ...`).

Desactivar metrics-server: `./cluster.ps1 up -MetricsServer $false`.

### Número de nodos

```powershell
./cluster.ps1 up -Workers 3 -DataNodes 2   # 1 CP + 3 workers + 2 data nodes
./cluster.ps1 up -Workers 1 -DataNodes 1   # mínimo ligero (3 VMs)
./cluster.ps1 up -DataNodes 0              # SIN data nodes (1 CP + 2 workers)
./cluster.ps1 up -Workers 1 -DataNodes 0  # cluster mínimo: 2 VMs (1 CP + 1 worker)
```

El **control-plane es 1** en esta variante (multi-CP en HA requiere un
balanceador delante de los API servers, fuera de alcance aquí). Workers y data
nodes son libres con `-Workers` / `-DataNodes` (rango 0–20).

**`-DataNodes 0`** crea el cluster sin nodos de storage dedicados — perfecto si
solo quieres practicar workloads, scheduling o kubeadm y no el lab de
MinIO/Longhorn (que sí necesita data nodes). Con 1 worker y 0 data nodes tienes
el cluster mínimo de 2 VMs.

### Practicar kubeadm a mano (`-Bootstrap $false`)

Por defecto el script automatiza `kubeadm init`, CNI y `join`. Para **practicar
kubeadm tú mismo** (como en el examen), créalo sin bootstrap: levanta las VMs ya
preparadas (containerd, kubeadm, kubelet, `open-iscsi`…) pero **sin inicializar
nada**:

```powershell
./cluster.ps1 up -Bootstrap $false
```

Al terminar imprime los pasos. Resumen del flujo manual:

```bash
# 1) Control-plane
multipass shell cka-cp
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=<IP-CP>
mkdir -p $HOME/.kube && sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 2) CNI (ejemplo Flannel)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 3) Join en cada worker
sudo kubeadm token create --print-join-command   # en el CP -> copia la salida
multipass shell cka-w1                            # y en cada worker
sudo kubeadm join ...                             # pega el comando

# 4) Trae el kubeconfig al host
exit
./cluster.ps1 kubeconfig
```

Así practicas `kubeadm init`, instalación de CNI, `kubeadm join`, `kubeadm token`,
`kubeadm reset`, upgrades, etc. — el dominio *Cluster Architecture* del CKA.

### Métricas: metrics-server vs. Prometheus (FreeLens)

Son cosas distintas y conviven:

| | metrics-server | Prometheus |
| --- | --- | --- |
| API / uso | `metrics.k8s.io` → `kubectl top`, HPA | scraper + TSDB (series temporales) |
| Tipo de dato | instantáneo, no se guarda | histórico, consultable |
| FreeLens | cifras puntuales | **gráficas históricas** (las que pide el UI) |

Por eso `kubectl top nodes` funciona solo con metrics-server, pero FreeLens te
pide Prometheus para sus gráficas. Prometheus se instala con `stack.ps1` (ver
abajo), recortado: solo Prometheus + node-exporter + kube-state-metrics, **sin**
Grafana/Alertmanager:

```powershell
./stack.ps1 up -Components prometheus
```

Values en [../../monitoring/prometheus/values.yaml](../../monitoring/prometheus/values.yaml).
Colocación: Prometheus, el operator y kube-state-metrics van a los **workers de
workloads** (el taint de los data nodes los repele solo); **node-exporter** corre
como DaemonSet en **todos** los nodos —incluidos los data nodes— gracias a una
toleration amplia. Prometheus **no** va a los data nodes: su TSDB es
almacenamiento interno, no la capa de storage del cluster.

Después, en FreeLens → *Settings → Metrics*, apunta Prometheus al Service
`monitoring/kube-prometheus-stack-prometheus:9090`.

## Qué hace `cluster.ps1 up`

1. Lanza las **VMs base** (sin cloud-init) y luego las **aprovisiona** una a una
   con [provision-node.sh](provision-node.sh) vía `multipass exec` (containerd,
   Kubernetes v1.34, `open-iscsi`, `nfs-common`, swap off, sysctl/módulos).
   Se hace así —y no con `--cloud-init` en el `launch`— porque en Windows el
   daemon de Multipass tiende a colgarse esperando a un cloud-init largo.
2. `kubeadm init` en el control-plane (`--pod-network-cidr=10.244.0.0/16`).
3. Instala el **CNI** elegido (`-Cni`, por defecto Flannel).
4. Une todos los workers (workloads + data nodes) con el token de `kubeadm`.
5. Etiqueta los workers de workloads (`node-role.kubernetes.io/worker`) y
   etiqueta + taintea los data nodes como storage.
6. Instala **metrics-server** (con `--kubelet-insecure-tls`, salvo `-MetricsServer $false`).
7. Exporta el kubeconfig a `./kubeconfig`.

## Plataforma (stack.ps1)

Mientras `cluster.ps1` monta la infraestructura, [stack.ps1](stack.ps1) despliega
la **plataforma** encima vía Helm (todo idempotente, `helm upgrade --install`, con
versiones **pinneadas**):

```powershell
./stack.ps1 up            # local-path (default) + Prometheus + MinIO + Longhorn
./stack.ps1 up -Components minio        # solo un componente (instala local-path si falta)
./stack.ps1 status        # helm releases + StorageClasses + pods por namespace
./stack.ps1 down          # desinstala la plataforma (NO toca el cluster)
```

Instala, **en orden de dependencia**:

1. **local-path-provisioner** → StorageClass por **defecto** (disco local). Va
   primero porque MinIO la consume; al ser default, MinIO omite `storageClassName`.
2. **kube-prometheus-stack** → Prometheus para FreeLens (ver arriba).
3. **MinIO** ([object](../../storage/object)) → objetos S3, usa la SC por defecto.
4. **Longhorn** ([block](../../storage/block)) → bloques CSI + su SC `longhorn-block`
   (réplicas a `2`, los 2 nodos de storage). Aquí **sí** arranca (iSCSI del cloud-init).

> Recuerda: **MinIO va sobre disco local** (local-path), **no** sobre Longhorn —
> MinIO ya replica con erasure coding y apilarlo sobre Longhorn sería doble
> replicación. Conviven en los mismos nodos de storage, en paralelo.

## Recrear el lab en dos comandos

Borrar hoy y reproducir mañana idéntico:

```powershell
./cluster.ps1 down                 # destruye las VMs
# ...mañana...
./cluster.ps1 up                   # 1) infraestructura
$env:KUBECONFIG = "$PWD\kubeconfig"
./stack.ps1 up                     # 2) plataforma completa
```

Todas las versiones (K8s v1.34 en cloud-init, local-path, kube-prometheus-stack,
MinIO, Longhorn) están pinneadas para que el resultado sea reproducible. Lo único
que cambia entre recreaciones son las IPs de las VMs (el kubeconfig se regenera
solo). Los **datos** de MinIO/Longhorn **no** persisten a un `down` (se destruyen
las VMs); para conservarlos habría que hacer backups (Longhorn → MinIO, S3).

## Notas

- Las VMs Multipass son accesibles desde el host, así que el kubeconfig exportado
  (server `https://<IP-CP>:6443`) funciona directamente.
- Cambiar de CNI en un cluster ya creado no es limpio (deja restos del anterior);
  para cambiar de CNI lo recomendable es `down` + `up -Cni <otro>`.
- Cilium con *kube-proxy replacement* completo (100% eBPF) requeriría hacer
  `kubeadm init --skip-phases=addon/kube-proxy` y pasar `k8sServiceHost/Port`; esta
  variante instala Cilium con kube-proxy presente (datapath eBPF) por simplicidad.
- Para un control-plane en HA (2+ CP) haría falta un balanceador delante de los
  API servers; se sale del alcance de esta variante ligera.

## Troubleshooting

### El `up` se queda bloqueado creando una VM (daemon de Multipass colgado)

Síntoma: la creación de una VM no avanza y **cualquier** comando (`multipass list`,
`multipass version`) también se cuelga → el daemon `multipassd` está *wedged*
(cuelgue conocido del driver Hyper-V al lanzar VMs seguidas).

Recuperación (PowerShell **como administrador**):

```powershell
Restart-Service Multipass -Force
# Si 'multipass list' sigue colgado, reinicio duro:
#   Stop-Service Multipass -Force; Stop-Process -Name multipassd -Force; Start-Service Multipass
multipass list                 # ver qué quedó a medias
multipass delete --all --purge # limpiar VMs parciales
```

Después, reintenta `./cluster.ps1 up`. El script lanza las VMs de una en una,
con `--timeout` y una pausa entre ellas, y **las VMs base se lanzan sin
cloud-init** (el aprovisionamiento va aparte por `exec`) — esto reduce mucho el
cuelgue, porque el `launch` ya no espera a una instalación larga.

### `Timed out waiting for instance launch`

Si el `launch` de una VM da timeout (y `multipass list` también se cuelga), es el
mismo cuelgue del daemon: aplica la recuperación de arriba (reinicio del servicio
+ `multipass delete --all --purge`) y reintenta. Multipass sobre Hyper-V es algo
inestable; si se repite, prueba a lanzar menos VMs (`-Workers 1 -DataNodes 0`)
para validar que el daemon aguanta, o reinicia Windows para dejar Hyper-V limpio.

> La GUI de Multipass no suele causar el cuelgue, pero cerrarla fuerza un reinicio
> limpio del daemon (en Windows detiene las instancias), lo que ayuda a recuperar.

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
```

## Prerequisitos

- **Hyper-V** habilitado (ya lo está si usas WSL2).
- **Multipass**: `winget install Canonical.Multipass`

## Uso

```powershell
./cluster.ps1 up          # lanza las VMs, kubeadm init/join, CNI y labels/taints
./cluster.ps1 status      # estado de VMs y nodos
./cluster.ps1 kubeconfig  # reescribe ./kubeconfig
./cluster.ps1 down        # destruye las VMs
```

Tras `up`, apunta kubectl al cluster:

```powershell
$env:KUBECONFIG = "$PWD\kubeconfig"
kubectl get nodes -o wide
```

## Qué hace `cluster.ps1 up`

1. Lanza las VMs con [cloud-init.yaml](cloud-init.yaml) (containerd, Kubernetes
   v1.34, `open-iscsi`, `nfs-common`, swap off, sysctl/módulos).
2. `kubeadm init` en el control-plane (`--pod-network-cidr=10.244.0.0/16`).
3. Instala **Flannel** como CNI.
4. Une todos los workers (workloads + data nodes) con el token de `kubeadm`.
5. Etiqueta los workers de workloads (`node-role.kubernetes.io/worker`) y
   etiqueta + taintea los data nodes como storage.
6. Exporta el kubeconfig a `./kubeconfig`.

## Desplegar el storage encima

Con `KUBECONFIG` apuntando a este cluster, sigue las guías de
[../../storage](../../storage):

- **Longhorn** ([block](../../storage/block)) — ahora **sí** arranca; baja
  `defaultReplicaCount` a `2` (solo hay 2 nodos de storage).
- **MinIO** ([object](../../storage/object)) — distribuido, igual que en kind.

## Notas

- Las VMs Multipass son accesibles desde el host, así que el kubeconfig exportado
  (server `https://<IP-CP>:6443`) funciona directamente.
- CNI alternativo para practicar NetworkPolicies (CKS): Calico en lugar de Flannel.
- Para un control-plane en HA (2+ CP) haría falta un balanceador delante de los
  API servers; se sale del alcance de esta variante ligera.

# CKA setup — clusters

Provisiona el cluster de prácticas del CKA. Hay **dos variantes**, elige según
lo que necesites:

| Variante | Carpeta | Backend | Cuándo usarla |
| --- | --- | --- | --- |
| **kind** (por defecto) | este directorio | contenedores (kernel WSL2) | rápido para el día a día; MinIO distribuido OK |
| **Multipass** | [multipass/](multipass/) | VMs Ubuntu (Hyper-V) | cuando necesitas kernel real → **Longhorn/iSCSI** |

> Longhorn necesita el módulo `iscsi_tcp`, que el kernel WSL2 de kind no trae.
> Para esa parte usa la variante Multipass. Detalles abajo y en
> [multipass/readme.md](multipass/readme.md).

---

## Variante kind (Kubernetes IN Docker)

This folder provisions the Kubernetes cluster used for CKA practice with
[kind](https://kind.sigs.k8s.io/) (Kubernetes IN Docker).

## Topology

8 nodes, highly-available control plane:

| Role          | Count | Notes                                            |
| ------------- | ----- | ------------------------------------------------ |
| control-plane | 2     | HA — kind adds an HAProxy load balancer in front |
| worker        | 6     | workloads run here                               |

> With more than one control-plane node, kind automatically spins up an extra
> HAProxy container that load-balances the API servers, so you get a realistic
> HA control plane to practise etcd, kubeadm and certificate-renewal scenarios.

The Kubernetes version is pinned in [kind-cka.yaml](kind-cka.yaml)
(`kindest/node:v1.34.0`); bump the image tags there to upgrade.

## Prerequisites

- [Docker](https://www.docker.com/) running
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Usage

Helper scripts wrap the raw `kind` commands. From this folder:

**Windows (PowerShell):**

```powershell
./cluster.ps1 up         # create the cluster
./cluster.ps1 status     # list nodes
./cluster.ps1 kubeconfig # point kubectl at the cluster
./cluster.ps1 down       # delete the cluster
```

**Linux / macOS / Git Bash:**

```bash
./cluster.sh up
./cluster.sh status
./cluster.sh kubeconfig
./cluster.sh down
```

Or call `kind` directly:

```bash
kind create cluster --config kind-cka.yaml
kind delete cluster --name cka
```

After creation, `kubectl` is pointed at the `kind-cka` context. Verify with:

```bash
kubectl get nodes -o wide
```

You should see 8 nodes (2 control-plane, 6 worker) in `Ready` state.

## Notes

- The cluster name is `cka`; the kubectl context is `kind-cka`.
- Each environment (CKA, CKS, …) gets its own kind cluster, so they can run
  side by side without interfering. Switch between them with
  `kubectl config use-context kind-<name>`.

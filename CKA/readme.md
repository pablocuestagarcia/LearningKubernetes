# CKA — Certified Kubernetes Administrator

Practice environment and notes for renewing the **CKA** certification.

## Cluster

A dedicated [kind](https://kind.sigs.k8s.io/) cluster is used for all CKA
exercises. It mirrors a small highly-available production setup:

- **2 control-plane** nodes (HA, fronted by an HAProxy load balancer)
- **6 worker** nodes

Everything needed to create it lives in [setup/](setup/). Quick start:

```powershell
cd setup
./cluster.ps1 up      # ./cluster.sh up on Linux/macOS
kubectl get nodes -o wide
```

See [setup/readme.md](setup/readme.md) for full details.

## Topics

- [storage/](storage/) — persistent volumes, claims and storage classes.
- [networking/](networking/) — Pod/Service networking, DNS, Ingress, NetworkPolicies.

_(More sections will be added as the CKA curriculum is covered.)_

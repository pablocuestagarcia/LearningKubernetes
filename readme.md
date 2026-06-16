# Learning Kubernetes

A personal lab for learning Kubernetes in depth — certifications first, then
building operators and beyond.

Each environment gets its **own [kind](https://kind.sigs.k8s.io/) cluster** so
they can run independently and be torn down without affecting the others.
Switch between them with `kubectl config use-context kind-<name>`.

## Environments

| Environment | Status         | Description                                           |
| ----------- | -------------- | ---------------------------------------------------- |
| [CKA](CKA/) | 🟢 active      | Certified Kubernetes Administrator (renewal)          |
| CKS         | ⬜ planned     | Certified Kubernetes Security Specialist              |
| PCA         | ⬜ planned     | Prometheus Certified Associate                        |
| CAPA        | ⬜ planned     | Cluster API Provider AWS                              |
| Operators   | ⬜ planned     | Building custom operators / controllers              |

## Prerequisites

- [Docker](https://www.docker.com/)
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Getting started

Start with the CKA environment:

```powershell
cd CKA/setup
./cluster.ps1 up      # ./cluster.sh up on Linux/macOS
```

See [CKA/readme.md](CKA/readme.md) for details.

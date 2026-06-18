# CKA — Fundamentos de networking

Material de estudio para el dominio **Services & Networking** del CKA (≈20% del
examen): modelo de red, CNI, Services, DNS, Ingress/Gateway API y NetworkPolicies.

| Documento | Contenido | Estado |
| --- | --- | --- |
| [concepts.md](concepts.md) | Teoría detallada: modelo de red, CNI, Service (tipos, endpoints), kube-proxy, DNS/CoreDNS, Ingress, Gateway API, NetworkPolicies, CIDRs, troubleshooting | ✅ |
| [cni-plugins.md](cni-plugins.md) | Deep-dive de plugins CNI: Flannel, Calico y eBPF/Cilium; overlay vs BGP, NetworkPolicy, kube-proxy replacement, implicaciones de cada elección | ✅ |
| examples.md | Labs estilo examen paso a paso (ClusterIP/NodePort, DNS, headless, NetworkPolicy, Ingress) | 📄 pendiente |

> Empieza por [concepts.md](concepts.md) para fijar el *qué* y el *porqué* antes
> de pasar a los labs prácticos.

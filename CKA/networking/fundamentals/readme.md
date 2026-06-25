# CKA — Fundamentos de networking

Material de estudio para el dominio **Services & Networking** del CKA (≈20% del
examen): modelo de red, CNI, Services, DNS, Ingress/Gateway API y NetworkPolicies.

| Documento | Contenido | Estado |
| --- | --- | --- |
| [concepts.md](concepts.md) | Teoría detallada: modelo de red, CNI, Service (tipos, endpoints), kube-proxy, DNS/CoreDNS, Ingress, Gateway API, NetworkPolicies, CIDRs, troubleshooting | ✅ |
| [cni-plugins.md](cni-plugins.md) | Deep-dive de plugins CNI: Flannel, Calico y eBPF/Cilium; overlay vs BGP, NetworkPolicy, kube-proxy replacement, implicaciones de cada elección | ✅ |
| [ingress.md](ingress.md) | Deep-dive de Ingress (intermedio-avanzado): recurso vs controller, ciclo de vida de la petición, reconciliación, data path, IngressClass, TLS/SNI, rewrites, patrones avanzados | ✅ |
| [comandos-rapidos.md](comandos-rapidos.md) | Chuleta operativa: setup del examen (alias, `$do`, vimrc, completion) y comandos imperativos por recurso (expose, create service/ingress, diagnóstico DNS/endpoints) | ✅ |
| examples.md | Labs estilo examen paso a paso (ClusterIP/NodePort, DNS, headless, NetworkPolicy, Ingress) | 📄 pendiente |

> Empieza por [concepts.md](concepts.md) para fijar el *qué* y el *porqué* antes
> de pasar a los labs prácticos.

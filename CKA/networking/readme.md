# CKA — Networking lab

Dominio **Services & Networking** del CKA (≈20% del examen).

- **Fundamentos del CKA** (modelo de red, CNI, Services, DNS, Ingress,
  NetworkPolicies) → [fundamentals/](fundamentals/). **Empieza por aquí.**
- **CNI en profundidad** (Flannel, Calico, eBPF/Cilium e implicaciones) →
  [fundamentals/cni-plugins.md](fundamentals/cni-plugins.md).

---

## Mapa del dominio

| Bloque | De qué va | Recurso k8s |
| --- | --- | --- |
| Modelo de red | IP por Pod, sin NAT, red plana | (contrato CNI) |
| CNI | quién implementa la red (Calico, Cilium, Flannel…) | DaemonSet |
| Service | IP estable + balanceo a Pods | `Service` |
| Tipos de Service | ClusterIP / NodePort / LoadBalancer / ExternalName / headless | `Service` |
| Endpoints | qué Pods atienden un Service | `Endpoints` / `EndpointSlice` |
| Enrutado | kube-proxy (iptables/ipvs/nftables) | `kube-proxy` |
| DNS | descubrimiento por nombre | CoreDNS |
| Publicar HTTP(S) | enrutado L7 por host/path + TLS | `Ingress` / Gateway API |
| Aislamiento | firewall por labels/namespaces | `NetworkPolicy` |

## Notas del entorno (kind)

- El CNI por defecto de kind es **kindnet**: da conectividad Pod↔Pod pero **no**
  aplica `NetworkPolicy`. Para practicar políticas, despliega **Calico** o
  **Cilium**.
- El cluster tiene 2 control-plane + 6 workers (ver [../setup/](../setup/)), útil
  para razonar sobre tráfico **inter-nodo** y `externalTrafficPolicy`.

## Estado

- [x] Fundamentos conceptuales ([fundamentals/concepts.md](fundamentals/concepts.md))
- [ ] Labs prácticos (`fundamentals/examples.md`)
- [ ] (Opcional) Desplegar Calico/Cilium para validar NetworkPolicies
- [ ] (Opcional) Ingress controller + Ingress de ejemplo

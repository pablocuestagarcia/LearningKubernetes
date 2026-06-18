# CNI en profundidad: Flannel, Calico y eBPF/Cilium

Deep-dive del plugin de red. Amplía la §4 de [concepts.md](concepts.md): **qué hace
realmente un CNI**, cómo difieren los *dataplanes*, y qué **implica** elegir
**Flannel**, **Calico** o un plugin **eBPF** (**Cilium**). Enfoque conceptual con
el peso justo de lo que cae en el CKA.

> Regla de oro del examen: en el CKA **no instalas ni comparas CNIs** (el cluster
> ya viene con uno), pero **sí** debes entender por qué un CNI ausente deja nodos
> `NotReady`, por qué una `NetworkPolicy` "no hace nada" con según qué plugin, y
> qué significan los términos overlay/BGP/eBPF cuando aparecen.

---

## Índice

1. [Qué hace exactamente un CNI](#1-qué-hace-exactamente-un-cni)
2. [El eje que lo explica todo: overlay vs ruteo nativo](#2-el-eje-que-lo-explica-todo-overlay-vs-ruteo-nativo)
3. [Flannel](#3-flannel)
4. [Calico](#4-calico)
5. [eBPF y Cilium](#5-ebpf-y-cilium)
6. [Tabla comparativa](#6-tabla-comparativa)
7. [Implicaciones de cada elección](#7-implicaciones-de-cada-elección)
8. [Cómo identificar y diagnosticar el CNI](#8-cómo-identificar-y-diagnosticar-el-cni)
9. [Qué entra de esto en el CKA](#9-qué-entra-de-esto-en-el-cka)
10. [Chuleta de referencia](#10-chuleta-de-referencia)

---

## 1. Qué hace exactamente un CNI

Cuando el kubelet crea un Pod, **no** sabe configurar redes: ejecuta el **binario
CNI** declarado en `/etc/cni/net.d/` y le pide dos cosas:

1. **IPAM** (IP Address Management): asignar una IP del Pod CIDR al nuevo Pod.
2. **Cablear** la red del Pod: crear la `veth`, conectarla al nodo y dejar rutas
   para que ese Pod alcance a cualquier otro del cluster.

Al borrar el Pod, lo invoca de nuevo para **liberar** la IP y limpiar. Eso es el
**contrato CNI**: un estándar simple (un binario + un JSON de config) que
desacopla Kubernetes de la implementación de red.

Lo que **cambia entre plugins** es *cómo* resuelven el punto 2 (el "dataplane")
y *qué extras* añaden encima (NetworkPolicy, cifrado, observabilidad, reemplazo de
kube-proxy). Por eso dos clusters idénticos pueden comportarse muy distinto según
el CNI.

> Matiz de nomenclatura: existen los **plugins CNI de referencia** (bridge,
> host-local, loopback…) que son piezas de bajo nivel, y los **"CNIs" de
> Kubernetes** (Flannel, Calico, Cilium) que son soluciones completas que **usan**
> esas piezas. Cuando se habla de "elegir un CNI" se refiere a lo segundo.

---

## 2. El eje que lo explica todo: overlay vs ruteo nativo

Casi todas las diferencias de rendimiento y operación salen de **cómo viaja un
paquete de un Pod en el nodo A a un Pod en el nodo B**:

### Overlay (red encapsulada)

El paquete Pod→Pod se **envuelve** dentro de otro paquete que viaja entre las IPs
de los **nodos**, y se **desenvuelve** al llegar. Técnicas:

- **VXLAN**: encapsula en UDP. Funciona sobre *cualquier* red subyacente (no
  exige que la infraestructura conozca las rutas de Pods). Es el más portable.
- **IP-in-IP (IPIP)**: encapsula IP dentro de IP. Más ligero que VXLAN pero menos
  universal (algunas redes cloud lo bloquean).

**Ventaja:** funciona "en cualquier sitio" sin tocar routers ni la red física.
**Coste:** **overhead** por la cabecera extra (reduce el MTU útil) y algo más de
CPU al encapsular/desencapsular.

### Ruteo nativo (sin encapsular, L3)

El nodo anuncia "los Pods de este rango están detrás de mí" mediante **BGP**, y la
red enruta los paquetes de Pod **tal cual**, sin envoltorio.

**Ventaja:** **sin overhead** de encapsulado, rendimiento casi nativo, IPs de Pod
visibles/depurables en la red.
**Coste:** requiere que la red subyacente **coopere** (mismo dominio L2, o routers
que hablen BGP). En muchas nubes no es trivial.

> Este eje es la clave: **Flannel** es esencialmente "overlay fácil"; **Calico**
> te deja elegir (BGP nativo o overlay); **Cilium** reinventa el dataplane con
> **eBPF** (y puede ir con o sin overlay).

---

## 3. Flannel

El CNI **más simple y minimalista**. Su objetivo es solo el punto 2: dar
conectividad Pod↔Pod plana, sin pretensiones.

**Cómo funciona:**

- Backend por defecto **VXLAN** (overlay). También ofrece `host-gw` (ruteo L2
  directo, sin encapsular, si todos los nodos están en la misma subred) y otros.
- Un daemon (`flanneld`) por nodo + IPAM sencillo que reparte un sub-rango del Pod
  CIDR a cada nodo.

**Implicaciones (lo que de verdad importa):**

- ✅ **Fácil de instalar y entender.** Ideal para labs y clusters pequeños.
- ❌ **No implementa `NetworkPolicy`.** Este es *el* punto a recordar: creas la
  policy, se admite, y **no surte ningún efecto**. Para aislamiento hay que
  añadir otra capa (p. ej. Calico en modo *policy-only* sobre Flannel =
  "Canal").
- ➖ Sin BGP, sin cifrado, sin features L7, sin observabilidad avanzada.
- ➖ Overhead de VXLAN salvo que uses `host-gw`.

**Cuándo tiene sentido:** entornos donde **solo necesitas conectividad** y
valoras la simplicidad por encima de todo. En cuanto pidas microsegmentación,
te quedas corto.

---

## 4. Calico

El CNI **más usado en producción** y el de referencia para **NetworkPolicy**.
Mucho más que conectividad: es una solución de red + políticas + seguridad.

**Cómo funciona:**

- **Dataplane flexible:** ruteo **L3 nativo con BGP** (sin encapsular, alto
  rendimiento) **o** overlay **IP-in-IP / VXLAN** cuando la red no permite BGP.
  Modo `CrossSubnet` = nativo dentro de la subred, encapsulado solo entre subnets.
- Componentes: **Felix** (programa rutas y reglas de filtrado en cada nodo),
  **BIRD** (el demonio BGP que anuncia rutas), e IPAM propio.
- **Tres dataplanes** posibles: el clásico **iptables**, el moderno **eBPF**, o
  **nftables**. Es decir, Calico *también* puede correr en eBPF (compite con
  Cilium en ese terreno).

**Implicaciones:**

- ✅ **NetworkPolicy de Kubernetes completa**, y además sus **CRDs propias**:
  `NetworkPolicy`/`GlobalNetworkPolicy` de Calico con reglas **deny** explícitas,
  orden/prioridad, selectores más ricos, ámbito de cluster, logging. Va mucho más
  allá del estándar.
- ✅ **Alto rendimiento** en modo BGP nativo (sin overhead de encapsulado).
- ✅ Maduro, gran comunidad, multiplataforma (on-prem y cloud).
- ➖ Más piezas que Flannel → **más superficie operativa** (entender BGP, Felix,
  modos de encapsulado). El modo BGP exige que la red lo soporte.

**Cuándo tiene sentido:** prácticamente cualquier producción que necesite
**políticas de red serias** con buen rendimiento. Es la respuesta "por defecto"
cuando alguien pregunta "¿qué CNI con NetworkPolicy?".

> Variante **Canal** = Flannel (conectividad VXLAN) + Calico (solo políticas). Un
> patrón histórico para "añadir NetworkPolicy a Flannel".

---

## 5. eBPF y Cilium

### Qué es eBPF (y por qué cambia las reglas)

**eBPF** (extended Berkeley Packet Filter) permite ejecutar **programas seguros y
verificados dentro del kernel de Linux**, enganchados a *hooks* (recepción de
paquete, syscalls, etc.), **sin** cargar módulos ni recompilar el kernel.

Para la red esto significa procesar/redirigir paquetes **muy temprano y muy
rápido en el kernel**, en lugar de atravesar largas cadenas de **iptables**
(que escalan mal: su coste crece con el número de Services/reglas, ~O(n)). eBPF
usa **mapas hash** → coste casi constante a gran escala.

### Cilium

El CNI de referencia **basado en eBPF**. Replantea el dataplane entero:

**Cómo funciona / qué aporta:**

- **Dataplane eBPF**: enruta, balancea y filtra en el kernel sin depender de
  iptables. Puede ir en modo **overlay (VXLAN/Geneve)** o **ruteo nativo**.
- **Reemplazo de kube-proxy** (`kube-proxy replacement`): implementa los Services
  con eBPF, eliminando kube-proxy y sus reglas iptables. Mejor latencia y escala.
- **Identidad en vez de IP**: las políticas se basan en una **identidad**
  derivada de los labels del workload, no en IPs efímeras → políticas más
  estables y eficientes a escala.
- **NetworkPolicy L3/L4 estándar + políticas L7**: puede filtrar por **HTTP**
  (método, path), **gRPC**, **Kafka**, DNS… algo fuera del alcance del estándar
  de Kubernetes.
- **Hubble**: observabilidad de red (flujos, mapa de servicios, métricas) montada
  sobre eBPF.
- Cifrado transparente (IPsec/WireGuard), multicluster (Cluster Mesh).

**Implicaciones:**

- ✅ **Máximo rendimiento y escala** (sin cadenas iptables; balanceo en kernel).
- ✅ **Políticas L7 e identidad**; observabilidad de primera (Hubble).
- ✅ Puede **eliminar kube-proxy** del cluster.
- ➖ **Mayor complejidad conceptual** y dependencia de un **kernel reciente** (las
  features eBPF avanzadas exigen versiones modernas de kernel).
- ➖ Curva de aprendizaje y depuración distinta (ya no lees iptables; usas
  herramientas de Cilium/Hubble).

**Cuándo tiene sentido:** clusters grandes, con muchos Services, necesidades de
políticas L7/observabilidad, o donde el coste de iptables/kube-proxy se nota.

> Importante: **eBPF no es un CNI**, es una **tecnología del kernel**. Tanto
> **Cilium** como **Calico** pueden usar un *dataplane* eBPF. "eBPF" en una
> comparativa suele ser un atajo para "el enfoque moderno de dataplane", del que
> Cilium es el exponente más conocido.

---

## 6. Tabla comparativa

| Criterio | Flannel | Calico | Cilium (eBPF) |
| --- | --- | --- | --- |
| **Dataplane** | VXLAN (overlay), `host-gw` | BGP nativo **o** IPIP/VXLAN; iptables/eBPF/nftables | eBPF (overlay o nativo) |
| **NetworkPolicy (k8s)** | ❌ no | ✅ sí | ✅ sí |
| **Políticas extendidas** | — | ✅ CRDs (Global, deny, prioridad) | ✅ L7 (HTTP/DNS/Kafka), identidad |
| **Rendimiento** | medio (overlay) | alto (BGP nativo) | muy alto (kernel/eBPF) |
| **Reemplazo de kube-proxy** | ❌ | parcial (modo eBPF) | ✅ completo |
| **Observabilidad** | básica | media | alta (Hubble) |
| **Cifrado** | ❌ | WireGuard/IPsec | WireGuard/IPsec |
| **Complejidad** | baja | media | media-alta |
| **Caso típico** | labs, clusters simples | producción con políticas | escala/L7/observabilidad |

---

## 7. Implicaciones de cada elección

Resumido en las decisiones que de verdad cambian:

- **¿Necesitas `NetworkPolicy`?** Entonces **descarta Flannel solo**. Quieres
  Calico o Cilium (o Canal). Esta es la implicación nº1 y la más preguntable.
- **¿La red subyacente permite BGP / mismo L2?** Si sí, **ruteo nativo**
  (Calico BGP) te da rendimiento sin overhead. Si no (cloud restrictiva),
  **overlay** (VXLAN) es la opción segura, asumiendo algo de overhead y **MTU**
  reducido.
- **¿Escala grande / muchos Services / latencia crítica?** El coste de
  **iptables** (kube-proxy) se nota; **eBPF/Cilium** (o Calico eBPF) lo evita y
  puede reemplazar kube-proxy.
- **¿Necesitas políticas L7 (HTTP/DNS) u observabilidad de flujos?** Solo
  **Cilium** lo cubre de forma nativa.
- **MTU**: cualquier overlay reduce el MTU efectivo (cabecera VXLAN/IPIP). Un MTU
  mal ajustado provoca fallos sutiles (conexiones que "cuelgan" con payloads
  grandes). Es una causa real de troubleshooting.
- **Operación/depuración**: con iptables lees reglas con `iptables-save`; con
  eBPF cambias de herramientas (CLI de Cilium, Hubble). Implica **otro modelo
  mental** para diagnosticar.

---

## 8. Cómo identificar y diagnosticar el CNI

En un cluster que te dan (o en el examen), saber **qué CNI corre** y si está sano:

```bash
# Config CNI activa en el nodo (el "winner" por orden alfabético)
ls /etc/cni/net.d/

# DaemonSets/Pods del plugin (busca calico, cilium, flannel, kindnet...)
kubectl -n kube-system get pods -o wide | grep -Ei 'calico|cilium|flannel|kindnet|weave'
kubectl -n kube-system get daemonset

# Síntoma de CNI ausente/roto:
kubectl get nodes                      # -> NotReady
kubectl get pods -A                    # -> Pods en ContainerCreating
kubectl describe pod <pod>             # -> "failed to setup network for sandbox"
```

Pistas de diagnóstico:

- **Nodos `NotReady` + Pods `ContainerCreating`** → el CNI falta o su DaemonSet
  está caído.
- **`NetworkPolicy` ignorada** → el CNI no la implementa (kindnet/Flannel).
- **Conexiones grandes que cuelgan** pero pings/handshakes OK → sospecha de
  **MTU** (overlay).

---

## 9. Qué entra de esto en el CKA

Calibrando expectativas para no estudiar de más:

- ✅ **Sí entra:** entender que el CNI es **obligatorio** (nodos `NotReady` sin
  él), que **NetworkPolicy depende del CNI**, y reconocer los términos
  overlay/BGP/eBPF/kube-proxy. Saber **localizar** el plugin en `kube-system` y
  leer sus síntomas.
- ➖ **Raramente:** instalar o reconfigurar un CNI concreto desde cero, o
  configurar BGP/eBPF a mano. El cluster del examen ya trae red funcionando.
- 🧪 **En tu lab (kind):** el CNI por defecto es **kindnet** — da conectividad
  pero **no** aplica `NetworkPolicy`. Para practicar políticas de verdad,
  despliega **Calico** o **Cilium** sobre el cluster (crear kind con el CNI por
  defecto desactivado, o instalar Calico encima). Es el experimento natural para
  cerrar este módulo.

---

## 10. Chuleta de referencia

### El eje
Overlay (VXLAN/IPIP) = funciona en cualquier red, con overhead y MTU reducido ·
Ruteo nativo (BGP) = sin overhead, exige red cooperante.

### Los tres en una línea
**Flannel** = conectividad simple, **sin NetworkPolicy** · **Calico** = producción
+ políticas (BGP nativo u overlay; puede eBPF) · **Cilium** = eBPF, L7, identidad,
reemplaza kube-proxy, observabilidad (Hubble).

### eBPF
Programas en el kernel sin módulos; evita el coste O(n) de iptables; lo usan
Cilium y (opcionalmente) Calico. **No es un CNI, es una tecnología.**

### Regla nº1 del examen
`NetworkPolicy` solo surte efecto si el **CNI la implementa**. kindnet/Flannel
**no**; Calico/Cilium **sí**.

### Síntomas
CNI ausente → nodos `NotReady`, Pods `ContainerCreating`, "failed to setup
network for sandbox".

---

## Relación con el resto del módulo

- Base conceptual del CNI y el modelo de red: [concepts.md §4](concepts.md#4-el-cni-quién-implementa-la-red).
- Las `NetworkPolicy` que estos plugins (no) implementan: [concepts.md §12](concepts.md#12-networkpolicies).
- kube-proxy, al que Cilium puede reemplazar: [concepts.md §8](concepts.md#8-kube-proxy-y-cómo-se-enruta-un-service).

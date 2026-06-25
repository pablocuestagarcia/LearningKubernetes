# Networking en Kubernetes (CKA) — Conceptos

Documento conceptual para el dominio **Services & Networking** del CKA (≈20% del
examen). Cubre el **modelo de red** de Kubernetes, la conectividad entre Pods, el
papel del **CNI**, los **Services** y su descubrimiento, el **DNS** interno,
**Ingress / Gateway API**, las **NetworkPolicies** y `kube-proxy`.

> Los **ejemplos prácticos** (manifests + labs estilo examen) van en el documento
> hermano `examples.md`. Aquí nos centramos en entender el *qué* y el *porqué*.

---

## Índice

1. [El modelo de red de Kubernetes](#1-el-modelo-de-red-de-kubernetes)
2. [Las cuatro conectividades](#2-las-cuatro-conectividades)
3. [Red dentro del Pod y entre Pods](#3-red-dentro-del-pod-y-entre-pods)
4. [El CNI: quién implementa la red](#4-el-cni-quién-implementa-la-red)
5. [Service: por qué existe](#5-service-por-qué-existe)
6. [Tipos de Service](#6-tipos-de-service)
7. [Endpoints y EndpointSlices](#7-endpoints-y-endpointslices)
8. [kube-proxy y cómo se enruta un Service](#8-kube-proxy-y-cómo-se-enruta-un-service)
9. [DNS y descubrimiento de servicios](#9-dns-y-descubrimiento-de-servicios)
10. [Ingress e Ingress Controllers](#10-ingress-e-ingress-controllers)
11. [Gateway API](#11-gateway-api)
12. [NetworkPolicies](#12-networkpolicies)
13. [Rangos de IP: Pod CIDR vs Service CIDR](#13-rangos-de-ip-pod-cidr-vs-service-cidr)
14. [Troubleshooting típico del CKA](#14-troubleshooting-típico-del-cka)
15. [Chuletas de referencia](#15-chuletas-de-referencia)

---

## 1. El modelo de red de Kubernetes

Kubernetes **no implementa** la red: define un **modelo** (un contrato) y delega
la implementación en un plugin **CNI**. El modelo impone tres reglas:

1. **Todo Pod tiene su propia IP** única en el cluster (IP "plana", de primera
   clase).
2. **Todos los Pods pueden comunicarse entre sí sin NAT**, estén en el nodo que
   estén. La IP que un Pod ve de sí mismo es la misma que ven los demás.
3. **Los agentes del nodo** (kubelet, daemons del sistema) pueden hablar con
   todos los Pods de ese nodo.

Idea clave: **no hay NAT entre Pods**. Esto simplifica el modelo mental respecto
a Docker clásico (donde se mapeaban puertos del host). En Kubernetes razonas en
términos de **IPs de Pod** y, sobre ellas, de **IPs estables de Service**.

> Consecuencia para el CKA: si dos Pods no se ven, el problema está en el **CNI**,
> en una **NetworkPolicy**, en el **DNS** o en el **Service** — casi nunca en
> "NAT" o "puertos del host".

---

## 2. Las cuatro conectividades

El modelo se entiende mejor separando los **cuatro problemas de comunicación**
que Kubernetes resuelve, cada uno con su mecanismo:

| # | Comunicación | Mecanismo | Recurso |
| --- | --- | --- | --- |
| 1 | **Contenedor ↔ contenedor** (mismo Pod) | comparten `localhost` y network namespace | Pod |
| 2 | **Pod ↔ Pod** (mismo o distinto nodo) | red plana sin NAT | CNI |
| 3 | **Pod ↔ Service** (IP estable interna) | IP virtual + balanceo | Service + kube-proxy |
| 4 | **Externo ↔ Service** (entrar al cluster) | NodePort / LoadBalancer / Ingress | Service / Ingress |

Casi todo el dominio de networking del examen es **entender qué nivel falla** y
con qué herramienta se diagnostica.

---

## 3. Red dentro del Pod y entre Pods

### Dentro del Pod

Todos los contenedores de un Pod **comparten el mismo network namespace**: misma
IP, mismos puertos, mismo `localhost`. Por eso:

- Se comunican entre sí por **`localhost:<puerto>`**.
- **No pueden** usar el mismo puerto dos contenedores del Pod (colisión).
- El "puente" lo monta un contenedor de infraestructura (el *pause container*),
  que sostiene el namespace mientras los contenedores de la app van y vienen.

### Entre Pods

Cada Pod recibe una IP del **Pod CIDR**. La conectividad Pod↔Pod la implementa el
CNI mediante:

- Una `veth` (par de interfaces virtuales) que conecta el namespace del Pod con
  el del nodo.
- Un **bridge** o ruteo en el nodo, más rutas/encapsulado (VXLAN, IP-in-IP) o
  ruteo nativo (BGP) para alcanzar Pods de **otros** nodos.

Punto importante para el CKA: **la IP del Pod es efímera**. Cambia en cada
recreación (rollout, crash, reschedule). Por eso **nunca** te conectas a un Pod
por su IP: usas un **Service** (§5).

---

## 4. El CNI: quién implementa la red

**CNI** (Container Network Interface) es el estándar de plugins que el kubelet
invoca al crear/destruir un Pod para **asignarle la IP y cablear su red**. Sin un
CNI instalado, los nodos quedan **`NotReady`** y los Pods no arrancan
(`ContainerCreating`).

Ejemplos: **Calico**, **Cilium**, **Flannel**, **Weave**. Difieren en:

| Aspecto | Implicación |
| --- | --- |
| **Modo de datos** | overlay (VXLAN/IP-in-IP) vs ruteo nativo (BGP) |
| **NetworkPolicy** | no todos las soportan (Flannel "puro" **no**; Calico/Cilium **sí**) |
| **Rendimiento / eBPF** | Cilium usa eBPF; puede sustituir a kube-proxy |

Para el CKA basta con:

- Saber que **el CNI es obligatorio** y que su ausencia explica nodos `NotReady`.
- Entender que **las NetworkPolicies solo funcionan si el CNI las implementa**.
- Conocer que los manifests del CNI se aplican con `kubectl apply -f` tras
  `kubeadm init` (y que el `--pod-network-cidr` de `kubeadm` debe casar con el del
  CNI).

> En este laboratorio (kind) el CNI por defecto es **kindnet**, que da
> conectividad Pod↔Pod pero **no** aplica NetworkPolicies. Para practicar
> políticas hay que desplegar Calico/Cilium.

> **Deep-dive:** comparativa en profundidad de **Flannel, Calico y eBPF/Cilium**
> (overlay vs BGP, NetworkPolicy, reemplazo de kube-proxy e implicaciones de cada
> elección) en [cni-plugins.md](cni-plugins.md).

---

## 5. Service: por qué existe

Las IPs de los Pods son **efímeras** y un Deployment puede tener N réplicas que
aparecen y desaparecen. Un consumidor necesita **un punto de entrada estable** y
**balanceo** entre las réplicas sanas. Eso es un **Service**.

Un Service:

- Tiene un **nombre DNS** y una **IP virtual estable** (la *ClusterIP*) durante
  toda su vida.
- Selecciona Pods de *backend* mediante un **`selector`** de labels.
- **Balancea** el tráfico entre los Pods que cumplen el selector y están **listos**
  (pasan su readiness probe).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web          # <-- elige los Pods backend por label
  ports:
    - port: 80         # puerto del Service (lo que consume el cliente)
      targetPort: 8080 # puerto del contenedor destino
```

Conceptos que el examen distingue bien:

- **`port`** = puerto del Service. **`targetPort`** = puerto del Pod. Pueden
  diferir; `targetPort` puede ser un **nombre** de puerto del contenedor.
- El **selector** es lo que enlaza el Service con sus Pods. Si no casa con
  ningún Pod, el Service existe pero **no tiene endpoints** (no balancea a nada).
- El Service **solo enruta a Pods `Ready`**. Un Pod que falla su readiness probe
  **sale** del balanceo automáticamente.

> **Atajo de examen:** no escribas el Service a mano —
> `kubectl expose deploy web --port=80 --target-port=8080` lo crea al instante.
> Ver [comandos-rapidos.md §3](comandos-rapidos.md#3-services).

---

## 6. Tipos de Service

El campo `spec.type` define el alcance del Service. **Son acumulativos**: cada
tipo "construye encima" del anterior.

| Tipo | Qué da | Alcance |
| --- | --- | --- |
| `ClusterIP` (def.) | IP virtual interna | **solo dentro** del cluster |
| `NodePort` | abre un puerto en **todos los nodos** (30000–32767) | externo, vía `IP_nodo:nodePort` |
| `LoadBalancer` | pide un LB externo al proveedor cloud | externo, IP pública |
| `ExternalName` | alias DNS (CNAME) a un host externo | redirección DNS, **sin** proxy |

Detalles muy preguntables:

- **NodePort** *incluye* una ClusterIP; **LoadBalancer** *incluye* NodePort +
  ClusterIP. Es una cebolla, no opciones excluyentes.
- El rango de **NodePort** es `30000–32767` por defecto.
- **`ExternalName`** no tiene selector ni ClusterIP: CoreDNS devuelve un CNAME al
  `externalName`. Útil para abstraer servicios externos (una BD gestionada).
- **Headless Service** (`clusterIP: None`): **no** asigna IP virtual ni balancea;
  el DNS devuelve **directamente las IPs de los Pods** (registros A múltiples). Es
  la base de los **StatefulSets** (cada Pod con su DNS estable
  `pod-0.svc...`).

```yaml
spec:
  clusterIP: None    # headless: DNS -> IPs de los Pods, sin balanceo
  selector:
    app: db
```

---

## 7. Endpoints y EndpointSlices

Cuando creas un Service con selector, el **control plane** calcula qué Pods
casan y están listos, y mantiene esa lista en objetos:

- **Endpoints** (objeto clásico): una lista de `IP:puerto` por Service.
- **EndpointSlices** (moderno, por defecto): la misma información **troceada** en
  fragmentos para escalar a miles de endpoints sin un objeto gigante.

Por qué importa en el CKA:

- Es la herramienta de diagnóstico nº1 de un Service: `kubectl get endpoints
  <svc>` o `kubectl get endpointslices`. **Sin endpoints, el Service no enruta a
  nada.**
- Endpoints **vacíos** casi siempre significan: el **selector no casa** con
  ningún Pod, o **ningún Pod está `Ready`**, o el `targetPort` está mal.
- Un Service **sin selector** permite gestionar los Endpoints **a mano** (apuntar
  a una IP externa fija). Es un patrón válido (p. ej., dar nombre interno a una BD
  externa con su propia IP).

---

## 8. kube-proxy y cómo se enruta un Service

La **ClusterIP es virtual**: no la tiene ninguna interfaz física. Quien hace que
"funcione" es **kube-proxy**, un agente que corre en **cada nodo** y programa las
reglas que interceptan el tráfico hacia la ClusterIP y lo **redirigen (DNAT)** a
una IP real de Pod (un endpoint).

Modos de kube-proxy:

| Modo | Cómo funciona | Notas |
| --- | --- | --- |
| `iptables` (clásico) | reglas iptables con probabilidades para balanceo | O(n) reglas; el más común |
| `ipvs` | tabla de balanceo del kernel (hash) | mejor a gran escala, más algoritmos |
| `nftables` | sucesor moderno de iptables | disponible en versiones recientes |

Lo esencial para el examen:

- kube-proxy **no es un proxy en el camino de datos** en modo iptables/ipvs: solo
  **programa el kernel**; el reenvío lo hace el propio kernel.
- El balanceo es **a nivel de conexión** (L4), aproximadamente aleatorio. No hay
  afinidad salvo que configures `sessionAffinity: ClientIP`.
- Si los Services **no responden** pero los Pods sí (por IP), sospecha de
  kube-proxy (caído, mal configurado) o del kernel del nodo.
- Algunos CNI (Cilium con eBPF) pueden **reemplazar** kube-proxy.

### externalTrafficPolicy (NodePort/LoadBalancer)

- `Cluster` (def.): el tráfico que entra por un nodo puede reenviarse a un Pod de
  **otro** nodo (segundo salto + **SNAT**, se **pierde la IP de origen** real).
- `Local`: solo enruta a Pods del **mismo nodo** que recibió el tráfico;
  **preserva la IP de origen** pero exige Pods en ese nodo.

---

## 9. DNS y descubrimiento de servicios

Kubernetes ejecuta un DNS interno (**CoreDNS**, como Deployment en `kube-system`,
expuesto por el Service `kube-dns`). Cada Pod se configura para resolver contra él
(su `/etc/resolv.conf`).

### Nombres de Service

Un Service `web` en el namespace `shop` es resoluble como:

```
web                        # desde Pods del mismo namespace (vía search domain)
web.shop                   # desde cualquier namespace
web.shop.svc.cluster.local # FQDN completo
```

El patrón es **`<servicio>.<namespace>.svc.cluster.local`**. Gracias al `search`
de `resolv.conf`, dentro del mismo namespace basta el nombre corto.

### Registros DNS

- **Service normal** → un registro **A/AAAA** que apunta a la **ClusterIP**.
- **Headless** (`clusterIP: None`) → **varios** registros A, uno por Pod listo.
- **Pods de un StatefulSet** con headless → nombre estable por Pod:
  `pod-0.web.shop.svc.cluster.local`.
- **ExternalName** → un **CNAME** al host externo.

Para el CKA:

- Diagnóstico clásico: lanzar un Pod efímero y hacer `nslookup`/`getent` a un
  Service. Si **no resuelve**, mira CoreDNS (`kubectl -n kube-system get pods`,
  logs) y el `resolv.conf` del Pod.
- El `dnsPolicy` del Pod (`ClusterFirst` por defecto) decide si usa CoreDNS.

---

## 10. Ingress e Ingress Controllers

Un **Service** tipo NodePort/LoadBalancer expone tráfico a nivel L4 (IP:puerto) y
**uno por servicio**. Para publicar **muchos servicios HTTP/HTTPS** detrás de una
sola entrada, con enrutado por **host** y **path** y terminación **TLS**, se usa
**Ingress** (L7).

Dos piezas que **no** hay que confundir:

1. **Ingress** (el recurso): reglas declarativas — "el host `a.com` va al Service
   X, el path `/api` va al Service Y, este TLS para este host".
2. **Ingress Controller** (el motor): un Pod real (NGINX, Traefik, HAProxy…) que
   **lee** los objetos Ingress y configura el proxy. **Sin un controller
   instalado, los objetos Ingress no hacen nada.**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  ingressClassName: nginx          # qué controller atiende este Ingress
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web          # enruta al Service "web"
                port:
                  number: 80
```

Conceptos clave del examen:

- **`ingressClassName`** selecciona qué controller atiende el recurso (puede haber
  varios). Sustituye a la vieja anotación `kubernetes.io/ingress.class`.
- **`pathType`**: `Prefix` (por segmentos de ruta), `Exact`, o
  `ImplementationSpecific`.
- **TLS**: se referencia un `Secret` de tipo `tls` con `tls.crt`/`tls.key`.
- El Ingress habla con **Services** (no con Pods directamente).

> **Deep-dive:** cómo funciona el Ingress por dentro (ciclo de vida de la
> petición, reconciliación del controller, data path hacia los Pods, TLS/SNI,
> rewrites y patrones avanzados) en [ingress.md](ingress.md).

---

## 11. Gateway API

La **Gateway API** es la evolución de Ingress: un modelo L4/L7 más expresivo y con
**roles separados**. Aparece en el currículum moderno del CKA, así que conviene
conocer sus tres recursos centrales:

| Recurso | Quién lo gestiona | Para qué |
| --- | --- | --- |
| `GatewayClass` | proveedor de infra | "tipo" de gateway (qué implementación) |
| `Gateway` | operador del cluster | una instancia: puertos, protocolos, TLS, listeners |
| `HTTPRoute` (y `TCPRoute`, …) | desarrollador de la app | reglas de enrutado a Services |

Idea: **separa responsabilidades** (infra vs app) que en Ingress estaban mezcladas,
y modela explícitamente protocolos más allá de HTTP. Para el CKA, basta entender
la relación `GatewayClass → Gateway → HTTPRoute → Service` y que **convive** con
Ingress (no lo elimina aún).

---

## 12. NetworkPolicies

Por defecto, **todo el tráfico Pod↔Pod está permitido** (red plana, sin
restricciones). Una **NetworkPolicy** es un "firewall" declarativo a nivel de Pod
que permite **restringir** ese tráfico por labels, namespaces y puertos.

Reglas mentales imprescindibles:

- **Solo restringen si las implementa el CNI.** Con un CNI que no las soporta
  (kindnet, Flannel puro), el objeto se crea pero **no surte efecto**.
- Son **aditivas y de tipo "allow"**: no existen reglas "deny" explícitas. El
  efecto "denegar" surge de **seleccionar** un Pod y **no** incluir ese tráfico.
- En cuanto **alguna** policy selecciona un Pod en una dirección (`Ingress` o
  `Egress`), ese Pod pasa a **denegar por defecto** en esa dirección, salvo lo
  explícitamente permitido. Pods **no seleccionados** por ninguna policy siguen
  abiertos.
- `Ingress` (entrante) y `Egress` (saliente) se controlan **por separado** vía
  `policyTypes`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-from-web
  namespace: shop
spec:
  podSelector:           # a qué Pods aplica (los "protegidos")
    matchLabels:
      app: api
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:        # solo desde Pods app=web
            matchLabels:
              app: web
      ports:
        - protocol: TCP
          port: 8080
```

Patrón clásico de examen: **deny-all** y luego abrir lo justo.

```yaml
spec:
  podSelector: {}          # selecciona TODOS los Pods del namespace
  policyTypes: [Ingress, Egress]
  # sin reglas ingress/egress -> bloquea todo en ambas direcciones
```

Matices que caen:

- `podSelector: {}` = **todos** los Pods del namespace.
- En el bloque `from`/`to`, `podSelector` y `namespaceSelector` **combinados en el
  mismo elemento** se interpretan como **AND**; en **elementos separados** de la
  lista, como **OR**. Esta distinción es trampa habitual.
- El **DNS (puerto 53)** suele necesitar permiso explícito si aplicas egress
  deny-all, o las apps dejan de resolver nombres.

---

## 13. Rangos de IP: Pod CIDR vs Service CIDR

Dos espacios de direcciones **distintos y que no deben solaparse**:

| Rango | Quién lo usa | Se configura en |
| --- | --- | --- |
| **Pod CIDR** | IPs reales de los Pods | `kubeadm --pod-network-cidr` + config del CNI |
| **Service CIDR** | ClusterIPs (virtuales) | `kube-apiserver --service-cluster-ip-range` |

Notas para el CKA:

- El **Pod CIDR** que pasas a `kubeadm init` **debe coincidir** con el que espera
  el CNI (p. ej. Calico por defecto `192.168.0.0/16`). Un desajuste deja los Pods
  sin red.
- Las **ClusterIP** salen del Service CIDR; **no son enrutables** fuera del cluster
  ni "viven" en ninguna interfaz: las materializa kube-proxy (§8).
- En multi-nodo, cada nodo recibe un **sub-rango** del Pod CIDR.

---

## 14. Troubleshooting típico del CKA

### "No puedo llegar a mi Service"

Recorre las capas de dentro hacia fuera:

1. **¿Hay endpoints?** `kubectl get endpoints <svc>` / `get endpointslices`.
   - Vacío → el **selector** no casa, los Pods no están `Ready`, o `targetPort`
     mal. Compara labels del Service con los de los Pods.
2. **¿Resuelve el DNS?** desde un Pod de prueba:
   `kubectl run tmp --image=busybox -it --rm -- nslookup <svc>`.
   - No resuelve → revisa **CoreDNS** (`-n kube-system`) y el `resolv.conf`.
3. **¿Funciona la ClusterIP?** `wget -qO- <clusterIP>:<port>` desde un Pod.
   - Falla con endpoints OK → sospecha **kube-proxy** o el **CNI**.
4. **¿Hay una NetworkPolicy** bloqueando? Revisa policies en el namespace de
   origen y destino (ingress **y** egress).

### Nodos `NotReady` / Pods en `ContainerCreating`

- Casi siempre falta el **CNI** o su DaemonSet está caído. `kubectl -n kube-system
  get pods` y mira el plugin de red.

### NetworkPolicy "no hace nada"

- ¿El **CNI** las soporta? Con kindnet/Flannel puro, **no**. Despliega
  Calico/Cilium.

### Comandos imprescindibles

```bash
kubectl get svc,endpoints,endpointslices -o wide
kubectl describe svc <svc>                 # selector, ports, type
kubectl get pods --show-labels             # ¿casan con el selector?
kubectl run tmp --image=busybox -it --rm -- sh   # Pod de pruebas (nslookup/wget)
kubectl -n kube-system get pods            # CoreDNS, kube-proxy, CNI
kubectl get networkpolicy -A
kubectl get ingress; kubectl describe ingress <ing>
```

---

## 15. Chuletas de referencia

### Tipos de Service
* `ClusterIP` = interno 
* `NodePort` = `IP_nodo:30000–32767` 
* `LoadBalancer` = LB externo 
* `ExternalName` = CNAME 
* `clusterIP: None` = headless (DNS→IPs de Pod).

### Puertos del Service
`port` = puerto del Service · `targetPort` = puerto del Pod · `nodePort` = puerto
en el nodo (solo NodePort/LB).

### DNS
`<svc>.<ns>.svc.cluster.local` · headless → varios A · StatefulSet →
`pod-0.<svc>.<ns>...`.

### NetworkPolicy
Por defecto todo permitido · seleccionar un Pod → deny-by-default en esa dirección
· solo reglas "allow" · `podSelector` + `namespaceSelector` mismo bloque = AND,
bloques separados = OR · requiere CNI que las implemente.

### Capas a diagnosticar
Pod (IP) → Endpoints → DNS → ClusterIP/kube-proxy → NetworkPolicy → Ingress.

### Ámbitos
Service, Endpoints, Ingress, NetworkPolicy = **namespace** · CNI, kube-proxy,
CoreDNS = **cluster** (componentes de sistema).

---

## Referencias a documentación oficial

> **Examen:** durante el CKA solo puedes abrir **una pestaña** a la documentación
> oficial. Dominios permitidos: `kubernetes.io/docs` (y subdominios como
> `kubernetes.io/blog`). Los enlaces de proveedores (Calico, Cilium…) son **para
> estudio**: normalmente **no** son accesibles dentro del examen.

Atajos por tema (accesibles en examen — `kubernetes.io`):

| Tema | Enlace |
| --- | --- |
| Índice Services & Networking | https://kubernetes.io/docs/concepts/services-networking/ |
| Modelo de red del cluster | https://kubernetes.io/docs/concepts/cluster-administration/networking/ |
| Service | https://kubernetes.io/docs/concepts/services-networking/service/ |
| Virtual IPs y kube-proxy (modos) | https://kubernetes.io/docs/reference/networking/virtual-ips/ |
| `externalTrafficPolicy` / traffic policy | https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/ |
| EndpointSlices | https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/ |
| DNS de Services y Pods | https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ |
| Depurar resolución DNS | https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/ |
| Ingress | https://kubernetes.io/docs/concepts/services-networking/ingress/ |
| Ingress Controllers | https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/ |
| Gateway API | https://kubernetes.io/docs/concepts/services-networking/gateway/ |
| NetworkPolicies | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| Plugins de red (CNI) | https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/ |
| Puertos y protocolos | https://kubernetes.io/docs/reference/networking/ports-and-protocols/ |
| Conectar frontend/backend con Service | https://kubernetes.io/docs/tasks/access-application-cluster/connecting-frontend-backend/ |

Referencia de API (para campos exactos de manifests):

| Recurso | Enlace |
| --- | --- |
| `Service` (v1) | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ |
| `Ingress` (networking.k8s.io/v1) | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/ingress-v1/ |
| `NetworkPolicy` (networking.k8s.io/v1) | https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/ |

---

## Siguiente paso

Con estos conceptos claros, el documento `examples.md` aplicará todo con manifests
reales: ClusterIP + NodePort, descubrimiento por DNS, headless service,
NetworkPolicy deny-all + allow selectivo, y un Ingress con enrutado por host/path.

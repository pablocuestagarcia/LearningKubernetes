# Ingress en profundidad (nivel intermedio-avanzado)

Deep-dive del **Ingress**. Amplía la §10 de [concepts.md](concepts.md): no solo
*qué* es, sino **cómo funciona por dentro** — el ciclo de vida real de una
petición, cómo el **controller** reconcilia el estado, el **data path** hacia los
Pods, **TLS/SNI**, **rewrites**, y los patrones avanzados (canary, auth, rate
limiting). Enfoque conceptual, con el peso justo de lo que entra en el CKA.

> Idea ancla: un **Ingress** es solo **datos** (reglas declarativas). El que hace
> el trabajo es el **Ingress Controller**, un proxy L7 real (NGINX, HAProxy,
> Traefik, Envoy…) que **observa** esos datos y **reconfigura su proxy**. Sin
> controller, el objeto Ingress no hace absolutamente nada.

---

## Índice

1. [El problema que resuelve y por qué L7](#1-el-problema-que-resuelve-y-por-qué-l7)
2. [Las dos piezas: recurso vs controller](#2-las-dos-piezas-recurso-vs-controller)
3. [El ciclo de vida completo de una petición](#3-el-ciclo-de-vida-completo-de-una-petición)
4. [Cómo reconcilia el controller (el bucle interno)](#4-cómo-reconcilia-el-controller-el-bucle-interno)
5. [Cómo entra el tráfico al controller](#5-cómo-entra-el-tráfico-al-controller)
6. [El data path: ¿el controller pasa por el Service?](#6-el-data-path-el-controller-pasa-por-el-service)
7. [IngressClass en profundidad](#7-ingressclass-en-profundidad)
8. [Reglas de enrutado: host, path y pathType](#8-reglas-de-enrutado-host-path-y-pathtype)
9. [Default backend](#9-default-backend)
10. [TLS, terminación y SNI](#10-tls-terminación-y-sni)
11. [Annotations: el "escape hatch" del controller](#11-annotations-el-escape-hatch-del-controller)
12. [Rewrites y manipulación de path](#12-rewrites-y-manipulación-de-path)
13. [Patrones avanzados](#13-patrones-avanzados)
14. [Troubleshooting](#14-troubleshooting)
15. [Ingress vs Gateway API](#15-ingress-vs-gateway-api)
16. [Qué entra de esto en el CKA](#16-qué-entra-de-esto-en-el-cka)
17. [Chuleta de referencia](#17-chuleta-de-referencia)

---

## 1. El problema que resuelve y por qué L7

Un **Service** publica tráfico a nivel **L4** (IP:puerto) y **uno por servicio**:

- `NodePort` → un puerto distinto por servicio, feo y difícil de recordar.
- `LoadBalancer` → **una IP de LB (y un coste) por servicio**. Publicar 30
  microservicios = 30 balanceadores. No escala ni en dinero ni en gestión.

Además, L4 **no entiende HTTP**: no puede mirar el **Host**, el **path**, las
cabeceras, ni terminar **TLS** por dominio. Para publicar muchos servicios
HTTP(S) detrás de **una sola entrada**, con enrutado por **host/path** y
**TLS centralizado**, necesitas un proxy **L7**. Eso es el Ingress.

Mentalmente: el Ingress es un **reverse proxy / virtual hosting** declarado con
recursos de Kubernetes. La novedad no es el proxy (lleva décadas existiendo),
sino que su **configuración se genera automáticamente** desde objetos del API.

---

## 2. Las dos piezas: recurso vs controller

Es **el** punto que separa entender Ingress de no entenderlo:

| Pieza | Qué es | Quién la crea | Analogía |
| --- | --- | --- | --- |
| **Ingress** (recurso) | reglas declarativas (host→Service, path→Service, TLS) | tú (`kubectl apply`) | el fichero de config deseado |
| **Ingress Controller** | un Pod real con un proxy L7 + un bucle de control | se instala una vez (Helm/manifests) | el nginx que lee esa config y sirve |

El controller hace **dos trabajos a la vez**:

1. **Control plane**: observa los objetos `Ingress` (y `Service`, `Endpoints`,
   `Secret`…) y **traduce** sus reglas a la config nativa del proxy.
2. **Data plane**: es el proxy que **recibe el tráfico real** de los clientes y
   lo reenvía a los Pods backend.

Por eso **instalar el controller es un prerrequisito**: sin él, `kubectl get
ingress` muestra tu objeto, pero no hay nada escuchando ni traduciendo. Es el
error nº1 de principiante ("creé el Ingress y no responde").

---

## 3. El ciclo de vida completo de una petición

Sigamos una petición `https://shop.example.com/api/orders` de principio a fin:

1. **DNS externo**: `shop.example.com` resuelve (fuera de Kubernetes, en tu DNS
   público) a la **IP de entrada del controller** — la IP del LoadBalancer o de
   los nodos (NodePort). *Kubernetes no gestiona este DNS.*
2. **Llega al controller**: el paquete entra por el Service del controller
   (LoadBalancer/NodePort) → kube-proxy → el **Pod del controller** (el proxy).
3. **Terminación TLS**: el proxy presenta el certificado correcto según el **SNI**
   (`shop.example.com`), descifra y ahora ve el HTTP en claro.
4. **Matching de reglas**: el proxy mira el **Host** (`shop.example.com`) y el
   **path** (`/api/orders`) y busca la regla de Ingress que casa → backend
   `Service: orders, port: 80`.
5. **Resolución de backend**: el controller ya tiene precargados los
   **Endpoints** (IPs de Pod) de ese Service. Elige un Pod **sano** y balancea.
6. **Reenvío al Pod**: el proxy abre/reusa una conexión al **Pod backend** y le
   pasa la petición (posiblemente con rewrites de path y cabeceras añadidas como
   `X-Forwarded-For`/`X-Forwarded-Proto`).
7. **Respuesta**: vuelve por el mismo proxy al cliente.

Observa que hay **dos saltos de balanceo**: el L4 (kube-proxy→Pod del controller)
y el L7 (controller→Pod backend). Y que el **TLS se termina en el controller**
(salvo passthrough, §10).

---

## 4. Cómo reconcilia el controller (el bucle interno)

Aquí está la parte "avanzada" que pocos miran. El controller es un **operador**
clásico con un bucle *watch → diff → apply*:

1. **Watch**: abre *watches* al API server sobre `Ingress`, `IngressClass`,
   `Service`, `Endpoints`/`EndpointSlice`, `Secret` (para los TLS) y su propia
   `ConfigMap` de tuning.
2. **Build model**: cada cambio dispara una **reconstrucción del modelo interno**:
   todas las reglas de todos los Ingress que le pertenecen (por `ingressClassName`)
   se fusionan en una tabla de virtual hosts → paths → upstreams.
3. **Render + apply**: traduce ese modelo a la config nativa del proxy.
   - En **NGINX Ingress** clásico: **renderiza un `nginx.conf`** y hace `reload`
     (con optimizaciones: muchos cambios de endpoints se aplican vía **Lua** sin
     recargar, para no cortar conexiones).
   - En **Traefik/Envoy-based** (Contour): config **dinámica en caliente**, sin
     recargar el proceso.
4. **Status update**: escribe de vuelta en `ingress.status.loadBalancer.ingress`
   la IP/host de entrada — por eso `kubectl get ingress` muestra una `ADDRESS`.

Implicaciones intermedias-avanzadas:

- El controller **vigila Endpoints, no solo el Service**: cuando un Pod backend se
  vuelve `Ready`/`NotReady`, el upstream se actualiza casi al instante.
- Un `Secret` TLS mal referenciado o un Service inexistente **no rompen todo**:
  esa regla concreta queda inservible mientras el resto sigue.
- Recargar config (modelo NGINX clásico) tiene un **coste**; por eso los grandes
  despliegues prefieren dataplanes dinámicos.

---

## 5. Cómo entra el tráfico al controller

Sutileza que confunde: **el propio controller necesita ser expuesto** al exterior.
Es un Pod, y como cualquier Pod no es accesible desde fuera por sí mismo. Se
expone con un **Service** propio, típicamente:

- **`LoadBalancer`** (en cloud): el proveedor da una IP pública; tu DNS apunta ahí.
- **`NodePort`** (on-prem/bare-metal/kind): el controller escucha en un puerto de
  todos los nodos; delante sueles poner un LB externo (o **MetalLB** para emular
  `LoadBalancer` on-prem).
- **`hostNetwork`/`hostPort`**: el Pod del controller usa directamente los puertos
  80/443 del nodo (común en bare-metal para evitar el salto NodePort).

El "chicken-and-egg": **el tráfico externo llega primero a un Service L4** (el del
controller) y **solo entonces** entra en juego la lógica L7 del Ingress. El
Ingress **no sustituye** a Services tipo LoadBalancer/NodePort: se **apoya** en uno
para su propia entrada, y multiplexa por L7 hacia los Services internos
(ClusterIP) de tus apps.

```
Internet → [Service LB/NodePort del controller] → [Pod controller (proxy L7)]
         → (mira Host/path, termina TLS) → [Endpoints del Service de tu app] → [Pod]
```

---

## 6. El data path: ¿el controller pasa por el Service?

Pregunta avanzada y muy reveladora. En el Ingress declaras `backend.service.name`,
pero **la mayoría de controllers NO enrutan a través de la ClusterIP** de ese
Service. En su lugar:

- Usan el Service solo para **descubrir sus Endpoints** (las IPs de Pod) y
  **balancean ellos mismos**, conectándose **directamente a los Pods**.

¿Por qué? Para **saltarse kube-proxy** y tener balanceo L7 propio: reintentos,
sticky sessions, health checks activos, *slow start*, peso por endpoint, keep-alive
a upstreams… cosas que la ClusterIP (L4, aleatoria) no ofrece.

Consecuencias prácticas:

- El **balanceo real** lo decide el controller, no kube-proxy → el algoritmo y la
  afinidad son los del controller, no `sessionAffinity` del Service.
- Si un Service **no tiene Endpoints** (selector mal, Pods `NotReady`), el Ingress
  devuelve **502/503** aunque la regla esté perfecta. Diagnosticar Ingress
  **siempre** incluye revisar `kubectl get endpoints <svc>`.
- Algunos controllers permiten elegir el modo (servicio vs endpoints) por
  annotation, pero el **endpoint-directo** es el comportamiento dominante.

> Regla mental: el Service del backend en un Ingress funciona más como un
> **selector de Pods** que como un proxy. La ClusterIP suele quedar fuera del
> camino de datos.

---

## 7. IngressClass en profundidad

En un cluster puede haber **varios controllers** (p. ej. uno público y otro
interno). `IngressClass` resuelve **qué controller atiende cada Ingress**:

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"   # opcional
spec:
  controller: k8s.io/ingress-nginx     # identifica QUÉ implementación la sirve
```

Puntos finos:

- En el Ingress se referencia con **`spec.ingressClassName: nginx`** (campo de
  primera clase). Sustituye a la **vieja annotation** `kubernetes.io/ingress.class`
  (deprecada, aún soportada por compatibilidad).
- `spec.controller` es un **identificador inmutable** del controller; cada
  implementación tiene el suyo (`k8s.io/ingress-nginx`, `traefik.io/ingress-controller`…).
- Con la annotation `is-default-class: "true"`, los Ingress **sin**
  `ingressClassName` van a esa clase. Si **no** hay default y omites la clase, el
  Ingress queda **huérfano** (ningún controller lo coge) → no responde.
- Un controller **ignora** los Ingress de clases que no le pertenecen. Es la base
  del multi-controller.

---

## 8. Reglas de enrutado: host, path y pathType

El cuerpo del Ingress es una lista de **reglas** host→paths→backend:

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service: { name: web, port: { number: 80 } }
```

### Host matching

- Una regla **sin `host`** casa con **cualquier** host (catch-all).
- Soporta **wildcard** `*.example.com` (un único nivel: casa `a.example.com`,
  **no** `a.b.example.com` ni el dominio desnudo).
- El matching de host es por **cabecera `Host`** de la petición (virtual hosting).

### pathType — la fuente nº1 de sorpresas

| `pathType` | Semántica |
| --- | --- |
| `Prefix` | casa por **segmentos de ruta** completos: `/api` casa `/api` y `/api/x`, **no** `/apinextra` |
| `Exact` | coincidencia **exacta** de la URL path, sensible a mayúsculas |
| `ImplementationSpecific` | lo decide el controller (NGINX puede tratarlo como **regex**) |

Gotchas que caen en entrevistas y exámenes:

- `Prefix` compara **por segmentos**, no por substring: `/api` **no** casa
  `/apiv2`. Mucha gente lo asume mal.
- La **precedencia**: ante varios paths que casan, gana el **más específico**
  (path más largo). Con hosts, un host explícito gana al catch-all.
- `ImplementationSpecific` rompe la portabilidad entre controllers: lo que con
  NGINX es regex, con otro controller puede no serlo.

---

## 9. Default backend

Qué pasa con una petición que **no casa ninguna regla** (host/path desconocido):

- Va al **default backend** del controller, que típicamente responde **404**.
- Es configurable (un Service propio) para servir una página de error de marca o
  un health endpoint.
- En NGINX Ingress es un componente desplegado junto al controller.

Útil saberlo para diagnosticar: si **todo** devuelve el 404 genérico del default
backend, tus reglas **no están casando** (host equivocado, clase huérfana, o el
controller no ve tu Ingress).

---

## 10. TLS, terminación y SNI

El Ingress centraliza **HTTPS**. Se declara con la sección `tls`:

```yaml
spec:
  tls:
    - hosts:
        - shop.example.com
      secretName: shop-tls       # Secret tipo kubernetes.io/tls (tls.crt + tls.key)
  rules:
    - host: shop.example.com
      ...
```

Conceptos intermedios-avanzados:

- **Terminación TLS** (lo normal): el **controller descifra**; del controller al
  Pod el tráfico viaja **en claro dentro del cluster** (o re-cifrado si configuras
  *backend HTTPS*). Centraliza certificados y descarga de TLS a los apps.
- **SNI** (Server Name Indication): como un solo controller sirve **muchos
  dominios** por la misma IP:443, usa el **SNI del handshake TLS** para elegir
  **qué certificado** presentar. Por eso cada `host` puede tener su `secretName`.
- El **Secret TLS** vive en el **mismo namespace** que el Ingress; es de tipo
  `kubernetes.io/tls` con claves `tls.crt` y `tls.key`.
- **cert-manager** automatiza la emisión/renovación (Let's Encrypt) y rellena esos
  Secrets — patrón estándar en producción (fuera del CKA, pero conviene nombrarlo).
- **TLS passthrough**: algunos controllers permiten **no terminar** TLS y pasar el
  handshake intacto al backend (el Pod hace la terminación). Necesario cuando el
  backend exige mTLS de extremo a extremo; se activa por annotation y **pierde** la
  capacidad de enrutar por path (el proxy no ve el HTTP).

---

## 11. Annotations: el "escape hatch" del controller

El recurso `Ingress` estándar es **deliberadamente minimalista** (host, path, TLS,
backend). Todo lo demás —rewrites, auth, rate limiting, timeouts, CORS, tamaños de
body, sticky sessions— se configura con **annotations específicas del controller**.

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
```

Implicaciones clave:

- Las annotations **NO son portables**: `nginx.ingress.kubernetes.io/*` no las
  entiende Traefik, y viceversa. Migrar de controller = reescribir annotations.
- Es la razón principal por la que nació la **Gateway API** (§15): mover esa
  configuración de "annotations mágicas en strings" a **campos tipados** de
  recursos propios.
- Hay **dos niveles** de tuning: por-Ingress (annotations) y **global** (la
  `ConfigMap` del controller: timeouts por defecto, log format, worker processes…).

---

## 12. Rewrites y manipulación de path

Caso clásico: expones `shop.example.com/api/...` pero tu app espera recibir las
rutas **sin** el prefijo `/api`. El controller debe **reescribir** el path antes de
reenviar:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
    - http:
        paths:
          - path: /api(/|$)(.*)     # grupos de captura
            pathType: ImplementationSpecific
            backend:
              service: { name: api, port: { number: 80 } }
```

Aquí `/api/orders` → el grupo `$2` captura `orders` → el backend recibe `/orders`.
Notas:

- Requiere `pathType: ImplementationSpecific` porque usa **regex** (no portable).
- Es una fuente habitual de **404 del backend**: la regla casa y llega al Pod, pero
  con un path que la app no conoce → el fallo parece de red pero es de **rewrite**.
- Otras manipulaciones por annotation: añadir/quitar cabeceras, forzar
  `ssl-redirect`, `app-root`, `configuration-snippet` (inyectar config NGINX cruda
  — potente y peligroso).

---

## 13. Patrones avanzados

Lo que los controllers modernos ofrecen sobre el Ingress básico (vía annotations o
CRDs propias):

- **Canary / traffic splitting**: enviar un % del tráfico a una versión nueva
  (`nginx.ingress.kubernetes.io/canary: "true"` + `canary-weight: "10"`), o por
  cabecera/cookie. Base de despliegues progresivos.
- **Sticky sessions (afinidad)**: cookie de sesión para fijar un cliente a un Pod
  (`affinity: cookie`). Recuerda: como el controller balancea por Endpoints (§6),
  esta afinidad la gestiona **él**, no el Service.
- **Autenticación**: básica (`auth-basic`) o **external auth** (`auth-url` apunta a
  un servicio que valida cada request — SSO/OAuth2-proxy).
- **Rate limiting**: límites por IP/conexión (`limit-rps`, `limit-connections`).
- **Timeouts y reintentos** hacia el upstream, **proxy buffering**, límites de
  tamaño de body.
- **Backend HTTPS / mTLS**: re-cifrar del controller al Pod, o exigir certificado
  de cliente (`auth-tls-*`).
- **CORS**, redirecciones permanentes, *custom error pages*.

Todo esto vive **fuera** del esquema estándar del Ingress → de nuevo, el argumento
para Gateway API.

---

## 14. Troubleshooting

Recorrido de diagnóstico de fuera hacia dentro:

1. **¿El Ingress tiene `ADDRESS`?** `kubectl get ingress`. Vacío → el controller no
   lo ha "adoptado": revisa **`ingressClassName`** (clase huérfana) y que el
   controller esté vivo.
2. **¿Resuelve el DNS** del host a la IP del controller? (DNS externo, fuera de k8s).
3. **¿Llega al controller?** `kubectl -n <ns-ingress> logs <pod-controller>` —
   verás la request, el host/path que matcheó y el upstream elegido.
4. **502/503/504**: casi siempre **backend**, no Ingress.
   - **502/503**: el Service **no tiene Endpoints** (`kubectl get endpoints <svc>`),
     Pods `NotReady`, o `targetPort` mal.
   - **504**: timeout — el Pod tarda o no responde.
5. **404 del default backend en todo**: ninguna regla casa → host equivocado,
   `pathType` mal entendido, o `ingressClassName` incorrecto.
6. **404 desde la app (no del controller)**: la regla casó pero el **rewrite** dejó
   un path que la app no conoce (§12).
7. **Errores TLS / certificado equivocado**: `secretName` mal, Secret en otro
   namespace, o el host no coincide con el del certificado (SNI).

```bash
kubectl get ingress -o wide
kubectl describe ingress <ing>                 # reglas, eventos, TLS
kubectl -n <ns> get pods -l <controller>       # ¿controller vivo?
kubectl -n <ns> logs deploy/<controller>       # request real, upstream, errores
kubectl get endpoints <svc-backend>            # ¿el backend tiene Pods sanos?
```

---

## 15. Ingress vs Gateway API

Por qué existe el sucesor (ver también [concepts.md §11](concepts.md#11-gateway-api)):

| | Ingress | Gateway API |
| --- | --- | --- |
| Configuración avanzada | **annotations** (strings, no portables) | **campos tipados** en CRDs |
| Roles | todo mezclado en un objeto | separados: `GatewayClass`/`Gateway`/`*Route` |
| Protocolos | HTTP/HTTPS | HTTP, TCP, UDP, TLS, gRPC |
| Traffic splitting, headers | depende de annotations | **nativo** en `HTTPRoute` |
| Multi-tenant / delegación | limitada | diseñada para ello (refs entre namespaces) |

Mentalmente: Gateway API **estandariza** lo que el Ingress dejaba a annotations
propietarias. **Convive** con Ingress (no lo elimina aún); muchos controllers
implementan ambos.

---

## 16. Qué entra de esto en el CKA

Calibrando para no estudiar de más:

- ✅ **Sí entra:** crear un `Ingress` con reglas host/path correctas, entender la
  distinción **recurso vs controller**, asignar `ingressClassName`, configurar
  **TLS** con un Secret, y **diagnosticar** (no `ADDRESS`, 502 por falta de
  Endpoints, clase huérfana). Saber que **el controller debe estar instalado**.
- ➖ **Menos probable:** annotations avanzadas concretas (canary, rewrites con
  regex, external auth) — útiles de conocer, pero dependen del controller.
- 🧪 **En tu lab (kind):** no hay LoadBalancer real; el patrón es desplegar
  **ingress-nginx** con `extraPortMappings` en kind (mapear 80/443 del host al
  nodo) o exponerlo por NodePort, y probar `curl -H "Host: ..."` contra
  `localhost`. Es el experimento natural para cerrar este tema.

> **Atajo de examen:** genera el Ingress sin escribir YAML con
> `kubectl create ingress web --class=nginx --rule="host/path*=svc:port[,tls=secret]"`.
> Ver [comandos-rapidos.md §4](comandos-rapidos.md#4-ingress).

---

## 17. Chuleta de referencia

### Las dos piezas
**Ingress** = datos (reglas) · **Ingress Controller** = el proxy L7 que los lee y
sirve. Sin controller, nada responde.

### El camino
DNS externo → Service LB/NodePort del controller → Pod controller (termina TLS,
mira Host/path) → **Endpoints del Service backend** → Pod. El controller suele
saltarse la ClusterIP y balancear a Pods directamente.

### pathType
`Prefix` = por segmentos (`/api` no casa `/apiv2`) · `Exact` = exacto ·
`ImplementationSpecific` = lo decide el controller (regex en NGINX).

### Clase
`spec.ingressClassName` (no la annotation vieja) elige el controller. Sin clase ni
default → Ingress **huérfano**.

### TLS
Secret `kubernetes.io/tls` (`tls.crt`/`tls.key`) en el **mismo namespace** ·
multi-dominio por **SNI** · passthrough = no terminar (pierde enrutado por path).

### Síntomas
Sin `ADDRESS` → clase/controller · 502/503 → Endpoints del backend · 404 genérico
→ ninguna regla casa · 404 de la app → rewrite.

### Lo no estándar
Rewrites, auth, canary, rate limiting, sticky → **annotations del controller**, no
portables. Gateway API lo vuelve tipado.

---

## Referencias a documentación

> **Examen:** copia la plantilla base del Ingress desde la doc oficial
> (`kubernetes.io/docs/.../ingress/`) — es el atajo más rápido para no escribir el
> YAML de memoria. Las annotations y la config del controller (ingress-nginx) son
> **para estudio**: dependen del controller y **no** son accesibles en el examen.

Accesible en examen (`kubernetes.io`):

| Tema | Enlace |
| --- | --- |
| Ingress (concepto + ejemplos YAML) | https://kubernetes.io/docs/concepts/services-networking/ingress/ |
| Ingress Controllers | https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/ |
| `IngressClass` y default class | https://kubernetes.io/docs/concepts/services-networking/ingress/#ingress-class |
| TLS en Ingress | https://kubernetes.io/docs/concepts/services-networking/ingress/#tls |
| `pathType` y tipos de path | https://kubernetes.io/docs/concepts/services-networking/ingress/#path-types |
| Secret TLS (`kubernetes.io/tls`) | https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets |
| Gateway API (sucesor) | https://kubernetes.io/docs/concepts/services-networking/gateway/ |
| API ref `Ingress` v1 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/ingress-v1/ |

Solo para estudio (controllers y herramientas):

| Recurso | Enlace |
| --- | --- |
| ingress-nginx (annotations, instalación) | https://kubernetes.github.io/ingress-nginx/ |
| Traefik (Ingress) | https://doc.traefik.io/traefik/ |
| Gateway API (spec completa) | https://gateway-api.sigs.k8s.io/ |
| cert-manager (TLS automático) | https://cert-manager.io/docs/ |

---

## Relación con el resto del módulo

- Base de Services y por qué L4 se queda corto: [concepts.md §6](concepts.md#6-tipos-de-service).
- Endpoints (lo que el controller realmente consume): [concepts.md §7](concepts.md#7-endpoints-y-endpointslices).
- El sucesor tipado: [concepts.md §11](concepts.md#11-gateway-api).
- Quién materializa la entrada L4 del controller: [concepts.md §8](concepts.md#8-kube-proxy-y-cómo-se-enruta-un-service).

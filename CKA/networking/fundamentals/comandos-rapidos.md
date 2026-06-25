# Comandos rápidos y setup del examen (networking)

Chuleta **operativa** del módulo: el setup del entorno que merece la pena
configurar al empezar el examen y los **comandos imperativos** que evitan escribir
YAML a mano para los recursos de red. Pensado para tenerlo abierto y copiar rápido.

> Filosofía del CKA: **cada segundo cuenta**. Generar el recurso con un comando
> imperativo (o volcar su YAML con `--dry-run=client -o yaml` y editar solo lo
> imprescindible) es casi siempre más rápido y menos propenso a errores de
> indentación que escribir el manifest desde cero.

---

## Índice

1. [Setup del entorno (transversal a todo el CKA)](#1-setup-del-entorno-transversal-a-todo-el-cka)
2. [El patrón base: imperativo vs `--dry-run`](#2-el-patrón-base-imperativo-vs---dry-run)
3. [Services](#3-services)
4. [Ingress](#4-ingress)
5. [NetworkPolicy: el que NO tiene generador](#5-networkpolicy-el-que-no-tiene-generador)
6. [Pods de prueba y diagnóstico de red](#6-pods-de-prueba-y-diagnóstico-de-red)
7. [Inspección rápida (get/describe con formato)](#7-inspección-rápida-getdescribe-con-formato)
8. [Chuleta condensada](#8-chuleta-condensada)

---

## 1. Setup del entorno (transversal a todo el CKA)

> Esta sección **no es solo de networking**: aplica a todo el examen. Vive aquí de
> momento; si más adelante creamos una guía raíz del CKA, se promueve allí.

Lo primero al entrar al examen. Cuesta ~30 s y ahorra minutos.

### Alias y variables de atajo

```bash
alias k=kubectl

# "do" = dry output: genera YAML sin crear nada
export do='--dry-run=client -o yaml'

# "now" = borrado inmediato (sin esperar grace period)
export now='--force --grace-period=0'
```

Uso típico: `k create ingress web --rule="..." $do > ing.yaml` y editas; o
`k delete pod tmp $now`.

### Autocompletado (incluido el alias `k`)

```bash
source <(kubectl completion bash)
complete -o default -F __start_kubectl k    # que el TAB funcione también con "k"
```

> En el entorno del examen `alias k=kubectl` y el completion **suelen venir ya
> configurados**; verifica con `k version` antes de reconfigurar. Si usas otra
> shell, sustituye `bash` por `zsh`.

### Namespace por defecto del contexto

Evita teclear `-n <ns>` en cada comando del ejercicio:

```bash
kubectl config set-context --current --namespace=<ns>
```

### `vim` para YAML (clave para no romper la indentación)

En `~/.vimrc`:

```vim
set expandtab      " tabs -> espacios (YAML no admite tabs)
set tabstop=2
set shiftwidth=2
set number
" antes de pegar bloques grandes: :set paste  (evita auto-indent en cascada)
```

`expandtab` + `shiftwidth=2` es lo que evita el error clásico de YAML con tabs.
Para pegar, `:set paste` y luego `:set nopaste`.

---

## 2. El patrón base: imperativo vs `--dry-run`

Dos velocidades, según el recurso lo permita:

- **Imperativo puro** (crea ya): cuando el comando soporta todo lo que necesitas.
  `k expose ...`, `k create service ...`, `k create ingress ...`.
- **`--dry-run=client -o yaml` + editar** (`$do`): cuando necesitas un campo que el
  comando **no** expone (p. ej. `clusterIP: None`, `sessionAffinity`, varias reglas
  raras, o **cualquier** NetworkPolicy). Generas el esqueleto y retocas lo justo.

```bash
k expose deploy web --port=80 $do > svc.yaml   # genera y edita
k create -f svc.yaml
```

Regla mental: **primero intenta imperativo; si falta un campo, cae a `$do`.**

---

## 3. Services

### Exponer algo existente (`expose`) — lo más rápido

```bash
# ClusterIP (por defecto) a partir de un Deployment
k expose deployment web --port=80 --target-port=8080

# NodePort
k expose deploy web --port=80 --type=NodePort

# Exponer un Pod y nombrar el Service
k expose pod nginx --port=80 --name=web

# Headless (DNS -> IPs de Pod): el flag de cluster-ip
k expose deploy db --port=5432 --cluster-ip=None --name=db
```

### Crear un Service "de cero" (`create service`)

```bash
k create service clusterip my-svc --tcp=80:8080
k create service nodeport  my-svc --tcp=80:8080 --node-port=30080
k create service externalname my-svc --external-name=db.example.com
k create service clusterip db --tcp=5432 --clusterip=None    # headless
```

### Pod + Service en un solo comando

```bash
k run nginx --image=nginx --port=80 --expose    # crea el Pod y un ClusterIP igual
```

> **`port` vs `target-port`**: `--port` es el del Service; `--target-port` el del
> Pod. Si los omites iguales, `expose` asume `targetPort = port`.

---

## 4. Ingress

`kubectl create ingress` cubre casi todo sin tocar YAML. Sintaxis de regla:
**`host/path=service:port`** (el `*` en el path lo vuelve `Prefix`/`pathType`
amplio según el controller).

```bash
# Regla simple host + path -> service:port
k create ingress web --rule="shop.example.com/=web:80"

# Varias reglas (repite --rule) + clase + path tipo prefijo
k create ingress web \
  --class=nginx \
  --rule="shop.example.com/api*=api:80" \
  --rule="shop.example.com/*=web:80"

# Con TLS (referencia a un Secret tipo kubernetes.io/tls)
k create ingress web --rule="shop.example.com/*=web:80,tls=shop-tls"

# Default backend y annotations
k create ingress web --default-backend=web:80 \
  --annotation nginx.ingress.kubernetes.io/rewrite-target=/

# ¿Falta un campo raro? genera y edita
k create ingress web --rule="shop.example.com/*=web:80" $do > ing.yaml
```

> Recuerda: el Secret TLS debe existir en el **mismo namespace**. Crearlo rápido:
> `k create secret tls shop-tls --cert=tls.crt --key=tls.key`.

---

## 5. NetworkPolicy: el que NO tiene generador

**Importante:** `kubectl` **no** tiene un generador imperativo para
`NetworkPolicy`. No hay `k create networkpolicy ...` con reglas. Opciones:

1. **Copiar la plantilla** desde la doc oficial
   (`kubernetes.io/docs/concepts/services-networking/network-policies/`) — el atajo
   real en el examen.
2. Tener memorizado el esqueleto **deny-all** y construir desde ahí:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}                 # todos los Pods del namespace
  policyTypes: [Ingress, Egress]  # sin reglas -> bloquea todo
```

> Por eso en el módulo se insiste en entender la **lógica** de las policies
> ([concepts.md §12](concepts.md#12-networkpolicies)): aquí no hay atajo
> imperativo que te salve, hay que escribir YAML.

---

## 6. Pods de prueba y diagnóstico de red

El caballo de batalla: lanzar un Pod efímero, probar y que se borre solo.

```bash
# Resolver un Service por DNS
k run tmp --image=busybox --rm -it --restart=Never -- nslookup web

# Golpear una ClusterIP / nombre de Service por HTTP
k run tmp --image=busybox --rm -it --restart=Never -- wget -qO- http://web:80

# FQDN entre namespaces
k run tmp --image=busybox --rm -it --restart=Never -- \
  wget -qO- http://web.shop.svc.cluster.local

# Imagen con más herramientas (curl, dig, etc.)
k run tmp --image=nicolaka/netshoot --rm -it --restart=Never -- bash
```

Claves de los flags: `--rm` (se borra al salir), `-it` (interactivo),
`--restart=Never` (Pod, no Deployment). Si solo quieres una orden y salir, ponla
tras `--`.

---

## 7. Inspección rápida (get/describe con formato)

```bash
# Servicios y sus endpoints de un vistazo (¿el Service enruta a algo?)
k get svc,ep -o wide
k get endpointslices -l kubernetes.io/service-name=web

# ¿Los labels de los Pods casan con el selector del Service?
k get pods --show-labels
k describe svc web | grep -i -A3 endpoints

# Ingress con su ADDRESS y reglas
k get ingress -o wide
k describe ingress web

# Estado de los componentes de red del sistema
k -n kube-system get pods -o wide        # CoreDNS, kube-proxy, CNI
k get networkpolicy -A

# Columnas a medida (rápido para ver IP/nodo de Pods)
k get pods -o wide
k get pods -o custom-columns=NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName
```

---

## 8. Chuleta condensada

### Setup (al entrar)
`alias k=kubectl` · `export do='--dry-run=client -o yaml'` ·
`export now='--force --grace-period=0'` · `completion` · `vimrc` (`expandtab`,
`shiftwidth=2`) · `set-context --namespace`.

### Service
`k expose deploy X --port=80 --target-port=8080` · `--type=NodePort` ·
`--cluster-ip=None` (headless) · `k create service nodeport X --tcp=80:8080
--node-port=30080` · `k run X --image=... --port=80 --expose`.

### Ingress
`k create ingress X --class=nginx --rule="host/path*=svc:port[,tls=secret]"` ·
`--default-backend=svc:port` · `--annotation k=v`.

### NetworkPolicy
**Sin generador** → copia de la doc o esqueleto deny-all + `$do`.

### Diagnóstico
`k run tmp --image=busybox --rm -it --restart=Never -- nslookup/wget` ·
`k get svc,ep -o wide` · `k get pods --show-labels`.

### Cae a `$do` cuando
necesitas `clusterIP: None`, `sessionAffinity`, `externalTrafficPolicy`,
o **cualquier** NetworkPolicy.

---

## Relación con el resto del módulo

- La teoría que estos comandos materializan: [concepts.md](concepts.md).
- Por qué NetworkPolicy no tiene atajo: [concepts.md §12](concepts.md#12-networkpolicies).
- Crear Ingress y su TLS: [ingress.md](ingress.md).
- Enlaces a la doc oficial (plantillas a copiar): sección "Referencias" de cada
  documento.

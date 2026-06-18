# CKA — Fundamentos de storage: ejercicios prácticos

Laboratorios estilo examen para practicar la abstracción nativa de almacenamiento.
La teoría está en [concepts.md](concepts.md); aquí se **aplica** paso a paso.

> **Entorno.** Pensado para el cluster kubeadm de
> [../../setup/multipass](../../setup/multipass) (5 VMs: `cka-cp`, `cka-w1/2`
> workers, `cka-data1/2` storage tainteados). Apunta `kubectl` antes de empezar:
>
> ```powershell
> $env:KUBECONFIG = "C:\...\CKA\setup\multipass\kubeconfig"
> kubectl get nodes
> ```
>
> Sirve igual en la variante kind; donde haya diferencias se indica.

## Índice de labs

| Lab | Concepto | Estado |
| --- | --- | --- |
| [Lab 1](#lab-1--pv--pvc--pod-con-almacenamiento-de-nodo-estático) | PV + PVC **estáticos** (hostPath), montaje en Pod, persistencia, reclaim | ✅ |
| [Lab 2](#lab-2--storageclass-y-aprovisionamiento-dinámico) | **StorageClass**: qué es, default, aprovisionamiento dinámico | ✅ |

Cada lab trae **enunciado** (resuélvelo tú primero), **solución**, **verificación**
y **limpieza**. La idea es que escribas el YAML a mano, como en el examen.

---

## Lab 1 — PV + PVC + Pod con almacenamiento de nodo (estático)

### Enunciado (estilo examen)

> En el namespace `storage-lab`, un compañero necesita un volumen persistente de
> **1Gi** servido desde el directorio `/mnt/data/web` del nodo `cka-w1`.
>
> 1. Crea un **PersistentVolume** llamado `pv-web` de **1Gi**, modo de acceso
>    **RWO**, política de reclamación **Retain**, sin StorageClass, respaldado por
>    un `hostPath` en `/mnt/data/web` de `cka-w1`.
> 2. Crea un **PersistentVolumeClaim** llamado `pvc-web` que pida **1Gi** RWO y
>    quede **enlazado** a ese PV.
> 3. Crea un **Pod** `web` (imagen `nginx:1.27`) que monte el PVC en
>    `/usr/share/nginx/html`.
> 4. Demuestra que el dato **persiste**: escribe un `index.html`, borra y recrea el
>    Pod, y comprueba que el contenido sigue ahí.

Intenta resolverlo antes de mirar la solución. Pistas: ámbitos (PV/SC = cluster,
PVC = namespace), el `storageClassName: ""` para binding estático puro, y que
hostPath está **atado al nodo** (hay que fijar el Pod a `cka-w1`).

### Solución

**Namespace:**

```bash
kubectl create namespace storage-lab
```

**PV + PVC** (`lab1-pv-pvc.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-web              # PV = recurso de CLUSTER, sin namespace
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""      # binding estático puro: NO uses provisioner dinámico
  hostPath:
    path: /mnt/data/web
    type: DirectoryOrCreate # crea el dir en el nodo si no existe
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-web
  namespace: storage-lab    # PVC = recurso de NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ""      # debe casar con el del PV ("" enlaza con "")
```

```bash
kubectl apply -f lab1-pv-pvc.yaml
kubectl get pv pv-web
kubectl -n storage-lab get pvc pvc-web
```

`pvc-web` debe aparecer `Bound` a `pv-web`. Si se queda `Pending`, ve a
[Troubleshooting](#troubleshooting-del-lab-1).

**Pod que monta el PVC** (`lab1-pod.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: storage-lab
spec:
  nodeName: cka-w1          # hostPath está atado al nodo -> fija el Pod ahí
  containers:
    - name: web
      image: nginx:1.27
      volumeMounts:
        - name: datos                       # <- mismo nombre que en volumes[]
          mountPath: /usr/share/nginx/html
  volumes:
    - name: datos
      persistentVolumeClaim:
        claimName: pvc-web                  # consume el PVC del namespace
```

```bash
kubectl apply -f lab1-pod.yaml
kubectl -n storage-lab get pod web -o wide   # debe estar Running en cka-w1
```

### Verificación de persistencia

Escribe un fichero en el volumen a través del Pod:

```bash
kubectl -n storage-lab exec web -- sh -c 'echo "hola CKA" > /usr/share/nginx/html/index.html'
kubectl -n storage-lab exec web -- cat /usr/share/nginx/html/index.html
```

Borra y recrea **solo el Pod** (el PV/PVC siguen vivos):

```bash
kubectl -n storage-lab delete pod web
kubectl apply -f lab1-pod.yaml
kubectl -n storage-lab exec web -- cat /usr/share/nginx/html/index.html   # -> "hola CKA"
```

El contenido sobrevive: vive en el disco de `cka-w1`, no en el contenedor. Puedes
confirmarlo desde el propio nodo:

```powershell
multipass exec cka-w1 -- sudo cat /mnt/data/web/index.html
```

### Variación recomendada: de `hostPath` a `local` (la versión "bien hecha")

`hostPath` tiene un fallo grave: el scheduler **no sabe** que el dato está en
`cka-w1`. Si quitas el `nodeName` y el Pod cae en otro nodo, verá un directorio
vacío. La forma correcta de "almacenamiento atado a nodo" es un PV `local` con
`nodeAffinity` + una StorageClass con `volumeBindingMode: WaitForFirstConsumer`,
que retrasa el binding hasta saber dónde se programa el Pod:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner   # estático: no crea PVs solo
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-web-local
spec:
  capacity: { storage: 1Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/data/web
  nodeAffinity:                              # ata el PV a su nodo (obligatorio en local)
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [cka-w1]
```

Un PVC `storageClassName: local-storage` se quedará `Pending` (¡esto es **normal**
con `WaitForFirstConsumer`!) hasta que crees un Pod que lo use; entonces se enlaza
y el scheduler manda el Pod a `cka-w1` automáticamente, sin `nodeName`.

### Troubleshooting del Lab 1

PVC en `Pending` → `kubectl -n storage-lab describe pvc pvc-web` y mira *Events*:

- `storageClassName` distinto entre PV y PVC (p. ej. PVC sin `""` busca la default,
  que aquí **no existe**).
- Capacidad o `accessModes` incompatibles.
- Pod en `Pending`/`FailedScheduling`: el `nodeName` apunta a un nodo inexistente,
  o (en `local`) falta `WaitForFirstConsumer`.

### Limpieza

```bash
kubectl -n storage-lab delete pod web
kubectl -n storage-lab delete pvc pvc-web
kubectl delete pv pv-web
# con Retain, el PV queda 'Released'; al borrarlo a mano el dato del nodo NO se borra:
multipass exec cka-w1 -- sudo rm -rf /mnt/data/web
# kubectl delete namespace storage-lab   # cuando termines también el Lab 2
```

> Nota sobre `Retain`: si en vez de borrar el PV borras solo el PVC, el PV pasa a
> `Released` y **no** vuelve a `Available` solo. Para reusarlo: `kubectl edit pv
> pv-web` y elimina la sección `spec.claimRef`. Es un clásico del examen.

---

## Lab 2 — StorageClass y aprovisionamiento dinámico

### ¿Qué es una StorageClass y para qué sirve?

En el Lab 1 **tú** pre-creaste el PV a mano (aprovisionamiento *estático*). Eso no
escala: en un cluster real, cuando un usuario pide un PVC, alguien tendría que
crear el PV correspondiente. Una **StorageClass (SC)** automatiza eso: describe
*cómo* crear PVs al vuelo mediante un **provisioner**. El usuario solo crea el PVC
referenciando una clase (o la default) y el PV **aparece solo** → aprovisionamiento
*dinámico*.

Campos que importan: `provisioner` (quién crea el volumen), `reclaimPolicy` y
`volumeBindingMode` (que heredan los PVs creados), `allowVolumeExpansion`.

### Enunciado (estilo examen)

> 1. Comprueba qué StorageClasses existen y cuál es la **default**.
> 2. Haz que el cluster tenga una StorageClass dinámica por defecto.
> 3. En `storage-lab`, crea un PVC `pvc-dyn` de **2Gi** RWO **sin especificar
>    `storageClassName`** (debe usar la default) y un Pod `app` (`busybox`) que lo
>    monte en `/data` y escriba un fichero. Verifica que el PV se creó **solo**.

### Paso 1: ¿hay StorageClass por defecto?

```bash
kubectl get storageclass     # alias: sc
```

En el cluster **multipass (kubeadm)** la lista sale **vacía**: no hay provisioner
ni default. (En **kind** verías `standard (default) → rancher.io/local-path`; si es
tu caso, salta al Paso 3.) Por eso un PVC dinámico aquí se quedaría `Pending` para
siempre: nadie crea el PV.

### Paso 2: instalar un provisioner dinámico

Usamos **local-path-provisioner** de Rancher (el mismo que kind llama `standard`):
ligero, sin dependencias y crea PVs en disco local de cada nodo.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl -n local-path-storage get pods        # espera a Running
kubectl get sc                                # aparece 'local-path' (aún NO default)
```

Márcala como **default** (anotación estándar):

```bash
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc          # ahora: local-path (default)
```

> En PowerShell, el JSON con comillas dobles puede dar guerra; si falla, crea la SC
> por fichero o usa `kubectl edit sc local-path` y añade la anotación a mano.
> Alternativa: si ya instalaste **Longhorn** (ver `../block`), tendrías una SC
> `longhorn` dinámica y podrías usarla en vez de local-path.

### Paso 3: PVC dinámico + Pod

`lab2-dyn.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-dyn
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
  # SIN storageClassName -> usa la StorageClass por defecto del cluster
---
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: storage-lab
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo dinamico > /data/marca.txt && sleep 3600"]
      volumeMounts:
        - name: vol
          mountPath: /data
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: pvc-dyn
```

```bash
kubectl apply -f lab2-dyn.yaml
```

### Verificación

```bash
kubectl -n storage-lab get pvc pvc-dyn        # Bound
kubectl get pv                                # ¡un PV creado AUTOMÁTICAMENTE, no lo creaste tú!
kubectl -n storage-lab exec app -- cat /data/marca.txt   # -> dinamico
```

Fíjate en el contraste con el Lab 1:

| | Lab 1 (estático) | Lab 2 (dinámico) |
| --- | --- | --- |
| ¿Quién crea el PV? | tú, a mano | el provisioner, al crear el PVC |
| StorageClass | `""` (binding puro) | la default (`local-path`) |
| reclaimPolicy del PV | `Retain` (lo pusiste tú) | `Delete` (heredada de la SC) |
| Al borrar el PVC | PV queda `Released` | PV **y** disco se borran solos |

`local-path` usa `volumeBindingMode: WaitForFirstConsumer`: por eso el PVC no se
enlaza hasta que el Pod `app` se programa (el provisioner crea el PV en el nodo
elegido). Si creas el PVC sin Pod, lo verás `Pending` a propósito.

### Limpieza

```bash
kubectl -n storage-lab delete pod app
kubectl -n storage-lab delete pvc pvc-dyn     # con Delete, el PV desaparece solo
kubectl delete namespace storage-lab
# Opcional: quitar la default y/o el provisioner
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
# kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```

---

## Qué cae en el examen de todo esto

- Escribir un **PV + PVC** y montarlo en un Pod **rápido y sin errores**.
- Entender por qué un PVC está `Pending` (SC, capacidad, accessModes, o
  `WaitForFirstConsumer` esperando al Pod — que es normal).
- La diferencia **estático vs dinámico** y el papel de la **StorageClass default**.
- `storageClassName: ""` vs omitirlo vs un nombre concreto.
- Reclaim policy `Retain` y cómo **reusar** un PV `Released`.

## Próximos labs (pendientes)

- `subPath` y montar un único fichero de un ConfigMap sin tapar el directorio.
- Expansión de un PVC (`allowVolumeExpansion`).
- `volumeMode: Block` (dispositivo crudo).
- Reclamar un PV `Released` con `Retain` (editar `claimRef`).

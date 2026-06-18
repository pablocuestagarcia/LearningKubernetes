# Almacenamiento nativo en Kubernetes (CKA) — Conceptos

Documento conceptual para el dominio **Storage** del CKA. Cubre los volúmenes
nativos (efímeros y de nodo), el modelo **PersistentVolume / PersistentVolumeClaim
/ StorageClass** y **cómo se montan los volúmenes dentro de un Pod**.

> Los **ejemplos prácticos** (manifests + ejercicios) van en el documento
> hermano `examples.md`. Aquí nos centramos en entender el *qué* y el *porqué*.

---

## Índice

1. [Por qué existen los volúmenes](#1-por-qué-existen-los-volúmenes)
2. [Tipos de almacenamiento: el mapa](#2-tipos-de-almacenamiento-el-mapa)
3. [Volúmenes efímeros](#3-volúmenes-efímeros)
4. [Volúmenes de nodo: hostPath y local](#4-volúmenes-de-nodo-hostpath-y-local)
5. [PersistentVolume (PV)](#5-persistentvolume-pv)
6. [PersistentVolumeClaim (PVC)](#6-persistentvolumeclaim-pvc)
7. [El binding: cómo se enlazan PVC y PV](#7-el-binding-cómo-se-enlazan-pvc-y-pv)
8. [StorageClass y aprovisionamiento dinámico](#8-storageclass-y-aprovisionamiento-dinámico)
9. [Access modes, volumeMode y reclaim policies](#9-access-modes-volumemode-y-reclaim-policies)
10. [Montar volúmenes en un Pod](#10-montar-volúmenes-en-un-pod)
11. [Ciclo de vida completo y reclamación](#11-ciclo-de-vida-completo-y-reclamación)
12. [Expansión de volúmenes](#12-expansión-de-volúmenes)
13. [Troubleshooting típico del CKA](#13-troubleshooting-típico-del-cka)
14. [Chuletas de referencia](#14-chuletas-de-referencia)

---

## 1. Por qué existen los volúmenes

El sistema de ficheros de un contenedor es **efímero**: si el contenedor se
reinicia (crash, OOM), todo lo escrito en su capa de escritura se **pierde**.
Además, dos contenedores del mismo Pod no comparten su sistema de ficheros.

Un **Volume** de Kubernetes resuelve dos necesidades:

- **Persistencia**: que los datos sobrevivan a reinicios del contenedor.
- **Compartición**: que varios contenedores de un Pod accedan a los mismos datos.

Idea clave: **un Volume se declara a nivel de Pod y se monta dentro de uno o
varios contenedores**. Su ciclo de vida depende del *tipo* de volumen:

- Volúmenes **efímeros** → viven y mueren con el **Pod**.
- Volúmenes **persistentes** (PV/PVC) → viven más allá del Pod; su ciclo es
  independiente.

---

## 2. Tipos de almacenamiento: el mapa

Conviene tener el mapa mental antes de entrar al detalle:

| Categoría | Ejemplos nativos | Ciclo de vida | Persiste si el Pod muere |
| --- | --- | --- | --- |
| **Efímero de Pod** | `emptyDir` | con el Pod | ❌ |
| **Inyección de config** | `configMap`, `secret`, `downwardAPI`, `projected` | con el Pod | ❌ (son datos de control) |
| **Efímero genérico** | `ephemeral` (PVC inline) | con el Pod | ❌ (PVC se borra con el Pod) |
| **De nodo** | `hostPath`, `local` | del nodo/PV | ✅ (atado a un nodo) |
| **Persistente (abstracción)** | `persistentVolumeClaim` → PV | independiente | ✅ |

En el **CKA** el peso está en:

- Entender **emptyDir** y **hostPath** (lo "nativo" sin drivers externos).
- Dominar el trío **PV + PVC + StorageClass** y su *binding*.
- Saber **montar** un PVC en un Pod (`volumes` + `volumeMounts`).
- **Diagnosticar** un PVC que no enlaza o un Pod que no monta.

> El almacenamiento "real" de producción (discos cloud, Ceph, etc.) se conecta
> mediante drivers **CSI**, pero todos exponen la **misma abstracción PV/PVC**.
> Por eso el CKA practica esa abstracción con backends nativos (hostPath/local),
> que no necesitan infraestructura externa.

---

## 3. Volúmenes efímeros

### emptyDir

Un directorio vacío que se crea cuando el Pod se asigna a un nodo y se **borra
al eliminar el Pod** del nodo. Útil para scratch, caché o para **compartir datos
entre contenedores del mismo Pod**.

Puntos clave:

- `medium: ""` → respaldado por el disco del nodo (por defecto).
- `medium: Memory` → un **tmpfs** (RAM); rápido y volátil. Cuenta contra la
  memoria del contenedor.
- `sizeLimit` → límite de tamaño opcional.
- **Sobrevive a reinicios del contenedor**, pero **no** a la eliminación del Pod.

```yaml
volumes:
  - name: scratch
    emptyDir:
      medium: Memory
      sizeLimit: 256Mi
```

### configMap, secret, downwardAPI

Montan datos de control como ficheros dentro del contenedor:

- **configMap** → claves de configuración como ficheros (o variables de entorno).
- **secret** → datos sensibles; montados como `tmpfs` (RAM), no tocan disco.
- **downwardAPI** → expone metadatos del propio Pod (nombre, namespace, labels,
  recursos) como ficheros.

Son de **solo lectura** en el punto de montaje y se actualizan (con cierto
retardo) si cambia el objeto origen (salvo `subPath`, que congela el valor).

### projected

Combina varias fuentes (`secret`, `configMap`, `downwardAPI`,
`serviceAccountToken`) en **un único directorio**. Es la forma moderna de, por
ejemplo, montar el token de la ServiceAccount.

### Volúmenes efímeros genéricos (`ephemeral`)

Permiten declarar **inline** una plantilla de PVC dentro del Pod. Kubernetes
crea un PVC (y, vía StorageClass, su PV) atado al ciclo de vida del Pod: cuando
el Pod se borra, el PVC se borra. Útil cuando quieres las *características* de un
PV (tamaño, StorageClass) pero **sin** persistencia más allá del Pod.

---

## 4. Volúmenes de nodo: hostPath y local

### hostPath

Monta un fichero o directorio **del sistema de ficheros del nodo** dentro del
Pod. Es el volumen "nativo" más directo, pero el más delicado.

`type` define qué se espera y si se crea:

| `type` | Significado |
| --- | --- |
| `""` (vacío) | sin comprobaciones (compatibilidad) |
| `DirectoryOrCreate` | si no existe el directorio, lo crea (0755, propietario kubelet) |
| `Directory` | el directorio **debe** existir |
| `FileOrCreate` | si no existe el fichero, lo crea (0644) |
| `File` | el fichero **debe** existir |
| `Socket` | debe existir un socket UNIX |
| `CharDevice` | debe existir un dispositivo de caracteres |
| `BlockDevice` | debe existir un dispositivo de bloque |

**Limitaciones y riesgos (importante para CKA y CKS):**

- **Atado al nodo**: los datos viven en *ese* nodo. Si el Pod se reprograma a
  otro nodo, **ve un directorio distinto** (o vacío). No hay replicación.
- **Riesgo de seguridad**: da acceso al filesystem del host; permite escapar del
  contenedor o leer datos sensibles del nodo. En producción se **desaconseja** y
  los Pod Security Standards lo restringen.
- **Casos legítimos**: agentes por nodo (DaemonSets) que necesitan `/var/log`,
  `/var/run/docker.sock`, métricas del host, etc.; o laboratorios de un nodo.

```yaml
volumes:
  - name: host-data
    hostPath:
      path: /data/app
      type: DirectoryOrCreate
```

### local (Local Persistent Volume)

Es la versión "bien hecha" de hostPath para **persistencia atada a nodo**: un
**PV** de tipo `local` que apunta a un disco/partición/directorio del nodo y
declara **`nodeAffinity` obligatoria**.

Diferencias frente a hostPath:

| | `hostPath` | `local` (PV) |
| --- | --- | --- |
| Se define como | volumen inline del Pod | **PersistentVolume** |
| Conciencia de topología del scheduler | ❌ (puede mandar el Pod a un nodo sin los datos) | ✅ (la `nodeAffinity` ata el PV a su nodo) |
| Aprovisionamiento dinámico | ❌ | ❌ por defecto (estático o provisioner externo) |
| Recomendado en producción | solo casos concretos | sí, para almacenamiento local rápido |

Como el PV `local` está fijado a un nodo, **debe** consumirse con
`volumeBindingMode: WaitForFirstConsumer` (ver §8) para que el binding espere a
saber en qué nodo se programa el Pod.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv
spec:
  capacity:
    storage: 5Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/disks/ssd1
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [cka-data1]
```

---

## 5. PersistentVolume (PV)

Un **PV** es un recurso **a nivel de cluster** (no namespaced) que representa
una **pieza de almacenamiento** ya existente o aprovisionada: el "disco" visto
por Kubernetes. Lo crea el **administrador** (estático) o un **provisioner**
(dinámico).

Campos esenciales de `spec`:

| Campo | Para qué |
| --- | --- |
| `capacity.storage` | tamaño del volumen (p. ej. `10Gi`) |
| `accessModes` | cómo puede montarse (RWO/ROX/RWX/RWOP) — ver §9 |
| `persistentVolumeReclaimPolicy` | qué pasa al liberar el PV (Retain/Delete) |
| `storageClassName` | clase a la que pertenece (enlaza con PVC) |
| `volumeMode` | `Filesystem` (def.) o `Block` (dispositivo crudo) |
| `mountOptions` | opciones de montaje del filesystem |
| `nodeAffinity` | restringe a qué nodos sirve (obligatorio en `local`) |
| *backend* | `hostPath`, `local`, `nfs`, `csi`, … — la fuente real |

**Fases (phase) de un PV** — se ven con `kubectl get pv`:

| Fase | Significado |
| --- | --- |
| `Available` | libre, sin PVC asociado |
| `Bound` | enlazado a un PVC |
| `Released` | el PVC se borró, pero el PV aún no se ha reciclado (datos intactos) |
| `Failed` | falló la reclamación automática |

Un PV en `Released` con política `Retain` **no vuelve a estar disponible
automáticamente**: hay que intervenir manualmente (ver §11).

---

## 6. PersistentVolumeClaim (PVC)

Un **PVC** es una **petición de almacenamiento** hecha por un usuario/aplicación
**dentro de un namespace**. Es la "solicitud de disco": *"quiero 5Gi, RWO, de la
clase X"*. Kubernetes la satisface enlazándola a un PV adecuado (estático) o
aprovisionando uno nuevo (dinámico vía StorageClass).

Campos esenciales de `spec`:

| Campo | Para qué |
| --- | --- |
| `accessModes` | modos requeridos; deben **caber** en los del PV |
| `resources.requests.storage` | tamaño mínimo solicitado |
| `storageClassName` | clase deseada (ver matices abajo) |
| `volumeMode` | `Filesystem` (def.) o `Block`; debe coincidir con el PV |
| `selector` | (opcional) elegir PV por labels |
| `volumeName` | (opcional) enlazar a un PV concreto por nombre |

Matices de `storageClassName` (muy preguntables):

- **Omitido** → usa la **StorageClass por defecto** del cluster (si existe).
- `storageClassName: ""` (cadena vacía) → **desactiva** el dinámico; solo
  enlazará con PVs que tampoco tengan clase (binding estático puro).
- `storageClassName: foo` → enlaza/provisiona en la clase `foo`.

**Quién usa qué:** el desarrollador crea **PVC** (en su namespace) y lo monta en
el Pod; el administrador (o el provisioner) gestiona los **PV**. Es la separación
de responsabilidades que el modelo busca.

---

## 7. El binding: cómo se enlazan PVC y PV

El **controlador de PV** busca, para cada PVC, un PV que cumpla **todas** estas
condiciones:

1. **Capacidad** del PV ≥ `requests.storage` del PVC.
2. **Access modes**: el PV soporta los modos pedidos por el PVC.
3. **StorageClass**: coinciden `storageClassName`.
4. **volumeMode**: coinciden (`Filesystem`/`Block`).
5. **selector / volumeName**: si el PVC los especifica, deben casar.

Detalles que caen en el examen:

- El binding es **1:1 y exclusivo**: un PV enlazado a un PVC no lo comparte otro
  PVC, aunque sobre capacidad. Si pides 1Gi y el único PV libre es de 100Gi,
  **se enlaza el de 100Gi** (y se "desperdician" 99Gi).
- Mientras no haya PV adecuado (y no haya dinámico), el PVC queda **`Pending`**.
- Si hay **StorageClass con provisioner**, no hace falta un PV previo: se crea al
  vuelo.
- El binding **no mira labels de nodo** por sí mismo; la topología la maneja
  `volumeBindingMode` (§8) y la `nodeAffinity` del PV.

---

## 8. StorageClass y aprovisionamiento dinámico

Una **StorageClass (SC)** describe una "clase de almacenamiento" y, sobre todo,
**cómo crear PVs automáticamente** cuando llega un PVC. Evita tener que
pre-crear PVs a mano.

Campos clave:

| Campo | Para qué |
| --- | --- |
| `provisioner` | quién crea el volumen (`kubernetes.io/no-provisioner`, `rancher.io/local-path`, un driver CSI…) |
| `parameters` | parámetros específicos del provisioner (tipo de disco, fs, réplicas…) |
| `reclaimPolicy` | política heredada por los PVs creados (`Delete` por defecto) |
| `volumeBindingMode` | **cuándo** se enlaza/provisiona (ver abajo) |
| `allowVolumeExpansion` | si se permite agrandar PVCs de esta clase |

**Estático vs dinámico:**

- **Estático**: el admin crea PVs a mano; los PVCs se enlazan a ellos. Para
  hostPath/local sin provisioner es lo habitual.
- **Dinámico**: el PVC referencia una SC con `provisioner`; el PV se crea solo.

**`volumeBindingMode` — concepto crítico:**

| Modo | Comportamiento |
| --- | --- |
| `Immediate` | el PV se enlaza/provisiona **en cuanto se crea el PVC**, sin saber dónde irá el Pod |
| `WaitForFirstConsumer` | el binding/aprovisionamiento **espera** a que un Pod que use el PVC sea programado, y entonces elige un PV/nodo **coherente con la topología** |

Para volúmenes **atados a nodo** (`local`, hostPath topológico) hay que usar
**`WaitForFirstConsumer`**; con `Immediate` el PVC podría enlazarse a un PV de un
nodo y luego el scheduler mandar el Pod a otro → el Pod **no podría montar**.

**StorageClass por defecto:** se marca con la anotación
`storageclass.kubernetes.io/is-default-class: "true"`. Un PVC sin
`storageClassName` la usa. (En kind es `standard` → `rancher.io/local-path`.)

---

## 9. Access modes, volumeMode y reclaim policies

### Access modes

Definen **cómo** y **desde cuántos sitios** puede montarse el volumen. Ojo: el
ámbito es **nodo**, no Pod (salvo RWOP):

| Modo | Abrev. | Semántica |
| --- | --- | --- |
| `ReadWriteOnce` | RWO | lectura-escritura por **un solo nodo**. Varios Pods en *ese mismo nodo* pueden usarlo |
| `ReadOnlyMany` | ROX | solo lectura desde **muchos nodos** |
| `ReadWriteMany` | RWX | lectura-escritura desde **muchos nodos** (necesita backend tipo NFS/CephFS) |
| `ReadWriteOncePod` | RWOP | lectura-escritura por **un único Pod** en todo el cluster (k8s 1.22+, GA 1.29) |

Confusión clásica: **RWO no significa "un Pod"**, significa "un nodo". Si quieres
exclusividad de un único Pod, usa **RWOP**.

### volumeMode

- `Filesystem` (por defecto): el volumen se formatea y se monta como directorio.
- `Block`: se expone como **dispositivo de bloque crudo** (`volumeDevices` en el
  contenedor, no `volumeMounts`). Para apps que gestionan su propio formato (BDs).

### Reclaim policies (qué pasa al borrar el PVC)

| Política | Efecto al liberar el PV |
| --- | --- |
| `Retain` | el PV pasa a `Released`; **los datos se conservan**; reclamación manual |
| `Delete` | se borran el PV **y** el almacenamiento subyacente (disco) |
| `Recycle` | (**obsoleto**) borrado básico `rm -rf`; no usar |

Regla práctica: para datos importantes, `Retain`. El dinámico suele usar
`Delete` (limpieza automática). Se puede **cambiar** la política de un PV con
`kubectl patch`.

---

## 10. Montar volúmenes en un Pod

Aquí está el núcleo operativo. Son **dos piezas** que se enlazan por **nombre**:

1. **`spec.volumes[]`** (a nivel de Pod): *declara* el volumen y de dónde sale.
2. **`spec.containers[].volumeMounts[]`** (por contenedor): *monta* ese volumen
   en una ruta del contenedor.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
    - name: app
      image: nginx
      volumeMounts:
        - name: datos          # <-- referencia al volume por nombre
          mountPath: /usr/share/nginx/html
          readOnly: false
  volumes:
    - name: datos              # <-- mismo nombre
      persistentVolumeClaim:
        claimName: mi-pvc       # consume un PVC del namespace
```

El **`name`** es el pegamento: `volumeMounts[].name` debe coincidir con
`volumes[].name`. El `volumes[]` puede apuntar a un PVC, a un `emptyDir`,
`configMap`, `hostPath`, etc.

Campos de `volumeMounts` que conviene dominar:

| Campo | Para qué |
| --- | --- |
| `mountPath` | ruta **dentro del contenedor** donde aparece el volumen |
| `readOnly` | montar en solo lectura |
| `subPath` | montar **solo un subdirectorio/fichero** del volumen (evita pisar el resto de `mountPath`) |
| `subPathExpr` | como `subPath` pero con variables de entorno (`$(POD_NAME)`) |
| `mountPropagation` | propagación de montajes host↔contenedor (casos avanzados) |

**`subPath` — uso típico:** montar un único fichero de un ConfigMap sin ocultar
el resto del directorio destino, o dar a cada réplica su subcarpeta dentro de un
mismo volumen. Aviso: con `subPath` las **actualizaciones** del ConfigMap/Secret
**no** se reflejan en caliente.

**Volúmenes de bloque** (`volumeMode: Block`) no usan `volumeMounts` sino
`volumeDevices` con `devicePath`.

```yaml
containers:
  - name: app
    image: busybox
    volumeDevices:
      - name: datos
        devicePath: /dev/xvda
```

---

## 11. Ciclo de vida completo y reclamación

Secuencia mental de principio a fin (caso dinámico):

1. **Admin** crea (o ya existe) una **StorageClass**.
2. **Usuario** crea un **PVC** pidiendo tamaño/modos/clase.
3. Según `volumeBindingMode`, el PV se **provisiona** y el PVC pasa a **`Bound`**
   (con `WaitForFirstConsumer`, esto ocurre cuando se programa el Pod).
4. El **Pod** monta el PVC (`volumes` + `volumeMounts`) y usa el almacenamiento.
5. Se **borra el Pod** → el PV/PVC siguen (persistencia real).
6. Se **borra el PVC** → el PV entra en reclamación según su política:
   - `Delete` → se borra PV + disco.
   - `Retain` → PV a **`Released`**; datos intactos; **no** se reusa solo.

**Reclamar un PV `Released` con `Retain`** (operación manual, muy CKA):

1. Recuperar los datos del backend si hace falta.
2. `kubectl edit pv <pv>` y **eliminar** la sección `spec.claimRef` (que lo ata
   al PVC borrado).
3. El PV vuelve a **`Available`** y puede enlazar con un nuevo PVC.

---

## 12. Expansión de volúmenes

Se puede **agrandar** (nunca encoger) un PVC si su StorageClass tiene
`allowVolumeExpansion: true`:

1. Editar el PVC y subir `spec.resources.requests.storage`.
2. El controlador expande el PV; según el driver puede requerir reinicio del Pod
   para que el filesystem crezca (expansión *online* vs *offline*).

Con backends nativos sencillos (hostPath/local) la expansión no siempre aplica;
es más relevante con CSI. Conviene **saber que existe** y el flag que la habilita.

---

## 13. Troubleshooting típico del CKA

### PVC en `Pending`

`kubectl describe pvc <nombre>` y mira los *Events*. Causas frecuentes:

- **No hay PV que cumpla** (capacidad, accessModes, storageClass, volumeMode) y
  **no hay provisioner** → crea un PV adecuado o corrige la SC.
- `storageClassName` **no existe** o está mal escrito.
- Con `WaitForFirstConsumer`, el PVC **se queda Pending a propósito** hasta que un
  Pod lo use: es **normal**, no un error.
- Conflicto de **volumeMode** o **accessModes** entre PVC y PV.

### Pod en `Pending` / `ContainerCreating`

- `FailedScheduling` por topología: el PV `local`/hostPath está en un nodo donde
  el Pod no cabe, o falta `WaitForFirstConsumer`.
- `FailedMount` / `FailedAttachVolume`: ruta de hostPath inexistente con
  `type: Directory`, permisos, o el backend no disponible.

### Comandos imprescindibles

```bash
kubectl get pv,pvc,sc
kubectl describe pvc <pvc>          # eventos del binding
kubectl describe pod <pod>          # eventos de montaje
kubectl get pv <pv> -o yaml         # ver claimRef, reclaimPolicy, nodeAffinity
kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

---

## 14. Chuletas de referencia

### Access modes
`RWO` = un nodo · `ROX` = muchos nodos solo lectura · `RWX` = muchos nodos RW
(necesita NFS/CephFS) · `RWOP` = un único Pod.

### Reclaim policies
`Retain` = conservar (manual) · `Delete` = borrar PV+disco · `Recycle` = obsoleto.

### volumeBindingMode
`Immediate` = enlaza ya · `WaitForFirstConsumer` = espera al Pod (obligatorio en
local/hostPath topológico).

### hostPath `type`
`DirectoryOrCreate` / `Directory` / `FileOrCreate` / `File` / `Socket` /
`CharDevice` / `BlockDevice`.

### El enlace en el Pod
`spec.volumes[].name`  ⇄  `spec.containers[].volumeMounts[].name`.

### Ámbitos
PV y StorageClass = **cluster** · PVC = **namespace**.

---

## Siguiente paso

Con estos conceptos claros, el documento `examples.md` aplicará todo con
manifests reales: `emptyDir`, `hostPath`, PV+PVC estáticos, PVC dinámico con la
StorageClass por defecto, montajes con `subPath`, cambio de reclaim policy y
diagnóstico de un PVC `Pending`.

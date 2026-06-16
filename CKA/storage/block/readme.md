# Block storage — Longhorn (distribuido)

Almacenamiento de **bloques replicado** que corre sobre los **dos nodos de
storage** (`cka-worker5` + `cka-worker6`), con una réplica de cada volumen por
nodo. Estado: **manifests/values listos; despliegue pendiente** de un entorno
con iSCSI (no WSL2 — ver prerequisitos).

> Esta guía está escrita con criterio de **producción**; cada apartado indica
> la adaptación para el lab de 2 nodos.

---

## ⚠️ Prerequisitos de nodo (imprescindibles)

Longhorn adjunta los volúmenes por **iSCSI** y usa NFS para RWX. En **todos** los
nodos que sirvan o consuman volúmenes:

| Requisito | Comprobar | Instalar (Debian/Ubuntu) |
| --- | --- | --- |
| `open-iscsi` + módulo `iscsi_tcp` | `lsmod \| grep iscsi_tcp` | `apt install -y open-iscsi && modprobe iscsi_tcp && systemctl enable --now iscsid` |
| NFSv4 client (RWX) | `cat /proc/filesystems \| grep nfs` | `apt install -y nfs-common` |
| `cryptsetup` (volúmenes cifrados) | `which cryptsetup` | `apt install -y cryptsetup` |

Longhorn trae un script oficial de verificación:

```bash
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/scripts/environment_check.sh | bash
```

### Por qué no funciona en este cluster (kind / WSL2)

El kernel `5.15.153.1-microsoft-standard-WSL2` **no incluye `iscsi_tcp`** (ni el
stack iSCSI). Comprobado: `docker exec cka-worker5 modprobe iscsi_tcp` → *Module
not found*. Opciones:

1. **Variante Multipass del cluster** (VMs Ubuntu con kernel real) — la forma más
   sencilla aquí: `cd ../../setup/multipass && ./cluster.ps1 up`. `open-iscsi`
   funciona y Longhorn arranca. Ver [../../setup/multipass](../../setup/multipass).
2. **Kernel WSL2 personalizado** con `CONFIG_ISCSI_TCP=y` + `CONFIG_SCSI_ISCSI_ATTRS=y`
   (build de [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel),
   apuntado en `C:\Users\pablo\.wslconfig`) para seguir usando kind.
3. Alternativa sin iSCSI: **Rook/Ceph** con mounter `rbd-nbd` (el módulo `nbd`
   sí está disponible en WSL2).

---

## Diseño

- Chart `longhorn/longhorn`; componentes fijados a los nodos de storage con
  `nodeSelector: node-role.kubernetes.io/storage` + `toleration` del taint
  `dedicated=storage:NoSchedule`.
- **Réplicas:** producción `3` en nodos distintos (`replicaSoftAntiAffinity:
  false`). En el lab de 2 nodos → `2`.
- **Data locality** `best-effort`: una réplica viaja con el pod (lectura rápida).
- **Backups a S3 → el MinIO de este mismo lab** (ver más abajo).
- Disco de datos dedicado (`defaultDataPath: /var/lib/longhorn`); en producción
  debe ser un disco aparte del raíz.
- Valores en [values.yaml](values.yaml), StorageClass en
  [storageclass.yaml](storageclass.yaml).

## Despliegue

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update longhorn

helm install longhorn longhorn/longhorn \
  -n longhorn-system --create-namespace \
  --version 1.7.2 -f values.yaml

kubectl apply -f storageclass.yaml
kubectl -n longhorn-system get pods -o wide   # manager/driver/UI en los nodos de storage
```

> Lab de 2 nodos: antes de instalar, baja `defaultReplicaCount` a `2` en
> values.yaml y `numberOfReplicas` a `"2"` en storageclass.yaml.

## Backups hacia MinIO (S3)

Longhorn puede usar el MinIO de [../object](../object) como destino de backups:

```bash
# 1. Bucket de backups en MinIO
kubectl -n minio exec deploy/mc-client -- \
  mc mb local/longhorn-backups

# 2. Secret con credenciales + endpoint de MinIO
kubectl -n longhorn-system create secret generic longhorn-minio-secret \
  --from-literal=AWS_ACCESS_KEY_ID=admin \
  --from-literal=AWS_SECRET_ACCESS_KEY=minio-cka-lab-2026 \
  --from-literal=AWS_ENDPOINTS=http://minio.minio.svc:9000 \
  --from-literal=VIRTUAL_HOSTED_STYLE=false
```

`backupTarget` y `backupTargetCredentialSecret` ya apuntan a este Secret en
[values.yaml](values.yaml).

## Validación

```bash
kubectl apply -f examples/pvc-and-pod.yaml
kubectl get pvc block-test-pvc                     # Bound
kubectl exec block-tester -- cat /data/hostname.txt

# HA: ver las réplicas repartidas por nodos distintos
kubectl -n longhorn-system get replicas.longhorn.io -o wide
# Simular caída de nodo: cordon+drain de un nodo de storage y comprobar que el
# volumen sigue disponible desde la otra réplica.
```

## UI de Longhorn

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# http://localhost:8080
```

## Desinstalar

```bash
# Longhorn protege contra borrados accidentales:
kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \
  --type=merge -p '{"value":"true"}'
helm uninstall longhorn -n longhorn-system
```

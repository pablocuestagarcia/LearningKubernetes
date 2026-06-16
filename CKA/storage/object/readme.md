# Object storage — MinIO (distribuido)

Almacenamiento de **objetos S3-compatible distribuido** sobre los **dos nodos de
storage** (`cka-worker5` + `cka-worker6`). Estado: **desplegado y validado**.

## Diseño

- Chart `minio/minio` en modo **distributed** (`mode: distributed`).
- **2 réplicas × 2 drives = 4-drive erasure set** (mínimo de MinIO). Anti-afinidad
  por hostname → un pod por nodo de storage (`minio-0`→worker5, `minio-1`→worker6).
- **Erasure coding `EC:2`**: 2 drives de datos + 2 de paridad → tolera la pérdida
  de hasta 2 drives, es decir **la caída de un nodo entero** en lectura.
- Cada drive es un PVC (`export-{0,1}-minio-{0,1}`) sobre la StorageClass
  `standard`. Valores en [values.yaml](values.yaml).

> **Producción vs lab.** En producción cada drive debe ser un **disco físico
> dedicado** (XFS, JBOD, sin RAID) en nodos separados; aquí los 4 drives son
> carpetas de local-path sobre el mismo disco del host de kind, así que el
> erasure coding es real a nivel lógico pero sin redundancia física. Otras
> mejoras de producción: ≥4 nodos, TLS, credenciales vía Secret externo,
> `metrics.serviceMonitor` activado, e ingress en lugar de port-forward.

## Despliegue

```powershell
helm repo add minio https://charts.min.io/
helm repo update minio
helm --kube-context kind-cka install minio minio/minio `
  -n minio --create-namespace -f values.yaml
```

Comprobar la topología:

```bash
kubectl -n minio get pods -l app=minio -o wide   # minio-0 y minio-1 en nodos distintos
kubectl -n minio get pvc                          # 4 PVCs (drives)
```

## Validación (erasure coding)

```bash
kubectl apply -f examples/test-client.yaml
kubectl -n minio exec deploy/mc-client -- sh -c '
  mc alias set local http://minio:9000 admin minio-cka-lab-2026
  mc admin info local        # 4 drives online, EC:2
  echo "distribuido" | mc pipe local/cka-lab/dist.txt
  mc cat local/cka-lab/dist.txt'
```

Salida esperada de `mc admin info`: `4 drives online, 0 drives offline, EC:2`,
con `Erasure stripe size: 4`.

## Acceso desde el host

```bash
kubectl -n minio port-forward svc/minio 9000:9000          # API S3
kubectl -n minio port-forward svc/minio-console 9001:9001  # Consola web
```

## Desinstalar

```bash
helm --kube-context kind-cka uninstall minio -n minio
kubectl delete ns minio
```

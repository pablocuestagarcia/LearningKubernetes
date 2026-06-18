# CKA — Storage lab

Dos bloques de contenido:

- **Fundamentos del CKA** (almacenamiento nativo, PV/PVC, montajes) →
  [fundamentals/](fundamentals/). Empieza por aquí si preparas el examen.
- **Almacenamiento distribuido** (este laboratorio): **MinIO** (objetos) y
  **Longhorn** (bloques) sobre los mismos dos nodos de storage.

---

## Laboratorio de almacenamiento distribuido

Explora **almacenamiento distribuido** en Kubernetes: **MinIO** (objetos) y
**Longhorn** (bloques). Ambos sistemas corren sobre los **mismos dos nodos de
storage**, y la distribución sale de que cada nodo aporta varios drives/réplicas.

## Nodos de storage (compartidos)

De los 6 workers, los dos últimos se dedican a storage y son usados por **todos**
los sistemas de almacenamiento a la vez:

| Nodo          | Rol       | Taint                          | MinIO        | Longhorn      |
| ------------- | --------- | ------------------------------ | ------------ | ------------- |
| `cka-worker5` | `storage` | `dedicated=storage:NoSchedule` | `minio-0` (2 drives) | réplica 1 |
| `cka-worker6` | `storage` | `dedicated=storage:NoSchedule` | `minio-1` (2 drives) | réplica 2 |

Ambos llevan la etiqueta de rol `node-role.kubernetes.io/storage`.

**Best practices aplicadas:**
- **Etiquetas** para seleccionar los nodos con `nodeSelector`/afinidad.
- **Taint** `NoSchedule` para *aislar* los nodos: solo los pods de storage que
  declaren la `toleration` se programan ahí (evita que cargas generales compitan
  por su CPU/disco).
- **Anti-afinidad** en cada sistema para repartir sus componentes entre los dos
  nodos (un pod de MinIO por nodo; una réplica de Longhorn por nodo).

### Cómo se aplica

- **Cluster nuevo:** ya viene en [../setup/kind-cka.yaml](../setup/kind-cka.yaml)
  (`cd ../setup && ./cluster.ps1 up`).
- **Cluster ya creado:**

  ```powershell
  ./dedicate-storage-nodes.ps1      # ./dedicate-storage-nodes.sh en Linux/macOS
  ```

  Verificar:

  ```bash
  kubectl get nodes -l node-role.kubernetes.io/storage -o wide
  kubectl describe node cka-worker5 | findstr Taints   # Select-String / grep
  ```

## Análisis de soluciones

Estudio comparativo (Rook, MinIO, Longhorn y alternativas) en
[analysis.md](analysis.md). **Resultado:** Longhorn para bloques, MinIO para
objetos; Rook/Ceph como alternativa avanzada.

## Soluciones

| Tipo    | Solución | Carpeta            | Estado                                                        |
| ------- | -------- | ------------------ | ------------------------------------------------------------- |
| Objetos | MinIO    | [object/](object/) | ✅ **desplegado y validado** — distribuido, 4 drives, `EC:2`   |
| Bloques | Longhorn | [block/](block/)   | 📄 versionado + guía de producción; requiere iSCSI (no WSL2)  |

> **MinIO** corre distribuido (2 nodos × 2 drives = erasure set de 4, tolera la
> caída de un nodo en lectura). Ver [object/readme.md](object/readme.md).
>
> **Longhorn** no puede correr en kind/WSL2 (el kernel no trae el módulo
> `iscsi_tcp`). Sus manifests/values están listos con criterio de producción y
> una guía completa de despliegue para un sistema Linux con iSCSI, incluyendo
> backups hacia el propio MinIO. Ver [block/readme.md](block/readme.md).

## Estado

- [x] Dedicar 2 nodos a storage compartidos (labels + taints)
- [x] Análisis comparativo de soluciones
- [x] Desplegar **MinIO distribuido** (4 drives, erasure coding) + validar
- [x] Documentar despliegue de Longhorn production-grade (para entorno con iSCSI)
- [ ] Desplegar y validar **Longhorn** en un sistema Linux nativo

# Análisis de soluciones de almacenamiento en Kubernetes

Objetivo: elegir **una solución de bloques** y **una de objetos** para
desplegarlas sobre los dos nodos dedicados a storage del cluster `cka`
(`cka-worker5` → bloques, `cka-worker6` → objetos).

> TL;DR de la recomendación: **Longhorn** para bloques y **MinIO** para objetos.
> **Rook/Ceph** es la opción más potente y "todo en uno", pero resulta
> sobredimensionada para un laboratorio de 2 nodos en kind; la dejamos
> documentada como alternativa y ejercicio futuro.

---

## 1. Conceptos previos

Conviene separar los **tipos de almacenamiento** de las **soluciones** que los
implementan:

| Tipo        | Interfaz / API           | Caso de uso típico                         | Access modes K8s |
| ----------- | ------------------------ | ------------------------------------------ | ---------------- |
| **Bloques** | dispositivo de bloque (PV) | bases de datos, discos de una sola escritura | RWO (a veces RWX) |
| **Ficheros**| sistema de ficheros (NFS/CephFS) | compartir entre varios pods            | RWX              |
| **Objetos** | API S3 (HTTP)            | backups, artefactos, data lakes, media     | n/a (no es un PV)|

En Kubernetes, bloques y ficheros se consumen vía **PV/PVC + CSI driver +
StorageClass**. El almacenamiento de objetos **no** se consume como PV: las
aplicaciones hablan S3 directamente (aunque existe la iniciativa **COSI** —
Container Object Storage Interface — para estandarizarlo).

---

## 2. Las tres soluciones del enunciado

### Longhorn (bloques)
- Proyecto **CNCF (incubating)**, originado en Rancher/SUSE.
- Almacenamiento de **bloques distribuido y replicado**: cada volumen se divide
  en réplicas síncronas repartidas por los nodos (anti-afinidad por defecto).
- RWO nativo; RWX mediante un `share-manager` (NFS) interno.
- Snapshots, backups incrementales a S3/NFS, expansión de volúmenes, DR y UI web.
- Arquitectura: un `longhorn-manager` (DaemonSet) por nodo + un engine por réplica.
- **Pros:** muy fácil de operar, buena UI, ideal para aprender conceptos de
  almacenamiento distribuido. **Contras:** solo bloques/ficheros (no objetos);
  en kind requiere `open-iscsi`/`iscsiadm` en los nodos (ver §5).

### MinIO (objetos)
- Almacenamiento **S3-compatible**, muy ligero y de alto rendimiento.
- Modos: SNSD (single-node single-drive), SNMD (single-node multi-drive,
  erasure coding) y MNMD (multi-node, producción; recomienda ≥4 drives).
- Se despliega con Helm o con el **MinIO Operator** (CRD `Tenant`).
- **Pros:** arranca en segundos, ecosistema S3 enorme, consola web.
  **Contras:** solo objetos; el erasure coding real necesita ≥4 discos/nodos.

### Rook (orquestador de Ceph — bloques + ficheros + objetos)
- **Operador CNCF (graduated)** que despliega y gestiona **Ceph**.
- Ceph ofrece a la vez **bloques (RBD)**, **ficheros (CephFS)** y **objetos
  (RGW, S3)** desde un único sistema: una sola solución cubre los tres tipos.
- Grado producción: auto-reparación, escalado, rebalanceo.
- **Pros:** lo más completo y robusto del ecosistema open source.
  **Contras:** pesado (los `mon` quieren quórum de 3; los OSD quieren discos
  crudos), curva de aprendizaje alta y consumo de RAM/CPU elevado — excesivo
  para 2 nodos en kind.

---

## 3. Alternativas a considerar

| Solución                  | Tipo(s)            | Notas                                                                 |
| ------------------------- | ------------------ | --------------------------------------------------------------------- |
| **OpenEBS**               | bloques/ficheros   | CNCF. Motores: LocalPV (sin réplica) y Mayastor (NVMe-oF, alto rendimiento, requiere hugepages). |
| **local-path-provisioner**| bloques (local)    | Default de kind. hostPath, RWO, **sin replicación**. Cero fricción para empezar. |
| **Piraeus / LINSTOR**     | bloques            | Basado en DRBD. Replicación a nivel kernel, muy rápido; más complejo. |
| **Portworx / Ondat**      | bloques/ficheros   | Comerciales, enfocados a producción empresarial.                      |
| **Rook + Ceph RGW**       | objetos            | El propio Ceph hace de almacén S3 (alternativa a MinIO si ya usas Rook). |
| **SeaweedFS / Garage**    | objetos            | Almacenes de objetos S3 ligeros, alternativas minimalistas a MinIO.   |
| **NFS subdir provisioner**| ficheros (RWX)     | Provisiona PVs RWX sobre un servidor NFS existente. Sencillo.         |

---

## 4. Comparativa resumida

### Bloques

| Criterio                | Longhorn       | Rook/Ceph (RBD) | OpenEBS (Mayastor) | local-path |
| ----------------------- | -------------- | --------------- | ------------------ | ---------- |
| Replicación             | ✅ síncrona     | ✅ (CRUSH)       | ✅                  | ❌          |
| Facilidad de operación  | 🟢 alta         | 🔴 baja          | 🟡 media            | 🟢 muy alta |
| Snapshots / backup      | ✅              | ✅               | ✅ (parcial)        | ❌          |
| Huella de recursos      | 🟡 media        | 🔴 alta          | 🟡 media            | 🟢 mínima   |
| Apto kind 2 nodos       | ✅ (réplica=2)¹  | ⚠️ forzado       | ⚠️ (hugepages)      | ✅          |
| Valor didáctico CKA/CKS | 🟢 alto         | 🟢 muy alto      | 🟡 medio            | 🟡 bajo     |

¹ Con 2 nodos de storage hay que fijar `numberOfReplicas: 2` (ver §5).

### Objetos

| Criterio               | MinIO          | Rook/Ceph (RGW) | SeaweedFS / Garage |
| ---------------------- | -------------- | --------------- | ------------------ |
| Compatibilidad S3      | 🟢 muy alta     | 🟢 alta          | 🟡 buena            |
| Facilidad de operación | 🟢 alta         | 🔴 baja          | 🟢 alta             |
| Huella de recursos     | 🟢 baja         | 🔴 alta          | 🟢 baja             |
| Erasure coding         | ✅ (≥4 drives)  | ✅               | ✅ (Garage/SW)      |
| Apto kind 1 nodo       | ✅ (standalone) | ⚠️ forzado       | ✅                  |

---

## 5. Restricciones de este laboratorio (kind, 2 nodos)

Los **dos nodos de storage son compartidos** por ambos sistemas; la distribución
sale de que cada nodo aporta varios drives/réplicas.

- **MinIO distribuido:** 2 nodos × 2 drives = **erasure set de 4** (mínimo de
  MinIO), con anti-afinidad para un pod por nodo. Da `EC:2` → tolera la caída de
  un nodo en lectura. *Caveat kind:* los 4 drives son carpetas de local-path
  sobre el mismo disco del host, así que la redundancia es lógica, no física.
- **Réplicas Longhorn:** con 2 nodos de storage la anti-réplica limita a
  `numberOfReplicas: 2` (producción usaría 3 en 3 nodos). El default 3 dejaría
  los volúmenes *degraded*.
- **iSCSI en kind/WSL2 (bloqueante para Longhorn):** Longhorn monta por iSCSI y
  el kernel WSL2 **no trae `iscsi_tcp`** (verificado). Longhorn no arranca aquí;
  se documenta su despliegue para un Linux con iSCSI. MinIO no usa iSCSI y sí
  funciona.
- **Taints/tolerations:** ambos nodos llevan `dedicated=storage:NoSchedule`, así
  que MinIO y Longhorn declaran la toleration y un `nodeSelector` hacia
  `node-role.kubernetes.io/storage`.
- **Rook/Ceph (alternativa sin iSCSI):** Ceph RBD puede usar el mounter
  `rbd-nbd` (el módulo `nbd` sí está disponible en WSL2), evitando el bloqueo de
  iSCSI; pero necesita discos crudos para los OSD (workaround con loop device) y
  3 `mon` para quórum, así que sigue siendo pesado para 2 nodos.

---

## 6. Recomendación final

| Necesidad | Solución elegida | Motivo                                                                 |
| --------- | ---------------- | ---------------------------------------------------------------------- |
| Bloques   | **Longhorn**     | Replicación real, fácil de operar y excelente para aprender; 1 réplica por nodo (`numberOfReplicas: 2` en el lab). |
| Objetos   | **MinIO**        | S3 estándar, ligero, **distribuido** sobre los 2 nodos (4 drives, `EC:2`). |
| Alternativa todo-en-uno | Rook/Ceph | Más potente (bloques+ficheros+objetos) y evita iSCSI vía `rbd-nbd`, pero pesado para 2 nodos en kind; ejercicio avanzado futuro. |

**Estado de la aplicación:**
1. ✅ Nodos de storage compartidos (labels + taints).
2. ✅ **MinIO distribuido** desplegado y validado (2 nodos × 2 drives, `EC:2`).
3. 📄 **Longhorn** versionado con criterio de producción + guía de despliegue
   para un sistema con iSCSI (ver [block/readme.md](block/readme.md)); pendiente
   de ejecutarlo en Linux nativo.

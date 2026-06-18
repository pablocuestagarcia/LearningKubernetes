# CKA — Fundamentos de almacenamiento nativo

Material de estudio para el dominio **Storage** del CKA: volúmenes nativos,
PV/PVC/StorageClass y montaje de volúmenes en Pods.

| Documento | Contenido | Estado |
| --- | --- | --- |
| [concepts.md](concepts.md) | Teoría detallada: efímeros, hostPath/local, PV, PVC, binding, StorageClass, access modes, reclaim policies, montajes, troubleshooting | ✅ |
| [examples.md](examples.md) | Labs estilo examen paso a paso. Lab 1: PV/PVC estáticos (hostPath) + Pod. Lab 2: StorageClass y aprovisionamiento dinámico | ✅ |

> Independiente del laboratorio de almacenamiento distribuido (MinIO/Longhorn)
> del directorio superior: aquí se practica la **abstracción nativa** que entra
> en el examen, con backends sencillos (emptyDir, hostPath, local).

#!/usr/bin/env bash
#
# Prepara un nodo (control-plane o worker) para kubeadm + Longhorn.
# Se ejecuta vía `multipass exec <vm> -- sudo bash /tmp/provision-node.sh`,
# DESPUÉS de lanzar la VM base. Desacoplar el aprovisionamiento del `launch`
# evita que el daemon de Multipass en Windows se cuelgue esperando a un
# cloud-init largo. Es idempotente: se puede re-ejecutar sin romper nada.
set -euo pipefail

log() { echo ">> $*"; }

# apt con reintentos (la red de la VM recién creada puede tardar en estar lista).
apt_retry() {
  for i in 1 2 3 4 5; do
    if DEBIAN_FRONTEND=noninteractive apt-get "$@"; then return 0; fi
    log "apt-get $* falló (intento $i), reintentando en 5s..."
    sleep 5
  done
  return 1
}

# --- Módulos de kernel + sysctl ---
log "Configurando módulos y sysctl"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
cat >/etc/modules-load.d/longhorn.conf <<'EOF'
iscsi_tcp
EOF
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
modprobe overlay
modprobe br_netfilter
modprobe iscsi_tcp || true
sysctl --system >/dev/null

# --- Swap off (requisito de kubelet) ---
log "Desactivando swap"
swapoff -a
sed -ri '/\sswap\s/s/^/#/' /etc/fstab || true

# --- Prerequisitos de almacenamiento ---
log "Instalando open-iscsi, nfs-common, cryptsetup y utilidades"
apt_retry update
apt_retry install -y open-iscsi nfs-common cryptsetup apt-transport-https ca-certificates curl gpg
systemctl enable --now iscsid

# --- containerd con SystemdCgroup ---
log "Instalando y configurando containerd"
apt_retry install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -ri 's/(SystemdCgroup = )false/\1true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# --- Repos y binarios de Kubernetes v1.34 ---
log "Instalando kubeadm, kubelet y kubectl (v1.34)"
mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt_retry update
apt_retry install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

log "Nodo preparado correctamente."

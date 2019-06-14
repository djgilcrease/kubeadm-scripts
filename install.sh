#!/bin/bash
set -e

export user=$(whoami)

sudo mkdir -p /opt/f5/{registry,controller/pg/data}
sudo chmod g+s /opt/f5

sudo setfacl -m d:g::rwX /opt/f5
sudo setfacl -m g::rwX /opt/f5
sudo setfacl -m d:u::rwX /opt/f5
sudo setfacl -m u::rwX /opt/f5
sudo setfacl -m d:u:${user}:rwX /opt/f5
sudo setfacl -m u:${user}:rwX /opt/f5
sudo setfacl -m d:o::- /opt/f5
sudo setfacl -m o::- /opt/f5

cat <<'EOF' >"/opt/f5/node-prep.sh"
#!/bin/bash

function prepareNode() {
    apt update && apt install -y apt-transport-https curl docker.io
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > "/etc/apt/sources.list.d/kubernetes.list"
    sysctl net.bridge.bridge-nf-call-iptables=1
    systemctl enable docker.service
    cat > /etc/docker/daemon.json <<DOCKEREOF
    {
      "exec-opts": ["native.cgroupdriver=systemd"],
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "10m",
        "max-file": "2"
      },
      "storage-driver": "overlay2"
    }
DOCKEREOF
    systemctl restart docker
    systemctl restart systemd-networkd
    apt update
    apt install -y kubelet kubeadm kubectl

    systemctl daemon-reload
    systemctl restart kubelet
}
export -f prepareNode
EOF

sudo chmod +x /opt/f5/node-prep.sh
source /opt/f5/node-prep.sh
sudo su -c "$(declare -f prepareNode); prepareNode"

export HOSTNAME=$(hostname)
export IPS=($(hostname -I))

if [ "${KUBE_LB_HOST}" == "" ]; then
  export KUBE_LB_HOST=${IPS[0]}
fi

cat <<EOF >"/opt/f5/kubeadm-config.yaml"
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: 1.14.2
networking:
  serviceSubnet: 10.0.0.0/12
  podSubnet: 10.16.0.0/12
apiServer:
  certSANs:
  - 127.0.0.1
  - localhost
  - ${HOSTNAME}
EOF

for ip in ${IPS[@]}; do
cat <<EOF >>"/opt/f5/kubeadm-config.yaml"
  - "${ip}"
EOF
done

cat <<EOF >>"/opt/f5/kubeadm-config.yaml"
  - "${KUBE_LB_HOST}"
controlPlaneEndpoint: "${KUBE_LB_HOST}:6443"
EOF

sudo kubeadm init --node-name ${HOSTNAME} --skip-token-print --skip-certificate-key-print --config /opt/f5/kubeadm-config.yaml
mkdir -p ${HOME}/.kube
sudo cp -f /etc/kubernetes/admin.conf ${HOME}/.kube/config
sudo chown -R ${user}:${user} ${HOME}/.kube
kubectl apply -f https://artifactory.f5net.com:443/artifactory/blue-dev/kube-flannel.yml
kubectl taint nodes ${HOSTNAME} node-role.kubernetes.io/master-
kubectl wait --for=condition=ready node ${HOSTNAME} --timeout=120s

echo 'k8s is running in single-machine mode.'
echo
echo 'To add additional control nodes run'
echo '/opt/f5/new-controller-join.sh $(whoami) <NEW_CONTROLER_IP> $(kubeadm token create --ttl 3m)'
echo
echo 'To add additional control nodes run'
echo '/opt/f5/new-worker-join.sh $(whoami) <NEW_WORKER_IP> $(kubeadm token create --ttl 3m)'
echo
echo 'Adding additional nodes will remove the single-machine mode.'
echo

################################
# Scripts to manage other nodes
################################
export KUBE_DISCOVERY_TOKEN_HASH=$(sudo openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')

cat <<EOF >"/opt/f5/node.env"
export KUBE_LB_HOST=${KUBE_LB_HOST}
export KUBE_DISCOVERY_TOKEN_HASH=${KUBE_DISCOVERY_TOKEN_HASH}
EOF

cat <<'EOF' >"/opt/f5/new-controller-join.sh"
#!/bin/bash

user=$1
host=$2
token=$3

set +e
kubectl taint nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/master=true:NoSchedule
set -e

mkdir -p /tmp/ncn/
sudo cp -R /etc/kubernetes/pki /tmp/ncn/.
sudo cp /etc/kubernetes/admin.conf /tmp/ncn/.
sudo chown -R ${user}:${user} /tmp/ncn/
scp /tmp/ncn/pki/ca.crt ${user}@${host}:
scp /tmp/ncn/pki/ca.key ${user}@${host}:
scp /tmp/ncn/pki/sa.key ${user}@${host}:
scp /tmp/ncn/pki/sa.pub ${user}@${host}:
scp /tmp/ncn/pki/front-proxy-ca.crt ${user}@${host}:
scp /tmp/ncn/pki/front-proxy-ca.key ${user}@${host}:
scp /tmp/ncn/pki/etcd/ca.crt ${user}@${host}:etcd-ca.crt
scp /tmp/ncn/pki/etcd/ca.key ${user}@${host}:etcd-ca.key
scp /tmp/ncn/admin.conf ${user}@${host}:
sudo rm -rf /tmp/ncn

scp /opt/f5/node-prep.sh ${user}@${host}:
scp /opt/f5/new-worker-join.sh ${user}@${host}:
scp /opt/f5/new-controller-join.sh ${user}@${host}:
scp /opt/f5/node.env ${user}@${host}:
ssh ${user}@${host} "sudo mkdir -p /opt/f5/"
ssh ${user}@${host} "sudo setfacl -m d:g::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m g::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m d:u::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m u::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m d:u:${user}:rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m u:${user}:rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m d:o::- /opt/f5"
ssh ${user}@${host} "sudo setfacl -m o::- /opt/f5"
ssh ${user}@${host} "sudo mv /home/${user}/node-prep.sh /opt/f5/"
ssh ${user}@${host} "sudo mv /home/${user}/node.env /opt/f5/"
ssh ${user}@${host} "sudo mv /home/${user}/new-worker-join.sh /opt/f5/"
ssh ${user}@${host} "sudo mv /home/${user}/new-controller-join.sh /opt/f5/"
ssh ${user}@${host} 'source /opt/f5/node-prep.sh && sudo su -c "$(declare -f prepareNode); prepareNode"'
ssh ${user}@${host} "sudo mkdir -p /etc/kubernetes/pki/etcd"
ssh ${user}@${host} "sudo mv /home/${user}/ca.crt /etc/kubernetes/pki/"
ssh ${user}@${host} "sudo mv /home/${user}/ca.key /etc/kubernetes/pki/"
ssh ${user}@${host} "sudo mv /home/${user}/sa.pub /etc/kubernetes/pki/"
ssh ${user}@${host} "sudo mv /home/${user}/sa.key /etc/kubernetes/pki/"
ssh ${user}@${host} "sudo mv /home/${user}/front-proxy-ca.crt /etc/kubernetes/pki/"
ssh ${user}@${host} "sudo mv /home/${user}/front-proxy-ca.key /etc/kubernetes/pki/"
ssh ${user}@${host} "sudo mv /home/${user}/etcd-ca.crt /etc/kubernetes/pki/etcd/ca.crt"
ssh ${user}@${host} "sudo mv /home/${user}/etcd-ca.key /etc/kubernetes/pki/etcd/ca.key"
ssh ${user}@${host} "sudo chown -R root:root /etc/kubernetes/"
ssh ${user}@${host} "echo 'export token=${token}' >> /opt/f5/node.env"
ssh ${user}@${host} 'source /opt/f5/node.env && sudo kubeadm join ${KUBE_LB_HOST}:6443 --token ${token} --discovery-token-ca-cert-hash sha256:${KUBE_DISCOVERY_TOKEN_HASH} --experimental-control-plane'
ssh ${user}@${host} "sed -i '$ d' /opt/f5/node.env"
ssh ${user}@${host} "mkdir -p $HOME/.kube"
ssh ${user}@${host} "sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config"
ssh ${user}@${host} "sudo chown ${user}:${user} $HOME/.kube/config"
ssh ${user}@${host} "kubectl wait --for=condition=ready node $(hostname) --timeout=120s"
EOF

sudo chmod +x /opt/f5/new-controller-join.sh

cat <<'EOF' >"/opt/f5/new-worker-join.sh"
#!/bin/bash

user=$1
host=$2
token=$3

set +e
kubectl taint nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/master=true:NoSchedule
set -e

mkdir -p /tmp/nwn/
sudo cp /etc/kubernetes/admin.conf /tmp/nwn/.
sudo chown -R ${user}:${user} /tmp/nwn/
scp /tmp/nwn/admin.conf ${user}@${host}:
scp /opt/f5/node-prep.sh ${user}@${host}:
scp /opt/f5/node.env ${user}@${host}:
sudo rm -rf /tmp/nwn

ssh ${user}@${host} "sudo mkdir -p /opt/f5/"
ssh ${user}@${host} "sudo setfacl -m d:g::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m g::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m d:u::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m u::rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m d:u:${user}:rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m u:${user}:rwX /opt/f5"
ssh ${user}@${host} "sudo setfacl -m d:o::- /opt/f5"
ssh ${user}@${host} "sudo setfacl -m o::- /opt/f5"
ssh ${user}@${host} "sudo mv /home/${user}/node-prep.sh /opt/f5/"
ssh ${user}@${host} "sudo mv /home/${user}/node.env /opt/f5/"
ssh ${user}@${host} 'source /opt/f5/node-prep.sh && sudo su -c "$(declare -f prepareNode); prepareNode"'
ssh ${user}@${host} "echo 'export token=${token}' >> /opt/f5/node.env"
ssh ${user}@${host} 'source /opt/f5/node.env && sudo kubeadm join ${KUBE_LB_HOST}:6443 --token ${token} --discovery-token-ca-cert-hash sha256:${KUBE_DISCOVERY_TOKEN_HASH}'
ssh ${user}@${host} "sudo mv /home/${user}/admin.conf $HOME/.kube/config"
ssh ${user}@${host} "sudo rm -rf /opt/f5"
EOF

sudo chmod +x /opt/f5/new-worker-join.sh

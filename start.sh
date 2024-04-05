#!/bin/bash

set -x
BASE_IP="10.10.1."
SECONDARY_PORT=3000
INSTALL_DIR=/home/cloudlab-openwhisk
NUM_MIN_ARGS=3
PRIMARY_ARG="primary"
SECONDARY_ARG="secondary"
USAGE=$'Usage:\n\t./start.sh secondary <node_ip> <start_kubernetes>\n\t./start.sh primary <node_ip> <num_nodes> <start_kubernetes> <deploy_openwhisk> <invoker_count> <invoker_engine> <scheduler_enabled>'
NUM_PRIMARY_ARGS=8
PROFILE_GROUP="profileuser"

configure_docker_storage() {
    printf "%s: %s\n" "$(date +"%T.%N")" "Configuring docker storage"
    sudo mkdir /mydata/docker
    echo -e '{
        "exec-opts": ["native.cgroupdriver=systemd"],
        "log-driver": "json-file",
        "log-opts": {
            "max-size": "100m"
        },
        "storage-driver": "overlay2",
        "data-root": "/mydata/docker"
    }' | sudo tee /etc/docker/daemon.json
    sudo systemctl restart docker || (echo "ERROR: Docker installation failed, exiting." && exit -1)
    sudo docker run hello-world | grep "Hello from Docker!" || (echo "ERROR: Docker installation failed, exiting." && exit -1)
    printf "%s: %s\n" "$(date +"%T.%N")" "Configured docker storage to use mountpoint"
}

disable_swap() {
    # Turn swap off and comment out swap line in /etc/fstab
    sudo swapoff -a
    if [ $? -eq 0 ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Turned off swap"
    else
        echo "***Error: Failed to turn off swap, which is necessary for Kubernetes"
        exit -1
    fi
    sudo sed -i.bak 's/UUID=.*swap/# &/' /etc/fstab
}

setup_primary() {
    # initialize k8 primary node
    printf "%s: %s\n" "$(date +"%T.%N")" "Starting Kubernetes... (this can take several minutes)... "
    sudo kubeadm init --apiserver-advertise-address=$1 --pod-network-cidr=10.11.0.0/16 > $INSTALL_DIR/k8s_install.log 2>&1
    if [ $? -eq 0 ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Done! Output in $INSTALL_DIR/k8s_install.log"
    else
        echo ""
        echo "***Error: Error when running kubeadm init command. Check log found in $INSTALL_DIR/k8s_install.log."
        exit 1
    fi

    # Set up kubectl for all users
    for FILE in /users/*; do
        CURRENT_USER=${FILE##*/}
        sudo mkdir /users/$CURRENT_USER/.kube
        sudo cp /etc/kubernetes/admin.conf /users/$CURRENT_USER/.kube/config
        sudo chown -R $CURRENT_USER:$PROFILE_GROUP /users/$CURRENT_USER/.kube
	printf "%s: %s\n" "$(date +"%T.%N")" "set /users/$CURRENT_USER/.kube to $CURRENT_USER:$PROFILE_GROUP!"
	ls -lah /users/$CURRENT_USER/.kube
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}

apply_calico() {
    # https://docs.tigera.io/calico/latest/getting-started/kubernetes/helm
    helm repo add projectcalico https://docs.tigera.io/calico/charts > $INSTALL_DIR/calico_install.log 2>&1
    if [ $? -ne 0 ]; then
       echo "***Error: Error when loading helm calico repo. Log written to $INSTALL_DIR/calico_install.log"
       exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Loaded helm calico repo"

    kubectl create namespace tigera-operator
    helm install calico projectcalico/tigera-operator --version v3.27.2 --namespace tigera-operator >> $INSTALL_DIR/calico_install.log 2>&1
    if [ $? -ne 0 ]; then
       echo "***Error: Error when installing calico with helm. Log appended to $INSTALL_DIR/calico_install.log"
       exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Applied Calico networking with helm"

    # wait for calico pods to be in ready state
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for calico pods to have status of 'Running': "
    NUM_PODS=$(kubectl get pods -n calico-system | wc -l)
    NUM_RUNNING=$(kubectl get pods -n calico-system | grep " Running" | wc -l)
    NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    while [ "$NUM_RUNNING" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_RUNNING=$(kubectl get pods -n calico-system | grep " Running" | wc -l)
        NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Calico pods running!"

    # wait for kube-system pods to be in ready state
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for all system pods to have status of 'Running': "
    NUM_PODS=$(kubectl get pods -n kube-system | wc -l)
    NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
    NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    while [ "$NUM_RUNNING" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
        NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Kubernetes system pods running!"
}


prepare_for_openwhisk() {
    # Args: 1 = IP, 2 = num nodes, 3 = num invokers, 4 = invoker engine, 5 = scheduler enabled

    # Use latest version of openwhisk-deploy-kube
    git clone https://github.com/cherrypiejam/faasten.git $ISNTALL_DIR

    pushd $INSTALL_DIR/faasten
    git pull
    popd

    # Iterate over each node and set the openwhisk role
    # From https://superuser.com/questions/284187/bash-iterating-over-lines-in-a-variable
    NODE_NAMES=$(kubectl get nodes -o name)
    CORE_NODES=$(($2-$3))
    counter=0
    while IFS= read -r line; do
	if [ $counter -lt $CORE_NODES ] ; then
	    printf "%s: %s\n" "$(date +"%T.%N")" "Skipped labelling non-invoker node ${line:5}"
        else
            kubectl label nodes ${line:5} openwhisk-role=invoker
            if [ $? -ne 0 ]; then
                echo "***Error: Failed to set openwhisk role to invoker on ${line:5}."
                exit -1
            fi
	    printf "%s: %s\n" "$(date +"%T.%N")" "Labelled ${line:5} as openwhisk invoker node"
	fi
	counter=$((counter+1))
    done <<< "$NODE_NAMES"
    printf "%s: %s\n" "$(date +"%T.%N")" "Finished labelling nodes."

    kubectl create namespace openwhisk
    if [ $? -ne 0 ]; then
        echo "***Error: Failed to create openwhisk namespace"
        exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Created openwhisk namespace in Kubernetes."

    cp /local/repository/mycluster.yaml $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_IP/$1/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_ENGINE/$4/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_INVOKER_COUNT/$3/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sed -i.bak "s/REPLACE_ME_WITH_SCHEDULER_ENABLED/$5/g" $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sudo chown $USER:$PROFILE_GROUP $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    sudo chmod -R g+rw $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml
    printf "%s: %s\n" "$(date +"%T.%N")" "Updated $INSTALL_DIR/openwhisk-deploy-kube/mycluster.yaml"

    if [ $4 == "docker" ] ; then
        if test -d "/mydata"; then
	    sed -i.bak "s/\/var\/lib\/docker\/containers/\/mydata\/docker\/containers/g" $INSTALL_DIR/openwhisk-deploy-kube/helm/openwhisk/templates/_invoker-helpers.tpl
            printf "%s: %s\n" "$(date +"%T.%N")" "Updated dockerrootdir to /mydata/docker/containers in $INSTALL_DIR/openwhisk-deploy-kube/helm/openwhisk/templates/_invoker-helpers.tpl"
        fi
    fi
}


# Start by recording the arguments
printf "%s: args=(" "$(date +"%T.%N")"
for var in "$@"
do
    printf "'%s' " "$var"
done
printf ")\n"

# Check the min number of arguments
if [ $# -lt $NUM_MIN_ARGS ]; then
    echo "***Error: Expected at least $NUM_MIN_ARGS arguments."
    echo "$USAGE"
    exit -1
fi

# Check to make sure the first argument is as expected
if [ $1 != $PRIMARY_ARG -a $1 != $SECONDARY_ARG ] ; then
    echo "***Error: First arg should be '$PRIMARY_ARG' or '$SECONDARY_ARG'"
    echo "$USAGE"
    exit -1
fi

# Kubernetes does not support swap, so we must disable it
disable_swap

# Use mountpoint (if it exists) to set up additional docker image storage
if test -d "/mydata"; then
    configure_docker_storage
fi

# All all users to the docker group

# Fix permissions of install dir, add group for all users to set permission of shared files correctly
sudo groupadd $PROFILE_GROUP
for FILE in /users/*; do
    CURRENT_USER=${FILE##*/}
    sudo gpasswd -a $CURRENT_USER $PROFILE_GROUP
    sudo gpasswd -a $CURRENT_USER docker
done
sudo chown -R $USER:$PROFILE_GROUP $INSTALL_DIR
sudo chmod -R g+rw $INSTALL_DIR

# At this point, a secondary node is fully configured until it is time for the node to join the cluster.
if [ $1 == $SECONDARY_ARG ] ; then

    SECONDARY_IP=$2
    SECONDARY_DATA_DIR=/mydata/tikv

    sudo mkdir -p $SECONDARY_DATA_DIR

    sudo docker pull pingcap/tikv:latest
    sudo docker pull pingcap/pd:latest

    sudo docker run -d --name pd1 \
           -p 2379:2379 \
           -p 2380:2380 \
           -v /etc/localtime:/etc/localtime:ro \
           -v $DATA_DIR:/data \
           pingcap/pd:latest \
           --name="pd1" \
           --data-dir="/data/pd1" \
           --client-urls="http://0.0.0.0:2379" \
           --advertise-client-urls="http://$SECONDARY_IP:2379" \
           --peer-urls="http://0.0.0.0:2380" \
           --advertise-peer-urls="http://$SECONDARY_IP:2380" \
           --initial-cluster="pd1=http://$SECONDARY_IP:2380"

    sudo docker run -d --name tikv1 \
           -p 20160:20160 \
           -v /etc/localtime:/etc/localtime:ro \
           -v $DATA_DIR:/data \
           pingcap/tikv:latest \
           --addr="0.0.0.0:20160" \
           --advertise-addr="$SECONDARY_IP:20160" \
           --data-dir="/data/tikv1" \
           --pd="$SECONDARY_IP:2379"

    curl $SECONDARY_IP:2379/pd/api/v1/stores

    exit 0
fi

# Check the min number of arguments
if [ $# -ne $NUM_PRIMARY_ARGS ]; then
    echo "***Error: Expected at least $NUM_PRIMARY_ARGS arguments."
    echo "$USAGE"
    exit -1
fi

PB_REL="https://github.com/protocolbuffers/protobuf/releases"
sudo curl -LO $PB_REL/download/v25.1/protoc-25.1-linux-x86_64.zip
sudo unzip protoc-25.1-linux-x86_64.zip -d /usr/local/

sudo apt -y install bridge-utils cpu-checker libvirt-clients libvirt-daemon qemu qemu-kvm squashfs-tools-ng

for FILE in /users/*; do
    CURRENT_USER=${FILE##*/}
    sudo gpasswd -a $CURRENT_USER kvm
done

printf "%s: %s\n" "$(date +"%T.%N")" "Profile setup completed!"

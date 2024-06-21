#!/bin/bash

kcmerge () {
        if ! [[ -f "$1" ]]
        then
                echo "Config file not found"
                return 1
        fi
        kube_config=$(KUBECONFIG=~/.kube/config:$1 kubectl config view --flatten)
        cp ~/.kube/config ~/.kube/config.bak
        echo "$kube_config" > ~/.kube/config
}

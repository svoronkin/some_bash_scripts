#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

cp ~/.kube/config ~/.kube/config.bak."$(date +%Y%m%d%H%M%S)"

files=(kubeconfigs/*.yaml)
kubeconfig=$(printf '%s:' "${files[@]}")
kubeconfig=${kubeconfig%:}

KUBECONFIG=$kubeconfig kubectl config view --flatten --raw > ~/.kube/config
chmod 600 ~/.kube/config

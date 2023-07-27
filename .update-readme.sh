#!/bin/bash


get_latest_release() {
	limit=${2:-5}
	curl --silent "https://api.github.com/repos/$1/releases" | jq -r '.[].tag_name' | head -n $limit
}

# kubebuidler version
if [ $# -eq 0 ]; then
	echo "specify kubebuilder version"
	get_latest_release "kubernetes-sigs/kubebuilder"
	exit 1
fi

if [[ ! "$1" =~ ^v[0-9]+.[0-9]+.[0-9]+$ ]];then
	echo "kubebuilder version format '$1' is invalid"
	get_latest_release "kubernetes-sigs/kubebuilder"
	exit 1
fi

KUBEBUILDER_VERSION=$1


# get versions

export $(grep CERT_MANAGER_VERSION= .upgrade-version.sh)
KUSTOMIZE_VERSION=$(bin/kustomize version)
GO_VERSION_CLI_RESULT=$(go version)
GO_VERSION=$(echo ${GO_VERSION_CLI_RESULT} | sed 's/go version \(go[^\s]*\) [^\s]*/\1/')

# update readme
gsed -i "s/.*Docker Engine.*/1. Docker Engine: $(docker version | grep -A 2 Server: | grep Version | sed 's/Version: *\([0-9\.]*\)/\1/' | xargs)/g" README.md
gsed -i "s#\[go\](https://github.com/golang/go):.*#[go](https://github.com/golang/go): [${GO_VERSION}](https://github.com/golang/go/releases/${GO_VERSION})#g" README.md
gsed -i "s#\[kubebuilder\](https://github.com/kubernetes-sigs/kubebuilder):.*#[kubebuilder](https://github.com/kubernetes-sigs/kubebuilder): [${KUBEBUILDER_VERSION}](https://github.com/kubernetes-sigs/kubebuilder/releases/${KUBEBUILDER_VERSION})#g" README.md
K8S_VERSION=$(kubectl version --output=json | jq -r .serverVersion.gitVersion)
gsed -i "s#\[Kubernetes\](https://github.com/kubernetes/kubernetes):.*#[Kubernetes](https://github.com/kubernetes/kubernetes): [${K8S_VERSION}](https://github.com/kubernetes/kubernetes/releases/tag/${K8S_VERSION})#g" README.md
KIND_VERSION=$(kind version | sed 's/kind \(v[0-9\.]*\) .*/\1/')
gsed -i "s#\[kind\](https://github.com/kubernetes-sigs/kind):.*#[kind](https://github.com/kubernetes-sigs/kind): [${KIND_VERSION}](https://github.com/kubernetes-sigs/kind/releases/tag/${KIND_VERSION})#g" README.md
gsed -i "s#\[kustomize](https://github.com/kubernetes-sigs/kustomize):.*#[kustomize](https://github.com/kubernetes-sigs/kustomize): [${KUSTOMIZE_VERSION}](https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2F${KUSTOMIZE_VERSION})#g" README.md
gsed -i "s#\[cert-manager\](https://github.com/cert-manager/cert-manager):.*#[cert-manager](https://github.com/cert-manager/cert-manager): [$CERT_MANAGER_VERSION](https://github.com/cert-manager/cert-manager/releases/tag/${CERT_MANAGER_VERSION})#g" README.md

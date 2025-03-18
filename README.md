# password-operator
Example Kubernetes Operator project created with kubebuilder, which manages a CRD `Password` and generates a configurable password.

## Versions
1. Docker Engine: 27.4.0
1. [go](https://github.com/golang/go): [go1.23.2](https://github.com/golang/go/releases/go1.23.2)
1. [kubebuilder](https://github.com/kubernetes-sigs/kubebuilder): [v4.0.0](https://github.com/kubernetes-sigs/kubebuilder/releases/v4.0.0)
1. [Kubernetes](https://github.com/kubernetes/kubernetes): [v1.31.0](https://github.com/kubernetes/kubernetes/releases/tag/v1.31.0)
1. [kind](https://github.com/kubernetes-sigs/kind): [v0.24.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.24.0)
1. [kustomize](https://github.com/kubernetes-sigs/kustomize): [5.4.1](https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2F5.4.1)
1. [cert-manager](https://github.com/cert-manager/cert-manager): [v1.8.0](https://github.com/cert-manager/cert-manager/releases/tag/v1.8.0)

## Getting Started
You’ll need a Kubernetes cluster to run against. You can use [KIND](https://sigs.k8s.io/kind) to get a local cluster for testing, or run against a remote cluster.
**Note:** Your controller will automatically use the current context in your kubeconfig file (i.e. whatever cluster `kubectl cluster-info` shows).

### Running on the cluster
1. Install Instances of Custom Resources:

```sh
kubectl apply -f config/samples/
```

2. Build and push your image to the location specified by `IMG`:

```sh
make docker-build docker-push IMG=<some-registry>/password-operator:tag
```

3. Deploy the controller to the cluster with the image specified by `IMG`:

```sh
make deploy IMG=<some-registry>/password-operator:tag
```

### Uninstall CRDs
To delete the CRDs from the cluster:

```sh
make uninstall
```

### Undeploy controller
UnDeploy the controller to the cluster:

```sh
make undeploy
```

## Contributing
// TODO(user): Add detailed information on how you would like others to contribute to this project

### How it works
This project aims to follow the Kubernetes [Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)

It uses [Controllers](https://kubernetes.io/docs/concepts/architecture/controller/)
which provides a reconcile function responsible for synchronizing resources untile the desired state is reached on the cluster

### Test It Out

1. Start kind cluster

    ```sh
    kind create cluster
    ```

1. Install the CRDs into the cluster:

    ```sh
    make install
    ```

1. Run cert manager

    ```
    CERT_MANAGER_VERSION=v1.8.0
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml
    ```

1. Run your controller (this will run in the foreground, so switch to a new terminal if you want to leave it running):

    ```sh
    IMG=password-operator:webhook
    make docker-build IMG=$IMG
    kind load docker-image $IMG
    make deploy IMG=$IMG
    ```

1. Create `Password` CR

    ```sh
    kubectl apply -f config/samples/secret_v1alpha1_password.yaml
    ```

1. Check Secret

    ```sh
    kubectl get secret
    NAME              TYPE     DATA   AGE
    password-sample   Opaque   1      5s
    ```

1. Check invalid CR (denied by admission webhook)

    ```yaml
    apiVersion: secret.example.com/v1alpha1
    kind: Password
    metadata:
      labels:
        app.kubernetes.io/name: password
        app.kubernetes.io/instance: password-sample
        app.kubernetes.io/part-of: password-operator
        app.kubernetes.io/managed-by: kustomize
        app.kubernetes.io/created-by: password-operator
      name: password-sample
    spec:
      length: 20
      digit: 10
      symbol: 15
    ```

    ```sh
    kubectl apply -f config/samples/secret_v1alpha1_password.yaml
    Error from server (Forbidden): error when creating "config/samples/secret_v1alpha1_password.yaml": admission webhook "vpassword.kb.io" denied the request: Number of digits and symbols must be less than total length
    ```

### Modifying the API definitions
If you are editing the API definitions, generate the manifests such as CRs or CRDs using:

```sh
make manifests
```

**NOTE:** Run `make --help` for more information on all potential `make` targets

More information can be found via the [Kubebuilder Documentation](https://book.kubebuilder.io/introduction.html)

### Recreate with new kubebuilder version

Example:

```
echo yes | SED=gsed ./.upgrade-version.sh v3.12.0
```

## License

Copyright 2022.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

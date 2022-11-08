#!/bin/bash

set -eux

PASSWORD_CONTROLLER_GO_FILE=controllers/password_controller.go
PASSWORD_GO_TYPE_FILE=api/v1alpha1/password_types.go
export KUSTOMIZE_VERSION=v4.5.5

# 0. Clean up
echo "======== CLEAN UP ==========="

KEEP_FILES=(
    mkdocs.yml
    README.md
    renovate.json
)

rm -rf api config controllers hack bin bundle
for f in `ls` .dockerignore .gitignore; do
    if [[ ! " ${KEEP_FILES[*]} " =~ " ${f} " ]] && [ -f "$f" ]; then
        rm $f
    fi
done

KUBEBUILDER_VERSION_CLI_RESULT=$(kubebuilder version)
KUBEBUILDER_VERSION_FOR_COMMIT=$(echo ${KUBEBUILDER_VERSION_CLI_RESULT} | sed 's/kubebuilder version: "\([v0-9\.]*\)".*kubernetes version: \"\([v0-9\.]*\)\".* go version: \"\(go[0-9\.]*\)\".*/kubebuilder: \1, kubernetes: \2, go: \3/g')
KUBEBUILDER_VERSION=$(echo ${KUBEBUILDER_VERSION_CLI_RESULT} | sed 's/kubebuilder version: "\([v0-9\.]*\)".*/\1/g')
GO_VERSION_CLI_RESULT=$(go version)
GO_VERSION=$(echo ${GO_VERSION_CLI_RESULT} | sed 's/go version \(go[^\s]*\) [^\s]*/\1/')
echo "KUBEBUILDER_VERSION: $KUBEBUILDER_VERSION_FOR_COMMIT, GO_VERSION: $GO_VERSION_CLI_RESULT"
commit_message="Remove all files to upgrade versions ($KUBEBUILDER_VERSION_FOR_COMMIT)"
last_commit_message=$(git log -1 --pretty=%B)
if [ -n "$(git status --porcelain)" ]; then
    echo "there are changes";
    if [[ $commit_message = $last_commit_message ]]; then
        echo "duplicated commit -> amend"
        git add .
        pre-commit run -a || true
        git commit -a --amend --no-edit
    else
        echo "create a commit"
        git add .
        pre-commit run -a || true
        git commit -am "$commit_message"
    fi
else
  echo "no changes";
  echo "======== CLEAN UP COMPLETED ==========="
  exit 0
fi

echo "======== CLEAN UP COMPLETED ==========="

# 1. [kubebuilder] Init project
echo "======== INIT PROJECT ==========="
# need to make the dir clean before initializing a project
kubebuilder init --domain example.com --repo example.com/password-operator
echo "======== INIT PROJECT kubebuilder init completed =========="

echo "git add & commit"
git add .
pre-commit run -a || true
git commit -am "[kubebuilder] Init project"

echo "======== INIT PROJECT COMPLETED ==========="

# 2. [kubebuilder] Create API Password (Controller & Resource)
kubebuilder create api --group secret --version v1alpha1 --kind Password --resource --controller
make manifests

git add .
pre-commit run -a || true
git commit -am "[kubebuilder] Create API Password (Controller & Resource)"

# 3. [Controller] Add log in Reconcile function
gsed -i '/Reconcile(ctx context.Context, req ctrl.Request) /,/^}/d' $PASSWORD_CONTROLLER_GO_FILE
cat << EOF > tmpfile
func (r *PasswordReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    logger := log.FromContext(ctx)

    logger.Info("Reconcile is called.")

    return ctrl.Result{}, nil
}
EOF
gsed -i "/pkg\/reconcile/ r tmpfile" $PASSWORD_CONTROLLER_GO_FILE

make fmt
git add . && git commit -m "[Controller] Add log in Reconcile function"

# 4. [API] Remove Foo field from custom resource Password
## PasswordSpec
gsed -i '/type PasswordSpec struct {/,/}/d' $PASSWORD_GO_TYPE_FILE
cat << EOF > tmpfile
type PasswordSpec struct {
    // INSERT ADDITIONAL SPEC FIELDS - desired state of cluster
    // Important: Run "make" to regenerate code after modifying this file
    // Foo is an example field of Password. Edit password_types.go to remove/update
}
EOF
gsed -i "/PasswordSpec defines/ r tmpfile" $PASSWORD_GO_TYPE_FILE
rm tmpfile

## fmt
KUSTOMIZE_VERSION=4.5.5 make install
# Check if Foo field is removed in CRD
test "$(kubectl get crd passwords.secret.example.com -o jsonpath='{.spec.versions[].schema.openAPIV3Schema.properties.spec}' | jq '.properties == null')" = "true"

git add .
pre-commit run -a || true
git commit -am "[API] Remove Foo field from custom resource Password"


# 5. [Controller] Fetch Password object
gsed -i '/Reconcile(ctx context.Context, req ctrl.Request) /,/^}/d' $PASSWORD_CONTROLLER_GO_FILE
cat << EOF > tmpfile
func (r *PasswordReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    logger := log.FromContext(ctx)

    logger.Info("Reconcile is called.")

	// Fetch Password object
	var password secretv1alpha1.Password
	if err := r.Get(ctx, req.NamespacedName, &password); err != nil {
    	logger.Error(err, "Fetch Password object - failed")
    	return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	logger.Info("Fetch Password object - succeeded", "password", password.Name, "createdAt", password.CreationTimestamp)
	return ctrl.Result{}, nil
}
EOF
gsed -i "/pkg\/reconcile/ r tmpfile" $PASSWORD_CONTROLLER_GO_FILE
rm tmpfile
make fmt

git add .
pre-commit run -a || true
git commit -am "[Controller] Fetch Password object"


## 6. [Controller] Create Secret object if not exists
gsed -i '/^import/a corev1 "k8s.io/api/core/v1"' $PASSWORD_CONTROLLER_GO_FILE
gsed -i '/^import/a "k8s.io/apimachinery/pkg/api/errors"' $PASSWORD_CONTROLLER_GO_FILE
gsed -i '/^import/a metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"' $PASSWORD_CONTROLLER_GO_FILE

cat << EOF > tmpfile

    // Create Secret object if not exists
    var secret corev1.Secret
    if err := r.Get(ctx, req.NamespacedName, &secret); err != nil {
        if errors.IsNotFound(err) {
            // Create Secret
            logger.Info("Create Secret object if not exists - create secret")
            secret := newSecretFromPassword(&password)
            err = r.Create(ctx, secret)
            if err != nil {
                logger.Error(err, "Create Secret object if not exists - failed to create Secret")
                return ctrl.Result{}, err
            }
            logger.Info("Create Secret object if not exists - Secret successfully created")
        } else {
            logger.Error(err, "Create Secret object if not exists - failed to fetch Secret")
            return ctrl.Result{}, err
        }
    }

    logger.Info("Create Secret object if not exists - completed")
EOF
# Add the contents before the last return in Reconcile function.
gsed -i $'/^\treturn ctrl.Result{}, nil/{e cat tmpfile\n}' $PASSWORD_CONTROLLER_GO_FILE

cat << EOF > tmpfile

func newSecretFromPassword(password *secretv1alpha1.Password) *corev1.Secret {
    secret := &corev1.Secret{
        ObjectMeta: metav1.ObjectMeta{
            Name:      password.Name,
            Namespace: password.Namespace,
        },
        Data: map[string][]byte{
            "password": []byte("123456789"), // password=123456789
        },
    }
    return secret
}
EOF
cat tmpfile >> $PASSWORD_CONTROLLER_GO_FILE
rm tmpfile

gsed -i '/kubebuilder:rbac:groups=secret.example.com,resources=passwords\/finalizers/a \/\/+kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch;create;' $PASSWORD_CONTROLLER_GO_FILE # add marker for secret
make fmt manifests

git add .
pre-commit run -a || true
git add . && git commit -m "[Controller] Create Secret object if not exists"

## 7. [Controller] Clean up Secret when Password is deleted

cat << EOF > tmpfile

    err := ctrl.SetControllerReference(&password, secret, r.Scheme) // Set owner of this Secret
    if err != nil {
        logger.Error(err, "Create Secret object if not exists - failed to set SetControllerReference")
        return ctrl.Result{}, err
    }
EOF
# Add the contents after secret := newSecretFromPassword(&password)
gsed -i '/secret := newSecretFromPassword(&password)$/r tmpfile' $PASSWORD_CONTROLLER_GO_FILE
rm tmpfile
make fmt

git add .
pre-commit run -a || true
git commit -am "[Controller] Clean up Secret when Password is deleted"


## 8. [Controller] Generate random password
gsed -i '/^import/a passwordGenerator "github.com/sethvargo/go-password/password"' $PASSWORD_CONTROLLER_GO_FILE

# Update the way to generate password
cat << EOF > tmpfile
    passwordStr, err := passwordGenerator.Generate(64, 10, 10, false, false)
    if err != nil {
        logger.Error(err, "Create Secret object if not exists - failed to generate password")
        return ctrl.Result{}, err
    }
    secret := newSecretFromPassword(&password, passwordStr)
EOF
gsed -i 's/secret := newSecretFromPassword(&password)/cat tmpfile/e' $PASSWORD_CONTROLLER_GO_FILE
gsed -i 's/err := ctrl.SetControllerReference(\&password, secret, r.Scheme)/err = ctrl.SetControllerReference(\&password, secret, r.Scheme)/g' $PASSWORD_CONTROLLER_GO_FILE

cat << EOF > tmpfile
func newSecretFromPassword(password *secretv1alpha1.Password, passwordStr string) *corev1.Secret {
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      password.Name,
			Namespace: password.Namespace,
		},
		Data: map[string][]byte{
			"password": []byte(passwordStr),
		},
	}
	return secret
}
EOF
gsed -i '/func newSecretFromPassword(password \*secretv1alpha1.Password) \*corev1.Secret {/,/^}/d' $PASSWORD_CONTROLLER_GO_FILE
cat tmpfile >> $PASSWORD_CONTROLLER_GO_FILE

make fmt
go mod tidy

git add .
pre-commit run -a || true
git commit -am "[Controller] Generate random password"


# 5. Write a test
CONTROLLER_SUITE_TEST_GO_FILE=controllers/suite_test.go
gsed -i '/^import/a "context"' $CONTROLLER_SUITE_TEST_GO_FILE # add "context" to import
gsed -i '/^import/a ctrl "sigs.k8s.io/controller-runtime"' $CONTROLLER_SUITE_TEST_GO_FILE # add 'ctrl "sigs.k8s.io/controller-runtime"' to import
gsed -i '/^import/a "sigs.k8s.io/controller-runtime/pkg/manager"' $CONTROLLER_SUITE_TEST_GO_FILE # add "sigs.k8s.io/controller-runtime/pkg/manager" to import
# gsed -i '/"k8s.io\/client-go\/rest"/d' $CONTROLLER_SUITE_TEST_GO_FILE # remove "k8s.io/client-go/rest" from import
gsed -i '/^var [a-z]/d' $CONTROLLER_SUITE_TEST_GO_FILE # remove vars

cat << EOF > tmpfile
var (
       cfg        *rest.Config
       k8sClient  client.Client
       k8sManager manager.Manager
       testEnv    *envtest.Environment
       ctx        context.Context
       cancel     context.CancelFunc
)

EOF
gsed -i $'/^func TestAPIs/{e cat tmpfile\n}' $CONTROLLER_SUITE_TEST_GO_FILE # add vars just before TestAPIs

cat << EOF > tmpfile

    // Create context with cancel.
    ctx, cancel = context.WithCancel(context.TODO())

    // Register the schema to manager.
    k8sManager, err = ctrl.NewManager(cfg, ctrl.Options{
        Scheme: scheme.Scheme,
    })

    // Initialize \`MemcachedReconciler\` with the manager client schema.
    err = (&MemcachedReconciler{
        Client: k8sManager.GetClient(),
        Scheme: k8sManager.GetScheme(),
    }).SetupWithManager(k8sManager)

    // Start the with a goroutine.
    go func() {
        defer GinkgoRecover()
        err = k8sManager.Start(ctx)
        Expect(err).ToNot(HaveOccurred(), "failed to run ger")
    }()
EOF
gsed -i '/Expect(k8sClient).NotTo(BeNil())$/r tmpfile' $CONTROLLER_SUITE_TEST_GO_FILE # add the logic to initialize a manager, register controller and start the manager.
gsed -i '/^var _ = AfterSuite(func() {$/a cancel()' $CONTROLLER_SUITE_TEST_GO_FILE # add cancel() after the line "var _ = AfterSuite(func() {"
rm tmpfile
cat << EOF > controllers/memcached_controller_test.go
package controllers

import (
	"context"
	"fmt"
	"time"

	cachev1alpha1 "github.com/example/memcached-operator/api/v1alpha1"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	appsv1 "k8s.io/api/apps/v1"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	memcachedApiVersion = "cache.example.com/v1alphav1"
	memcachedKind       = "Memcached"
	memcachedName       = "sample"
	memcachedNamespace  = "default"
	memcachedStartSize  = int32(3)
	memcachedUpdateSize = int32(10)
	timeout             = time.Second * 10
	interval            = time.Millisecond * 250
)

var _ = Describe("Memcached controller", func() {

	lookUpKey := types.NamespacedName{Name: memcachedName, Namespace: memcachedNamespace}

	AfterEach(func() {
		// Delete Memcached
		deleteMemcached(ctx, lookUpKey)
		// Delete all Pods
		deleteAllPods(ctx)
	})

	Context("When creating Memcached", func() {
		BeforeEach(func() {
			// Create Memcached
			createMemcached(ctx, memcachedStartSize)
		})
		It("Should create Deployment with the specified size and memcached image", func() {
			// Deployment is created
			deployment := &appsv1.Deployment{}
			Eventually(func() error {
				return k8sClient.Get(ctx, lookUpKey, deployment)
			}, timeout, interval).Should(Succeed())
			Expect(*deployment.Spec.Replicas).Should(Equal(memcachedStartSize))
			Expect(deployment.Spec.Template.Spec.Containers[0].Image).Should(Equal("memcached:1.4.36-alpine"))
			// https://github.com/kubernetes-sigs/controller-runtime/blob/master/pkg/controller/controllerutil/controllerutil_test.go
			Expect(deployment.OwnerReferences).ShouldNot(BeEmpty())
		})
		It("Should have pods name in Memcached Node", func() {
			checkIfDeploymentExists(ctx, lookUpKey)

			By("By creating Pods with labels")
			podNames := createPods(ctx, int(memcachedStartSize))

			updateMemcacheSize(ctx, lookUpKey, memcachedUpdateSize) // just to trigger reconcile

			checkMemcachedStatusNodes(ctx, lookUpKey, podNames)
		})
	})

	Context("When updating Memcached", func() {
		BeforeEach(func() {
			// Create Memcached
			createMemcached(ctx, memcachedStartSize)
			// Deployment is ready
			checkDeploymentReplicas(ctx, lookUpKey, memcachedStartSize)
		})

		It("Should update Deployment replicas", func() {
			By("Changing Memcached size")
			updateMemcacheSize(ctx, lookUpKey, memcachedUpdateSize)

			checkDeploymentReplicas(ctx, lookUpKey, memcachedUpdateSize)
		})

		It("Should update the Memcached status with the pod names", func() {
			By("Changing Memcached size")
			updateMemcacheSize(ctx, lookUpKey, memcachedUpdateSize)

			podNames := createPods(ctx, int(memcachedUpdateSize))
			checkMemcachedStatusNodes(ctx, lookUpKey, podNames)
		})
	})
	Context("When changing Deployment", func() {
		BeforeEach(func() {
			// Create Memcached
			createMemcached(ctx, memcachedStartSize)
			// Deployment is ready
			checkDeploymentReplicas(ctx, lookUpKey, memcachedStartSize)
		})

		It("Should check if the deployment already exists, if not create a new one", func() {
			By("Deleting Deployment")
			deployment := &appsv1.Deployment{}
			Expect(k8sClient.Get(ctx, lookUpKey, deployment)).Should(Succeed())
			Expect(k8sClient.Delete(ctx, deployment)).Should(Succeed())

			// Deployment will be recreated by the controller
			checkIfDeploymentExists(ctx, lookUpKey)
		})

		It("Should ensure the deployment size is the same as the spec", func() {
			By("Changing Deployment replicas")
			deployment := &appsv1.Deployment{}
			Expect(k8sClient.Get(ctx, lookUpKey, deployment)).Should(Succeed())
			*deployment.Spec.Replicas = 0
			Expect(k8sClient.Update(ctx, deployment)).Should(Succeed())

			// replicas will be updated back to the original one by the controller
			checkDeploymentReplicas(ctx, lookUpKey, memcachedStartSize)
		})
	})

	// Deployment is expected to be deleted when Memcached is deleted.
	// As it's garbage collector's responsibility, which is not part of envtest, we don't test it here.
})

func checkIfDeploymentExists(ctx context.Context, lookUpKey types.NamespacedName) {
	deployment := &appsv1.Deployment{}
	Eventually(func() error {
		return k8sClient.Get(ctx, lookUpKey, deployment)
	}, timeout, interval).Should(Succeed())
}

func checkDeploymentReplicas(ctx context.Context, lookUpKey types.NamespacedName, expectedSize int32) {
	Eventually(func() (int32, error) {
		deployment := &appsv1.Deployment{}
		err := k8sClient.Get(ctx, lookUpKey, deployment)
		if err != nil {
			return int32(0), err
		}
		return *deployment.Spec.Replicas, nil
	}, timeout, interval).Should(Equal(expectedSize))
}

func newMemcached(size int32) *cachev1alpha1.Memcached {
	return &cachev1alpha1.Memcached{
		TypeMeta: metav1.TypeMeta{
			APIVersion: memcachedApiVersion,
			Kind:       memcachedKind,
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      memcachedName,
			Namespace: memcachedNamespace,
		},
		Spec: cachev1alpha1.MemcachedSpec{
			Size: size,
		},
	}
}

func createMemcached(ctx context.Context, size int32) {
	memcached := newMemcached(size)
	Expect(k8sClient.Create(ctx, memcached)).Should(Succeed())
}

func updateMemcacheSize(ctx context.Context, lookUpKey types.NamespacedName, size int32) {
	memcached := &cachev1alpha1.Memcached{}
	Expect(k8sClient.Get(ctx, lookUpKey, memcached)).Should(Succeed())
	memcached.Spec.Size = size
	Expect(k8sClient.Update(ctx, memcached)).Should(Succeed())
}

func deleteMemcached(ctx context.Context, lookUpKey types.NamespacedName) {
	memcached := &cachev1alpha1.Memcached{}
	Expect(k8sClient.Get(ctx, lookUpKey, memcached)).Should(Succeed())
	Expect(k8sClient.Delete(ctx, memcached)).Should(Succeed())
}

func checkMemcachedStatusNodes(ctx context.Context, lookUpKey types.NamespacedName, podNames []string) {
	memcached := &cachev1alpha1.Memcached{}
	Eventually(func() ([]string, error) {
		err := k8sClient.Get(ctx, lookUpKey, memcached)
		if err != nil {
			return nil, err
		}
		return memcached.Status.Nodes, nil
	}, timeout, interval).Should(ConsistOf(podNames))
}

func createPods(ctx context.Context, num int) []string {
	podNames := []string{}
	for i := 0; i < num; i++ {
		podName := fmt.Sprintf("pod-%d", i)
		podNames = append(podNames, podName)
		pod := newPod(podName)
		Expect(k8sClient.Create(ctx, pod)).Should(Succeed())
	}
	return podNames
}

func deleteAllPods(ctx context.Context) {
	err := k8sClient.DeleteAllOf(ctx, &v1.Pod{}, client.InNamespace(memcachedNamespace))
	Expect(err).NotTo(HaveOccurred())
}

func newPod(name string) *v1.Pod {
	return &v1.Pod{
		TypeMeta: metav1.TypeMeta{
			Kind:       "Pod",
			APIVersion: "v1",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: memcachedNamespace,
			Labels: map[string]string{
				"app":          "memcached",
				"memcached_cr": memcachedName,
			},
		},
		Spec: v1.PodSpec{
			Containers: []v1.Container{
				{
					Name:  "memcached",
					Image: "memcached",
				},
			},
		},
		Status: v1.PodStatus{},
	}
}
EOF
make fmt
go mod tidy
make test

git add .
pre-commit run -a || true
git commit -am "5. Write controller test"


# 6.1. Deploy with Deployment
make kustomize
cd config/manager && ../../bin/kustomize edit set image controller=nakamasato/memcached-operator && cd -

git add .
pre-commit run -a || true
git commit -am "6.1. Deploy with Deployment"

# 6.2. Deploy with OLM
mkdir -p config/manifests/bases
cat << EOF > config/manifests/bases/memcached-operator.clusterserviceversion.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: ClusterServiceVersion
metadata:
  annotations:
    alm-examples: '[]'
    capabilities: Basic Install
  name: memcached-operator.v0.0.0
  namespace: placeholder
spec:
  apiservicedefinitions: {}
  customresourcedefinitions:
    owned:
    - description: Memcached is the Schema for the memcacheds API
      displayName: Memcached
      kind: Memcached
      name: memcacheds.cache.example.com
      version: v1alpha1
  description: memcached-operator
  displayName: memcached-operator
  icon:
  - base64data: ""
    mediatype: ""
  install:
    spec:
      deployments: null
    strategy: ""
  installModes:
  - supported: false
    type: OwnNamespace
  - supported: false
    type: SingleNamespace
  - supported: false
    type: MultiNamespace
  - supported: true
    type: AllNamespaces
  keywords:
  - memcached
  links:
  - name: Memcached Operator
    url: https://memcached-operator.domain
  maintainers:
  - email: masatonaka1989@gmail.com
    name: naka
  maturity: alpha
  provider:
    name: naka
  version: 0.0.0
EOF

IMG=nakamasato/memcached-operator
make bundle
git add .
pre-commit run -a || true
git commit -am "6.2. Deploy with OLM"

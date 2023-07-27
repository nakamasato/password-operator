#!/bin/bash

set -eux

PASSWORD_CONTROLLER_GO_FILE=internal/controller/password_controller.go
PASSWORD_GO_TYPE_FILE=api/v1alpha1/password_types.go
PASSWORD_WEBHOOK_FILE=api/v1alpha1/password_webhook.go
SAMPLE_YAML_FILE=config/samples/secret_v1alpha1_password.yaml
CERT_MANAGER_VERSION=v1.8.0
export CONTROLLER_TOOLS_VERSION=v0.12.0 # https://github.com/kubernetes-sigs/kubebuilder/issues/3316

pre-commit
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
echo "kubebuilder version: $KUBEBUILDER_VERSION"

read -r -p "Are you to upgrade to kubebuilder version $KUBEBUILDER_VERSION? [y/N] " response
case "$response" in
    [yY][eE][sS]|[yY])
        echo "start upgrading"
        ;;
    *)
        exit 1
        ;;
esac

curl -sS -L -o kubebuilder https://github.com/kubernetes-sigs/kubebuilder/releases/download/${KUBEBUILDER_VERSION}/kubebuilder_$(go env GOOS)_$(go env GOARCH)
chmod +x kubebuilder
mv kubebuilder /usr/local/bin/
echo "install finished"

# 0. Clean up
echo "======== CLEAN UP ==========="

KEEP_FILES=(
    mkdocs.yml
    README.md
    renovate.json
)

sudo rm -rf bin
rm -rf api config controllers hack bin bundle cmd internal
for f in `ls` .dockerignore .gitignore; do
    if [[ ! " ${KEEP_FILES[*]} " =~ " ${f} " ]] && [ -f "$f" ]; then
        rm $f
    fi
done


GO_VERSION_CLI_RESULT=$(go version)
GO_VERSION=$(echo ${GO_VERSION_CLI_RESULT} | sed 's/go version \(go[^\s]*\) [^\s]*/\1/')
echo "KUBEBUILDER_VERSION: $KUBEBUILDER_VERSION, GO_VERSION: $GO_VERSION_CLI_RESULT"
commit_message="Remove all files to upgrade versions ($KUBEBUILDER_VERSION)"
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


make kustomize
kustomize version

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
make install
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
gsed -i '/sigs.k8s.io\/controller-runtime\/pkg\/log/a \\ncorev1 "k8s.io/api/core/v1"' $PASSWORD_CONTROLLER_GO_FILE
gsed -i '/corev1 "k8s.io\/api\/core\/v1"/a "k8s.io/apimachinery/pkg/api/errors"' $PASSWORD_CONTROLLER_GO_FILE
gsed -i '/"k8s.io\/apimachinery\/pkg\/api\/errors"/a metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"' $PASSWORD_CONTROLLER_GO_FILE

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

# add rbac after the last rbac line
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
gsed -i '/secretv1alpha1 "example.com\/password-operator\/api\/v1alpha1"/a passwordGenerator "github.com/sethvargo/go-password/password"' $PASSWORD_CONTROLLER_GO_FILE

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
rm tmpfile

make fmt
go mod tidy

git add .
pre-commit run -a || true
git commit -am "[Controller] Generate random password"


# 9. [API&Controller] Make password configurable with CRD fields

cat << EOF > tmpfile
type PasswordSpec struct {
    //+kubebuilder:validation:Minimum=8
    //+kubebuilder:default:=20
    //+kubebuilder:validation:Required
    Length int \`json:"length"\`

    //+kubebuilder:validation:Minimum=0
    //+kubebuilder:default:=10
    //+kubebuilder:validation:Optional
    Digit int \`json:"digit"\`

    //+kubebuilder:validation:Minimum=0
    //+kubebuilder:default:=10
    //+kubebuilder:validation:Optional
    Symbol int \`json:"symbol"\`

    //+kubebuilder:default:=false
    //+kubebuilder:validation:Optional
    CaseSensitive  bool \`json:"caseSensitive"\`
    //+kubebuilder:default:=false
    //+kubebuilder:validation:Optional
    DisallowRepeat bool \`json:"disallowRepeat"\`
}
EOF
# replace PasswordSpec with tmpfile
gsed -i "/type PasswordSpec struct {/,/^}/c $(sed 's/$/\\n/' tmpfile | tr -d '\n' | sed 's/.\{2\}$//')" $PASSWORD_GO_TYPE_FILE

# check the length of the properties
make install
test "$(kubectl get crd passwords.secret.example.com -o jsonpath='{.spec.versions[].schema.openAPIV3Schema.properties.spec}' | jq '.properties | length')" = "5"


cat << EOF > tmpfile
	passwordStr, err := passwordGenerator.Generate(
		password.Spec.Length,
		password.Spec.Digit,
		password.Spec.Symbol,
		password.Spec.CaseSensitive,
		password.Spec.DisallowRepeat,
	)
EOF
# replace a line with tmpfile
gsed -i 's/passwordStr, err := passwordGenerator.Generate(64, 10, 10, false, false)/cat tmpfile/e' $PASSWORD_CONTROLLER_GO_FILE
make fmt
rm tmpfile

# Write length: 20 in spec
gsed -i '/spec/!b;n;c\ \ length: 20' $SAMPLE_YAML_FILE


git add .
pre-commit run -a || true
git commit -am "[API&Controller] Make password configurable with CRD fields"


# 10. [API&Controller] Add Password Status
cat << EOF > tmpfile
type PasswordState string

const (
	PasswordInSync  PasswordState = "InSync"
	PasswordFailed  PasswordState = "Failed"
)

EOF

gsed -i $'/EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!/{e cat tmpfile\n}' $PASSWORD_GO_TYPE_FILE

cat << EOF > tmpfile
type PasswordStatus struct {

    // Information about if Password is in-sync.
    State PasswordState \`json:"state,omitempty"\` // in-sync, failed
}
EOF
# replace PasswordStatus with tmpfile
gsed -i "/type PasswordStatus struct {/,/^}/c $(sed 's/$/\\n/' tmpfile | tr -d '\n' | sed 's/.\{2\}$//')" $PASSWORD_GO_TYPE_FILE
make manifests

cat << EOF > tmpfile
password.Status.State = secretv1alpha1.PasswordFailed
if err := r.Status().Update(ctx, &password); err != nil {
    logger.Error(err, "Failed to update Password status")
    return ctrl.Result{}, err
}
EOF
# Add the contents before returning the error
gsed -i $'/return ctrl.Result{}, err/{e cat tmpfile\n}' $PASSWORD_CONTROLLER_GO_FILE

cat << EOF > tmpfile

    password.Status.State = secretv1alpha1.PasswordInSync
    if err := r.Status().Update(ctx, &password); err != nil {
        logger.Error(err, "Failed to update Password status")
        return ctrl.Result{}, err
    }
EOF
# Add the contents before the last return in Reconcile function.
gsed -i $'/^\treturn ctrl.Result{}, nil/{e cat tmpfile\n}' $PASSWORD_CONTROLLER_GO_FILE

rm tmpfile
make fmt install

git add .
pre-commit run -a || true
git commit -am "[API&Controller] Add Password Status"


# 11. [API] Add AdditionalPrinterColumns

# //+kubebuilder:printcolumn:name="State",type=string,JSONPath=`.status.state`
# //+kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
gsed -i '/\/\/+kubebuilder:subresource:status/a \/\/+kubebuilder:printcolumn:name="State",type=string,JSONPath=`.status.state`' $PASSWORD_GO_TYPE_FILE
gsed -i '/\/\/+kubebuilder:subresource:status/a \/\/+kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`' $PASSWORD_GO_TYPE_FILE

make manifests
make install
# check additionalPrinterColumns is set
test "$(kubectl get crd passwords.secret.example.com -o jsonpath='{.spec.versions[].additionalPrinterColumns}' | jq length)" = "2"

git add .
pre-commit run -a || true
git commit -am "[API] Add AdditionalPrinterColumns"

# 12. [kubebuilder] Create validating admission webhook
kubebuilder create webhook --group secret --version v1alpha1 --kind Password --programmatic-validation
make manifests
git add .
pre-commit run -a || true
git add . && git commit -am "[kubebuilder] Create validating admission webhook"

# 13. [API] Implement Validating Admission Webhook

# Replace ValidateCreate
cat << EOF > tmpfile
func (r *Password) ValidateCreate() error {
	passwordlog.Info("validate create", "name", r.Name)

	return r.validatePassword()
}
EOF
gsed -i "/func (r \*Password) ValidateCreate() error {/,/^}/c $(sed 's/$/\\n/' tmpfile | tr -d '\n' | sed 's/.\{2\}$//')" $PASSWORD_WEBHOOK_FILE

# Replace ValidateUpdate
cat << EOF > tmpfile
func (r *Password) ValidateUpdate(old runtime.Object) error {
	passwordlog.Info("validate update", "name", r.Name)

	return r.validatePassword()
}
EOF
gsed -i "/func (r \*Password) ValidateUpdate(old runtime.Object) error {/,/^}/c $(sed 's/$/\\n/' tmpfile | tr -d '\n' | sed 's/.\{2\}$//')" $PASSWORD_WEBHOOK_FILE

# add validatePassword at the bottom
cat << EOF >> $PASSWORD_WEBHOOK_FILE

var ErrSumOfDigitAndSymbolMustBeLessThanLength = errors.New("Number of digits and symbols must be less than total length")

func (r *Password) validatePassword() error {
	if r.Spec.Digit+r.Spec.Symbol > r.Spec.Length {
		return ErrSumOfDigitAndSymbolMustBeLessThanLength
	}
	return nil
}
EOF
rm tmpfile

# add "k8s.io/apimachinery/pkg/api/errors" to import
gsed -i '/^import/a "errors"' $PASSWORD_WEBHOOK_FILE
make fmt

# comment out
gsed -i -e '/fieldSpecs/,+3 s/^\(.*\): \(.*\)/#\1: \2/' config/webhook/kustomizeconfig.yaml
gsed -i -e '/namespace:/,+4 s/^\(.*\): \(.*\)/#\1: \2/' config/webhook/kustomizeconfig.yaml

gsed -i -e '/MutatingWebhookConfiguration/,+11 s/^/#/' config/default/webhookcainjection_patch.yaml
gsed -i '0,/apiVersion/s/apiVersion/#apiVersion/' config/default/webhookcainjection_patch.yaml

# uncomment

gsed -i 's/#- ..\/webhook/- ..\/webhook/g' config/default/kustomization.yaml
gsed -i 's/#- ..\/certmanager/- ..\/certmanager/g' config/default/kustomization.yaml
gsed -i 's/#- manager_webhook_patch.yaml/- manager_webhook_patch.yaml/g' config/default/kustomization.yaml # To enable webhook, uncomment all the sections with [WEBHOOK] prefix
gsed -i 's/#- webhookcainjection_patch.yaml/- webhookcainjection_patch.yaml/g' config/default/kustomization.yaml  # To enable cert-manager uncomment all sections with 'CERTMANAGER' prefix.
gsed -i -e '/#replacements:/,+96 s/#//' config/default/kustomization.yaml # To enable cert-manager uncomment all sections with 'CERTMANAGER' prefix.
gsed -i 's/#- patches/- patches/g' config/crd/kustomization.yaml

make install
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml
# wait cert manager
while [ "$(kubectl get po -n cert-manager -o json | jq '.items | length')" != "3" ]; do
	sleep 5
	echo "waiting for 3 cert-manager Pods creation"
done

while [ "$(kubectl get po -n cert-manager -o 'jsonpath={.items[*].status.containerStatuses[*]}' | jq '.ready' | uniq)" != "true" ]; do
	sleep 5
	echo "waiting for 3 cert-manager Pods readiness"
done
echo "cert-manager is ready"

make kustomize # To ensure kustomize is installed
# To ensure Certificate and Secret exist before starting operator, deploy Namespace and Certificate first.
kustomize build config/default | yq '. | select(.kind == "Certificate" or .kind == "Namespace")' | kubectl apply -f -
IMG=password-operator:webhook
make docker-build IMG=$IMG
kind load docker-image $IMG
make deploy IMG=$IMG

# wait operator manager Pod
while [ $(kubectl get po -n password-operator-system -o json | jq '.items | length') != "1" ]; do
	sleep 5
	echo "waiting for Pod creation"
done
loop=0
while [ $(kubectl get po -n password-operator-system -o 'jsonpath={.items[].status.containerStatuses[].ready}') != true ]; do
	sleep 5
	echo 'waiting for Pod readiness'
	((loop++))
	if [[ $loop -gt 100 ]]; then
		echo "timeout"
		exit 1
	fi
done
make undeploy
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml

git add .
pre-commit run -a || true
git add . && git commit -am "[API] Implement validating admission webhook"

# Update README

# Description
gsed -i '/# password-operator/{n;s/.*/Example Kubernetes Operator project created with kubebuilder, which manages a CRD \`Password\` and generates a configurable password./}' README.md

# Versions
./.update-readme.sh $KUBEBUILDER_VERSION

git add .
pre-commit run -a || true
git add . && git commit -am "Update README"

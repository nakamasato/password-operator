#!/bin/bash

set -eux

PASSWORD_CONTROLLER_GO_FILE=controllers/password_controller.go
PASSWORD_GO_TYPE_FILE=api/v1alpha1/password_types.go
SAMPLE_YAML_FILE=config/samples/secret_v1alpha1_password.yaml
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
gsed -i "/type PasswordSpec struct {/,/^}/c $(sed 's/$/\\n/' tmpfile | tr -d '\n')" $PASSWORD_GO_TYPE_FILE

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

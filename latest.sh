#!/bin/bash

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare COMMAND="help"

valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

wait_seconds() {
  local count=${1:-5}
  for i in {1..$count}
  do
    echo "."
    sleep 1
  done
  printf "\n"
}

case "$OSTYPE" in
    darwin*)  PLATFORM="OSX" ;;
    linux*)   PLATFORM="LINUX" ;;
    bsd*)     PLATFORM="BSD" ;;
    *)        PLATFORM="UNKNOWN" ;;
esac

cross_sed() {
    if [[ "$PLATFORM" == "OSX" || "$PLATFORM" == "BSD" ]]; then
        sed -i "" "$1" "$2"
    elif [ "$PLATFORM" == "LINUX" ]; then
        sed -i "$1" "$2"
    fi
}

while (( "$#" )); do
  case "$1" in
    install|uninstall|start)
      COMMAND=$1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *)
      break
      ;;
  esac
done

declare -r dev_prj="dev"
declare -r uat_prj="uat"
declare -r cicd_prj="infra"
declare -r gitlab_namespace="infra"  # Updated namespace to infra

command.help() {
  cat <<-EOF

  Usage:
      demo [command] [options]

  Example:
      demo install --project-prefix mydemo

  COMMANDS:
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo
      start                          Starts the deploy DEV pipeline
      help                           Help about this command

  OPTIONS:
      -p|--project-prefix [string]   Prefix to be added to demo project names e.g. PREFIX-dev
EOF
}

command.install() {
  oc version >/dev/null 2>&1 || err "no oc binary found"

  info "Creating namespaces $cicd_prj, $dev_prj, $uat_prj"
  oc get ns $cicd_prj 2>/dev/null  || {
    oc new-project $cicd_prj
  }
  oc get ns $dev_prj 2>/dev/null  || {
    oc new-project $dev_prj
  }
  oc get ns $uat_prj 2>/dev/null  || {
    oc new-project $uat_prj
  }

cat <<EOF | oc apply -f -
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: gitlab-scc1
allowHostDirVolumePlugin: false
allowPrivilegeEscalation: true
allowPrivilegedContainer: false
allowedCapabilities:
- CHOWN
- FOWNER
- DAC_OVERRIDE
- SETGID
- SETUID
fsGroup:
  type: MustRunAs
  ranges:
  - min: 1000
    max: 1000
runAsUser:
  type: MustRunAsRange
  uidRangeMin: 0  # Allow root for initContainer
  uidRangeMax: 1000  # And non-root for main container
seLinuxContext:
  type: RunAsAny
supplementalGroups:
  type: RunAsAny
volumes:
- configMap
- secret
- persistentVolumeClaim
- emptyDir
users:
- system:serviceaccount:infra:gitlab
EOF

#   cat <<EOF | oc apply -f -
# apiVersion: security.openshift.io/v1
# kind: SecurityContextConstraints
# metadata:
#   name: gitlab-scc
# allowHostDirVolumePlugin: false
# allowPrivilegeEscalation: true  # Required for GitLab
# allowPrivilegedContainer: false
# allowedCapabilities:
# - CHOWN
# - DAC_OVERRIDE
# - FOWNER
# - SETGID
# - SETUID
# fsGroup:
#   type: MustRunAs
#   ranges:
#   - min: 1000
#     max: 1000
# readOnlyRootFilesystem: false
# runAsUser:
#   type: MustRunAsRange
#   uidRangeMin: 1000
#   uidRangeMax: 1000
# seLinuxContext:
#   type: RunAsAny  # Temporarily permissive
# supplementalGroups:
#   type: MustRunAs
#   ranges:
#   - min: 1000
#     max: 1000
# volumes:
# - configMap
# - secret
# - persistentVolumeClaim
# - emptyDir
# users:
# - system:serviceaccount:infra:gitlab
# EOF


# cat <<EOF | oc apply -f -
# apiVersion: security.openshift.io/v1
# kind: SecurityContextConstraints
# metadata:
#   name: gitlab-scc1
# allowHostDirVolumePlugin: false
# allowPrivilegeEscalation: false
# allowedCapabilities: []
# fsGroup:
#   type: RunAsAny
# runAsUser:
#   type: RunAsAny
# seLinuxContext:
#   type: RunAsAny
# supplementalGroups:
#   type: RunAsAny
# volumes:
# - configMap
# - secret
# - persistentVolumeClaim
# - emptyDir
# users:
# - system:serviceaccount:infra:gitlab
# EOF


  info "Configure service account permissions for pipeline"
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $dev_prj
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $uat_prj
  oc policy add-role-to-user system:image-puller system:serviceaccount:$dev_prj:default -n $cicd_prj
  oc policy add-role-to-user system:image-puller system:serviceaccount:$uat_prj:default -n $cicd_prj

  oc adm policy add-scc-to-user anyuid -z default -n infra
  oc adm policy add-scc-to-user gitlab-scc1 -z gitlab -n infra
  oc adm policy add-scc-to-user anyuid -z gitlab -n infra
  

  oc adm policy add-scc-to-user gitlab-scc1 -z gitlab -n infra

  oc create secret docker-registry my-dockerhub-secret  --docker-server=docker.io --docker-username=rearahhal   --docker-password=dckr_pat__6pCYpfEBYLRN6eZsDfCED09K9Y --docker-email=rea_rahhal@hotmail.com -n infra

oc secrets link default my-dockerhub-secret --for=pull -n infra

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -f infra -n $cicd_prj

  sed -i 's/\r//' config/gitlab.rb


  for file in config/*.rb config/*.yaml; do
    cross_sed 's/\r//' "$file"
  done

  # Replace gitlab-system with infra in all yaml files
  for file in config/*.yaml; do
    cross_sed 's/infra/infra/g' "$file"
  done



#   oc create configmap gitlab-values --from-file=gitlab.rb=config/gitlab.rb --from-file=values.yaml=config/values.yaml --from-file=gitlab-values.yaml=config/gitlab-values.yaml \
# -n infra
 oc create configmap gitlab-values --from-file=gitlab.rb=config/gitlab.rb --from-file=values.yaml=config/values.yaml --from-file=gitlab-values.yaml=config/gitlab-values.yaml -n infra


# oc replace -f gitlab-values.yaml -n infra
  oc replace -f config/gitlab-values.yaml -n infra

   

  echo "Creating git-auth-secret in 'infra' namespace..."
    oc create secret generic git-auth-secret  --from-literal=token=glpat-Aj7C8JvX5sc-Zdnf9Zuu -n infra


  GITLAB_HOSTNAME=$(oc get route gitlab -o template --template='{{.spec.host}}' -n infra)
  GITLAB_HOSTNAME_OLD='https://github.com'

  info "Initializing git repository in Gitea and configuring webhooks"
  WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n pipelines-as-code -o template --template="{{.spec.host}}"  --ignore-not-found)
  if [ -z "$WEBHOOK_URL" ]; then 
      WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n openshift-pipelines -o template --template="{{.spec.host}}")
  fi

  echo "The webhook URL is: $WEBHOOK_URL"

  echo "The GITAB HOSTNAME is: $GITLAB_HOSTNAME"



  oc apply -f config/gitlab-values.yaml -n infra

  oc rollout status deployment/gitlab -n infra

    echo "before replacing url and hostname"







if oc get configmap gitlab-values -n $cicd_prj >/dev/null 2>&1; then
    echo "ConfigMap gitlab-values exists, updating it..."
    sed "s#@webhook-url@#https://$WEBHOOK_URL#g" config/gitlab-init-taskrun.yaml | sed "s#@gitlab-url@#https://$GITLAB_HOSTNAME#g" | \
    oc get configmap gitlab-values -n $cicd_prj -o jsonpath='{.data.gitlab-values\.yaml}' | \
    sed "s#@webhook-url@#$WEBHOOK_URL#g; s#@gitlab-url@#$GITLAB_HOSTNAME#g" | \
    sed '/^[[:space:]]*namespace:/d' | \
    awk -v cicd_prj="$cicd_prj" 'BEGIN {print "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: gitlab-values\n  namespace: "cicd_prj"\ndata:\n  gitlab-values.yaml: |"} {print} END {print ""}' | \
    oc apply -f - -n $cicd_prj
else
    echo "ConfigMap gitlab-values does not exist, creating it..."
    sed "s#@webhook-url@#https://$WEBHOOK_URL#g" config/gitlab-init-taskrun.yaml | sed "s#@gitlab-url@#https://$GITLAB_HOSTNAME#g" | \
    oc get configmap gitlab-values -n infra -o jsonpath='{.data.gitlab-values\.yaml}' | \
    sed "s#@webhook-url@#$WEBHOOK_URL#g; s#@gitlab-url@#$GITLAB_HOSTNAME#g" | \
    sed '/^[[:space:]]*namespace:/d' | \
    awk -v cicd_prj="$cicd_prj" 'BEGIN {print "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: gitlab-values\n  namespace: "cicd_prj"\ndata:\n  gitlab-values.yaml: |"} {print} END {print ""}' | \
    oc create -f - -n $cicd_prj
fi


  echo "after replacing url and hostname"

  echo "Creating GitLab init TaskRun..."

# Replace placeholders and create the TaskRun
sed "s#@webhook-url@#https://$WEBHOOK_URL#g" config/gitlab-init-taskrun.yaml | \
sed "s#@gitlab-url@#https://$GITLAB_HOSTNAME#g" | \
oc create -f - -n $cicd_prj
   

  wait_seconds 20

  while oc get taskrun -n $cicd_prj | grep Running >/dev/null 2>/dev/null
  do
    echo "waiting for Gitea init..."
    wait_seconds 5
  done

  echo "Waiting for source code to be imported to Gitea..."
  while true; 
  do
      echo "The old           URL is: $GITLAB_HOSTNAME_OLD"

    result=$(curl --write-out '%{response_code}' --head --silent --output /dev/null $GITLAB_HOSTNAME_OLD/rrahhal1/spring-petclinic)
    if [ "$result" == "200" ]; then
	    break
    fi
    wait_seconds 5
  done

  wait_seconds 5

  info "Updating pipelinerun values for the demo environment"
  tmp_dir=$(mktemp -d)
  pushd $tmp_dir

    echo "The old URL is: $GITLAB_HOSTNAME_OLD"


  git clone $GITLAB_HOSTNAME_OLD/rrahhal1/spring-petclinic 
  echo "after clone"
  cd spring-petclinic 
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"
  cat .tekton/build.yaml | grep -A 2 GIT_REPOSITORY
  cross_sed "s#https://github.com/rrahhal1/spring-petclinic-config#https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic-config#g" .tekton/build.yaml
  cat .tekton/build.yaml | grep -A 2 GIT_REPOSITORY
  git status
  git add .tekton/build.yaml
  git commit -m "Updated manifests git url"
  git remote add auth-origin https://rearahhal:openshift@$GITLAB_HOSTNAME/rearahhal/spring-petclinic
  git push auth-origin cicd-demo
  popd

  info "Configuring pipelines-as-code"
  TASKRUN_NAME=$(oc get taskrun -n $cicd_prj -o jsonpath="{.items[0].metadata.name}")
  GITLAB_TOKEN=$(oc logs $TASKRUN_NAME-pod -n $cicd_prj | grep Token | sed 's/^## Token: \(.*\) ##$/\1/g')

  cat << EOF > /tmp/tmp-pac-repository.yaml
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: spring-petclinic
  namespace: $cicd_prj
spec:
  url: https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic
  git_provider:
    user: rearahhal
    url: https://$GITLAB_HOSTNAME
    secret:
      name: "rearahhal"
      key: token
    webhook_secret:
      name: "rearahhal"
      key: "webhook"
---
apiVersion: v1
kind: Secret
metadata:
  name: rearahhal
  namespace: $cicd_prj
type: Opaque
stringData:
  token: "$GITLAB_TOKEN"
  webhook: ""
EOF
  oc apply -f /tmp/tmp-pac-repository.yaml -n $cicd_prj 

  wait_seconds 10

  info "Configure Argo CD"
  cat << EOF > argo/tmp-argocd-app-patch.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-spring-petclinic
spec:
  destination:
    namespace: $dev_prj
  source:
    repoURL: https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic-config
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: uat-spring-petclinic
spec:
  destination:
    namespace: $uat_prj
  source:
    repoURL: https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic-config
EOF
  oc apply -k argo -n $cicd_prj

  info "Wait for Argo CD route..."

  until oc get route argocd-server -n $cicd_prj >/dev/null 2>/dev/null
  do
    wait_seconds 5
  done

  info "Grants permissions to ArgoCD instances to manage resources in target namespaces"
  oc label ns $dev_prj argocd.argoproj.io/managed-by=$cicd_prj
  oc label ns $uat_prj argocd.argoproj.io/managed-by=$cicd_prj

  oc project $cicd_prj

  cat <<-EOF

############################################################################
############################################################################

Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gitea:
     https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic.git

  2) Log into Gitea with username/password: rearahhal/openshift

  3) Edit a file in the repository and commit to trigger the pipeline (alternatively, create a pull-request)

  4) Check the pipeline run logs in Dev Console or Tekton CLI:

    \$ opc pac logs -n $cicd_prj

  You can find further details at:

  Gitea Git Server: https://$GITLAB_HOSTNAME/explore/repos
  SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
  Sonatype Nexus: https://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)
  Argo CD:  http://$(oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj)  [login with OpenShift credentials]

############################################################################
############################################################################
EOF
}

command.start() {
  GITLAB_HOSTNAME=$(oc get route gitlab -o template --template='{{.spec.host}}' -n $cicd_prj)
  info "Pushing a change to https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic-config"
  tmp_dir=$(mktemp -d)
  pushd $tmp_dir
  git clone https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic 
  cd spring-petclinic 
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"
  echo "   " >> readme.md
  git add readme.md
  git commit -m "Updated readme.md"
  git remote add auth-origin https://rearahhal:openshift@$GITLAB_HOSTNAME/rearahhal/spring-petclinic
  git push auth-origin cicd-demo
  popd
}

command.uninstall() {
  oc delete project $dev_prj $uat_prj $cicd_prj
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  cd $SCRIPT_DIR
  $fn
  return $?
}

main

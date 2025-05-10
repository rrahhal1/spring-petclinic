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


declare -r prod_prj="prd"
declare -r cicd_prj="infra"
declare -r uat_prj="uat"
declare -r dev_prj="dev"


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


command start(){
}
command.install() {
  oc version >/dev/null 2>&1 || err "no oc binary found"

  info "Creating namespaces $prod_prj"
  # oc get ns $cicd_prj 2>/dev/null  || {
  #   oc new-project $cicd_prj
  # }
  # oc get ns $dev_prj 2>/dev/null  || {
  #   oc new-project $dev_prj
  # }
  oc get ns $prod_prj 2>/dev/null  || {
    oc new-project $prod_prj
  }

  info "Configure service account permissions for pipeline"
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $prod_prj
  oc policy add-role-to-user system:image-puller system:serviceaccount:$prod_prj:default -n $cicd_prj


  
  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -f infra -n $cicd_prj
  GITLAB_HOSTNAME=$(oc get route gitlab -o template --template='{{.spec.host}}' -n $cicd_prj)

  info "Initiatlizing git repository in Gitea and configuring webhooks"
  WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n pipelines-as-code -o template --template="{{.spec.host}}"  --ignore-not-found)
  if [ -z "$WEBHOOK_URL" ]; then 
      WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n openshift-pipelines -o template --template="{{.spec.host}}")
  fi

  oc get configmap gitlab-values -o jsonpath='{.data.values\.yaml}' | \
  sed "s/@HOSTNAME/$GITLAB_HOSTNAME/g" | \
  oc create -f - -n $cicd_prj

# Wait for the deployment to complete
 oc rollout status deployment/gitlab -n $cicd_prj

# Replace @webhook-url@ and @gitlab-url@ in gitlab-init-taskrun.yaml from the ConfigMap and apply it
oc get configmap gitlab-values -o jsonpath='{.data.gitlab-init-taskrun\.yaml}' | \
  sed "s#@webhook-url@#https://$WEBHOOK_URL#g" | \
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
    result=$(curl --write-out '%{response_code}' --head --silent --output /dev/null https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic)
    if [ "$result" == "200" ]; then
	    break
    fi
    wait_seconds 5
  done
  
  wait_seconds 5

  info "Updating pipelinerun values for the demo environment"
  tmp_dir=$(mktemp -d)
  pushd $tmp_dir
  git clone https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic 
  cd spring-petclinic 
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"

 
  info "Adding build2.yaml and updating pipelinerun values for the demo environment"

# Create a temporary directory
tmp_dir=$(mktemp -d)
pushd "$tmp_dir"

# Clone the Git repository
git clone "https://$GITEA_HOSTNAME/gitea/spring-petclinic"
cd spring-petclinic 

# Set Git user info
git config user.email "openshift-pipelines@redhat.com"
git config user.name "openshift-pipelines"

# Create the build2.yaml file (only if it doesn't already exist)
if [[ ! -f .tekton/build2.yaml ]]; then
    cat <<EOF > .tekton/build2.yaml
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: spring-petclinic2-build
  annotations:
    pipelinesascode.tekton.dev/on-event: "[pull_request, push]"
    pipelinesascode.tekton.dev/on-target-branch: "cicd-demo"
    pipelinesascode.tekton.dev/max-keep-runs: "5"
spec:
  params:
    - name: repo_url
      value: "{{ repo_url }}"
    - name: revision
      value: "{{ revision }}"
  pipelineSpec:
    params:
      - name: repo_url
      - name: revision
    workspaces:
      - name: source
      - name: basic-auth
    results:
      - name: APP_IMAGE_DIGETST
        description: The image digest built in the pipeline
        value: $(tasks.build-image.results.IMAGE_DIGEST)
    tasks:
      - name: source-clone
        taskRef:
          resolver: cluster
          params:
          - name: name
            value: git-clone
          - name: namespace
            value: openshift-pipelines
          - name: kind
            value: task
        workspaces:
          - name: output
            workspace: source
          - name: basic-auth
            workspace: basic-auth
        params:
          - name: URL
            value: $(params.repo_url)
          - name: REVISION
            value: $(params.revision)
          - name: DEPTH
            value: "0"
          - name: SUBDIRECTORY
            value: spring-petclinic
      - name: mvn-config
        taskRef: 
          name: mvn-config
        runAfter:
          - source-clone
        workspaces:
        - name: workspace
          workspace: source
      - name: unit-tests
        taskRef:
          resolver: cluster
          params:
          - name: name
            value: maven
          - name: namespace
            value: openshift-pipelines
          - name: kind
            value: task
        runAfter:
          - mvn-config
        workspaces:
        - name: source
          workspace: source
        - name: maven_settings
          workspace: source
        params:
        - name: GOALS
          value: ["package", "-f", "spring-petclinic"]
      - name: code-analysis
        taskRef:
          resolver: cluster
          params:
          - name: name
            value: maven
          - name: namespace
            value: openshift-pipelines
          - name: kind
            value: task
        runAfter:
          - unit-tests
        workspaces:
        - name: source
          workspace: source
        - name: maven_settings
          workspace: source
        params:
        - name: GOALS
          value:
          - install
          - org.sonarsource.scanner.maven:sonar-maven-plugin:5.0.0.4389:sonar
          - -f
          - spring-petclinic
          - -Dsonar.host.url=http://sonarqube:9000
          - -Dsonar.userHome=/tmp/sonar
          - -DskipTests=true
          - -Dsonar.qualitygate.wait=true
          - -Dsonar.login=admin
          - -Dsonar.password=sonarqube
      - name: security-scan
        taskRef:
          resolver: cluster
          params:
          - name: name
            value: maven
          - name: namespace
            value: openshift-pipelines
          - name: kind
            value: task
        runAfter:
          - unit-tests
        workspaces:
        - name: source
          workspace: source
        - name: maven_settings
          workspace: source
        params:
        - name: GOALS
          value: ["--version", "-f", "spring-petclinic"]
      - name: release-app
        taskRef:
          resolver: cluster
          params:
          - name: name
            value: maven
          - name: namespace
            value: openshift-pipelines
          - name: kind
            value: task
        runAfter:
          - code-analysis
          - security-scan
        workspaces:
        - name: source
          workspace: source
        - name: maven_settings
          workspace: source
        params:
        - name: GOALS
          value:
          - deploy
          - -f 
          - spring-petclinic
          - -DskipTests=true
          - -DaltDeploymentRepository=nexus::default::http://nexus:8081/repository/maven-releases/
          - -DaltSnapshotDeploymentRepository=nexus::default::http://nexus:8081/repository/maven-snapshots/
          - -Durl=http://nexus:8081/repository/maven-releases/
          - -DrepositoryId=nexus
      - name: build-image
        taskRef:
          resolver: cluster
          params:
          - name: name
            value: s2i-java
          - name: namespace
            value: openshift-pipelines
          - name: kind
            value: task
        runAfter:
        - release-app
        params:
          - name: TLS_VERIFY
            value: "false"
          # - name: MAVEN_MIRROR_URL
            # value: http://nexus:8081/repository/maven-public/
          - name: CONTEXT
            value: spring-petclinic/target
          - name: IMAGE
            value: image-registry.openshift-image-registry.svc:5000/$(context.pipelineRun.namespace)/spring-petclinic:latest
          - name: IMAGE_SCRIPTS_URL
            value: "image:///usr/local/s2i"
        workspaces:
        - name: source
          workspace: source
      - name: update-manifests
        runAfter:
        - build-image
        taskRef:
          name: git-update-deployment
        params:
          - name: GIT_REPOSITORY
            value: https://github.com/rrahhal1/spring-petclinic-config
          - name: GIT_USERNAME
            value: rearahhal
          - name: GIT_PASSWORD
            valueFrom:
              secretKeyRef:
                name: "{{ git_auth_secret }}"  # Reference to secret name
                key: token  # The key inside the secret that holds your GitLab token
          - name: CURRENT_IMAGE
            value: quay.io/siamaksade/spring-petclinic:latest
          - name: NEW_IMAGE
            value: image-registry.openshift-image-registry.svc:5000/$(context.pipelineRun.namespace)/spring-petclinic
          - name: NEW_DIGEST
            value: "$(tasks.build-image.results.IMAGE_DIGEST)"
          - name: KUSTOMIZATION_PATH
            value: environments/uat
        workspaces:
        - name: workspace
          workspace: source
      - name: pr-promote
        runAfter:
        - update-manifests
        taskRef:
          name: create-promote-pull-request
        params:
          - name: GIT_REPOSITORY
            value: https://github.com/rrahhal1/spring-petclinic-config
          - name: GIT_USERNAME
            value: rearahhal
          - name: GIT_PASSWORD
            valueFrom:
              secretKeyRef:
                name: "{{ git_auth_secret }}"  # Reference to secret name
                key: token  # The key inside the secret that holds your GitLab token
          - name: COPY_FROM_PATH
            value: environments/uat
          - name: COPY_TO_PATH
            value: environments/prd
        workspaces:
        - name: workspace
          workspace: source
  workspaces:
  - name: source
    volumeClaimTemplate:
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
  - name: basic-auth
    secret:
      secretName: "{{ git_auth_secret }}"


EOF
    echo "build2.yaml created successfully."
fi

# Git operations

cat .tekton/build2.yaml | grep -A 2 GIT_REPOSITORY
cross_sed "s#https://github.com/rrahhal1/spring-petclinic-config#https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic-config#g" .tekton/build2.yaml
git status
git add .tekton/build2.yaml
git commit -m "Added build2.yaml"
git remote add auth-origin "https://rearahhal:openshift@$GITLAB_HOSTNAME/rearahhal/spring-petclinic"
git push auth-origin cicd-demo

# Return to the previous directory
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
  name: uat-spring-petclinic
spec:
  destination:
    namespace: $uat_prj
  source:
    repoURL: https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prd-spring-petclinic
spec:
  destination:
    namespace: $prod_prj
  source:
    repoURL: https://$GITLAB_HOSTNAME/rearahhal/spring-petclinic
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
  oc label ns $prod_prj argocd.argoproj.io/managed-by=$cicd_prj


  oc project $cicd_prj

  cat <<-EOF

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gitea:
     https://$GITEA_HOSTNAME/gitea/spring-petclinic.git

  2) Log into Gitea with username/password: gitea/openshift

  3) Edit a file in the repository and commit to trigger the pipeline (alternatively, create a pull-request)

  4) Check the pipeline run logs in Dev Console or Tekton CLI:

    \$ opc pac logs -n $cicd_prj


  You can find further details at:

  Gitea Git Server: https://$GITEA_HOSTNAME/explore/repos
  SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
  Sonatype Nexus: https://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)
  Argo CD:  http://$(oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj)  [login with OpenShift credentials]

############################################################################
############################################################################
EOF
}



command.uninstall() {
  oc delete project $dev_prj $uat_prj $cicd_prj $prod_prj
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

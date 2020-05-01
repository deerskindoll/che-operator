#!/bin/bash
#
# Copyright (c) 2019 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Contributors:
#   Red Hat, Inc. - initial API and implementation

set -e

init() {
  RELEASE="$1"
  BRANCH=$(echo $RELEASE | sed 's/.$/x/')
  GIT_REMOTE_UPSTREAM="git@github.com:eclipse/che-operator.git"
  PULL_REQUEST=false
  PUSH_OLM_FILES=false
  PUSH_GIT_CHANGES=false
  RELEASE_DIR=$(cd "$(dirname "$0")"; pwd)

  if [[ $# -lt 1 ]]; then usage; exit; fi

  while [[ "$#" -gt 0 ]]; do
    case $1 in
      '--branch') BRANCH="$2"; shift 1;;
      '--pr') PULL_REQUEST=true; shift 0;;
      '--push-olm-files') PUSH_OLM_FILES=true; shift 0;;
      '--push-git-changes') PUSH_GIT_CHANGES=true; shift 0;;
    '--help'|'-h') usage; exit;;
    esac
    shift 1
  done

  [ -z "$QUAY_USERNAME" ] && echo "[ERROR] QUAY_USERNAME is not set" && exit 1
  [ -z "$QUAY_PASSWORD" ] && echo "[ERROR] QUAY_PASSWORD is not set" && exit 1
  command -v operator-courier >/dev/null 2>&1 || { echo "[ERROR] operator-courier is not installed. Aborting."; exit 1; }
  command -v operator-sdk >/dev/null 2>&1 || { echo "[ERROR] operator-sdk is not installed. Aborting."; exit 1; }
  command -v skopeo >/dev/null 2>&1 || { echo "[ERROR] skopeo is not installed. Aborting."; exit 1; }
  [[ $(operator-sdk version) =~ .*v0.10.0.* ]] || { echo "[ERROR] operator-sdk v0.10.0 is required. Aborting."; exit 1; }

  local ubiMinimal8Version=$(skopeo inspect docker://registry.access.redhat.com/ubi8-minimal:latest | jq -r '.Labels.version')
  local ubiMinimal8Release=$(skopeo inspect docker://registry.access.redhat.com/ubi8-minimal:latest | jq -r '.Labels.release')
  UBI8_MINIMAL_IMAGE="registry.access.redhat.com/ubi8-minimal:"$ubiMinimal8Version"-"$ubiMinimal8Release
  skopeo inspect docker://$UBI8_MINIMAL_IMAGE > /dev/null
}

usage () {
	echo "Usage:   $0 [RELEASE_VERSION] --branch [SOURCE_PATH] --pr "
}

resetChanges() {
  echo "[INFO] Reseting changes in $1 branch"
  git reset --hard
  git checkout $1
  git fetch ${GIT_REMOTE_UPSTREAM} --prune
  git pull ${GIT_REMOTE_UPSTREAM} $1
}

checkoutToReleaseBranch() {
  echo "[INFO] Checking out to $BRANCH branch."
  local branchExist=$(git ls-remote -q --heads | grep $BRANCH | wc -l)
  if [[ $branchExist == 1 ]]; then
    echo "[INFO] $BRANCH exists."
    resetChanges $BRANCH
  else
    echo "[INFO] $BRANCH does not exist. Will be created a new one from master."
    resetChanges master
    git push origin master:$BRANCH
  fi
  git checkout -B $RELEASE
}

getPropertyValue() {
  local file=$1
  local key=$2
  echo $(cat $file | grep -m1 "$key" | tr -d ' ' | tr -d '\t' | cut -d = -f2)
}

checkImageReferences() {
  local filename=$1

  if ! grep -q "value: ${RELEASE}" $filename; then
    echo "[ERROR] Unable to find Che version ${RELEASE} in the $filename"; exit 1
  fi

  if ! grep -q "value: quay.io/eclipse/che-server:$RELEASE" $filename; then
    echo "[ERROR] Unable to find Che server image with version ${RELEASE} in the $filename"; exit 1
  fi

  if ! grep -q "value: quay.io/eclipse/che-plugin-registry:$RELEASE" $filename; then
    echo "[ERROR] Unable to find plugin registry image with version ${RELEASE} in the $filename"; exit 1
  fi

  if ! grep -q "value: quay.io/eclipse/che-devfile-registry:$RELEASE" $filename; then
    echo "[ERROR] Unable to find devfile registry image with version ${RELEASE} in the $filename"; exit 1
  fi

  if ! grep -q "value: quay.io/eclipse/che-keycloak:$RELEASE" $filename; then
    echo "[ERROR] Unable to find che-keycloak image with version ${RELEASE} in the $filename"; exit 1
  fi

  if ! grep -q "value: $IMAGE_default_pvc_jobs" $filename; then
    echo "[ERROR] Unable to find ubi8_minimal image in the $filename"; exit 1
  fi

  wget https://raw.githubusercontent.com/eclipse/che/${RELEASE}/assembly/assembly-wsmaster-war/src/main/webapp/WEB-INF/classes/che/che.properties -q -O /tmp/che.properties

  plugin_broker_meta_image=$(cat /tmp/che.properties | grep  che.workspace.plugin_broker.metadata.image | cut -d '=' -f2)
  if ! grep -q "value: $plugin_broker_meta_image" $filename; then
    echo "[ERROR] Unable to find plugin broker meta image '$plugin_broker_meta_image' in the $filename"; exit 1
  fi

  plugin_broker_artifacts_image=$(cat /tmp/che.properties | grep  che.workspace.plugin_broker.artifacts.image | cut -d '=' -f2)
  if ! grep -q "value: $plugin_broker_artifacts_image" $filename; then
    echo "[ERROR] Unable to find plugin broker artifacts image '$plugin_broker_artifacts_image' in the $filename"; exit 1
  fi

  jwt_proxy_image=$(cat /tmp/che.properties | grep  che.server.secure_exposer.jwtproxy.image | cut -d '=' -f2)
  if ! grep -q "value: $jwt_proxy_image" $filename; then
    echo "[ERROR] Unable to find jwt proxy image $jwt_proxy_image in the $filename"; exit 1
  fi
}

releaseOperatorCode() {
  echo "[INFO] Releasing operator code"
  echo "[INFO] Launching 'release-operator-code.sh' script"
  . ${RELEASE_DIR}/release-operator-code.sh $RELEASE $UBI8_MINIMAL_IMAGE

  local operatoryaml=$RELEASE_DIR/deploy/operator.yaml
  echo "[INFO] Validating changes for $operatoryaml"
  checkImageReferences $operatoryaml

  local operatorlocalyaml=$RELEASE_DIR/deploy/operator-local.yaml
  echo "[INFO] Validating changes for $operatorlocalyaml"
  checkImageReferences $operatorlocalyaml

  echo "[INFO] List of changed files:"
  git status -s

  echo "[INFO] Commiting changes"
  git commit -am "Update defaults tags to "$RELEASE --signoff

  echo "[INFO] Pushing image to quay.io"
  docker login quay.io -u $QUAY_USERNAME
  docker push quay.io/eclipse/che-operator:$RELEASE
}

updateNightlyOlmFiles() {
  echo "[INFO] Updateing nighlty OLM files"
  echo "[INFO] Launching 'olm/update-nightly-olm-files.sh' script"
  cd $RELEASE_DIR/olm
  . update-nightly-olm-files.sh
  cd $RELEASE_DIR

  echo "[INFO] Validating changes"
  lastKubernetesNightlyDir=$(ls -dt $RELEASE_DIR/eclipse-che-preview-kubernetes/deploy/olm-catalog/eclipse-che-preview-kubernetes/* | head -1)
  csvFile=$(ls ${lastKubernetesNightlyDir}/*.clusterserviceversion.yaml)
  checkImageReferences $csvFile

  lastNightlyOpenshiftDir=$(ls -dt $RELEASE_DIR/eclipse-che-preview-openshift/deploy/olm-catalog/eclipse-che-preview-openshift/* | head -1)
  csvFile=$(ls ${lastNightlyOpenshiftDir}/*.clusterserviceversion.yaml)
  checkImageReferences $csvFile

  echo "[INFO] List of changed files:"
  git status -s

  echo "[INFO] Commiting changes"
  git add -A
  git commit -m "Update nightly olm files" --signoff
}

releaseOlmFiles() {
  echo "[INFO] Releasing OLM files"
  echo "[INFO] Launching 'olm/release-olm-files.sh' script"
  cd $RELEASE_DIR/olm
  . release-olm-files.sh $RELEASE
  cd $RELEASE_DIR

  local openshift=$RELEASE_DIR/eclipse-che-preview-openshift/deploy/olm-catalog/eclipse-che-preview-openshift
  local kubernetes=$RELEASE_DIR/eclipse-che-preview-kubernetes/deploy/olm-catalog/eclipse-che-preview-kubernetes

  echo "[INFO] Validating changes"
  grep -q "currentCSV: eclipse-che-preview-openshift.v"$RELEASE $openshift/eclipse-che-preview-openshift.package.yaml
  grep -q "currentCSV: eclipse-che-preview-kubernetes.v"$RELEASE $kubernetes/eclipse-che-preview-kubernetes.package.yaml
  grep -q "version: "$RELEASE $openshift/$RELEASE/eclipse-che-preview-openshift.v$RELEASE.clusterserviceversion.yaml
  grep -q "version: "$RELEASE $kubernetes/$RELEASE/eclipse-che-preview-kubernetes.v$RELEASE.clusterserviceversion.yaml
  test -f $kubernetes/$RELEASE/eclipse-che-preview-kubernetes.crd.yaml
  test -f $openshift/$RELEASE/eclipse-che-preview-openshift.crd.yaml

  echo "[INFO] List of changed files:"
  git status -s
  echo git status -s

  echo "[INFO] Commiting changes"
  git add -A
  git commit -m "Release OLM files to "$RELEASE --signoff
}

pushOlmFilesToQuayIo() {
  echo "[INFO] Pushing OLM files to quay.io"
  cd $RELEASE_DIR/olm
  . push-olm-files-to-quay.sh
  cd $RELEASE_DIR
}

pushGitChanges() {
  echo "[INFO] Pushing git changes into $RELEASE branch"
  git push origin $RELEASE
  git tag -a $RELEASE -m $RELEASE
  git push --tags origin
}

createPRInCheOperatorRepository() {
  echo "[INFO] Creating pull request into $GIT_REMOTE_UPSTREAM repository"
  hub pull-request --base ${BRANCH} --head ${RELEASE} --browse -m "Release version ${RELEASE}"
}

run() {
  checkoutToReleaseBranch
  releaseOperatorCode
  updateNightlyOlmFiles
  releaseOlmFiles

  if [[ $PUSH_OLM_FILES == "true" ]]; then
    pushOlmFilesToQuayIo
  fi

  if [[ $PUSH_GIT_CHANGES == "true" ]]; then
    pushGitChanges
  fi
}

init "$@"

if [[ $PULL_REQUEST == "true" ]]; then
  createPRInCheOperatorRepository
else
  echo "[INFO] Release '$RELEASE' from branch '$BRANCH'"
  run "$@"
fi

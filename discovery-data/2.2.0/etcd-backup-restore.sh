#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

# shellcheck source=lib/restore-utilites.bash
source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

OC_ARGS="${OC_ARGS:-}"
ETCD_BACKUP="/tmp/etcd.backup"
ETCD_BACKUP_DIR="/tmp/etcd_backup"
ETCD_BACKUP_FILE="${ETCD_BACKUP_DIR}/etcd_snapshot.db"
PG_SERVICE_FILE="${ETCD_BACKUP_DIR}/pg_service_name.txt"
TMP_WORK_DIR="tmp/etcd_workspace"

printUsage() {
  echo "Usage: $(basename ${0}) [command] [tenantName] [-f backupFile]"
  exit 1
}

COMMAND=$1
shift
TENANT_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
  esac
done

brlog "INFO" "ETCD: "
brlog "INFO" "Tenant name: $TENANT_NAME"

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}

ETCD_SERVICE=`oc get svc ${OC_ARGS} -o jsonpath="{.items[*].metadata.name}" -l app=etcd | tr '[[:space:]]' '\n' | grep etcd-client`
ETCD_SECRET=`oc get secret ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l tenant=${TENANT_NAME},app=etcd-root`
ETCD_USER=`oc get secret ${OC_ARGS} ${ETCD_SECRET} --template '{{.data.username}}' | base64 --decode`
ETCD_PASSWORD=`oc get secret ${OC_ARGS} ${ETCD_SECRET} --template '{{.data.password}}' | base64 --decode`

# backup etcd
if [ ${COMMAND} = 'backup' ] ; then
  ETCD_POD=`oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l etcd_cluster=${TENANT_NAME}-discovery-etcd`
  BACKUP_FILE=${BACKUP_FILE:-"etcd_snapshot_`date "+%Y%m%d_%H%M%S"`.db"}
  brlog "INFO" "Start backup etcd..."
  run_cmd_in_pod ${ETCD_POD} "rm -rf ${ETCD_BACKUP_DIR} ${ETCD_BACKUP} && \
  mkdir -p ${ETCD_BACKUP_DIR} && \
  export ETCDCTL_USER='${ETCD_USER}:${ETCD_PASSWORD}' && \
  export ETCDCTL_CERT='/etc/etcdtls/operator/etcd-tls/etcd-client.crt' && \
  export ETCDCTL_CACERT='/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt' && \
  export ETCDCTL_KEY='/etc/etcdtls/operator/etcd-tls/etcd-client.key' && \
  export ETCDCTL_ENDPOINTS='https://${ETCD_SERVICE}:2379' && \
  etcdctl get --prefix '/' -w fields > ${ETCD_BACKUP_FILE} && \
  tar zcf ${ETCD_BACKUP} -C ${ETCD_BACKUP_DIR} ." ${OC_ARGS}
  brlog "INFO" "Transfering archive..."
  kube_cp_to_local ${ETCD_POD} "${BACKUP_FILE}" "${ETCD_BACKUP}" ${OC_ARGS}
  oc ${OC_ARGS} exec ${ETCD_POD} --  bash -c "rm -rf ${ETCD_BACKUP_DIR} ${ETCD_BACKUP}"
  brlog "INFO" "Verifying backup..."
  if ! tar tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

# restore etcd
if [ ${COMMAND} = 'restore' ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "WARN" "no such file: ${BACKUP_FILE}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi
  ETCD_POD=`oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l etcd_cluster=${TENANT_NAME}-discovery-etcd`
  brlog "INFO" "Start restore etcd: ${BACKUP_FILE}"
  brlog "INFO" "Transfering archive..."
  kube_cp_from_local ${ETCD_POD} "${BACKUP_FILE}" "${ETCD_BACKUP}" ${OC_ARGS}
  brlog "INFO" "Restoring data..."
  run_cmd_in_pod ${ETCD_POD} 'export ETCDCTL_API=3 && \
  export ETCDCTL_USER='${ETCD_USER}':'${ETCD_PASSWORD}' && \
  export ETCDCTL_CERT=/etc/etcdtls/operator/etcd-tls/etcd-client.crt && \
  export ETCDCTL_CACERT=/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt && \
  export ETCDCTL_KEY=/etc/etcdtls/operator/etcd-tls/etcd-client.key && \
  export ETCDCTL_ENDPOINTS=https://'${ETCD_SERVICE}':2379 && \
  export ETCD_BACKUP='${ETCD_BACKUP}' && \
  if tar -tf '${ETCD_BACKUP}'  &> /dev/null ; then mkdir -p '${ETCD_BACKUP_DIR}' &&  tar xf ${ETCD_BACKUP} -C '${ETCD_BACKUP_DIR}' && export ETCD_BACKUP='${ETCD_BACKUP_FILE}' ; fi && \
  etcdctl del --prefix "/" && \
  cat ${ETCD_BACKUP} | grep -e "\"Key\" : " -e "\"Value\" :" | sed -e "s/^\"Key\" : \"\(.*\)\"$/\1\t/g" -e "s/^\"Value\" : \"\(.*\)\"$/\1\t/g" | awk '"'"'{ORS="";print}'"'"' | sed -e '"'"'s/\\\\n/\\n/g'"'"' -e "s/\\\\\"/\"/g" | sed -e "s/\\\\\\\\/\\\\/g" | while read -r -d $'"'\t'"' line1 ; read -r -d $'"'\t'"' line2; do etcdctl put "$line1" "$line2" ; done && \
  rm -rf ${ETCD_BACKUP} '${ETCD_BACKUP_DIR} ${OC_ARGS}
  brlog "INFO" "Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  etcd_updates
  brlog "INFO" "Completed Updates"
  echo
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi
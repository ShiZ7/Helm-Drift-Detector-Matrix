#!/usr/bin/env bash
# Usage: detect-drift.sh <values_file> <chart_path> <namespace> <report_prefix>
# Example: detect-drift.sh ./desired.yaml ./charts/nginx sandbox-nginx sandbox-uscentral1
set -euo pipefail

VALUES_FILE="${1:-./desired.yaml}"
CHART_PATH="${2:-./charts/nginx}"
NAMESPACE="${3:-default}"
REPORT_PREFIX="${4:-default}"

SERVER_SIDE_DIFF="${SERVER_SIDE_DIFF:-true}"
DRIFT_STRICT="${DRIFT_STRICT:-true}"

mkdir -p reports
desired_yaml="reports/${REPORT_PREFIX}_desired.yaml"
csv="reports/${REPORT_PREFIX}_drift_report.csv"
log="reports/${REPORT_PREFIX}_drift.log"

echo "Rendering Helm template → ${desired_yaml}"
helm template drift-check "${CHART_PATH}" -n "${NAMESPACE}" -f "${VALUES_FILE}" > "${desired_yaml}"

echo "===== KUBECTL DIFF (server-side=${SERVER_SIDE_DIFF}) =====" > "${log}"
if [ "${SERVER_SIDE_DIFF}" = "true" ]; then
  kubectl diff --server-side=true -n "${NAMESPACE}" -f "${desired_yaml}" || true >> "${log}" 2>&1
else
  kubectl diff -n "${NAMESPACE}" -f "${desired_yaml}" || true >> "${log}" 2>&1
fi

# desired
desired_hpa_cpu=$(yq -r '
  [.items[]?
   | select(.kind=="HorizontalPodAutoscaler")
   | .spec.metrics[]? 
   | select(.resource.name=="cpu" and .type=="Resource")
   | .resource.target.averageUtilization] 
  | map(select(.!=null)) | first // ""' <(kubectl apply --dry-run=server -n "${NAMESPACE}" -f "${desired_yaml}" -o yaml 2>/dev/null || cat "${desired_yaml}"))

desired_replicas=$(yq -r '
  [.items[]? | select(.kind=="Deployment") | .spec.replicas] 
  | map(select(.!=null)) | first // ""' "${desired_yaml}")

desired_svc_ports=$(yq -r '
  [.items[]?
   | select(.kind=="Service")
   | .spec.ports[]?
   | "\(.port):\(.targetPort)"] 
  | unique | sort | join(",")' "${desired_yaml}")

# live
live_hpa_cpu=$(kubectl get hpa -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.spec.metrics[*].resource.target.averageUtilization}{"\n"}{end}' | head -n1 || true)
live_replicas=$(kubectl get deploy -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.replicas}' || true)
live_svc_ports=$(kubectl get svc -n "${NAMESPACE}" -o json | yq -r '[.items[]? | .spec.ports[]? | "\(.port):\(.targetPort)"] | unique | sort | join(",")')

desired_hpa_cpu="${desired_hpa_cpu:-}"
live_hpa_cpu="${live_hpa_cpu:-}"
desired_replicas="${desired_replicas:-}"
live_replicas="${live_replicas:-}"
desired_svc_ports="${desired_svc_ports:-}"
live_svc_ports="${live_svc_ports:-}"

echo "cluster,namespace,field,desired,live,status" > "${csv}"

drift="false"
compare() {
  local field="$1" desired="$2" live="$3"
  local status="MATCH"
  if [ "${desired}" != "${live}" ]; then
    status="DRIFT"
    drift="true"
  fi
  echo "${REPORT_PREFIX},${NAMESPACE},${field},${desired},${live},${status}" >> "${csv}"
}

compare "replicas" "${desired_replicas}" "${live_replicas}"
compare "hpa_cpu_target" "${desired_hpa_cpu}" "${live_hpa_cpu}"
compare "service_ports" "${desired_svc_ports}" "${live_svc_ports}"

echo "===== SUMMARY =====" >> "${log}"
if [ "${drift}" = "true" ]; then
  echo "DRIFT detected." | tee -a "${log}"
  if [ "${DRIFT_STRICT}" = "true" ]; then
    exit 2
  fi
else
  echo "No drift." | tee -a "${log}"
fi

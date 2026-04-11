#!/usr/bin/env bash
# =============================================================================
# Helper script to fetch credential values from an existing MinIO/AI Store
# deployment in the aib-data namespace, and print them so you can paste into
# secrets.yaml before applying.
#
# Usage:
#   ./get-secrets-values.sh
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#   - aib-data namespace exists with the object store already deployed
# =============================================================================

set -euo pipefail

NAMESPACE="aib-data"

echo "======================================================================"
echo "Looking for S3-compatible object store credentials in ${NAMESPACE}"
echo "======================================================================"
echo

# Try common secret names for MinIO / AI Store
SECRETS_TO_TRY=(
  "minio"
  "minio-credentials"
  "minio-secret"
  "ai-store"
  "ai-store-credentials"
  "s3-credentials"
)

FOUND_SECRET=""
for s in "${SECRETS_TO_TRY[@]}"; do
  if kubectl get secret "${s}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    FOUND_SECRET="${s}"
    echo "Found secret: ${FOUND_SECRET}"
    break
  fi
done

if [[ -z "${FOUND_SECRET}" ]]; then
  echo "ERROR: could not find a known object-store secret in ${NAMESPACE}"
  echo "Available secrets in ${NAMESPACE}:"
  kubectl get secrets -n "${NAMESPACE}"
  echo
  echo "Inspect one manually:"
  echo "  kubectl get secret <name> -n ${NAMESPACE} -o yaml"
  exit 1
fi

echo
echo "Secret keys:"
kubectl get secret "${FOUND_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(f"  - {k}") for k in d.keys()]'

echo
echo "======================================================================"
echo "Attempting to decode common key names..."
echo "======================================================================"

# Try common access-key field names
for key in rootUser root-user accessKey access-key ACCESS_KEY_ID AWS_ACCESS_KEY_ID user username; do
  VALUE=$(kubectl get secret "${FOUND_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "${VALUE}" ]]; then
    echo "Access key (${key}): ${VALUE}"
    ACCESS_KEY="${VALUE}"
    break
  fi
done

# Try common secret-key field names
for key in rootPassword root-password secretKey secret-key SECRET_ACCESS_KEY AWS_SECRET_ACCESS_KEY password; do
  VALUE=$(kubectl get secret "${FOUND_SECRET}" -n "${NAMESPACE}" \
    -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "${VALUE}" ]]; then
    echo "Secret key (${key}): ${VALUE}"
    SECRET_KEY="${VALUE}"
    break
  fi
done

echo
echo "======================================================================"
echo "Ready-to-apply YAML (copy the output and pipe to kubectl apply -f -):"
echo "======================================================================"
cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: aib-system
  labels:
    app.kubernetes.io/part-of: mlrun-ce
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${ACCESS_KEY:-REPLACE_ME}"
  AWS_SECRET_ACCESS_KEY: "${SECRET_KEY:-REPLACE_ME}"
---
apiVersion: v1
kind: Secret
metadata:
  name: mlpipeline-minio-artifact
  namespace: aib-system
  labels:
    app.kubernetes.io/part-of: mlrun-ce
    application-crd-id: kubeflow-pipelines
type: Opaque
stringData:
  accesskey: "${ACCESS_KEY:-REPLACE_ME}"
  secretkey: "${SECRET_KEY:-REPLACE_ME}"
EOF
echo
echo "======================================================================"
echo "To apply directly:"
echo "  ./get-secrets-values.sh | kubectl apply -f -"
echo "======================================================================"

#!/bin/sh

# Note that the main loop is driven by running "kubectl get --watch".
# It doesn't attempt to reconnect, so if it fails, the script will
# exit. This is not a problem if this is running in a Pod (because
# Kubernetes will restart the container automatically, and the backoff
# policy will actually help us to behave correctly during e.g. an API
# server upgrade that would take down the API server for a few minutes)
# but if you run the operator locally, you will have to restart it
# when it stops.

config () {
  # This is the Namespace where the ConfigMap and Secrets will be created.
  info "REQUESTS_NAMESPACE=${REQUESTS_NAMESPACE:=nsplease-requests}"

  # Space-separated list of regexes to use to validate ConfigMap names.
  # Make sure that they are enclosed in ^$ if you want a full name match.
  info "VALID_REGEXES=${VALID_REGEXES:=^ci-commit-[0-9a-f]+$ ^ci-branch-[a-z0-9-]+$ ^nsp-[a-z0-9-]+$}"

  # Space-separated list of ConfigMap names to ignore silently.
  # (Instead of emitting warnings when they are found.)
  info "IGNORE_SILENTLY=${IGNORE_SILENTLY:=kube-root-ca.crt}"

  # Annotation to use to indicate if we should allow a secret to be re-issued.
  info "TOKEN_POLICY_ANNOTATION=${TOKEN_POLICY_ANNOTATION:=nsplease.container.training/issue-token}"

  # Default value for the annotation. Valid values are "only-once" or "multiple-times".
  info "TOKEN_POLICY_DEFAULT=${TOKEN_POLICY_DEFAULT:=multiple-times}"
}

debug() {
  printf "🐞\t[DEBUG]\t%s\n" "$*"
}

info() {
  printf "ℹ️\t[INFO]\t%s\n" "$*"
}

warn() {
  printf "⚠️\t[WARN]\t%s\n" "$*"
}

out() {
  "$@" | while read line; do
    printf "💬\t[EXEC]\t%s\n" "$line"
  done
}

main() {
  info "Waiting for ConfigMap events in $REQUESTS_NAMESPACE..."
  kubectl --namespace $REQUESTS_NAMESPACE get configmaps \
    --watch --output-watch-events -o json \
    | jq --unbuffered --raw-output '[.type,.object.metadata.name] | @tsv' \
    | while read TYPE NAMESPACE; do

    debug "Got event: $TYPE $NAMESPACE"

    IGNORE=no
    for N in $IGNORE_SILENTLY; do
      if [ "$NAMESPACE" = "$N" ]; then
        IGNORE=yes
        break
      fi
    done
    if [ "$IGNORE" = "yes" ]; then
      debug "Ignoring $NAMESPACE."
      continue
    fi

    VALID=no
    for REGEX in $VALID_REGEXES; do
      if echo $NAMESPACE | grep -E -q "$REGEX"; then
        VALID=yes
        break
      fi
    done
    if [ "$VALID" = "no" ]; then
      warn "Namespace $NAMESPACE doesn't match any of our valid regexes. Ignoring."
      warn "(Valid regexes are: $VALID_REGEXES)"
      continue
    fi

    if [ "$TYPE" = "ADDED" ]; then
      info "Creating or updating namespace $NAMESPACE and associated objects."
      export REQUESTS_NAMESPACE NAMESPACE
      envsubst < namespace-template.yaml | out kubectl apply -f- \
      || {
        warn "Something bad happened when creating or updating the resources."
        continue
      }
      debug "Waiting for ServiceAccount token to be available."
      TOKEN_NAME=""
      TIMEOUT=$((30 + $(date +%s)))
      while [ "$(date +%s)" -lt "$TIMEOUT" ]; do
        TOKEN_NAME=$(kubectl --namespace $NAMESPACE get serviceaccount admin \
                     -o "jsonpath={.secrets[0].name}") \
        && break
        sleep 1
      done
      if [ "$TOKEN_NAME" = "" ]; then
        warn "Timeout while trying to retrieve token name for ServiceAccount."
        continue
      fi

      JSONPATH="{.metadata.annotations.$(echo $TOKEN_POLICY_ANNOTATION | sed "s/\./\\\./"g)}"
      ANNOTATION=$(kubectl --namespace $NAMESPACE get serviceaccount admin \
                   -o "jsonpath=$JSONPATH")
      case "$ANNOTATION" in
        only-once)
          info "$TOKEN_POLICY_ANNOTATION=$ANNOTATION; not reissuing token."
          continue
          ;;
        multiple-times)
          info "$TOKEN_POLICY_ANNOTATION=$ANNOTATION; reissuing token."
          ;;
        "")
          info "$TOKEN_POLICY_ANNOTATION isn't set; issuing token."
          out kubectl --namespace $NAMESPACE annotate serviceaccount admin \
              $TOKEN_POLICY_ANNOTATION=$TOKEN_POLICY_DEFAULT
          ;;
        *)
          warn "$TOKEN_POLICY_ANNOTATION=$ANNOTATION; invalid value."
          warn "The only valid values are 'only-once' and 'multiple-times'."
          warn "Token won't be reissued."
          continue
          ;;
        esac

      info "Copying ServiceAccount token from $NAMESPACE to $REQUESTS_NAMESPACE."
      TOKEN=$(kubectl --namespace $NAMESPACE get secrets $TOKEN_NAME \
              -o json | jq -r ".data.token | @base64d")
      kubectl create secret generic $NAMESPACE --from-literal=token=$TOKEN \
              --dry-run=client -o yaml \
              | out kubectl --namespace $REQUESTS_NAMESPACE apply -f-

      info "Setting ownerReferences for ConfigMap and Secret."
      NSUID=$(kubectl get ns $NAMESPACE -o "jsonpath={.metadata.uid}")
      PATCH="metadata:
               ownerReferences:
               - apiVersion: v1
                 kind: Namespace
                 name: $NAMESPACE
                 uid: $NSUID"
      out kubectl --namespace $REQUESTS_NAMESPACE patch configmap $NAMESPACE \
          --patch="$PATCH"
      out kubectl --namespace $REQUESTS_NAMESPACE patch secret $NAMESPACE \
          --patch="$PATCH"
    fi

  done
}

config
main

#!/bin/sh

NAMESPACE=nsp-hello-there

run() {
	echo "$1" | while read line; do echo "> $line"; done
	echo ""
	echo "$ $2"
	echo ""
	echo "<press ENTER to run that command>"
	read
	eval "$2"
	echo ""
}

run "
Create a ConfigMap named like the Namespace that you want to create.
For instance, if I want to create Namespace $NAMESPACE, I create a
ConfigMap named $NAMESPACE. It has to be created in a special
Namespace called 'nsplease-requests'.
" "kubectl --namespace nsplease-requests create configmap $NAMESPACE"

run "
The nsplease operator will create a Secret with the same name.
We need to wait until that Secret has been created.
This will typically be almost instantaneous. If it takes a while,
make sure that nsplease is running, or check if it got an error.
" "kubectl --namespace nsplease-requests get secret --field-selector=metadata.name=$NAMESPACE --watch | head -n 0"

run "
Now we can obtain the token stored in that Secret.
" 'TOKEN=$(kubectl --namespace nsplease-requests get secret '$NAMESPACE' -o "jsonpath={.data.token}" | base64 -d)'

run "
Before we continue, let's save the current auth info.
That way, we will be able to restore it at the end of the demo.
" 'AUTHINFO=$(kubectl config  get-contexts  $(kubectl config current-context) --no-headers | awk '"'"'{print $4}'"'"')'

run "
Now, let's clear the current user.
If we don't do that, our TLS cert might override the token that
we will pass on the command-line.
" "kubectl config set-context --current --user="

run "
Try to access the default Namespace with the token.
This should tell us that access is denied.
" 'kubectl --token $TOKEN --namespace default get configmaps'

run "
Try to access our new Namespace with the token.
That should work.
" 'kubectl --token $TOKEN --namespace '$NAMESPACE' get configmaps'

run "
When we're done working with the Namespace, all we have to do
is destroy it.
" 'kubectl --token $TOKEN delete namespace '$NAMESPACE

run "
Restore our old auth info.
" 'kubectl config set-context --current --user=$AUTHINFO'

run "
Finally, let's check what we have in nsplease-requests.
The ConfigMap and Secret are deleted (or will be shortly).
" 'kubectl get configmaps,secrets --namespace nsplease-requests'

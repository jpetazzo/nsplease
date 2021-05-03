# Namesystem, please!

`nsplease` is a tiny Kubernetes controller to create and configure
namespaces on-demand.

It's intended to be used in CI/CD pipelines, when a particular
component (job, pipeline, run...) needs full access to an individual
namespace (for instance, to deploy a staging environment for a
given branch, commit, pull request...) but shouldn't have any
other access outside of that namespace.

Using `nsplease` improves the safety of CI/CD pipelines, because
they don't need full access (`cluster-admin`) privileges to a
Kubernetes cluster anymore.


## Overview

`nsplease` uses two namespaces.

1. `nsplease-system`: that's where the operator itself is running.
2. `nsplease-requests`: that namespace only holds ConfigMaps and Secrets.
   The ConfigMaps correspond to "requests" (meaning "I want you to create
   a new Namespace") and the secrets correspond to "responses" (they
   hold the credentials to access created namespaces).

This is the general flow of operation.

- User wants to create a new Namespace named `hello`.
- User creates a ConfigMap named `hello` in Namespace `nsplease-requests`.
- User waits until a Secret named `hello` shows up in Namespace `nsplease-requests`.
- `nsplease` sees the ConfigMap named `hello` in Namespace `nsplease-requests`.
- `nsplease` validates the name of the ConfigMap.
- `nsplease` creates the Namespace `hello`.
- `nsplease` creates a ServiceAccount named `admin` in Namespace `hello`.
- `nsplease` grants the `admin` ClusterRole to ServiceAccount `admin` in Namespace `hello`.
- `nsplease` can optionally prepopulate Namespace `hello` with other resources.
- `nsplease` retrieves the token for ServiceACccount `admin` in Namespace `hello`.
- `nsplease` creates a Secret named `hello` in Namespace `nsplease-requests`,
  containing the token.
- User detects the Secret and obtains the token.
- User can now work in the `hello` namespace by using the token.
- When User doesn't need the Namespace anymore, they delete the `hello` Namespace.
- The ConfigMap and Secret (in `nsplease-requests`) get deleted automatically.


## Installing

The repository provides a Kubernetes YAML manifest that will run
`nsplease` and grant it the privileges that it needs to create further
Namespaces.

You can install it like this:

```bash
kubectl apply -f https://raw.githubusercontent.com/jpetazzo/nsplease/main/nsplease.yaml
```

You can remove it similarly with `kubectl delete -f`.

If you remove `nsplease`, the Namespaces that it created won't be removed.
If you want to remove all these namespaces, they are labelled, so you can
easily identify them with a selector. No other object is created.


## Requesting a Namespace

Let's say that you have a CI job that needs to deploy a staging copy
of your application in a dedicated namespace.

1. Compute the name of the namespace. Let's say that it'll be
   `ci-projectfoo-pr123`. For convenient, let's put that in an
   environment variable for the rest of the example.
   ```bash
   NAMESPACE=ci-projectfoo-pr123
   ```
2. Create a ConfigMap named `ci-projectfoo-pr123` in the namespace
   `nsplease-requests`.
   ```bash
   kubectl --namespace nsplease-requests \
           create configmap $NAMESPACE
   ```
3. Wait until the Secret named `ci-projectfoo-pr123` in the namespace
   `nsplease-request` exists.
   ```bash
   kubectl --namespace nsplease-requests \
           get secret --field-selector=metadata.name=$NAMESPACE --watch \
           | head -n 0
   ```
4. Obtain the token stored in that Secret.
   ```bash
   TOKEN=$(kubectl --namespace nsplease-requests \
           get secret $NAMESPACE -o "jsonpath={.data.token}" | base64 -d)
   ```
5. Use it to access the `ci-projectfoo-pr123` namespace.
   ```bash
   kubectl --namespace $NAMESPACE --token $TOKEN create configmap hello
   ```

The examples above use simple `kubectl` commands, but of course
you can use whatever else you'd like instead.

If your system doesn't have `base64 -d` you can also use `openssl base64 -d`
or use `jq` to decode the Secret.

The token that you obtained is the token of the ServiceAccount
`ci-projectfoo-pr123:admin`. That ServiceAccount has `admin` privileges
in the namespace `ci-projectfoo-pr123`.


## Cleaning up a Namespace

In each Namespace created by `nsplease`, there is a ServiceAccount named
`admin`. That ServiceAccount has the right to delete the Namespace.
Of course, deleting the Namespace will probably be the last operation
that the ServiceAccount will do, since deleting the Namespace will
eventually delete the ServiceAccount as well.

The ConfigMap and Secret corresponding to the Namespace (in the `nsplease-requests`
Namespace) get automatically deleted when the Namespace is deleted
(thanks to `ownerReferences`).


## Security model

`nsplease` itself requires `cluster-admin` privileges. However, we hope
that its code is simple enough to be easily audited and be sure that it
doesn't introduce any vulnerability.

Your CI pipeline only needs to be able to:
- create ConfigMaps in `nsplease-requests`
- read Secrets in `nsplease-requests`

After creating the ConfigMap, it obtains the token that it should use
to interact with the Namespace. That token only lets it interact with
the Namespace, and nothing else.


## Hardening

*If someone compromises my CI pipeline, what can they do?*

They won't get `cluster-admin` access to the cluster. However, they will
get access to all the ConfigMaps and Secrets in the `nsplease-requests`
Namespace. They will therefore be able to list the other Namespaces
created by `nsplease`, and obtain the tokens allowing to connect to them.

*That sounds bad. What can I do about it?*

You can change the `TOKEN_POLICY_DEFAULT` environment variable to `only-once`,
and after obtaining the token for a given Namespace, delete the corresponding
Secret. An attacker won't be able to obtain the tokens of existing namespaces.
(They will still be able to compromise future Namespaces, however.)

Note: it is not enough to delete the Secret, because if the ConfigMap object
is deleted and recreated, the Secret will be recreated as well. *Unless*
the `admin` ServiceAccount has a special annotation that tells `nsplease`
"only copy that ServiceAccount's token once". By default, that annotation
is `nsplease.container.training/issue-token` and the possible values are
`only-once` or `multiple-times`.

*Cool. Is there anything else I can do?*

After obtaining the token for ServiceAccount `admin`, you can use that
token to rotate the token itself. This is *kind of* risky business,
because you need to watch changes on Secrets, then delete the Secret.
If your watch request is interrupted before the new Secret is issued,
you will lose access to the Namespace. But if you do that, there will
only be a tiny window during which an attacker (who would have compromised
your CI pipeline) would be able to get the ServiceAccount token.
If you're dealing with a basic compromise (something that intentionally
or accidentally leaks Secrets, for instance) this reduces the risk;
but it won't prevent a very determined attacker from getting access to
the token and getting the new token as you rotate it.

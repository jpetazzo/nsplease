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

A "system" namespace (default value: `nsplease-system`) in which
it is running; this namespace holds `nsplease` code and configuration.

A "requests" namespace (default value: `nsplease-requests`) which
holds ConfigMap (representing namespaces to be created) and Secrets
(holding the credentials to access created namespaces).


## Installing

FIXME


## Basic usage

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


## Cleaning up

The `admin` ServiceAccount can delete its own Namespace. When the
Namespace is deleted, the ConfigMap and the Secret (in the `nsplease-requests`
Namespace) are automatically deleted as well.


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

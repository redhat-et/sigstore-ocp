## Sigstore on OpenShift, with AWS Security Token Service (STS)

[Running pods in OpenShift with AWS IAM Roles for service accounts (IRSA)](https://cloud.redhat.com/blog/running-pods-in-openshift-with-aws-iam-roles-for-service-accounts-aka-irsa)

AWS STS is used to create workload identity tokens for service accounts.
Sigstore is configured to use the service account OIDC Identity Token to pass to Fulcio to authenticate requests.

[Understanding ROSA with STS](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-getting-started-workflow.html)

### Configure Fulcio chart with AWS STS OIDC issuer

In the values file the `scaffold.fulcio` section should include the following:

```yaml
fulcio:
  config:
    contents:
      OIDCIssuers:
        # replace
        ? https://rh-oidc.s3.us-east-1.amazonaws.com/.....
        : IssuerURL: https://rh-oidc.s3.us-east-1.amazonaws.com/.......
          ClientID: sigstore
          Type: kubernetes
```

### Create a service account and signer deployment

For this an `IAM role` associated with an AWS Identity Provider with
permissions to list S3 buckets is required. From the AWS Console, choose
`Roles-> Create Role -> Web Identity`.
Choose an Identity provider from the dropdown list and
set the  Audience to `sigstore`. Next, add the Policy `AmazonS3ReadOnlyAccess`.
Note the ARN `arn:aws:iam::xxxx:role/xxxxxxxx`, to add to the cosign service account.

Inspect the cosign deployment manifests and make any necessary changes. These are in `./docs/sts`.

Create the `cosign-sts` serviceaccount and deployment

```bash
oc apply -f docs/sts/aws-sts-sa.yaml
oc apply -f docs/sts/cosign-dep.yaml
```

Finally, [cosign](https://github.com/sigstore/cosign) can be used in the pod to sign and verify artifacts.
As a PoC, here we will exec into the cosigin-sts pod in the cosign namespace.
First, find the pod name.

```bash
oc get pods -n cosign | grep cosign-sts
# note the pod name for below commands
```

### Sign and verify images

Login to the image repository of choice using cosign.

```
oc exec -n cosign <pod_name> -- /bin/sh -c 'cosign login <repo> -u <username> -p <password>'
```

Sign an image

```
oc exec -n cosign <pod_name> -- /bin/sh -c 'cosign sign -y --fulcio-url=$FULCIO_URL --rekor-url=$REKOR_URL --oidc-issuer=$OIDC_ISSUER_URL --identity-token=$AWS_WEB_IDENTITY_TOKEN_FILE <image>'
```

Verify an image

```shell
oc exec -n cosign <pod_name> -- /bin/sh -c 'cosign verify --rekor-url=$REKOR_URL --certificate-identity https://kubernetes.io/namespaces/cosign/serviceaccounts/cosign --certificate-oidc-issuer $OIDC_ISSUER_URL <image>'
```
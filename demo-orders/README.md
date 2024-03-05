# Demonstration: Orders Application With High Availability Zonal Load Balancing (HAZL)

## demo-orders

### Tom Dean | Buoyant

### Last edit: 3/4/2024

## Introduction

In this _hands-on demonstration_, we will deploy **Buoyant Enterprise for Linkerd** and demonstrate how to enable **High Availability Zonal Load Balancing (HAZL)**. We'll then take a look at how **HAZL** works to keep network traffic _in-zone_ where possible.

### How High Availability Zonal Load Balancing (HAZL) Works

For every endpoint, **HAZL** maintains a set of data that includes:

- The **zone** of the endpoint
- The **cost** associated with that zone
- The **recent latency** of responses to that endpoint
- The **recent failure rate** of responses to that endpoint

For every service, **HAZL** continually computes a load metric measuring the utilization of the service. When load to a service falls outside the acceptable range, whether through failures, latency, spikes in traffic, or any other reason, **HAZL** dynamically adds additional endpoints from other zones. When load returns to normal, **HAZL** automatically shrinks the load balancing pool to just in-zone endpoints.

In short: under normal conditions, **HAZL** keeps all traffic within the zone, but when the system is under stress, **HAZL** will temporarily allow cross-zone traffic until the system returns to normal. We'll see this in the **HAZL** demonstration.

**HAZL** will also apply these same principles to cross-cluster / multi-cluster calls: it will preserve zone locality by default, but allow cross-zone traffic if necessary to preserve reliability.

### High Availability Zonal Load Balancing (HAZL) vs Topology Hints

**HAZL** was designed in response to limitations seen by customers using Kubernetes's native **Topology Hints** (aka **Topology-aware Routing**) mechanism. These limitations are shared by native Kubernetes balancing (**kubeproxy**) as well as systems such as open source **Linkerd** and **Istio** that make use of **Topology Hints** to make routing decisions.

Within these systems, the endpoints for each service are allocated ahead of time to specific zones by the **Topology Hints** mechanism. This distribution is done at the Kubernetes API level, and attempts to allocate endpoints within the same zone (but note this behavior isn't guaranteed, and the Topology Hints mechanism may allocate endpoints from other zones). Once this allocation is done, it is static until endpoints are added or removed. It does not take into account traffic volumes, latency, or service health (except indirectly, if failing endpoints get removed via health checks).

Systems that make use of **Topology Hints**, including **Linkerd** and **Istio**, use this allocation to decide where to send traffic. This accomplishes the goal of keeping traffic within a zone but at the expense of reliability: **Topology Hints** itself provides no mechanism for sending traffic across zones if reliability demands it. The closest approximation in (some of) these systems are manual failover controls that allow the operator to failover traffic to a new zone.

Finally, **Topology Hints** has a set of well-known constraints, including:

- It does not work well for services where a large proportion of traffic originates from a subset of zones.
- It does not take into account tolerations, unready nodes, or nodes that are marked as control plane or master nodes.
- It does not work well with autoscaling. The autoscaler may not respond to increases in traffic, or respond by adding endpoints in other zones.
- No affordance is made for cross-cluster traffic.

These constraints have real-world implications. As one customer put it when trying **Istio** + **Topology Hints**: "What we are seeing in _some_ applications is that they won’t scale fast enough or at all (because maybe two or three pods out of 10 are getting the majority of the traffic and is not triggering the HPA) and _can cause a cyclic loop of pods crashing and the service going down_."

### Demonstration: Overview

In this _hands-on demonstration_, we will deploy **Buoyant Enterprise for Linkerd** on a `k3d` Kubernetes cluster and will demonstrate how to quickly enable **High Availability Zonal Load Balancing (HAZL)**. We'll then take a look at how **HAZL** works to keep network traffic _in-zone_ where possible, and explore **Security Policy generation**.

**In this demonstration, we're going to do the following:**

- Deploy a `k3d` Kubernetes cluster
- Deploy **Buoyant Enterprise for Linkerd** with **HAZL** disabled on the cluster
- Deploy the **Orders** application to the clusters, to generate multi-zonal traffic
  - Monitor traffic from the **Orders** application, with **HAZL** disabled
- Enable **High Availability Zonal Load Balancing (HAZL)**
  - Monitor traffic from the **Orders** application, with **HAZL** enabled
  - Observe the effect on cross-az traffic
- Increase the number of requests in the **Orders** application
  - Monitor the increased traffic from the **Orders** application
  - Observe the effect on cross-az traffic
- Decrease the number of requests in the **Orders** application
  - Monitor the decreased traffic from the **Orders** application
  - Observe the effect on cross-az traffic

Feel free to follow along with _your own instance_ if you'd like, using the resources and instructions provided in this repository.

### Demo: Prerequisites

**If you'd like to follow along, you're going to need the following:**

- [Docker](https://docs.docker.com/get-docker/)
- [k3d](https://k3d.io)
- [step](https://smallstep.com/docs/step-cli/installation/)
- The `watch` command must be installed and working
- [Buoyant Enterprise for Linkerd License](https://enterprise.buoyant.io/start_trial)
- [The Demo Assets, from GitHub](https://github.com/BuoyantIO/service-mesh-academy/tree/main/deploying-bel-with-hazl)

All prerequisites must be _installed_ and _working properly_ before proceeding. The instructions in the provided links will get you there. A trial license for Buoyant Enterprise for Linkerd can be obtained from the link above. Instructions on obtaining the demo assets from GitHub are below.

### The Orders Application

This repository includes the **Orders** application, which generates traffic across multiple availability zones in our Kubernetes cluster, allowing us to observe the effect that **High Availability Zonal Load Balancing (HAZL)** has on traffic.

## Demo 1: Deploy a Kubernetes Cluster With Buoyant Enterprise for Linkerd, With HAZL Disabled

First, we'll deploy a Kubernetes cluster using `k3d` and deploy Buoyant Enterprise for Linkerd (BEL).

### Task 1: Clone the `demo-orders` Assets

[GitHub: Demonstration: Orders Application With High Availability Zonal Load Balancing (HAZL)](https://github.com/southsidedean/linkerd-demos/tree/main/demo-orders)

To get the resources we will be using in this demonstration, you will need to clone a copy of the GitHub `southsidedean/linkerd-demos` repository. We'll be using the materials in the `demo-orders` subdirectory.

Clone the `southsidedean/linkerd-demos` GitHub repository to your preferred working directory:

```bash
git clone https://github.com/southsidedean/linkerd-demos.git
```

Change directory to the `demo-orders` subdirectory in the `linkerd-demos` repository:

```bash
cd linkerd-demos/demo-orders
```

Taking a look at the contents of `linkerd-demos/demo-orders`:

```bash
ls -la
```

With the assets in place, we can proceed to creating a cluster with `k3d`.

### Task 2: Deploy a Kubernetes Cluster Using `k3d`

Before we can deploy **Buoyant Enterprise for Linkerd**, we're going to need a Kubernetes cluster. Fortunately, we can use `k3d` for that. There's a cluster configuration file in the `cluster` directory, that will create a cluster with one control plane and three worker nodes, in three different availability zones.

Create the `demo-cluster-orders` cluster, using the configuration file in `cluster/demo-cluster-orders.yaml`:

```bash
k3d cluster create -c cluster/demo-cluster-orders.yaml --wait
```

Check for our `demo-cluster-orders` cluster:

```bash
k3d cluster list
```

Now that we have a Kubernetes cluster, we can proceed with deploying **Buoyant Enterprise for Linkerd**.

### Task 3: Create mTLS Root Certificates

[Generating the certificates with `step`](https://linkerd.io/2.14/tasks/generate-certificates/#generating-the-certificates-with-step)

In order to support **mTLS** connections between _meshed pods_, **Linkerd** needs a **trust anchor certificate** and an **issuer certificate** with its corresponding **key**.

Since we're using **Helm** to install **BEL**, it’s not possible to automatically generate these certificates and keys. We'll need to generate certificates and keys, and we'll use `step`for this.

#### Create Certificates Using `step`

You can generate certificates using a tool like `step`. All certificates must use the ECDSA P-256 algorithm which is the default for `step`. In this section, we’ll walk you through how to to use the `step` CLI to do this.

##### Step 1: Trust Anchor Certificate

To generate your certificates using `step`, use the `certs` directory:

```bash
cd certs
```

Generate the root certificate with its private key (using step):

```bash
step certificate create root.linkerd.cluster.local ca.crt ca.key \
--profile root-ca --no-password --insecure
```

_Note: We use `--no-password` `--insecure` to avoid encrypting those files with a passphrase._

This generates the `ca.crt` and `ca.key` files. The `ca.crt` file is what you need to pass to the `--identity-trust-anchors-file` option when installing **Linkerd** with the CLI, and the `identityTrustAnchorsPEM` value when installing the `linkerd-control-plane` chart with Helm.

For a longer-lived trust anchor certificate, pass the `--not-after` argument to the step command with the desired value (e.g. `--not-after=87600h`).

##### Step 2: Generate Intermediate Certificate and Key Pair

Next, generate the intermediate certificate and key pair that will be used to sign the **Linkerd** proxies’ CSR.

```bash
step certificate create identity.linkerd.cluster.local issuer.crt issuer.key \
--profile intermediate-ca --not-after 8760h --no-password --insecure \
--ca ca.crt --ca-key ca.key
```

This will generate the `issuer.crt` and `issuer.key` files.

Checking our certificates:

```bash
ls -la
```

We should see:

```bash
total 40
drwxr-xr-x  7 tdean  staff  224 Mar  4 18:30 .
drwxr-xr-x  8 tdean  staff  256 Mar  4 18:09 ..
-rw-r--r--  1 tdean  staff   55 Mar  4 17:45 README.md
-rw-------  1 tdean  staff  599 Mar  4 18:29 ca.crt
-rw-------  1 tdean  staff  227 Mar  4 18:29 ca.key
-rw-------  1 tdean  staff  652 Mar  4 18:30 issuer.crt
-rw-------  1 tdean  staff  227 Mar  4 18:30 issuer.key
```

Change back to the parent directory:

```bash
cd ..
```

Now that we have **mTLS** root certificates, we can deploy **BEL**.

### Task 4: Deploy Buoyant Enterprise for Linkerd With HAZL Disabled

[Installation: Buoyant Enterprise for Linkerd](https://docs.buoyant.io/buoyant-enterprise-linkerd/latest/installation/)

Next, we will walk through the process of installing **Buoyant Enterprise for Linkerd**. We're going to start with **HAZL** disabled, and will enable **HAZL** during testing.

#### Step 1: Obtain Buoyant Enterprise for Linkerd (BEL) Trial Credentials and Log In to Buoyant Cloud

If you require credentials for accessing **Buoyant Enterprise for Linkerd**, [sign up here](https://enterprise.buoyant.io/start_trial), and follow the instructions.

You should end up with a set of credentials in environment variables like this:

```bash
export API_CLIENT_ID=[CLIENT_ID]
export API_CLIENT_SECRET=[CLIENT_SECRET]
export BUOYANT_LICENSE=[LICENSE]
```

Add these to a file in the root of the `linkerd-demos/demo-orders` directory, named `settings.sh`, plus add a new line with the cluster name, `export CLUSTER_NAME=demo-cluster-orders`, like this:

```bash
export API_CLIENT_ID=[CLIENT_ID]
export API_CLIENT_SECRET=[CLIENT_SECRET]
export BUOYANT_LICENSE=[LICENSE]
export CLUSTER_NAME=demo-cluster-orders
```

Check the contents of the `settings.sh` file:

```bash
more settings.sh
```

Once you're satisfied with the contents, `source` the file, to load the variables:

```bash
source settings.sh
```

Now that you have a trial login, open an additional browser window or tab, and open **[Buoyant Cloud](https://buoyant.cloud)**. _Log in with the credentials you used for your trial account_.

![Buoyant Cloud: Add Cluster](images/buoyant-cloud-addcluster.png)

We'll be adding a cluster during **BEL** installation, so go ahead and click 'Cancel' for now.

![Buoyant Cloud: Overview](images/buoyant-cloud-overview.png)

You should find yourself in the Buoyant Cloud Overview page. This page provides summary metrics and status data across all your deployments. We'll be working with **Buoyant Cloud** a little more in the coming sections, so we'll set that aside for the moment.

Our credentials have been loaded into environment variables, we're logged into **Buoyant Cloud**, and we can proceed with installing **Buoyant Enterprise Linkerd (BEL)**.

#### Step 2: Download the BEL CLI

We'll be using the **Buoyant Enterprise Linkerd** CLI for many of our operations, so we'll need it _installed and properly configured_.

First, download the **BEL** CLI:

```bash
curl https://enterprise.buoyant.io/install | sh
```

Add the CLI executables to your `$PATH`:

```bash
export PATH=~/.linkerd2/bin:$PATH
```

Let's give the CLI a quick check:

```bash
linkerd version
```

With the CLI installed and working, we can get on with running our pre-installation checks.

#### Step 3: Run Pre-Installation Checks

Use the `linkerd check --pre` command to validate that your cluster is ready for installation:

```bash
linkerd check --pre
```

We should see all green checks.  With everything good and green, we can proceed with installing the **BEL operator**.

#### Step 4: Install BEL Operator Components

[Kubernetes Docs: Operator Pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)

Next, we'll install the **BEL operator**, which we will use to deploy the **ControlPlane** and **DataPlane** objects.

Add the `linkerd-buoyant` Helm chart, and refresh **Helm** before installing the operator:

```bash
helm repo add linkerd-buoyant https://helm.buoyant.cloud
helm repo update
```

Now, we can install the **BEL operator**, using Helm:

```bash
helm install linkerd-buoyant \
  --create-namespace \
  --namespace linkerd-buoyant \
  --set metadata.agentName=$CLUSTER_NAME \
  --set api.clientID=$API_CLIENT_ID \
  --set api.clientSecret=$API_CLIENT_SECRET \
linkerd-buoyant/linkerd-buoyant
```

_If you'd like to deploy the **BEL operator** with **debug** enabled:_

```bash
helm install linkerd-buoyant \
  --create-namespace \
  --namespace linkerd-buoyant \
  --set metadata.agentName=$CLUSTER_NAME \
  --set api.clientID=$API_CLIENT_ID \
  --set api.clientSecret=$API_CLIENT_SECRET \
  --set metrics.debugMetrics=true \
  --set agent.logLevel=debug \
  --set metrics.logLevel=debug \
linkerd-buoyant/linkerd-buoyant
```

After the install, wait for the `buoyant-cloud-metrics` agent to be ready, then run the post-install operator health checks:

```bash
kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant
linkerd buoyant check
```

We may see a few warnings (!!), but we're good to proceed _as long as the overall status check results are good_.

#### Step 5: Create the Identity Secret

Now we're going to take those **certificates** and **keys** we created using `step`, and use the `ca.crt`, `issuer.crt`, and `issuer.key` to create a Kubernetes Secret that will be used by **Helm** at runtime.

Generate the `linkerd-identity-secret.yaml` manifest:

```bash
cat <<EOF > linkerd-identity-secret.yaml
apiVersion: v1
data:
  ca.crt: $(base64 < certs/ca.crt | tr -d '\n')
  tls.crt: $(base64 < certs/issuer.crt| tr -d '\n')
  tls.key: $(base64 < certs/issuer.key | tr -d '\n')
kind: Secret
metadata:
  name: linkerd-identity-issuer
  namespace: linkerd
type: kubernetes.io/tls
EOF
```

Create the `linkerd-identity-issuer` secret from the `linkerd-identity-secret.yaml` manifest:

```bash
kubectl apply -f linkerd-identity-secret.yaml
```

Checking the secrets on our cluster:

```bash
kubectl get secrets -A
```

Now that we have our `linkerd-identity-issuer` secret, we can proceed with creating the **ControlPlane CRD** configuration manifest.

#### Step 6: Create a ControlPlane Manifest

[Kubernetes Docs: Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)

We deploy the **BEL ControlPlane** and **DataPlane** using **Custom Resources**. We'll create a manifest for each that contains the object's configuration. We'll start with the **ControlPlane** first.

This **CRD configuration** also enables **High Availability Zonal Load Balancing (HAZL)**, using the `- -ext-endpoint-zone-weights` `experimentalArgs`. We're going to omit the `- -ext-endpoint-zone-weights` in the `experimentalArgs` for now, by commenting it out with a `#` in the manifest.

Let's create the ControlPlane manifest:

```bash
cat <<EOF > linkerd-control-plane-config.yaml
apiVersion: linkerd.buoyant.io/v1alpha1
kind: ControlPlane
metadata:
  name: linkerd-control-plane
spec:
  components:
    linkerd:
      version: enterprise-2.15.1-0
      license: $BUOYANT_LICENSE
      controlPlaneConfig:
        proxy:
          image:
            version: enterprise-2.15.1-0-hazl
        identityTrustAnchorsPEM: |
$(sed 's/^/          /' < certs/ca.crt )
        identity:
          issuer:
            scheme: kubernetes.io/tls
        destinationController:
          additionalArgs:
           # - -ext-endpoint-zone-weights
EOF
```

Apply the ControlPlane CRD config to have the Linkerd BEL operator create the ControlPlane:

```bash
kubectl apply -f linkerd-control-plane-config.yaml
```

To make adjustments to your **BEL ControlPlane** deployment _simply edit and re-apply the `linkerd-control-plane-config.yaml` manifest_.

#### Step 7: Verify the ControlPlane Installation

After the installation is complete, watch the deployment of the Control Plane using `kubectl`:

```bash
watch -n 1 kubectl get pods -A -o wide --sort-by .metadata.namespace
```

**_Use `CTRL-C` to exit the watch command._**

Let's can verify the health and configuration of Linkerd by running the `linkerd check` command:

```bash
linkerd check
```

Again, we may see a few warnings (!!), but we're good to proceed _as long as the overall status is good_.

#### Step 8: Create the DataPlane Objects for `linkerd-buoyant`

Now, we can deploy the **DataPlane** for the `linkerd-buoyant` namespace. Let's create the **DataPlane** manifest:

```bash
cat <<EOF > linkerd-data-plane-config.yaml
---
apiVersion: linkerd.buoyant.io/v1alpha1
kind: DataPlane
metadata:
  name: linkerd-buoyant
  namespace: linkerd-buoyant
spec:
  workloadSelector:
    matchLabels: {}
EOF
```

Apply the **DataPlane CRD configuration** manifest to have the **BEL operator** create the **DataPlane**:

```bash
kubectl apply -f linkerd-data-plane-config.yaml
```

#### Step 9: Monitor Buoyant Cloud Metrics Rollout and Check Proxies

Now that both our **BEL ControlPlane** and **DataPlane** have been deployed, we'll check the status of our `buoyant-cloud-metrics` daemonset rollout:

```bash
kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant
```

Once the rollout is complete, we'll use `linkerd check --proxy` command to check the status of our **BEL** proxies:

```bash
linkerd check --proxy -n linkerd-buoyant
```

Again, we may see a few warnings (!!), _but we're good to proceed as long as the overall status is good_.

We've successfully installed **Buoyant Enterprise for Linkerd**, and can now use **BEL** to manage and secure our Kubernetes applications.

## Demo 2: Observe the Effects of High Availability Zonal Load Balancing (HAZL)

### Deploy the Orders Application

Now that **BEL** is fully deployed, we're going to need some traffic to observe.

Deploy the **Orders** application, from the `orders` directory:

```bash
kubectl apply -k orders
```

We can check the status of the **Orders** application by watching the rollout:

```bash
watch -n 1 kubectl get pods -n orders -o wide --sort-by .metadata.namespace
```

**_Use `CTRL-C` to exit the watch command._**

If you don't have the `watch` command on your system, just run:

```bash
kubectl get pods -n orders -o wide --sort-by .metadata.namespace
```

With the **Orders** application deployed, we now have some traffic to work with.

### Monitor Traffic Without HAZL

Let's take a look at traffic flow _without **HAZL** enabled_ in **Buoyant Cloud**. This will give us a more visual representation of our baseline traffic. Head over to **Buoyant Cloud**, and take a look at the contents of the `orders` namespace.

### Enable High Availability Zonal Load Balancing (HAZL)

Let's take a look at how quick and easy we can enable **High Availability Zonal Load Balancing (HAZL)**.

Remember, to make adjustments to your **BEL** deployment _simply edit and re-apply the previously-created `linkerd-control-plane-config.yaml` manifest_. We're going to **enable** the `- -ext-endpoint-zone-weights` in the `experimentalArgs` for now, by uncommenting it in the manifest:

Edit the `linkerd-control-plane-config.yaml` file:

```bash
vi linkerd-control-plane-config.yaml
```

Apply the ControlPlane CRD config to have the Linkerd BEL operator update the Linkerd control plane configuration, and enable HAZL:

```bash
kubectl apply -f linkerd-control-plane-config.yaml
```

Now, we can see the effect **HAZL** has on the traffic in our multi-az cluster.

### Monitor Traffic With HAZL Enabled

Let's take a look at what traffic looks like with **HAZL** enabled, using **Buoyant Cloud**. This will give us a more visual representation of the effect of **HAZL** on our traffic.

![Buoyant Cloud: Topology](images/Orders-with-hazl.png)

<<Explain what we're seeing here>>

### Increase Number of Requests

<<Instructions on how to turn up requests>>

```bash
kubectl get cm -n orders
```

```bash
kubectl edit -n orders cm brush-config
```

We're going to change the value of `requestsPerSecond: 50` to `requestsPerSecond: 300`.

```bash
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
data:
  config.yml: |
    requestsPerSecond: 300
    reportIntervalSeconds: 10
    uri: http://paint.orders.svc.cluster.local
kind: ConfigMap
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","data":{"config.yml":"requestsPerSecond: 50\nreportIntervalSeconds: 10\nuri: http://paint.orders.svc.cluster.local\n"},"kind":"ConfigMap","metadata":{"annotations":{},"labels":{"app":"brush"},"name":"brush-config","namespace":"orders"}}
  creationTimestamp: "2024-02-06T02:35:53Z"
  labels:
    app: brush
  name: brush-config
  namespace: orders
  resourceVersion: "21137"
  uid: 8007b421-163c-4650-9ca6-a99f38e3d2c8
```

Once we save our change with `:wq`, the number of requests will go from 50 to 300. Give things a minute to develop, then head over to **Buoyant Cloud**.

### Monitor Traffic Using Buoyant Cloud

Let's take a look at what the increased traffic looks like in **Buoyant Cloud**. This will give us a more visual representation of the effect of **HAZL** on our traffic.

![Buoyant Cloud: Topology](images/Orders-increase-requests-hazl.png)

<<Explain what we're seeing here>>

### Decrease Number of Requests

<<Instructions on how to turn down requests>>

```bash
kubectl edit -n orders cm brush-config
```

We're going to change the value of `requestsPerSecond: 300` to `requestsPerSecond: 50`.

```bash
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
data:
  config.yml: |
    requestsPerSecond: 50
    reportIntervalSeconds: 10
    uri: http://paint.orders.svc.cluster.local
kind: ConfigMap
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","data":{"config.yml":"requestsPerSecond: 50\nreportIntervalSeconds: 10\nuri: http://paint.orders.svc.cluster.local\n"},"kind":"ConfigMap","metadata":{"annotations":{},"labels":{"app":"brush"},"name":"brush-config","namespace":"orders"}}
  creationTimestamp: "2024-02-06T02:35:53Z"
  labels:
    app: brush
  name: brush-config
  namespace: orders
  resourceVersion: "21137"
  uid: 8007b421-163c-4650-9ca6-a99f38e3d2c8
```

Once we save our change with `:wq`, the number of requests will go from 300 to 50. Give things a minute to develop, then head over to **Buoyant Cloud**.

### Monitor Traffic Using Buoyant Cloud

Let's take a look at what traffic looks like in **Buoyant Cloud**. This will give us a more visual representation of the effect of **HAZL** on our traffic.

![Buoyant Cloud: Topology](images/Orders-decrease-requests-hazl.png)

<<Explain what we're seeing here>>

### Summary: Observe the Effects of HAZL

<<Summary for the Observe the Effects of HAZL section>>

## Demo 4: Using Buoyant Enterprise for Linkerd (BEL) to Generate Security Policies

<<Talk about this, give some context>>

### Creating Security Policies

<<Say something about creating Security Policies with BEL here>>

Use the `linkerd policy generate` command to have BEL generate policies from observed traffic:

```bash
linkerd policy generate > linkerd-policy.yaml
```

We've put these policies into a manifest in the `linkerd-policy.yaml`. Let's take a look:

```bash
more linkerd-policy.yaml
```

We can see the policies that `linkerd policy generate` created.

```bash
apiVersion: policy.linkerd.io/v1beta2
kind: Server
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: blue-8080
  namespace: orders
spec:
  podSelector:
    matchLabels:
      app: paint
      color: blue
  port: 8080
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: blue-8080
  namespace: orders
spec:
  identityRefs:
  - group: ""
    kind: ServiceAccount
    name: default
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: blue-8080
  namespace: orders
spec:
  requiredAuthenticationRefs:
  - group: policy.linkerd.io
    kind: MeshTLSAuthentication
    name: blue-8080
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: blue-8080
---
apiVersion: policy.linkerd.io/v1alpha1
kind: NetworkAuthentication
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: blue-8080-allow
  namespace: orders
spec:
  networks:
  - cidr: 0.0.0.0/0
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: blue-8080-allow
  namespace: orders
spec:
  requiredAuthenticationRefs:
  - group: policy.linkerd.io
    kind: NetworkAuthentication
    name: blue-8080-allow
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: blue-8080
---
apiVersion: policy.linkerd.io/v1beta2
kind: Server
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: green-8080
  namespace: orders
spec:
  podSelector:
    matchLabels:
      app: paint
      color: green
  port: 8080
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: green-8080
  namespace: orders
spec:
  identityRefs:
  - group: ""
    kind: ServiceAccount
    name: default
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: green-8080
  namespace: orders
spec:
  requiredAuthenticationRefs:
  - group: policy.linkerd.io
    kind: MeshTLSAuthentication
    name: green-8080
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: green-8080
---
apiVersion: policy.linkerd.io/v1alpha1
kind: NetworkAuthentication
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: green-8080-allow
  namespace: orders
spec:
  networks:
  - cidr: 0.0.0.0/0
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: green-8080-allow
  namespace: orders
spec:
  requiredAuthenticationRefs:
  - group: policy.linkerd.io
    kind: NetworkAuthentication
    name: green-8080-allow
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: green-8080
---
apiVersion: policy.linkerd.io/v1beta2
kind: Server
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: red-8080
  namespace: orders
spec:
  podSelector:
    matchLabels:
      app: paint
      color: red
  port: 8080
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: red-8080
  namespace: orders
spec:
  identityRefs:
  - group: ""
    kind: ServiceAccount
    name: default
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: red-8080
  namespace: orders
spec:
  requiredAuthenticationRefs:
  - group: policy.linkerd.io
    kind: MeshTLSAuthentication
    name: red-8080
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: red-8080
---
apiVersion: policy.linkerd.io/v1alpha1
kind: NetworkAuthentication
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: red-8080-allow
  namespace: orders
spec:
  networks:
  - cidr: 0.0.0.0/0
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  annotations:
    buoyant.io/created-by: linkerd policy generate
  name: red-8080-allow
  namespace: orders
spec:
  requiredAuthenticationRefs:
  - group: policy.linkerd.io
    kind: NetworkAuthentication
    name: red-8080-allow
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: red-8080
```

Now, let's apply the policies to our cluster:

```bash
kubectl apply -f linkerd-policy.yaml
```

We should see:

```bash
server.policy.linkerd.io/blue-8080 created
meshtlsauthentication.policy.linkerd.io/blue-8080 created
authorizationpolicy.policy.linkerd.io/blue-8080 created
networkauthentication.policy.linkerd.io/blue-8080-allow created
authorizationpolicy.policy.linkerd.io/blue-8080-allow created
server.policy.linkerd.io/green-8080 created
meshtlsauthentication.policy.linkerd.io/green-8080 created
authorizationpolicy.policy.linkerd.io/green-8080 created
networkauthentication.policy.linkerd.io/green-8080-allow created
authorizationpolicy.policy.linkerd.io/green-8080-allow created
server.policy.linkerd.io/red-8080 created
meshtlsauthentication.policy.linkerd.io/red-8080 created
authorizationpolicy.policy.linkerd.io/red-8080 created
networkauthentication.policy.linkerd.io/red-8080-allow created
authorizationpolicy.policy.linkerd.io/red-8080-allow created
```

Let's take a look at our new Security Policies in Buoyant Cloud.

### Examine Security Policies Using Buoyant Cloud

Let's take a look at the Security Policies we just created in **Buoyant Cloud**.

![Buoyant Cloud: Resources: Security Policies](images/Orders-security-policies-1.png)

<<Explain what we're seeing here>>

![Buoyant Cloud: Resources: Security Policies](images/Orders-security-policies-2.png)

<<Explain what we're seeing here>>

![Buoyant Cloud: Resources: Security Policies](images/Orders-security-policies-3.png)

<<Explain what we're seeing here>>

### Summary: Using Buoyant Enterprise for Linkerd (BEL) to Generate Security Policies

<<Security policies summary>>

## Summary: Deploying BEL with HAZL

<<Summarize the entire thing here. Bullet points?>>


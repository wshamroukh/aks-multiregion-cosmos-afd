# Multi-Region AKS + Cosmos DB (Multi-Region Write) + Azure Front Door — Private Networking Edition

An Azure CLI script that deploys an **active/active, two-region** application platform:

- **Azure Kubernetes Service (AKS)** in **Central India** and **Sweden Central**
- **Azure Cosmos DB** (NoSQL / SQL API) with **multi-region writes** in both regions
- **Azure Key Vault** in each region
- **Azure Container Registry (Premium)** with **geo-replication**
- **Azure Front Door Premium** in front of both clusters, connected over **Private Link**
- A small demo app, **cosmos-cats**, that shows which region served you and which Cosmos DB region took your write

Every internal service (Cosmos DB, Key Vault, ACR) is reachable **only through private endpoints**, and the app authenticates to Cosmos DB with **Microsoft Entra ID (workload identity)**. No account keys are used anywhere.

Inspired by the Ignite 2019 demo [`Azure/aks-bestpractices-ignite19/multi_region_cosmos`](https://github.com/Azure/aks-bestpractices-ignite19/tree/master/multi_region_cosmos), rebuilt to production-style practices: a private registry instead of Docker Hub, Key Vault and managed identity instead of keys in environment variables, and Front Door Premium instead of Traffic Manager.

---

## Architecture

```
                         Users (internet)
                               │  HTTPS
                ┌──────────────▼───────────────┐
                │   Azure Front Door Premium   │  latency-based, active/active,
                │  health probe: /healthz      │  HTTP→HTTPS redirect
                └───────┬───────────────┬──────┘
             Private Link│               │Private Link
   ┌─────────────────────▼───┐       ┌───▼─────────────────────────┐
   │ Central India           │       │ Sweden Central              │
   │ vnet-cosmocats-ci       │◄─────►│ vnet-cosmocats-sec          │
   │ 10.10.0.0/16            │ global│ 10.20.0.0/16                │
   │                         │ VNet  │                             │
   │ Private Link Service    │peering│ Private Link Service        │
   │   └ internal LB         │       │   └ internal LB             │
   │      └ AKS (2 pods)     │       │      └ AKS (2 pods)         │
   │                         │       │                             │
   │ Private endpoints:      │       │ Private endpoints:          │
   │  Cosmos DB · ACR · KV   │       │  Cosmos DB · ACR · KV       │
   │ Private DNS zones       │       │ Private DNS zones           │
   └───────────┬─────────────┘       └─────────────┬───────────────┘
               │                                   │
   ┌───────────▼───────────────────────────────────▼───────────────┐
   │ Cosmos DB  (write region: Central India ⇄ write region:       │
   │             Sweden Central — multi-region write, Session)     │
   │ ACR Premium (replicas: Central India, Sweden Central)         │
   └───────────────────────────────────────────────────────────────┘
```

### Design highlights

| Area | Choice |
|---|---|
| Ingress | Front Door Premium with Private Link origins to an **internal** load balancer behind a Private Link Service. The app has **no public IP**. The script approves Front Door's Private Link connections automatically. |
| Data | Cosmos DB multi-region write; each region's pods set `preferredLocations` to **their local region first**, so writes land locally and fail over to the other region |
| Identity | AKS workload identity per region → **Key Vault Secrets User** on its own vault + **Cosmos DB Built-in Data Contributor** (data-plane RBAC). Cosmos DB local auth (keys) is **disabled**. |
| Secrets | The Cosmos DB endpoint is stored in Key Vault through Azure Resource Manager (no data-plane access needed) and mounted into pods by the Key Vault CSI driver |
| Network | One VNet per region (no overlapping ranges), **global VNet peering**, a separate subnet each for AKS, private endpoints and Private Link Service, and private DNS zones per region (each region resolves to its own endpoints) |
| Registry | ACR Premium, geo-replicated. Public access is opened **only during the cloud image build** and disabled straight after. |
| AKS | Azure CNI Overlay in a custom VNet, user-assigned control-plane identity, OIDC issuer, workload identity, Key Vault CSI add-on with secret rotation |

---

## Prerequisites

- **Ubuntu or WSL (Ubuntu)**. The script installs anything missing: `curl`, `jq`, Azure CLI, `kubectl` and `kubelogin`.
- An Azure subscription where you hold **Owner**, or **Contributor + User Access Administrator**. The script creates role assignments.
- Resource providers are registered automatically: `Microsoft.ContainerService`, `ContainerRegistry`, `DocumentDB`, `KeyVault`, `Cdn`, `ManagedIdentity`, `Network`.
- Enough quota for 2 × 2-vCPU nodes per region (plus 1 VM if you use the test VM).

> **Policy-friendly:** built for subscriptions that enforce *public network access disabled* on PaaS services and *Cosmos DB local auth disabled*.

---

## Quick start

```bash
chmod +x aks-multiregion-cosmos-afd.sh
./aks-multiregion-cosmos-afd.sh            # full deployment, ~50–60 min
```

When it finishes, it prints a summary with the **Front Door URL** (`https://cosmocats-xxxxx.azurefd.net`). Allow **15–20 minutes** for Front Door and Private Link to start serving traffic.

The script is **re-runnable**: it skips anything that already exists, so after any failure just fix the cause and run it again. Resource names are kept between runs in `~/.cosmocats-multiregion.env`.

> ⚠️ Don't replace or edit the script file **while it is running**. Bash reads scripts incrementally, and swapping the file mid-run causes random errors.

---

## Commands

| Command | What it does |
|---|---|
| `./aks-multiregion-cosmos-afd.sh` | Deploy or continue the deployment |
| `./aks-multiregion-cosmos-afd.sh testvm` | After deployment: create a Windows test VM in **Sweden Central**, then call the Front Door URL from it |
| `./aks-multiregion-cosmos-afd.sh testvm-run` | Re-run the Front Door test from the test VM |
| `./aks-multiregion-cosmos-afd.sh destroy` | Delete every `rg-cosmocats-*` resource group, wait for completion, and purge soft-deleted Key Vaults |
| `./aks-multiregion-cosmos-afd.sh destroy --no-wait` | Start the deletion and return immediately |

---

## Configuration (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `PREFIX` | `cosmocats` | Name prefix for all resources |
| `REGION1` | `centralindia` | Primary region |
| `REGION2` | `swedencentral` | Secondary region (AKS, Key Vault, ACR replica, Cosmos DB write region) |
| `COSMOS_REGION2` | `$REGION2` | Override only the second Cosmos DB write region |
| `COSMOS_REGION2_CANDIDATES` | `$COSMOS_REGION2` | Space-separated fallback list if a region has no Cosmos DB capacity |
| `NODE_COUNT` | `2` | Nodes per cluster |
| `NODE_VM_SIZE1` / `NODE_VM_SIZE2` | `Standard_B2s_v2` | Node size per region. If the subscription rejects a size, the script picks an allowed 2-vCPU size from the error message. |
| `API_AUTHORIZED_IPS` | *(none)* | Restrict the AKS API servers, e.g. `203.0.113.10/32` |
| `IMAGE_TAG` | `v2` | App image tag |
| `FORCE_BUILD` | `false` | Rebuild the app image even if it exists |
| `TEST_VM_SIZE` | the region's AKS node size | Size of the test VM |
| `BASTION_SKU` | `Basic` | Azure Bastion SKU for the test VM |

Example:

```bash
NODE_COUNT=3 API_AUTHORIZED_IPS="$(curl -s ifconfig.me)/32" ./aks-multiregion-cosmos-afd.sh
```

---

## What gets created

| Resource group | Contents |
|---|---|
| `rg-cosmocats-global` | Cosmos DB account (`catsdb` database / `cats` container, partition key `/id`), ACR Premium + replica, Front Door Premium profile / endpoint / origin group / route |
| `rg-cosmocats-ci` | VNet + subnets, private DNS zones, private endpoints (Cosmos DB, ACR, Key Vault), Key Vault, AKS `aks-cosmocats-ci`, control-plane and workload identities |
| `rg-cosmocats-sec` | The same for Sweden Central (`aks-cosmocats-sec`); plus the test VM, NAT gateway and Bastion if you run `testvm` |
| `MC_*` (managed by AKS) | Node pools, internal load balancer, Private Link Service `pls-cosmocats` |

### Address plan

| Subnet | Central India | Sweden Central |
|---|---|---|
| `snet-aks` (nodes) | 10.10.0.0/22 | 10.20.0.0/22 |
| `snet-pe` (private endpoints) | 10.10.8.0/24 | 10.20.8.0/24 |
| `snet-pls` (Private Link Service) | 10.10.9.0/24 | 10.20.9.0/24 |
| `snet-vm` (test VM) | — | 10.20.10.0/24 |
| `AzureBastionSubnet` | — | 10.20.11.0/26 |

---

## The demo app: cosmos-cats

The Node.js 22 / Express app's source is **embedded in the script** and built in ACR, so there's no external repository to fetch.

**In the browser:** add cats (named, or random). The header shows the **AKS region and pod** that served the page: **orange = Central India, blue = Sweden Central**. The table shows, for each cat, the AKS region it was added through and the **Cosmos DB region that accepted the write**.

| Path | Purpose |
|---|---|
| `/` | Web UI (auto-refreshes every 5 s) |
| `GET /api/cats` | Latest 50 cats + the Cosmos DB region that served the read |
| `POST /api/cats` | Add a cat `{ "name": "Luna" }` |
| `/api/info` | Region, pod, preferred Cosmos DB regions |
| `/healthz` | Liveness, also used by Front Door's health probe |
| `/readyz` | Ready only when Cosmos DB is reachable with the pod's identity |

Security: runs as non-root with a read-only root filesystem and no privilege escalation. It uses Entra ID tokens only.

---

## Testing

### 1. Each region directly (without Front Door)

```bash
kubectl --context aks-cosmocats-ci  -n cosmocats port-forward svc/cosmos-cats 8080:80   # http://localhost:8080
kubectl --context aks-cosmocats-sec -n cosmocats port-forward svc/cosmos-cats 8081:80   # http://localhost:8081
```

### 2. Through Front Door from Sweden Central

```bash
./aks-multiregion-cosmos-afd.sh testvm
```

This creates `vm-afdtest-sec` (Windows Server 2025, **no public IP**, NAT gateway for outbound access, Azure Bastion for RDP), then calls the Front Door URL from inside the VM. Expected output:

```
call 1: served by AKS region = Sweden Central  pod = cosmos-cats-xxxx
```

To browse it yourself: Azure portal → `vm-afdtest-sec` → **Connect → Bastion**. Credentials are in `~/.cosmocats-testvm.txt`.

### 3. Failover

```bash
kubectl --context aks-cosmocats-sec -n cosmocats scale deploy/cosmos-cats --replicas 0
./aks-multiregion-cosmos-afd.sh testvm-run        # now served by Central India (allow 1–2 min)
kubectl --context aks-cosmocats-sec -n cosmocats scale deploy/cosmos-cats --replicas 2
```

### 4. Multi-region write

Add cats from both regions. Central India writes show `centralindia` and Sweden Central writes show `swedencentral` in the *Written to Cosmos region* column. Every cat appears in both regions within seconds.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `VM size … is not allowed in your subscription` | Size restrictions per region. The script falls back automatically, or set `NODE_VM_SIZE1` / `NODE_VM_SIZE2`. |
| `AvailabilityZoneNotSupported` | The script doesn't use availability zones |
| Cosmos DB `high demand in <region>` | No regional capacity. Use `COSMOS_REGION2_CANDIDATES="swedencentral northeurope"` or request access at https://aka.ms/cosmosdbquota |
| Pods stuck in `ContainerCreating`, `FailedMount … no such host` | A private DNS A record is missing. The script now creates or validates records for every private endpoint; re-run it. |
| Pods `0/1 Running`, log shows `Local Authorization is disabled` | You're on an old app version that used keys. Image `v2` uses Entra ID; re-run with the current script. |
| `lookup …azmk8s.io … no such host` (NXDOMAIN) | The cluster is **stopped** (for example by an overnight auto-shutdown). The script starts stopped clusters automatically, or run `az aks start -g <rg> -n <cluster>`. |
| `unrecognized arguments: --enable-private-link` | Front Door CLI syntax changed between versions. The script now uses the ARM REST API for origins and routes. |
| `make sure that the originGroup is created successfully…` | Origins were still provisioning. The script waits and retries; re-run. |
| `Policy blocks public access on <acr>` during the build | Your policy forbids even temporary public access on ACR. Build the image from a machine inside the VNet (e.g. the test VM) and push over the private endpoint. |

Useful checks:

```bash
kubectl --context aks-cosmocats-ci -n cosmocats get pods,svc
kubectl --context aks-cosmocats-ci -n cosmocats get events --sort-by=.lastTimestamp | tail
kubectl --context aks-cosmocats-ci -n cosmocats logs deploy/cosmos-cats --tail=30
az aks list --query "[].{name:name, power:powerState.code, state:provisioningState}" -o table
```

---

## Cost notes

The main cost drivers are **Front Door Premium** (~$330/month base, required for Private Link origins), **ACR Premium** with a replica, **Cosmos DB** with 400 RU/s shared across 2 write regions, **4 AKS nodes**, and, if used, the **test VM, Bastion and NAT gateway**.

To pause it:

```bash
az aks stop -g rg-cosmocats-ci  -n aks-cosmocats-ci
az aks stop -g rg-cosmocats-sec -n aks-cosmocats-sec
az vm deallocate -g rg-cosmocats-sec -n vm-afdtest-sec
```

Delete everything when you're done:

```bash
./aks-multiregion-cosmos-afd.sh destroy
```

---

## Production considerations

This deployment is a reference and demo. Before using it in production, consider:

- **Hub-and-spoke or Virtual WAN** per region with Azure Firewall, centralized private DNS and egress control, instead of direct VNet peering
- **Private AKS clusters** or API server VNet integration, with CI/CD running from inside the network
- **Availability zones** for AKS node pools and Cosmos DB, where the region and subscription support them
- A **WAF policy** on Front Door, a **custom domain** with a managed certificate, and **HTTPS to the origin** (TLS at the ingress)
- An **ingress controller** (e.g. App Routing / NGINX) with HPA, PodDisruptionBudgets and resource quotas
- **Azure Monitor / Container Insights**, Cosmos DB diagnostic logs, and Front Door logs and alerts
- An **image build pipeline** that runs inside the network (ACR Tasks agent pool or self-hosted runners), so ACR never needs public access
- **Infrastructure as code** (Bicep / Terraform) instead of an imperative script for long-lived environments

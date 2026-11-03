#!/usr/bin/env bash
# =============================================================================
#  AKS multi-region ACTIVE-ACTIVE app tier + Cosmos DB with a SINGLE WRITE REGION
#   * AKS, Key Vault, VNet, private endpoints in both regions (Central India + Sweden Central
#     by default; e.g. REGION1=westeurope REGION2=swedencentral for the customer scenario)
#   * ONE Cosmos DB account: WRITE region = REGION1 (primary), READ replica = REGION2
#       - reads are local in both regions
#       - writes from REGION2 cross to the primary region over the private endpoint
#       - service-managed failover promotes REGION2 if the primary region goes down
#     No multi-region writes -> no conflicts; any consistency level (incl. Strong)
#   * ACR Premium geo-replicated, all PaaS behind private endpoints, no keys (Entra ID)
#   * Front Door Premium -> Private Link -> internal LB in each region (latency routing)
#  Demo app: "cosmos-cats-sw" (Node.js 22 + Express + Cosmos DB SDK v4), source embedded;
#  shows the region that served you, the Cosmos DB write region and the write latency.
#
#  Usage:
#     ./aks-singlewrite-cosmos-afd.sh                  # deploy (re-runnable)
#     ./aks-singlewrite-cosmos-afd.sh status           # current write/read regions
#     ./aks-singlewrite-cosmos-afd.sh cosmos-failover  # move the write region to the other
#                                                      # region (run again to fail back)
#     ./aks-singlewrite-cosmos-afd.sh testvm           # (re)create the Sweden Central test VM (also done by every deploy)
#     ./aks-singlewrite-cosmos-afd.sh testvm-run       # re-run the Front Door test from it
#     ./aks-singlewrite-cosmos-afd.sh destroy [--wait]
#  Optional env vars:
#     REGION1=centralindia REGION2=swedencentral   primary (write) / secondary (read) region
#     COSMOS_CONSISTENCY=Session      Session | BoundedStaleness | Strong | ConsistentPrefix | Eventual
#     API_AUTHORIZED_IPS=x.x.x.x/32   restrict the AKS API servers to these IPs
#     FORCE_BUILD=true                rebuild the app image
#     SKIP_TEST_VM=true               don't create the Windows test VM + Bastion Developer
#     TEST_VM_REGION=swedencentral    region (one of the two) for the test VM
#  Runs on Ubuntu / WSL; missing prerequisites are installed automatically.
# =============================================================================
set -Eeuo pipefail
trap 'echo -e "\n[ERROR] line $LINENO: \"$BASH_COMMAND\" failed" >&2' ERR

# ----------------------------- Configuration --------------------------------
PREFIX="${PREFIX:-cosmossw}"
REGION1="${REGION1:-centralindia}"   # primary = Cosmos DB write region
REGION2="${REGION2:-swedencentral}"  # secondary = Cosmos DB read replica
cell_code() { case "$1" in centralindia) echo ci;; swedencentral) echo sec;; westeurope) echo weu;; northeurope) echo neu;;
  eastus) echo eus;; eastus2) echo eus2;; uaenorth) echo uaen;; *) echo "${1:0:4}";; esac; }
R1="$(cell_code "$REGION1")"; R2="$(cell_code "$REGION2")"
COSMOS_CONSISTENCY="${COSMOS_CONSISTENCY:-Session}"
VNET1_CIDR="10.10"; VNET2_CIDR="10.20"   # a /16 per region, no overlap

NODE_COUNT="${NODE_COUNT:-2}"
NODE_VM_SIZE1="${NODE_VM_SIZE1:-Standard_B2s_v2}"    # Central India (Intel B-series v2)
NODE_VM_SIZE2="${NODE_VM_SIZE2:-Standard_B2s_v2}"    # Sweden Central (auto-fallback if not allowed)
IMAGE_NAME="cosmos-cats-sw"
IMAGE_TAG="${IMAGE_TAG:-v1}"
COSMOS_DB_NAME="catsdb"; COSMOS_CONTAINER_NAME="cats"
K8S_NS="cosmossw"
K8S_SA="cosmossw-sa"
PLS_NAME="pls-cosmossw"

# Stable names across re-runs
STATE_FILE="${STATE_FILE:-$HOME/.${PREFIX}-multiregion.env}"
if [[ -f "$STATE_FILE" ]]; then source "$STATE_FILE"; fi
gen_suffix() {  # pure bash (no pipes -> safe with pipefail)
  local chars=abcdefghijklmnopqrstuvwxyz0123456789 out="" i
  out+=${chars:RANDOM%26:1}
  for i in 1 2 3 4; do out+=${chars:RANDOM%36:1}; done
  echo "$out"
}
SUFFIX="${SUFFIX:-$(gen_suffix)}"
IMAGE_BUILT="${IMAGE_BUILT:-}"
save_state() { printf 'SUFFIX=%s\nIMAGE_BUILT=%s\n' "$SUFFIX" "$IMAGE_BUILT" > "$STATE_FILE"; }

RG_GLOBAL="rg-${PREFIX}-global-${SUFFIX}"
RG1="rg-${PREFIX}-${R1}-${SUFFIX}";  RG2="rg-${PREFIX}-${R2}-${SUFFIX}"
ACR="acr${PREFIX}${SUFFIX}"
COSMOS="cosmos-${PREFIX}-${SUFFIX}"
AKS1="aks-${PREFIX}-${R1}";  AKS2="aks-${PREFIX}-${R2}"
KV1="kv-${PREFIX:0:8}-${R1}-${SUFFIX}"; KV2="kv-${PREFIX:0:8}-${R2}-${SUFFIX}"
ID1="id-${PREFIX}-${R1}";    ID2="id-${PREFIX}-${R2}"      # workload identities (app -> Key Vault)
CPID1="id-aks-${R1}";        CPID2="id-aks-${R2}"          # AKS control-plane identities
VNET1="vnet-${PREFIX}-${R1}"; VNET2="vnet-${PREFIX}-${R2}"
AFD_PROFILE="afd-${PREFIX}-${SUFFIX}"
AFD_ENDPOINT="${PREFIX}-${SUFFIX}"
AFD_OG="og-aks"
DNS_ZONES=(privatelink.documents.azure.com privatelink.vaultcore.azure.net privatelink.azurecr.io)

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
info() { echo "    $*"; }
die()  { echo -e "\n[FAILED] $*" >&2; exit 1; }

# ----------------------------- Prerequisites --------------------------------
install_prereqs() {
  log "Checking prerequisites"
  local pkgs=() c
  for c in curl jq; do command -v "$c" >/dev/null || pkgs+=("$c"); done
  if ((${#pkgs[@]})); then
    info "Installing: ${pkgs[*]}"
    sudo apt-get update -y && sudo apt-get install -y "${pkgs[@]}" ca-certificates lsb-release gnupg
  fi
  command -v az >/dev/null || { info "Installing Azure CLI"; curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash; }
  az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1 || true
  if ! command -v kubectl >/dev/null || ! command -v kubelogin >/dev/null; then
    info "Installing kubectl + kubelogin"; sudo az aks install-cli >/dev/null
  fi
  az account show >/dev/null 2>&1 || az login --use-device-code >/dev/null
  info "Subscription: $(az account show --query '[name,id]' -o tsv | paste -sd' ')"
}
register_providers() {
  log "Registering resource providers"
  local p
  for p in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.DocumentDB \
           Microsoft.KeyVault Microsoft.Cdn Microsoft.ManagedIdentity Microsoft.Network; do
    az provider register --namespace "$p" --wait >/dev/null
  done
}
# Role assignment that tolerates "already exists" but surfaces any real error
assign_role() { # principalId role scope
  local err
  err=$(az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
          --role "$2" --scope "$3" -o none 2>&1) && return 0
  grep -qi "already exists" <<<"$err" && return 0
  die "Role assignment '$2' failed: $err"
}

# ----------------------------- App source (cosmos-cats-sw) ------------------
# Reads from the local region (write region or read replica), writes to the account's
# current write region, records the write latency, shows the live write/read regions.
write_app_source() { # targetDir
cat > "$1/package.json" <<'APP_SRC_EOF'
{
  "name": "cosmos-cats-sw",
  "version": "2.0.0",
  "private": true,
  "description": "Single-write-region Cosmos DB demo: reads from the local region, writes to the primary region; Entra ID (workload identity) auth",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "engines": { "node": ">=20" },
  "dependencies": {
    "@azure/cosmos": "^4.2.0",
    "@azure/identity": "^4.5.0",
    "express": "^4.21.2"
  }
}
APP_SRC_EOF
cat > "$1/Dockerfile" <<'APP_SRC_EOF'
FROM node:22-alpine
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force
COPY server.js ./
USER node
EXPOSE 8080
CMD ["node", "server.js"]
APP_SRC_EOF
cat > "$1/.dockerignore" <<'APP_SRC_EOF'
node_modules
npm-debug.log
APP_SRC_EOF
cat > "$1/server.js" <<'APP_SRC_EOF'
'use strict';
// Cosmos Cats - tiny multi-region demo for AKS + Cosmos DB (multi-region write)
// Auth: Microsoft Entra ID only (AKS workload identity via DefaultAzureCredential) -
//       no account keys, works with Cosmos DB "local authorization disabled".
// Config (env): COSMOS_ENDPOINT_FILE (file mounted from Key Vault) or COSMOS_ENDPOINT,
//               PREFERRED_REGIONS ("Central India,Sweden Central"), REGION_NAME, POD_NAME,
//               COSMOS_DB, COSMOS_CONTAINER, PORT. Database + container are created by the
//               deployment script (control plane); data-plane RBAC can't create them.
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const express = require('express');
const { CosmosClient } = require('@azure/cosmos');
const { DefaultAzureCredential } = require('@azure/identity');

const PORT = parseInt(process.env.PORT || '8080', 10);
const REGION = process.env.REGION_NAME || 'local';
const POD = process.env.POD_NAME || os.hostname();
const DB = process.env.COSMOS_DB || 'catsdb';
const CONTAINER = process.env.COSMOS_CONTAINER || 'cats';
const PREFERRED = (process.env.PREFERRED_REGIONS || '').split(',').map(s => s.trim()).filter(Boolean);
const REGION_KEYS = PREFERRED.map(r => r.toLowerCase().replace(/\s+/g, ''));
const REGION_INDEX = process.env.REGION_INDEX || '1';
let clientRef;

const EMOJI = ['🐱', '😺', '😸', '😹', '😻', '😼', '😽', '🙀', '😿', '😾', '🐈', '🐈‍⬛'];
const NAMES = ['Luna', 'Milo', 'Simba', 'Nala', 'Oliver', 'Leo', 'Bella', 'Chloe', 'Tiger', 'Shadow',
               'Zaatar', 'Qahwa', 'Masala', 'Chai', 'Mango', 'Pepper', 'Biscuit', 'Kiwi'];
const pick = a => a[crypto.randomInt(a.length)];

function setting(fileVar, envVar) {
  const f = process.env[fileVar];
  if (f && fs.existsSync(f)) return fs.readFileSync(f, 'utf8').trim(); // re-read: Key Vault rotation
  return process.env[envVar];
}

let containerPromise;
function getContainer() {
  if (!containerPromise) {
    containerPromise = (async () => {
      const endpoint = setting('COSMOS_ENDPOINT_FILE', 'COSMOS_ENDPOINT');
      if (!endpoint) throw new Error('Cosmos DB endpoint not configured');
      const client = new CosmosClient({
        endpoint,
        aadCredentials: new DefaultAzureCredential(),
        userAgentSuffix: `cosmos-cats-sw/${REGION}`,
        // Single write region: reads go to the local region, writes always go to the account's
        // current write region (cross-region from the secondary).
        connectionPolicy: { preferredLocations: PREFERRED, enableEndpointDiscovery: true }
      });
      clientRef = client;
      const container = client.database(DB).container(CONTAINER);
      await container.read();   // verifies network path, Entra ID token and data-plane RBAC
      console.log(`Connected to Cosmos DB ${endpoint} with Entra ID (preferred regions: ${PREFERRED.join(', ') || 'account default'})`);
      return container;
    })().catch(err => { containerPromise = undefined; throw err; });
  }
  return containerPromise;
}

// Which Cosmos DB regional endpoint actually served the request
function servedBy(response) {
  const eps = response?.diagnostics?.clientSideRequestStatistics?.locationEndpointsContacted || [];
  const last = eps[eps.length - 1];
  if (!last) return 'unknown';
  try { const h = new URL(last).hostname.split('.')[0]; return REGION_KEYS.find(r => h.endsWith('-' + r)) || 'global'; }
  catch { return 'unknown'; }
}

// Current write / read regions of the account (changes after a failover)
async function accountRegions() {
  try {
    await getContainer();
    const { resource } = await clientRef.getDatabaseAccount();
    return { writeRegions: (resource.writableLocations || []).map(l => l.name), readRegions: (resource.readableLocations || []).map(l => l.name) };
  } catch (e) { return { error: e.message }; }
}

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '10kb' }));

app.get('/healthz', (_req, res) => res.send('ok'));
app.get('/readyz', async (_req, res) => {
  try { await getContainer(); res.send('ready'); } catch (e) { res.status(503).send(e.message); }
});
app.get('/api/info', async (_req, res) => res.json({ region: REGION, pod: POD, preferredRegions: PREFERRED, cosmos: await accountRegions() }));

app.get('/api/cats', async (_req, res) => {
  try {
    const c = await getContainer();
    const t0 = Date.now();
    const r = await c.items.query('SELECT TOP 50 c.id, c.name, c.emoji, c.createdInRegion, c.createdByPod, c.writtenTo, c.writeMs, c.createdAt FROM c ORDER BY c._ts DESC').fetchAll();
    res.json({ servedByRegion: REGION, readFrom: servedBy(r), readMs: Date.now() - t0, cats: r.resources });
  } catch (e) { console.error(e); res.status(500).json({ error: e.message }); }
});

app.post('/api/cats', async (req, res) => {
  try {
    const c = await getContainer();
    const name = String(req.body?.name || '').trim().slice(0, 40) || pick(NAMES);
    const cat = { id: crypto.randomUUID(), name, emoji: pick(EMOJI), createdInRegion: REGION, createdByPod: POD, createdAt: new Date().toISOString() };
    const t0 = Date.now();
    const r = await c.items.create(cat);
    const writeMs = Date.now() - t0;                    // includes the cross-region hop from the secondary
    const writtenTo = servedBy(r);
    await c.item(cat.id, cat.id).patch([{ op: 'add', path: '/writtenTo', value: writtenTo }, { op: 'add', path: '/writeMs', value: writeMs }]).catch(() => {});
    res.status(201).json({ ...cat, writtenTo, writeMs });
  } catch (e) { console.error(e); res.status(500).json({ error: e.message }); }
});

app.get('/', (_req, res) => {
  res.type('html').send(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Cosmos Cats</title>
<style>
 body{font-family:Segoe UI,system-ui,sans-serif;margin:0;background:#f5f7fb;color:#1b1f24}
 header{padding:20px 32px;color:#fff;background:${REGION_INDEX === '1' ? '#e8590c' : '#1c7ed6'}}
 header h1{margin:0 0 6px;font-size:26px} header p{margin:0;opacity:.9}
 main{max-width:980px;margin:24px auto;padding:0 16px}
 form{display:flex;gap:8px;margin-bottom:16px} input{flex:1;padding:10px;border:1px solid #ccd;border-radius:6px;font-size:15px}
 button{padding:10px 18px;border:0;border-radius:6px;background:#2b2f36;color:#fff;font-size:15px;cursor:pointer}
 .meta{color:#555;font-size:13px;margin-bottom:12px}
 table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px #0001}
 th,td{padding:10px 12px;text-align:left;border-bottom:1px solid #eef} th{background:#eef1f6;font-size:13px}
 td.e{font-size:24px;width:40px} .tag{padding:2px 8px;border-radius:10px;font-size:12px;background:#eef1f6}
</style></head><body>
<header><h1>🐾 Cosmos Cats · single write region</h1><p>Served from <b>${REGION}</b> · pod <code>${POD}</code> · Cosmos DB write region: <b id="wr">…</b> · read replicas: <b id="rr">…</b></p></header>
<main>
 <form id="f"><input id="n" maxlength="40" placeholder="Cat name (leave empty for a random one)"><button>Add cat</button></form>
 <div class="meta" id="meta">Loading…</div>
 <table><thead><tr><th></th><th>Name</th><th>Added via AKS region</th><th>Written to Cosmos region</th><th>Write latency</th><th>Pod</th><th>When</th></tr></thead><tbody id="t"></tbody></table>
</main>
<script>
const t=document.getElementById('t'),meta=document.getElementById('meta');
function cell(tr,v,cls){const td=document.createElement('td');if(cls)td.className=cls;td.textContent=v??'';tr.appendChild(td);return td;}
async function load(){
  const r=await fetch('/api/cats');const d=await r.json();
  if(!r.ok){meta.textContent='Error: '+d.error;return;}
  meta.textContent='Read from Cosmos DB region: '+d.readFrom+' ('+d.readMs+' ms) · '+d.cats.length+' cats (latest 50)';
  t.replaceChildren();
  for(const c of d.cats){const tr=document.createElement('tr');cell(tr,c.emoji,'e');cell(tr,c.name);
    cell(tr,c.createdInRegion).className='';cell(tr,c.writtenTo||'');cell(tr,c.writeMs!=null?c.writeMs+' ms':'');cell(tr,c.createdByPod);
    cell(tr,new Date(c.createdAt).toLocaleString());t.appendChild(tr);}
}
document.getElementById('f').onsubmit=async e=>{e.preventDefault();const n=document.getElementById('n');
  const r=await fetch('/api/cats',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n.value})});
  if(!r.ok){meta.textContent='Error: '+(await r.json()).error;return;} n.value='';load();};
async function info(){try{const d=await (await fetch('/api/info')).json();
  document.getElementById('wr').textContent=(d.cosmos.writeRegions||['?']).join(', ');
  document.getElementById('rr').textContent=(d.cosmos.readRegions||['?']).join(', ');}catch(e){}}
load();info();setInterval(load,5000);setInterval(info,15000);
</script></body></html>`);
});

const server = app.listen(PORT, () => {
  console.log(`cosmos-cats-sw listening on :${PORT} (region ${REGION}, pod ${POD})`);
  getContainer().catch(e => console.error('Cosmos DB not ready yet:', e.message));
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
APP_SRC_EOF
}

# ----------------------------- Test VM (Sweden Central) ---------------------
# Always created at the end of a deployment (SKIP_TEST_VM=true to skip), in the cell /
# region that matches TEST_VM_REGION (default swedencentral): a Windows Server 2025 VM
# inside that region's VNet to browse the Front Door URL from there -> Front Door
# routes it to the nearest healthy origin = that region's AKS.
#  * no public IP on the VM; RDP from the Azure portal through Azure Bastion DEVELOPER
#    (free, shared pool: no AzureBastionSubnet, no public IP, one session at a time,
#     same-VNet VMs only). BASTION_SKU=Basic|Standard for a dedicated host instead.
#  * outbound internet through a NAT gateway (new VNets have no default outbound access)
TEST_VM_REGION="${TEST_VM_REGION:-swedencentral}"
VM_ADMIN="azureadmin"
VM_CRED_FILE="$HOME/.${PREFIX}-testvm.txt"
tvm_resolve() { # sets TVM_RG / TVM_VNET / TVM_CIDR / TVM_R / TVM_AKS / VM_NAME, or returns 1
  if   [[ "$TEST_VM_REGION" == "$REGION2" ]]; then TVM_RG=$RG2; TVM_VNET=$VNET2; TVM_CIDR=$VNET2_CIDR; TVM_R=$R2; TVM_AKS=$AKS2
  elif [[ "$TEST_VM_REGION" == "$REGION1" ]]; then TVM_RG=$RG1; TVM_VNET=$VNET1; TVM_CIDR=$VNET1_CIDR; TVM_R=$R1; TVM_AKS=$AKS1
  else return 1; fi
  VM_NAME="vm-afdtest-${TVM_R}"               # <= 15 chars (Windows computer name)
  TVM_REGION_NAME=$(az account list-locations --query "[?name=='$TEST_VM_REGION'].displayName" -o tsv)
}
test_from_vm() {
  local host ps
  tvm_resolve || die "TEST_VM_REGION=$TEST_VM_REGION is not one of this deployment's regions ($REGION1, $REGION2)"
  host=$(az afd endpoint show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --endpoint-name "$AFD_ENDPOINT" --query hostName -o tsv)
  log "Calling https://$host/api/info 6 times from $VM_NAME ($TEST_VM_REGION)"
  ps=$(cat <<'PS'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
1..6 | ForEach-Object {
  try {
    $r = Invoke-RestMethod -Uri 'https://__AFD__/api/info' -TimeoutSec 20 -Headers @{ 'Cache-Control'='no-cache' }
    "call $($_): served by AKS region = $($r.region)  pod = $($r.pod)"
  } catch { "call $($_): ERROR $($_.Exception.Message)" }
  Start-Sleep -Seconds 2
}
PS
)
  ps=${ps//__AFD__/$host}
  az vm run-command invoke -g "$TVM_RG" -n "$VM_NAME" --command-id RunPowerShellScript --scripts "$ps" \
    --query "value[0].message" -o tsv | sed 's/^/    /'
  info "(errors right after a fresh deployment usually mean Front Door is still propagating -"
  info " try again in 10-15 min with: $0 testvm-run)"
}
create_bastion() {
  local bas="bas-${PREFIX}-${TVM_R}" sku="${BASTION_SKU:-Developer}" basip vnet_id body
  if az network bastion show -g "$TVM_RG" -n "$bas" >/dev/null 2>&1; then info "Bastion $bas already exists"; return; fi
  if [[ "$sku" == "Developer" ]]; then
    log "[$TEST_VM_REGION] Azure Bastion Developer $bas (free, no subnet / public IP)"
    if ! az network bastion create -g "$TVM_RG" -n "$bas" -l "$TEST_VM_REGION" --vnet-name "$TVM_VNET" \
         --sku Developer -o none 2>/tmp/${PREFIX}-bastion.err; then
      # Older CLI versions: create it through Azure Resource Manager instead
      vnet_id=$(az network vnet show -g "$TVM_RG" -n "$TVM_VNET" --query id -o tsv)
      body=$(jq -n --arg loc "$TEST_VM_REGION" --arg vnet "$vnet_id" \
        '{location:$loc, sku:{name:"Developer"}, properties:{virtualNetwork:{id:$vnet}, ipConfigurations:[]}}')
      az rest --method put -o none \
        --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${TVM_RG}/providers/Microsoft.Network/bastionHosts/${bas}?api-version=2023-09-01" \
        --body "$body" || { cat /tmp/${PREFIX}-bastion.err >&2; info "WARNING: Bastion not created - connect another way (or BASTION_SKU=Basic)"; return; }
    fi
  else
    log "[$TEST_VM_REGION] Azure Bastion $sku $bas (dedicated host, ~10 min)"
    basip="pip-bas-${PREFIX}-${TVM_R}"
    az network vnet subnet show -g "$TVM_RG" --vnet-name "$TVM_VNET" -n AzureBastionSubnet >/dev/null 2>&1 || \
      az network vnet subnet create -g "$TVM_RG" --vnet-name "$TVM_VNET" -n AzureBastionSubnet --address-prefixes "${TVM_CIDR}.11.0/26" -o none
    az network public-ip show -g "$TVM_RG" -n "$basip" >/dev/null 2>&1 || \
      az network public-ip create -g "$TVM_RG" -n "$basip" -l "$TEST_VM_REGION" --sku Standard --allocation-method Static -o none
    az network bastion create -g "$TVM_RG" -n "$bas" -l "$TEST_VM_REGION" --vnet-name "$TVM_VNET" \
      --public-ip-address "$basip" --sku "$sku" -o none
  fi
  info "Bastion $bas ready"
}
create_test_vm() {
  tvm_resolve || { info "Test VM skipped: TEST_VM_REGION=$TEST_VM_REGION is not one of $REGION1 / $REGION2"; return 0; }
  local c="$TVM_CIDR" nsg="nsg-vm-afdtest-${TVM_R}" ng="ng-${PREFIX}-${TVM_R}" ngip="pip-ng-${PREFIX}-${TVM_R}" size pw out cand
  az afd endpoint show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --endpoint-name "$AFD_ENDPOINT" >/dev/null 2>&1 || \
    die "Front Door $AFD_PROFILE not found - run the full deployment first"
  az network vnet show -g "$TVM_RG" -n "$TVM_VNET" >/dev/null 2>&1 || die "$TVM_VNET not found - run the full deployment first"

  log "[$TEST_VM_REGION] Test VM network: subnet snet-vm (${c}.10.0/24) + NAT gateway + NSG"
  az network nsg show -g "$TVM_RG" -n "$nsg" >/dev/null 2>&1 || \
    az network nsg create -g "$TVM_RG" -n "$nsg" -l "$TEST_VM_REGION" -o none   # default rules: no inbound from internet
  # Bastion Developer reaches the VM from the Azure platform IP 168.63.129.16
  az network nsg rule show -g "$TVM_RG" --nsg-name "$nsg" -n allow-bastion-dev-rdp >/dev/null 2>&1 || \
    az network nsg rule create -g "$TVM_RG" --nsg-name "$nsg" -n allow-bastion-dev-rdp --priority 200 \
      --direction Inbound --access Allow --protocol Tcp --source-address-prefixes 168.63.129.16 \
      --destination-port-ranges 3389 -o none
  az network public-ip show -g "$TVM_RG" -n "$ngip" >/dev/null 2>&1 || \
    az network public-ip create -g "$TVM_RG" -n "$ngip" -l "$TEST_VM_REGION" --sku Standard --allocation-method Static -o none
  az network nat gateway show -g "$TVM_RG" -n "$ng" >/dev/null 2>&1 || \
    az network nat gateway create -g "$TVM_RG" -n "$ng" -l "$TEST_VM_REGION" --public-ip-addresses "$ngip" --idle-timeout 10 -o none
  az network vnet subnet show -g "$TVM_RG" --vnet-name "$TVM_VNET" -n snet-vm >/dev/null 2>&1 || \
    az network vnet subnet create -g "$TVM_RG" --vnet-name "$TVM_VNET" -n snet-vm --address-prefixes "${c}.10.0/24" \
      --network-security-group "$nsg" --nat-gateway "$ng" -o none

  if az vm show -g "$TVM_RG" -n "$VM_NAME" >/dev/null 2>&1; then
    info "$VM_NAME already exists"
    [[ "$(az vm get-instance-view -g "$TVM_RG" -n "$VM_NAME" --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv)" == "PowerState/running" ]] || \
      { info "starting $VM_NAME"; az vm start -g "$TVM_RG" -n "$VM_NAME" -o none; }
  else
    # Same size the subscription already allows for AKS nodes in this region (override: TEST_VM_SIZE)
    size="${TEST_VM_SIZE:-$(az aks show -g "$TVM_RG" -n "$TVM_AKS" --query 'agentPoolProfiles[0].vmSize' -o tsv 2>/dev/null)}"
    size="${size:-Standard_B2s_v2}"
    pw="Cc9#$(openssl rand -hex 10 2>/dev/null || echo "$RANDOM$RANDOM$RANDOM$RANDOM")"
    log "[$TEST_VM_REGION] Creating Windows Server 2025 VM $VM_NAME (no public IP)"
    for cand in "$size" Standard_B2s_v2 Standard_B2as_v2 Standard_D2s_v5 Standard_D2as_v5; do
      info "trying size $cand"
      if out=$(az vm create -g "$TVM_RG" -n "$VM_NAME" -l "$TEST_VM_REGION" \
          --image MicrosoftWindowsServer:WindowsServer:2025-datacenter-azure-edition:latest \
          --size "$cand" --admin-username "$VM_ADMIN" --admin-password "$pw" \
          --vnet-name "$TVM_VNET" --subnet snet-vm --public-ip-address "" --nsg "" \
          --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
          --os-disk-delete-option Delete --nic-delete-option Delete -o none 2>&1); then
        size=$cand; break
      fi
      grep -qiE 'not allowed|SkuNotAvailable|not available|NotAvailableForSubscription|quota' <<<"$out" || die "VM create failed: $out"
      size=""
    done
    [[ -n "$size" ]] || die "No allowed VM size for $VM_NAME in $TEST_VM_REGION: $out"
    printf 'VM: %s (%s, %s)\nUser: %s\nPassword: %s\n' "$VM_NAME" "$TVM_RG" "$size" "$VM_ADMIN" "$pw" > "$VM_CRED_FILE"
    chmod 600 "$VM_CRED_FILE"
    info "$VM_NAME created ($size); credentials saved to $VM_CRED_FILE"
  fi

  create_bastion
  test_from_vm
  cat <<VMSUM

=====================================================================
 Test VM ready
---------------------------------------------------------------------
 VM          : $VM_NAME in $TVM_REGION_NAME (${TVM_RG}), no public IP
 Connect     : Azure portal -> $VM_NAME -> Connect -> Bastion (Developer: 1 session at a time)
 Credentials : cat $VM_CRED_FILE
 Browse      : https://$(az afd endpoint show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --endpoint-name "$AFD_ENDPOINT" --query hostName -o tsv)
               (should be served by the $TVM_REGION_NAME AKS cluster)
 Re-test     : $0 testvm-run
 Cost saving : az vm deallocate -g $TVM_RG -n $VM_NAME
=====================================================================
VMSUM
}

# ----------------------------- Destroy --------------------------------------
install_prereqs
# Deployments created before resource group names carried the suffix keep their old
# names (only if that legacy group holds THIS deployment's registry)
LEGACY_RG="rg-${PREFIX}-global"
if [[ "$(az group exists -n "$RG_GLOBAL")" != "true" ]] && az acr show -n "$ACR" -g "$LEGACY_RG" >/dev/null 2>&1; then
  RG_GLOBAL="$LEGACY_RG"; RG1="rg-${PREFIX}-${R1}"; RG2="rg-${PREFIX}-${R2}"
  info "Existing deployment found - keeping its resource group names: $RG_GLOBAL, $RG1, $RG2"
fi
if [[ "${1:-}" == "destroy" ]]; then
  # Every rg-<prefix>-* group, so groups from earlier layouts (e.g. East US) go too
  mapfile -t DEL < <(az group list --query "[?starts_with(name,'rg-${PREFIX}-')].name" -o tsv)
  log "Deleting resource groups: ${DEL[*]:-none}"
  for rg in "${DEL[@]}"; do
    [[ "$(az group show -n "$rg" --query properties.provisioningState -o tsv)" == "Deleting" ]] || \
      az group delete -n "$rg" --yes --no-wait
  done
  if [[ "${2:-}" == "--wait" ]]; then
    for rg in "${DEL[@]}"; do
      info "Waiting for $rg to be deleted (AKS + Cosmos DB take ~10-20 min)..."
      az group wait -n "$rg" --deleted --interval 30 --timeout 3600
    done
    for kv in $(az keyvault list-deleted --query "[?starts_with(name,'kv-${PREFIX:0:8}-')].name" -o tsv); do
      az keyvault purge -n "$kv" && info "purged Key Vault $kv"
    done
    info "All resources deleted."
  else
    info "Deletion runs in the background (~15-20 min). Check progress with:"
    info "  az group list --query \"[?starts_with(name,'rg-${PREFIX}-')].[name,properties.provisioningState]\" -o table"
    info "Run '$0 destroy --wait' afterwards to wait for completion and purge the soft-deleted Key Vaults."
  fi
  rm -f "$STATE_FILE" "$VM_CRED_FILE"; exit 0
fi
cosmos_status() {
  az cosmosdb show -n "$COSMOS" -g "$RG_GLOBAL" --query "{account:name, write:writeLocations[0].locationName, read:join(', ', readLocations[].locationName), consistency:consistencyPolicy.defaultConsistencyLevel, autoFailover:enableAutomaticFailover, multiWrite:enableMultipleWriteLocations}" -o table 2>/dev/null \
    || info "$COSMOS not found"
}
if [[ "${1:-}" == "status" ]]; then log "Cosmos DB account"; cosmos_status; exit 0; fi
if [[ "${1:-}" == "cosmos-failover" ]]; then
  CUR=$(az cosmosdb show -n "$COSMOS" -g "$RG_GLOBAL" --query "writeLocations[0].locationName" -o tsv)
  R1N=$(az account list-locations --query "[?name=='$REGION1'].displayName" -o tsv)
  if [[ "$CUR" == "$R1N" ]]; then NEW="$REGION2"; OLD="$REGION1"; else NEW="$REGION1"; OLD="$REGION2"; fi
  log "Manual failover of $COSMOS: write region $CUR -> $NEW (takes a few minutes)"
  az cosmosdb failover-priority-change -n "$COSMOS" -g "$RG_GLOBAL" --failover-policies "$NEW=0" "$OLD=1" -o none
  cosmos_status; exit 0
fi
if [[ "${1:-}" == "testvm" || "${1:-}" == "testvm-run" ]]; then
  if [[ "$1" == "testvm" ]]; then create_test_vm; else test_from_vm; fi
  exit 0
fi
save_state
register_providers
TENANT_ID=$(az account show --query tenantId -o tsv)
for rg in "$RG_GLOBAL" "$RG1" "$RG2"; do
  [[ "$(az group show -n "$rg" --query properties.provisioningState -o tsv 2>/dev/null || true)" == "Deleting" ]] && \
    die "$rg is still being deleted - wait until it's gone, then run again"
done

log "Creating resource groups"
az group create -n "$RG_GLOBAL" -l "$REGION1" -o none
az group create -n "$RG1"       -l "$REGION1" -o none
az group create -n "$RG2"       -l "$REGION2" -o none

# ----------------------------- Cosmos DB (background) -----------------------
# ONE account: single WRITE region in REGION1 + READ replica in REGION2.
# Created with the write region only, then the replica is added (a capacity error in
# the second region doesn't fail the account). Service-managed failover, keys disabled.
create_cosmos() { # account writeRegion readRegion
  set +e
  local acct=$1 wr=$2 rr=$3 out rc attempt
  cstate() { az cosmosdb show -n "$acct" -g "$RG_GLOBAL" --query provisioningState -o tsv 2>/dev/null; }
  wait_ready() {
    local st i
    for i in {1..120}; do st=$(cstate); [[ "$st" == "Succeeded" ]] && return 0; sleep 20; done
    echo "$acct stuck in state: $st"; return 1
  }
  if [[ -z "$(cstate)" ]]; then
    echo "Creating $acct with write region $wr"
    az cosmosdb create -n "$acct" -g "$RG_GLOBAL" --kind GlobalDocumentDB \
      --default-consistency-level "$COSMOS_CONSISTENCY" \
      --locations regionName="$wr" failoverPriority=0 isZoneRedundant=False \
      --enable-automatic-failover true --disable-local-auth true \
      --public-network-access Disabled -o none || { echo "Account creation failed"; return 1; }
  fi
  wait_ready || return 1
  if [[ -n "$(az cosmosdb show -n "$acct" -g "$RG_GLOBAL" --query "locations[?failoverPriority==\`1\`].locationName" -o tsv)" ]]; then
    echo "$acct: read replica already present"; return 0
  fi
  for attempt in 1 2 3; do
    echo "$acct: adding read replica in $rr (attempt $attempt) - can take 10+ min"
    out=$(az cosmosdb update -n "$acct" -g "$RG_GLOBAL" \
      --locations regionName="$wr" failoverPriority=0 isZoneRedundant=False \
      --locations regionName="$rr" failoverPriority=1 isZoneRedundant=False -o none 2>&1); rc=$?
    wait_ready || return 1
    if [[ $rc -eq 0 ]]; then echo "$acct: read replica $rr added"; return 0; fi
    echo "$acct: could not add $rr: $(grep -oE 'experiencing high demand in [A-Za-z0-9 ]+ region|"message":"[^"]{0,160}' <<<"$out" | head -1)"
    grep -qiE 'high demand|ServiceUnavailable|capacity' <<<"$out" || return 1
    sleep 60
  done
  echo "$acct: no capacity for a replica in $rr - request access at https://aka.ms/cosmosdbquota"; return 1
}
log "Cosmos DB $COSMOS (background): WRITE $REGION1 | READ replica $REGION2, no multi-region writes"
( create_cosmos "$COSMOS" "$REGION1" "$REGION2" ) > /tmp/${PREFIX}-cosmos.log 2>&1 &
COSMOS_PID=$!

# ----------------------------- ACR + image build ----------------------------
log "ACR $ACR (Premium, geo-replicated to $REGION2)"
az acr show -n "$ACR" >/dev/null 2>&1 || \
  az acr create -n "$ACR" -g "$RG_GLOBAL" -l "$REGION1" --sku Premium --admin-enabled false -o none
az acr replication show -r "$ACR" -n "$REGION2" >/dev/null 2>&1 || az acr replication create -r "$ACR" -l "$REGION2" -o none
ACR_ID=$(az acr show -n "$ACR" --query id -o tsv)
IMAGE="${ACR}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"

if [[ "${FORCE_BUILD:-false}" == "true" || "$IMAGE_BUILT" != "$IMAGE_TAG" ]]; then
  log "Building $IMAGE in ACR (cloud build)"
  # ACR Tasks build agents run outside your VNet -> registry must be reachable during the build
  if [[ "$(az acr show -n "$ACR" --query publicNetworkAccess -o tsv)" == "Disabled" ]]; then
    info "Temporarily enabling public access on $ACR for the build"
    az acr update -n "$ACR" --public-network-enabled true --default-action Allow -o none || \
      die "Policy blocks public access on $ACR during the build - build from a machine inside the VNet instead"
  fi
  SRC_DIR=$(mktemp -d)
  write_app_source "$SRC_DIR"
  az acr build -r "$ACR" -t "${IMAGE_NAME}:${IMAGE_TAG}" "$SRC_DIR" -o none
  rm -rf "$SRC_DIR"
  IMAGE_BUILT="$IMAGE_TAG"; save_state
else
  info "$IMAGE already built - skipping (FORCE_BUILD=true to rebuild)"
fi

# ----------------------------- Networking per region ------------------------
setup_network() { # rg location vnet cidrPrefix
  local rg=$1 loc=$2 vnet=$3 c=$4 z vnet_id
  log "[$loc] VNet $vnet (${c}.0.0/16) + private DNS zones"
  az network vnet show -g "$rg" -n "$vnet" >/dev/null 2>&1 || \
    az network vnet create -g "$rg" -n "$vnet" -l "$loc" --address-prefixes "${c}.0.0/16" \
      --subnet-name snet-aks --subnet-prefixes "${c}.0.0/22" -o none
  az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n snet-pe >/dev/null 2>&1 || \
    az network vnet subnet create -g "$rg" --vnet-name "$vnet" -n snet-pe --address-prefixes "${c}.8.0/24" -o none
  az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n snet-pls >/dev/null 2>&1 || \
    az network vnet subnet create -g "$rg" --vnet-name "$vnet" -n snet-pls --address-prefixes "${c}.9.0/24" -o none
  az network vnet subnet update -g "$rg" --vnet-name "$vnet" -n snet-pls \
    --set privateLinkServiceNetworkPolicies=Disabled -o none
  vnet_id=$(az network vnet show -g "$rg" -n "$vnet" --query id -o tsv)
  # One set of privatelink zones per region: each VNet resolves to its OWN private endpoints
  for z in "${DNS_ZONES[@]}"; do
    az network private-dns zone show -g "$rg" -n "$z" >/dev/null 2>&1 || \
      az network private-dns zone create -g "$rg" -n "$z" -o none
    az network private-dns link vnet show -g "$rg" -z "$z" -n "link-$vnet" >/dev/null 2>&1 || \
      az network private-dns link vnet create -g "$rg" -z "$z" -n "link-$vnet" -v "$vnet_id" -e false -o none
  done
}
setup_network "$RG1" "$REGION1" "$VNET1" "$VNET1_CIDR"
setup_network "$RG2" "$REGION2" "$VNET2" "$VNET2_CIDR"
# Global VNet peering: the two regions can reach each other privately
# (in production this would usually be hub-and-spoke via a hub / Virtual WAN per region)
log "Peering $VNET1 <-> $VNET2 (global VNet peering)"
peer() { # rg vnet remoteRg remoteVnet name
  az network vnet peering show -g "$1" --vnet-name "$2" -n "$5" >/dev/null 2>&1 || \
    az network vnet peering create -g "$1" --vnet-name "$2" -n "$5" \
      --remote-vnet "$(az network vnet show -g "$3" -n "$4" --query id -o tsv)" \
      --allow-vnet-access --allow-forwarded-traffic -o none
  info "$2 -> $4: $(az network vnet peering show -g "$1" --vnet-name "$2" -n "$5" --query peeringState -o tsv)"
}
peer "$RG1" "$VNET1" "$RG2" "$VNET2" "peer-to-${R2}"
peer "$RG2" "$VNET2" "$RG1" "$VNET1" "peer-to-${R1}"
SUBNET1=$(az network vnet subnet show -g "$RG1" --vnet-name "$VNET1" -n snet-aks --query id -o tsv)
SUBNET2=$(az network vnet subnet show -g "$RG2" --vnet-name "$VNET2" -n snet-aks --query id -o tsv)

# ----------------------------- AKS clusters (background) --------------------
create_aks() { # rg name location vmsize subnetId cpIdentity vnet
  local rg=$1 name=$2 loc=$3 size=$4 subnet=$5 cpid=$6 vnet=$7 id_res id_pid extra=()
  if az aks show -g "$rg" -n "$name" >/dev/null 2>&1; then info "$name already exists"; return; fi
  az identity show -g "$rg" -n "$cpid" >/dev/null 2>&1 || az identity create -g "$rg" -n "$cpid" -l "$loc" -o none
  id_res=$(az identity show -g "$rg" -n "$cpid" --query id -o tsv)
  id_pid=$(az identity show -g "$rg" -n "$cpid" --query principalId -o tsv)
  # Cluster identity manages the internal LB + Private Link Service inside our VNet
  assign_role "$id_pid" "Network Contributor" "$(az network vnet show -g "$rg" -n "$vnet" --query id -o tsv)"
  sleep 30   # let the role assignment propagate before AKS validates it
  [[ -n "${API_AUTHORIZED_IPS:-}" ]] && extra+=(--api-server-authorized-ip-ranges "$API_AUTHORIZED_IPS")
  local out allowed s2 try
  for try in 1 2; do
    if out=$(az aks create -g "$rg" -n "$name" -l "$loc" \
        --node-count "$NODE_COUNT" --node-vm-size "$size" \
        --network-plugin azure --network-plugin-mode overlay --vnet-subnet-id "$subnet" \
        --enable-managed-identity --assign-identity "$id_res" \
        --enable-oidc-issuer --enable-workload-identity \
        --enable-addons azure-keyvault-secrets-provider --enable-secret-rotation \
        "${extra[@]}" --generate-ssh-keys --no-wait -o none 2>&1); then
      info "$name creation started ($size)"; return 0
    fi
    # Subscription may only allow certain sizes per region: pick one from the error's list
    allowed=$(grep -oE "available VM sizes are '[^']+'" <<<"$out" | cut -d"'" -f2 | tr ',' '\n' || true)
    [[ $try -eq 1 && -n "$allowed" ]] || die "AKS create failed for $name: $out"
    size=""
    for s2 in standard_b2s_v2 standard_b2as_v2 standard_b2ls_v2 standard_b2als_v2 standard_d2s_v5 standard_d2as_v5 standard_d2s_v6 standard_d2as_v6; do
      grep -qx "$s2" <<<"$allowed" && { size=$s2; break; }
    done
    [[ -n "$size" ]] || size=$(grep -E '^standard_[a-z]+2[a-z]*_v[0-9]+$' <<<"$allowed" | grep -v 'p' | head -1 || true)
    [[ -n "$size" ]] || die "No suitable VM size in $loc. Allowed: $(paste -sd' ' <<<"$allowed")"
    info "$4 not allowed in $loc - retrying with $size"
  done
}
log "Creating AKS clusters in the custom VNets"
create_aks "$RG1" "$AKS1" "$REGION1" "$NODE_VM_SIZE1" "$SUBNET1" "$CPID1" "$VNET1"
create_aks "$RG2" "$AKS2" "$REGION2" "$NODE_VM_SIZE2" "$SUBNET2" "$CPID2" "$VNET2"

# ----------------------------- Cosmos DB ready ------------------------------
log "Waiting for Cosmos DB account (10-20 min on first run)"
wait "$COSMOS_PID" || { sed 's/^/    /' /tmp/${PREFIX}-cosmos.log; die "Cosmos DB setup failed (account is kept - re-run to retry)"; }
sed 's/^/    /' /tmp/${PREFIX}-cosmos.log
[[ -n "$(az cosmosdb show -n "$COSMOS" -g "$RG_GLOBAL" --query "locations[?failoverPriority==\`1\`].locationName" -o tsv)" ]] || \
  die "Cosmos DB has no read replica - re-run to retry"
COSMOS_ID=$(az cosmosdb show -n "$COSMOS" -g "$RG_GLOBAL" --query id -o tsv)
COSMOS_ENDPOINT=$(az cosmosdb show -n "$COSMOS" -g "$RG_GLOBAL" --query documentEndpoint -o tsv)
cosmos_status
# Database + container through the control plane (works with public access disabled)
az cosmosdb sql database show -a "$COSMOS" -g "$RG_GLOBAL" -n "$COSMOS_DB_NAME" >/dev/null 2>&1 || \
  az cosmosdb sql database create -a "$COSMOS" -g "$RG_GLOBAL" -n "$COSMOS_DB_NAME" --throughput 400 -o none
az cosmosdb sql container show -a "$COSMOS" -g "$RG_GLOBAL" -d "$COSMOS_DB_NAME" -n "$COSMOS_CONTAINER_NAME" >/dev/null 2>&1 || \
  az cosmosdb sql container create -a "$COSMOS" -g "$RG_GLOBAL" -d "$COSMOS_DB_NAME" -n "$COSMOS_CONTAINER_NAME" -p /id -o none
info "Database $COSMOS_DB_NAME / container $COSMOS_CONTAINER_NAME ready"

# ----------------------------- Key Vaults -----------------------------------
# Secrets are written through Azure Resource Manager (control plane), so the
# vaults never need public data-plane access - not even from this machine.
kv_secret() { # kvName secretName value
  local kvid body; kvid=$(az keyvault show -n "$1" --query id -o tsv); body=$(mktemp)
  jq -n --arg v "$3" '{properties:{value:$v}}' > "$body"
  az rest --method put --url "https://management.azure.com${kvid}/secrets/$2?api-version=2023-07-01" \
    --body @"$body" -o none
  rm -f "$body"
}
create_kv() { # rg name location
  log "[$3] Key Vault $2 (public access disabled)"
  az keyvault show -n "$2" >/dev/null 2>&1 || \
    az keyvault create -n "$2" -g "$1" -l "$3" --enable-rbac-authorization true \
      --public-network-access Disabled -o none
  kv_secret "$2" cosmos-endpoint "$COSMOS_ENDPOINT"
  info "Secret cosmos-endpoint stored (no keys: Cosmos DB uses Entra ID auth)"
}
create_kv "$RG1" "$KV1" "$REGION1"
create_kv "$RG2" "$KV2" "$REGION2"

# ----------------------------- Private endpoints ----------------------------
# Make sure every FQDN the private endpoint serves has an A record in our zone.
# (Don't rely only on the DNS zone group: on policy-managed subscriptions its
#  records can be missing, which shows up as "no such host" inside the cluster.)
ensure_pe_dns() { # rg peName dnsZone
  local rg=$1 pe=$2 zone=$3 suffix nic fqdn ip name cur
  suffix="${zone#privatelink.}"; [[ "$zone" == "privatelink.vaultcore.azure.net" ]] && suffix="vault.azure.net"
  nic=$(az network private-endpoint show -g "$rg" -n "$pe" --query "networkInterfaces[0].id" -o tsv)
  while read -r fqdn ip; do
    [[ -n "$fqdn" && "$fqdn" == *".$suffix" ]] || continue
    name="${fqdn%.$suffix}"
    cur=$(az network private-dns record-set a show -g "$rg" -z "$zone" -n "$name" --query "aRecords[].ipv4Address" -o tsv 2>/dev/null || true)
    grep -qx "$ip" <<<"$cur" || az network private-dns record-set a add-record -g "$rg" -z "$zone" -n "$name" -a "$ip" -o none
    info "  $fqdn -> $ip"
  done < <(az network nic show --ids "$nic" -o json | jq -r '.ipConfigurations[] | .privateIPAddress as $ip
             | (.privateLinkConnectionProperties.fqdns // [])[] | "\(.) \($ip)"')
}
create_pe() { # rg location vnet peName resourceId groupId dnsZone
  local rg=$1 loc=$2 vnet=$3 pe=$4 res=$5 gid=$6 zone=$7 zone_id
  az network private-endpoint show -g "$rg" -n "$pe" >/dev/null 2>&1 || \
    az network private-endpoint create -g "$rg" -n "$pe" -l "$loc" --vnet-name "$vnet" --subnet snet-pe \
      --private-connection-resource-id "$res" --group-id "$gid" --connection-name "${pe}-conn" -o none
  zone_id=$(az network private-dns zone show -g "$rg" -n "$zone" --query id -o tsv)
  az network private-endpoint dns-zone-group show -g "$rg" --endpoint-name "$pe" -n default >/dev/null 2>&1 || \
    az network private-endpoint dns-zone-group create -g "$rg" --endpoint-name "$pe" -n default \
      --private-dns-zone "$zone_id" --zone-name cfg -o none
  info "$pe:"
  ensure_pe_dns "$rg" "$pe" "$zone"
}
pe_region() { # rg location vnet r kv
  log "[$2] Private endpoints for Cosmos DB, ACR and Key Vault"
  create_pe "$1" "$2" "$3" "pe-cosmos-$4" "$COSMOS_ID" Sql      privatelink.documents.azure.com
  create_pe "$1" "$2" "$3" "pe-acr-$4"    "$ACR_ID"    registry privatelink.azurecr.io
  create_pe "$1" "$2" "$3" "pe-kv-$4"     "$(az keyvault show -n "$5" --query id -o tsv)" vault privatelink.vaultcore.azure.net
}
pe_region "$RG1" "$REGION1" "$VNET1" "$R1" "$KV1"
pe_region "$RG2" "$REGION2" "$VNET2" "$R2" "$KV2"

log "Locking down public network access"
[[ "$(az cosmosdb show -n "$COSMOS" -g "$RG_GLOBAL" --query publicNetworkAccess -o tsv)" == "Disabled" ]] || \
  az cosmosdb update -n "$COSMOS" -g "$RG_GLOBAL" --public-network-access Disabled -o none
az acr update -n "$ACR" --public-network-enabled false --allow-trusted-services true -o none
info "Cosmos DB: $(az cosmosdb show -n "$COSMOS" -g "$RG_GLOBAL" --query publicNetworkAccess -o tsv) | ACR: $(az acr show -n "$ACR" --query publicNetworkAccess -o tsv) | Key Vaults: $(az keyvault show -n "$KV1" --query properties.publicNetworkAccess -o tsv)/$(az keyvault show -n "$KV2" --query properties.publicNetworkAccess -o tsv)"

# ----------------------------- AKS ready ------------------------------------
log "Waiting for AKS clusters (typically 8-15 min)"
az aks wait -g "$RG1" -n "$AKS1" --created --interval 30 --timeout 2400
az aks wait -g "$RG2" -n "$AKS2" --created --interval 30 --timeout 2400
# Internal subscriptions may stop clusters automatically (e.g. overnight) - start them again
for pair in "$RG1/$AKS1" "$RG2/$AKS2"; do
  if [[ "$(az aks show -g "${pair%/*}" -n "${pair#*/}" --query powerState.code -o tsv)" == "Stopped" ]]; then
    info "${pair#*/} is stopped - starting it"; az aks start -g "${pair%/*}" -n "${pair#*/}" --no-wait
  fi
done
for pair in "$RG1/$AKS1" "$RG2/$AKS2"; do
  az aks wait -g "${pair%/*}" -n "${pair#*/}" --custom "powerState.code=='Running' && provisioningState=='Succeeded'" --interval 30 --timeout 1800
done
for pair in "$RG1/$AKS1" "$RG2/$AKS2"; do
  assign_role "$(az aks show -g "${pair%/*}" -n "${pair#*/}" --query identityProfile.kubeletidentity.objectId -o tsv)" AcrPull "$ACR_ID"
  info "AcrPull granted to ${pair#*/}"
  az aks get-credentials -g "${pair%/*}" -n "${pair#*/}" --context "${pair#*/}" --overwrite-existing
done

# ----------------------------- App per region -------------------------------
region_display() { az account list-locations --query "[?name=='$1'].displayName" -o tsv; }
REGION1_NAME=$(region_display "$REGION1"); REGION2_NAME=$(region_display "$REGION2")

deploy_region() { # rg aks kv identity location regionDisplay preferredRegions regionIndex
  local rg=$1 aks=$2 kv=$3 idn=$4 loc=$5 rname=$6 pref=$7 ridx=$8 client_id principal_id issuer ip="" node_rg
  log "[$loc] Workload identity for $aks -> $kv"
  az identity show -g "$rg" -n "$idn" >/dev/null 2>&1 || az identity create -g "$rg" -n "$idn" -l "$loc" -o none
  client_id=$(az identity show -g "$rg" -n "$idn" --query clientId -o tsv)
  principal_id=$(az identity show -g "$rg" -n "$idn" --query principalId -o tsv)
  issuer=$(az aks show -g "$rg" -n "$aks" --query oidcIssuerProfile.issuerUrl -o tsv)
  assign_role "$principal_id" "Key Vault Secrets User" "$(az keyvault show -n "$kv" --query id -o tsv)"
  # Cosmos DB data-plane RBAC: Built-in Data Contributor (read/write items, no keys needed)
  if [[ -z "$(az cosmosdb sql role assignment list -a "$COSMOS" -g "$RG_GLOBAL" \
               --query "[?principalId=='$principal_id' && ends_with(roleDefinitionId,'00000000-0000-0000-0000-000000000002')].id" -o tsv)" ]]; then
    az cosmosdb sql role assignment create -a "$COSMOS" -g "$RG_GLOBAL" --scope "/" \
      --principal-id "$principal_id" --role-definition-id 00000000-0000-0000-0000-000000000002 -o none
    info "Cosmos DB Built-in Data Contributor granted to $idn"
  fi
  local fic_issuer
  fic_issuer=$(az identity federated-credential show -g "$rg" --identity-name "$idn" -n "fic-${aks}" --query issuer -o tsv 2>/dev/null || true)
  [[ -n "$fic_issuer" && "$fic_issuer" != "$issuer" ]] && \
    az identity federated-credential delete -g "$rg" --identity-name "$idn" -n "fic-${aks}" --yes -o none
  [[ "$fic_issuer" == "$issuer" ]] || az identity federated-credential create -g "$rg" --identity-name "$idn" -n "fic-${aks}" \
    --issuer "$issuer" --subject "system:serviceaccount:${K8S_NS}:${K8S_SA}" \
    --audiences api://AzureADTokenExchange -o none

  log "[$loc] Deploying $IMAGE_NAME to $aks (internal LB + Private Link Service)"
  local api; api=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='$aks')].cluster.server}")
  for i in {1..12}; do
    kubectl --context "$aks" get ns kube-system --request-timeout=15s >/dev/null 2>&1 && break
    [[ $i -eq 12 ]] && die "Can't reach the $aks API server ($api) from this machine.
    Check this machine's DNS/network (e.g. run 'wsl --shutdown' in Windows, reopen WSL) and re-run the script."
    info "API server not reachable from this machine yet - retrying ($i/12)"; sleep 10
  done
  kubectl --context "$aks" apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata: { name: ${K8S_NS} }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${K8S_SA}
  namespace: ${K8S_NS}
  annotations:
    azure.workload.identity/client-id: "${client_id}"
---
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: cosmos-kv
  namespace: ${K8S_NS}
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "${client_id}"
    keyvaultName: "${kv}"
    tenantId: "${TENANT_ID}"
    objects: |
      array:
        - |
          objectName: cosmos-endpoint
          objectType: secret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${IMAGE_NAME}
  namespace: ${K8S_NS}
spec:
  replicas: 2
  selector: { matchLabels: { app: ${IMAGE_NAME} } }
  template:
    metadata:
      labels:
        app: ${IMAGE_NAME}
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: ${K8S_SA}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app: ${IMAGE_NAME} } }
      securityContext: { runAsNonRoot: true, runAsUser: 1000 }
      containers:
        - name: app
          image: ${IMAGE}
          ports: [ { containerPort: 8080 } ]
          env:
            - { name: COSMOS_ENDPOINT_FILE, value: "/mnt/secrets-store/cosmos-endpoint" }
            - { name: COSMOS_DB,            value: "${COSMOS_DB_NAME}" }
            - { name: COSMOS_CONTAINER,     value: "${COSMOS_CONTAINER_NAME}" }
            - { name: REGION_NAME,          value: "${rname}" }
            - { name: PREFERRED_REGIONS,    value: "${pref}" }
            - { name: REGION_INDEX,         value: "${ridx}" }
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe: { httpGet: { path: /readyz,  port: 8080 }, initialDelaySeconds: 5,  periodSeconds: 10 }
          livenessProbe:  { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 10, periodSeconds: 20 }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true }
          volumeMounts:
            - { name: secrets-store, mountPath: /mnt/secrets-store, readOnly: true }
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes: { secretProviderClass: cosmos-kv }
---
apiVersion: v1
kind: Service
metadata:
  name: ${IMAGE_NAME}
  namespace: ${K8S_NS}
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-pls-create: "true"
    service.beta.kubernetes.io/azure-pls-name: "${PLS_NAME}"
    service.beta.kubernetes.io/azure-pls-ip-configuration-subnet: "snet-pls"
spec:
  type: LoadBalancer
  selector: { app: ${IMAGE_NAME} }
  ports: [ { port: 80, targetPort: 8080 } ]
YAML
  if ! kubectl --context "$aks" -n "$K8S_NS" rollout status "deploy/${IMAGE_NAME}" --timeout=600s; then
    kubectl --context "$aks" -n "$K8S_NS" get pods -o wide
    echo "---- recent events ----"
    kubectl --context "$aks" -n "$K8S_NS" get events --sort-by=.lastTimestamp | tail -15 | cut -c1-400
    kubectl --context "$aks" -n "$K8S_NS" logs "deploy/${IMAGE_NAME}" --tail=30 2>/dev/null || true
    die "$IMAGE_NAME did not become ready in $aks"
  fi
  for i in {1..40}; do
    ip=$(kubectl --context "$aks" -n "$K8S_NS" get svc "$IMAGE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$ip" ]] && break; sleep 10
  done
  [[ -n "$ip" ]] || die "Internal load balancer IP not assigned in $aks"
  node_rg=$(az aks show -g "$rg" -n "$aks" --query nodeResourceGroup -o tsv)
  for i in {1..30}; do
    az network private-link-service show -g "$node_rg" -n "$PLS_NAME" >/dev/null 2>&1 && break; sleep 10
  done
  PLS_ID_OUT=$(az network private-link-service show -g "$node_rg" -n "$PLS_NAME" --query id -o tsv)
  ILB_IP_OUT="$ip"; NODE_RG_OUT="$node_rg"
  info "$aks -> internal LB $ip, Private Link Service $PLS_NAME"
}
# Each region reads from its own region first; writes always go to the current write region
deploy_region "$RG1" "$AKS1" "$KV1" "$ID1" "$REGION1" "$REGION1_NAME" "$REGION1_NAME,$REGION2_NAME" 1
PLS1="$PLS_ID_OUT"; ILB1="$ILB_IP_OUT"; NRG1="$NODE_RG_OUT"
deploy_region "$RG2" "$AKS2" "$KV2" "$ID2" "$REGION2" "$REGION2_NAME" "$REGION2_NAME,$REGION1_NAME" 2
PLS2="$PLS_ID_OUT"; ILB2="$ILB_IP_OUT"; NRG2="$NODE_RG_OUT"

# ----------------------------- Azure Front Door Premium ---------------------
log "Azure Front Door Premium $AFD_PROFILE with Private Link origins"
az afd profile show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" >/dev/null 2>&1 || \
  az afd profile create -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --sku Premium_AzureFrontDoor -o none
az afd endpoint show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --endpoint-name "$AFD_ENDPOINT" >/dev/null 2>&1 || \
  az afd endpoint create -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --endpoint-name "$AFD_ENDPOINT" --enabled-state Enabled -o none
az afd origin-group show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --origin-group-name "$AFD_OG" >/dev/null 2>&1 || \
  az afd origin-group create -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --origin-group-name "$AFD_OG" \
    --probe-request-type GET --probe-protocol Http --probe-path /healthz --probe-interval-in-seconds 30 \
    --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 -o none
# Origins + route are written straight to Azure Resource Manager: the 'az afd' CLI
# flags for Private Link differ between CLI/extension versions, the REST API doesn't.
AFD_API="2024-02-01"
afd_put() { # urlPath jsonBody
  local f; f=$(mktemp); echo "$2" > "$f"
  az rest --method put --url "https://management.azure.com${AFD_ID}$1?api-version=${AFD_API}" --body @"$f" -o none
  rm -f "$f"
}
AFD_ID=$(az afd profile show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --query id -o tsv)
add_origin() { # name ilbIp plsId location
  if az afd origin show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --origin-group-name "$AFD_OG" --origin-name "$1" >/dev/null 2>&1; then
    info "origin $1 already exists"; return; fi
  afd_put "/originGroups/${AFD_OG}/origins/$1" "$(jq -n --arg ip "$2" --arg pls "$3" --arg loc "$4" --arg msg "Azure Front Door $AFD_PROFILE" '{
    properties: { hostName:$ip, originHostHeader:$ip, httpPort:80, httpsPort:443, priority:1, weight:1000,
      enabledState:"Enabled", enforceCertificateNameCheck:true,
      sharedPrivateLinkResource: { privateLink:{id:$pls}, privateLinkLocation:$loc, requestMessage:$msg } } }')"
  info "origin $1 -> $2 via Private Link ($4)"
}
add_origin "aks-${R1}" "$ILB1" "$PLS1" "$REGION1"   # same priority + weight = active/active,
add_origin "aks-${R2}" "$ILB2" "$PLS2" "$REGION2"   # users go to the closest healthy region
# Origin creation finishes asynchronously; the route needs them provisioned first
wait_origin() { # name
  local st i
  for i in {1..40}; do
    st=$(az afd origin show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --origin-group-name "$AFD_OG" \
           --origin-name "$1" --query provisioningState -o tsv 2>/dev/null || true)
    [[ "$st" == "Succeeded" ]] && { info "origin $1 provisioned"; return 0; }
    [[ "$st" == "Failed" ]] && die "Front Door origin $1 failed to provision"
    sleep 15
  done
  die "Front Door origin $1 still '$st' after 10 min - re-run the script"
}
wait_origin "aks-${R1}"
wait_origin "aks-${R2}"
if ! az afd route show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --endpoint-name "$AFD_ENDPOINT" --route-name default >/dev/null 2>&1; then
  ROUTE_BODY=$(jq -n --arg og "${AFD_ID}/originGroups/${AFD_OG}" '{
    properties: { originGroup:{id:$og}, patternsToMatch:["/*"], supportedProtocols:["Http","Https"],
      httpsRedirect:"Enabled", forwardingProtocol:"HttpOnly", linkToDefaultDomain:"Enabled", enabledState:"Enabled" } }')
  for i in 1 2 3 4 5 6; do
    afd_put "/afdEndpoints/${AFD_ENDPOINT}/routes/default" "$ROUTE_BODY" 2>/tmp/afd-route.err && break
    [[ $i -eq 6 ]] && { cat /tmp/afd-route.err >&2; die "Could not create the Front Door route"; }
    info "route not accepted yet (origins still settling) - retrying in 30s ($i/6)"; sleep 30
  done
  info "route default -> $AFD_OG"
fi

approve_pls() { # nodeRg
  local pending approved c
  info "Waiting for Front Door's connection request on $PLS_NAME ($1)..."
  for i in {1..60}; do
    pending=$(az network private-link-service show -g "$1" -n "$PLS_NAME" \
      --query "privateEndpointConnections[?privateLinkServiceConnectionState.status=='Pending'].name" -o tsv)
    for c in $pending; do
      az network private-link-service connection update -g "$1" --service-name "$PLS_NAME" -n "$c" \
        --connection-status Approved --description "Approved for Azure Front Door" -o none
      info "Approved $c"
    done
    approved=$(az network private-link-service show -g "$1" -n "$PLS_NAME" \
      --query "privateEndpointConnections[?privateLinkServiceConnectionState.status=='Approved'].name" -o tsv)
    [[ -n "$approved" ]] && return 0
    sleep 15
  done
  die "No Front Door connection request arrived on $PLS_NAME in $1 within 15 min - re-run the script to retry"
}
log "Approving Front Door Private Link connections"
approve_pls "$NRG1"
approve_pls "$NRG2"
AFD_HOST=$(az afd endpoint show -g "$RG_GLOBAL" --profile-name "$AFD_PROFILE" --endpoint-name "$AFD_ENDPOINT" --query hostName -o tsv)

cat <<SUMMARY

=====================================================================
 Deployment complete
---------------------------------------------------------------------
 App URL        : https://${AFD_HOST}   (allow ~15-20 min to go live)
 ${REGION1_NAME}  : ${AKS1}  internal LB ${ILB1} (Private Link)
 ${REGION2_NAME}        : ${AKS2}  internal LB ${ILB2} (Private Link)
 VNet peering   : ${VNET1} (10.10.0.0/16) <-> ${VNET2} (10.20.0.0/16)
 Cosmos DB      : ${COSMOS}  WRITE ${REGION1_NAME} | READ replica ${REGION2_NAME}
                  (single write region, service-managed failover, private endpoints only)
 ACR            : ${ACR}.azurecr.io  geo-replicated, private endpoints only
 Key Vaults     : ${KV1} / ${KV2}  private endpoints only
 kube contexts  : ${AKS1} / ${AKS2}
---------------------------------------------------------------------
 Test a region  : kubectl --context ${AKS1} -n ${K8S_NS} port-forward svc/${IMAGE_NAME} 8080:80
                  then open http://localhost:8080
 Failover test  : kubectl --context ${AKS1} -n ${K8S_NS} scale deploy/${IMAGE_NAME} --replicas 0
 Test VM        : created below in ${TEST_VM_REGION} (re-create: $0 testvm, re-test: $0 testvm-run)
 Cosmos status  : $0 status
 Failover drill : $0 cosmos-failover   (run again to fail back)
 Tear down      : $0 destroy
=====================================================================
SUMMARY

# ----------------------------- Test VM (always) -----------------------------
if [[ "${SKIP_TEST_VM:-false}" != "true" ]]; then
  # background + wait so 'set -e' stays active inside the step; a failure doesn't fail the deployment
  ( create_test_vm ) & TVM_PID=$!
  wait "$TVM_PID" || info "WARNING: test VM step failed (the platform itself is deployed) - retry with: $0 testvm"
fi

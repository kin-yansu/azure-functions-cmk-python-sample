# 文書暗号化 API の PoC

新しいリソースグループに VNet、サブネット、Private DNS、Managed HSM、Flex Consumption、Function App、Storage Account、マネージド ID を構築し、Mac から暗号化と復号を確認します。事前に必要なのは Azure サブスクリプション、同じ Microsoft Entra テナントでの権限、Mac の接続元 IPv4 が `59.136.249.169` であることです。

| ファイル | 役割 |
|---|---|
| `infra/bootstrap.bicep` | VNet `10.0.0.0/24`、Flex 統合用 `10.0.0.0/27`、Private Endpoint 用 `10.0.0.32/27`、Private DNS 3ゾーン、Managed HSM とその Private Endpoint |
| `infra/main.bicep` | Flex Consumption の Python 3.12 Function App、Storage Account、Blob コンテナ、実行用 ID とストレージ権限、Blob と Function の Private Endpoint、Entra 認証 |
| `app/` | Azure Functions に載せる Python API |

Function App の API とコード配布用 SCM の公開入口は `59.136.249.169/32` のみ許可します。HSM は公開アクセス無効で作成します。Mac から初期化・管理するには、手順2の Azure Portal で同じ IP に公開アクセスを限定します。bootstrap を再実行した場合は、Mac から HSM を操作する前に手順2の設定を確認してください。Function App は VNet 統合経由で HSM と Blob にアクセスします。VNet は単独で動かせるので ExpressRoute や既存 VNet は不要です。後から接続する場合はアドレス範囲の重複を確認してください。

**Managed HSM は未使用でも課金されるリソースです。** この PoC は削除保護を無効にして作成します。検証終了時は、不要な HSM の削除・パージと Entra 登録の削除を確認してください。業務データの入っていない専用環境で使用します。

## 1. RG とネットワーク・HSM の作成

最新の Azure CLI（Bicep が使えるもの）、OpenSSL、jq、zip を用意し、展開したディレクトリをカレントにして Bash で実行します。途中の変数を使うので同じシェルで進めます。RG 内のリソース作成と Azure RBAC 割り当て、および Entra アプリ登録・サービスプリンシパル作成ができる権限が必要です。

```bash
az login
az account set --subscription '<検証用サブスクリプション ID>'
RG=rg-cmk-poc
LOCATION=japaneast  # Flex Consumption と Managed HSM が利用できるリージョンに変更可
az functionapp list-flexconsumption-locations --output table
ADMIN_OID=$(az ad signed-in-user show --query id --output tsv)
TENANT_ID=$(az account show --query tenantId --output tsv)

for provider in Microsoft.App Microsoft.Network Microsoft.KeyVault Microsoft.Storage Microsoft.Web Microsoft.ManagedIdentity; do
  az provider register --namespace "$provider" --wait
done

az group create --name "$RG" --location "$LOCATION"
az deployment group create --resource-group "$RG" --name cmkpoc-bootstrap \
  --template-file infra/bootstrap.bicep --parameters hsmAdminObjectId="$ADMIN_OID"

bootstrap_output() {
  az deployment group show --resource-group "$RG" --name cmkpoc-bootstrap \
    --query "properties.outputs.$1.value" --output tsv
}

HSM_NAME=$(bootstrap_output hsmName)
HSM_KEY_NAME=document-wrap-poc
```

## 2. Managed HSM の初回有効化と CMK 作成

Mac からセキュリティドメインを取得する前に、Azure Portal で Managed HSM の公開アクセスを `59.136.249.169/32` に限定します。

1. Azure Portal で手順1の Managed HSM（`$HSM_NAME`）を開き、**Networking** → **Public access** に進みます。
2. **Public network access** の **Manage** を開き、公開アクセスを **Enable**、**Default action** を **Enable from selected networks** に設定します。
3. **IP Networks** に `59.136.249.169/32` を登録し、許可 IP がこの1件だけであることを確認します。Microsoft の信頼されたサービスによるファイアウォールのバイパスは **No** に設定します。
4. **Save** で保存します。

この設定が保存済みの場合は、以下のセキュリティドメイン取得に進みます。[Microsoft Learn の画面手順](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/configure-network-security)

以下のセキュリティドメイン取得は新規HSMに対して一度だけ行います。下の RSA 鍵は、セキュリティドメインの復旧用です。文書の DEK をラップする AES 鍵は、その後で HSM 内に生成します。

```bash
umask 077
HSM_RECOVERY_DIR="$HOME/cmk-poc-hsm-recovery/$HSM_NAME"
mkdir -p "$HSM_RECOVERY_DIR"
for n in 1 2 3; do
  openssl req -newkey rsa:2048 -nodes -x509 -days 365 \
    -subj "/CN=cmk-poc-recovery-$n" \
    -keyout "$HSM_RECOVERY_DIR/recovery-$n.key" \
    -out "$HSM_RECOVERY_DIR/recovery-$n.cer"
done

az keyvault security-domain download --hsm-name "$HSM_NAME" \
  --sd-wrapping-keys "$HSM_RECOVERY_DIR/recovery-1.cer" \
    "$HSM_RECOVERY_DIR/recovery-2.cer" "$HSM_RECOVERY_DIR/recovery-3.cer" \
  --sd-quorum 2 --security-domain-file "$HSM_RECOVERY_DIR/security-domain.json"

az keyvault role assignment create --hsm-name "$HSM_NAME" \
  --role 'Managed HSM Crypto User' --assignee "$ADMIN_OID" --scope /keys

HSM_KID=$(az keyvault key create --hsm-name "$HSM_NAME" --name "$HSM_KEY_NAME" \
  --kty oct-HSM --size 256 --ops wrapKey unwrapKey --query key.kid --output tsv)
HSM_KEY_VERSION=${HSM_KID##*/}
```

RSA 秘密鍵とセキュリティドメインは Git に登録せず、安全に保管します。権限を付けた直後に鍵作成が拒否された場合は、割り当ての反映後に再実行します。

## 3. Entra の API と呼び出し元を作成

初回だけ実行します。再デプロイ時は作成済みの ID を再利用します。これは同一テナントのアプリ間認証を使い、Function App Authentication のサービスプリンシパル許可リストで呼び出し元を絞る PoC です。API 側のエンタープライズアプリで「割り当てが必要」が強制されるテナントでは、アプリロールと呼び出し元への割り当ても追加してください。

```bash
API_CLIENT_ID=$(az ad app create --display-name cmk-poc-api \
  --sign-in-audience AzureADMyOrg --requested-access-token-version 2 \
  --query appId --output tsv)
az ad app update --id "$API_CLIENT_ID" --identifier-uris "api://$API_CLIENT_ID"
az ad sp create --id "$API_CLIENT_ID" --output none

CALLER_CLIENT_ID=$(az ad app create --display-name cmk-poc-client \
  --sign-in-audience AzureADMyOrg --query appId --output tsv)
CALLER_OID=$(az ad sp create --id "$CALLER_CLIENT_ID" --query id --output tsv)
```

## 4. Function App を構築してアプリを配布

```bash
az deployment group create --resource-group "$RG" --name cmkpoc-app \
  --template-file infra/main.bicep --parameters \
    integrationSubnetId="$(bootstrap_output integrationSubnetId)" \
    privateEndpointSubnetId="$(bootstrap_output privateEndpointSubnetId)" \
    functionsPrivateDnsZoneId="$(bootstrap_output functionsPrivateDnsZoneId)" \
    blobPrivateDnsZoneId="$(bootstrap_output blobPrivateDnsZoneId)" \
    hsmName="$HSM_NAME" hsmKeyName="$HSM_KEY_NAME" hsmKeyVersion="$HSM_KEY_VERSION" \
    apiClientId="$API_CLIENT_ID" callerPrincipalId="$CALLER_OID"

app_output() {
  az deployment group show --resource-group "$RG" --name cmkpoc-app \
    --query "properties.outputs.$1.value" --output tsv
}

az keyvault role assignment create --hsm-name "$HSM_NAME" \
  --role 'Managed HSM Crypto Service Encryption User' \
  --assignee "$(app_output runtimePrincipalId)" --scope "/keys/$HSM_KEY_NAME"

APP_NAME=$(app_output functionAppName)
API_URL=$(app_output functionUrl)
PACKAGE="$(pwd)/function-package.zip"
(cd app && zip -q "$PACKAGE" function_app.py host.json requirements.txt)
az functionapp deployment source config-zip \
  --resource-group "$RG" --name "$APP_NAME" --src "$PACKAGE" --build-remote true
```

Python 依存関係は Azure CLI のリモートビルドで解決します。Azure 側でパッケージ取得を制限している場合は、承認済みの配布元または Linux で依存関係を同梱したパッケージを使用してください。

## 5. Mac から保存・復号を確認

### 5.1 呼び出し元のクライアントシークレットを設定

1. [Azure Portal](https://portal.azure.com) で、手順3と同じディレクトリに切り替えます。
2. **Microsoft Entra ID → アプリの登録 → cmk-poc-client → 証明書とシークレット → クライアント シークレット → 新しいクライアント シークレット** を開きます。PoC用に短い有効期間を選んで追加します。
3. 追加直後に表示される **「値」** をコピーします。「シークレット ID」は識別子です。発行済みのシークレットの値を紛失していたら、新しいシークレットを作成します。
4. 手順3・4で使ったターミナルで次の1行を実行します。入力待ちになったら値を貼り付けて Enter を押します。入力文字は画面に表示されません。

```bash
printf 'CALLER_SECRET: '; IFS= read -rs CALLER_SECRET; printf '\n'
```

[Microsoft Learn のクライアントシークレット作成手順](https://learn.microsoft.com/entra/identity-platform/how-to-add-credentials)

### 5.2 トークンを取得

同じターミナルで実行します。成功時はトークンを `TOKEN` に格納し、失敗時は Entra のエラーコードを表示します。

```bash
TOKEN=
if [ -z "$CALLER_SECRET" ]; then
  printf 'CALLER_SECRET が空です。手順5.1で値を設定してください。\n' >&2
elif token_response=$(curl -sS "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode "client_id=$CALLER_CLIENT_ID" \
  --data-urlencode "client_secret=$CALLER_SECRET" \
  --data-urlencode "scope=api://$API_CLIENT_ID/.default"); then
  if TOKEN=$(printf '%s' "$token_response" | jq -er '.access_token // empty'); then
    printf 'トークン取得成功\n'
  else
    printf '%s' "$token_response" | jq '{error, error_codes}' >&2
  fi
fi
unset token_response
```

`invalid_client` で `7000216` が表示された場合は、`CALLER_SECRET` に値を入れたターミナルで実行しているか確認します。`7000215` の場合は、手順3の `CALLER_CLIENT_ID` に対応する **cmk-poc-client** の有効なシークレットの「値」を設定し直します。

### 5.3 文書を保存して復号

「トークン取得成功」と表示されたら、同じターミナルで実行します。

```bash
printf '%s\n' 'CMK prototype sample' > original.txt
DOCUMENT_ID=$(curl -fsS "$API_URL/v1/documents" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @original.txt | jq -er .id) &&
curl -fsS "$API_URL/v1/documents/$DOCUMENT_ID" \
  -H "Authorization: Bearer $TOKEN" --output restored.txt &&
cmp original.txt restored.txt &&
printf '復号結果が一致しました。Blob名: %s\n' "$DOCUMENT_ID"
unset CALLER_SECRET TOKEN
```

Function API の呼び出しが `403` の場合は実際の公開送信元 IP と Entra の許可リストを、`401` の場合はトークンの宛先やテナントを確認します。

### 5.4 Azure Portalで暗号化済みBlobを確認（任意）

自分のMacからストレージを直接確認するときは、ネットワークの許可と、PortalにサインインしているユーザーのBlob読み取り権限が必要です。

1. **ストレージ アカウント → ネットワーク** でパブリック ネットワーク アクセスを選択したネットワークのみに限定し、Macの公開送信元IPv4だけを許可します。[ストレージのネットワーク設定](https://learn.microsoft.com/azure/storage/common/storage-network-security-set-default-access)
2. **コンテナー → documents → アクセス制御 (IAM)** で、Portalにサインインしている自分のEntraユーザーに **ストレージ Blob データ閲覧者 (Storage Blob Data Reader)** を割り当てます。Entra認証で一覧を表示できないというエラーが出たら、この割り当てを確認します。反映には最大10分ほどかかることがあります。[Blobデータへのロール割り当て](https://learn.microsoft.com/azure/storage/blobs/assign-azure-role-data-access)
3. `documents` を開き、手順5.3の `DOCUMENT_ID` と同じ名前のBlobを選びます。サンプルでは元ファイルの21 BにAES-GCMの認証タグ16 Bが加わり、Blobのサイズは37 Bです。
4. Blobの**概要 → メタデータ**で、`wrapped_dek`（CMKでラップしたDEKのBase64表現）と、`key_version`（CMKのバージョン）を確認します。Blobの本文には、Functionが保存前に暗号化した文書が入っています。

Portal確認のため一時的に有効にしたストレージのパブリック ネットワーク アクセスは、確認後に無効へ戻します。

参考: [Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to) · [Managed HSM の有効化](https://learn.microsoft.com/azure/key-vault/managed-hsm/quick-create-cli) · [Python のデプロイ](https://learn.microsoft.com/azure/azure-functions/python-build-options)

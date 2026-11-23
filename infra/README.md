# 文書暗号化 API のプロトタイプ基盤

既存のリソースグループに Flex Consumption の Python 3.12 Function App、ストレージ、実行用のユーザー割り当てマネージド ID、Blob と Function App の Private Endpoint、Entra 認証を構成します。ストレージはホスト・アプリ配布・文書用で共用し、デプロイパッケージと暗号文は別コンテナに保存します。実行用 ID にアカウント単位の Storage Blob Data Owner を付けます。HTTP トリガーの構成です。Queue や Durable Functions を追加する場合は、それらが必要とするエンドポイントと権限を追加してください。

## 既存リソース

- Flex 対応リージョンのリソースグループと、Function App と同じリージョンの VNet。サブスクリプションで `Microsoft.App` を登録済みとし、送信用サブネットは `Microsoft.App/environments` に委任済みとします。受信用 Private Endpoint には別サブネットを指定します。
- `privatelink.azurewebsites.net` と `privatelink.blob.core.windows.net` の既存 Private DNS ゾーン。利用者、ランナー、Function App の各ネットワークからプライベート IP を解決できるように、事前に VNet リンクや DNS 転送を構成します。ランナーにはアプリの SCM ホスト名の名前解決と到達性も必要です。
- 有効化済み Managed HSM、その Private Endpoint と DNS、および `wrapKey` / `unwrapKey` が有効な 256 ビットの `oct-HSM` 検証鍵。Function App から HSM のデータプレーンへ到達できることが前提です。
- 同じ Entra テナント内の API アプリ登録と許可済みの呼び出し元サービスプリンシパル。API は v2 アクセストークンを想定します。呼び出し元 ID にはアプリ登録のクライアント ID ではなく、エンタープライズアプリケーション側のサービスプリンシパルのオブジェクト ID を指定します。トークンの `aud` が API クライアント ID と異なる構成では、`apiAudience` を設定します。

## 基盤を配布する

`poc.bicepparam` のプレースホルダーを置き換えて実行します。Private Endpoint と DNS ゾーングループの設定、ストレージのロール割り当てを実施できる Azure 権限が必要です。

```bash
az deployment group create \
  --name cmk-poc \
  --resource-group "$RESOURCE_GROUP" \
  --parameters poc.bicepparam
```

Managed HSM 管理者が次を実行します。`RUNTIME_PRINCIPAL_ID` は出力 `runtimePrincipalId` の値です。割り当ては対象鍵の範囲に限定します。

```bash
az keyvault role assignment create \
  --hsm-name "$HSM_NAME" \
  --role 'Managed HSM Crypto Service Encryption User' \
  --assignee "$RUNTIME_PRINCIPAL_ID" \
  --scope "/keys/$HSM_KEY_NAME"
```

この後、既存の Python サンプルを Function App に配布します。先の GitHub Actions を使う場合は、Flex 用にスロット指定と Premium 向けビルド指定を外し、既存のデプロイ用 OIDC ID に対象 Function App の権限を付けます。閉域ランナーから配布し、許可された呼び出し元でテスト文書を POST・GET して元ファイルと一致することを確認します。

参考
- [Flex Consumption の作成と管理](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to)
- [マネージド ID を使う公式 Bicep サンプル](https://learn.microsoft.com/samples/azure/azure-quickstart-templates/function-app-flex-managed-identities/)
- [Managed HSM の組み込みロール](https://learn.microsoft.com/azure/key-vault/managed-hsm/built-in-roles)

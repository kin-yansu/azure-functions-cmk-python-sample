# 文書保存 API の Python サンプル

Azure Functions Python v2 の HTTP トリガーです。文書ごとに AES-256-GCM 用の DEK を生成し、Managed HSM の AES-256 鍵で `A256KW` ラップします。Blob の本体には暗号文と GCM タグ、メタデータにはラップ済み DEK・nonce・CMK のバージョン・保存形式のバージョンを保存します。GET は保存時の鍵バージョンでアンラップし、GCM の認証に成功した文書を返します。

## Azure 側の設定

- Linux Elastic Premium、Python 3.12、`production` と `staging` を想定。Azure Functions のホスト用ストレージは別途構成する。閉域の場合は、各スロットの受信用 Private Endpoint・Private DNS と、Blob / HSM に到達する送信用 VNet 統合を構成する。
- スロットごとにアプリ設定を入れる。下表の項目をデプロイスロット設定として指定し、通常のステージング検証には検証用の Blob コンテナと CMK を使う。スワップ時は本番設定でウォームアップが走るため、スロットの ID とネットワークが構成どおり動作するかを確認する。
- 実行用マネージド ID に対象コンテナの `Storage Blob Data Contributor`、対象鍵に Managed HSM ローカル RBAC の `Managed HSM Crypto Service Encryption User` を付与する。鍵は `oct-HSM`、256 ビット、`wrapKey` と `unwrapKey` を有効にする。
- 各スロットで Function App の認証を有効化し、Microsoft Entra の単一テナント、正しい API audience、未認証リクエストに HTTP 401 を設定する。Entra の `allowedPrincipals.identities` には利用を許可する呼び出し元サービスプリンシパルのオブジェクト ID を指定する。サンプルは**単一の信頼済み業務アプリで文書を共有**する前提。許可された呼び出し元はコンテナ内の全ドキュメントを取得できる。複数利用者の文書を分離する場合は、文書単位の認可を追加する。

| アプリ設定 | 値 |
|---|---|
| `DOCUMENT_BLOB_URL` | `https://<account>.blob.core.windows.net` |
| `DOCUMENT_CONTAINER` | 作成済みコンテナ名 |
| `HSM_URL` | `https://<hsm>.managedhsm.azure.net` |
| `HSM_KEY_NAME` | CMK の名前 |
| `HSM_KEY_VERSION` | 新規保存に使う鍵バージョン ID |
| `DOCUMENT_MANAGED_IDENTITY_CLIENT_ID` | ユーザー割り当て ID を使う場合のクライアント ID。省略時はシステム割り当て ID |

CMK のローテーション時は `HSM_KEY_VERSION` を更新し、既存文書が参照する旧バージョンを復号可能な状態で維持する。このサンプルでは HSM と鍵名をアプリ設定に固定しているため、別の HSM や鍵名に移行する場合は別途移行設計が必要。

## API の呼び出し

`BASE_URL` は HTTPS の API 入口。`TOKEN` には許可済みの呼び出し元が取得した、この API 向けの Entra アクセストークンを設定する。

```bash
curl --fail-with-body -X POST "$BASE_URL/v1/documents" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @document.pdf
# {"id": "レスポンスに含まれる文書ID"}

curl --fail-with-body "$BASE_URL/v1/documents/$DOCUMENT_ID" \
  -H "Authorization: Bearer $TOKEN" \
  --output restored.pdf
```

依存関係を入れたローカル環境で Functions Core Tools を使う場合は、`DOCUMENT_USE_AZURE_CLI=1` と上表の設定をローカル環境変数に設定し、`az login` と `func start` を実行する。CLI ユーザーにも検証用リソースへの権限が必要。Core Tools のローカル HTTP 入口は上記の Azure 側認証の代用にはならないため、ローカル検証に限定する。

## GitHub Actions

1. リポジトリにこのディレクトリの中身を登録し、GitHub Environment `staging` を作成する。デプロイ元ブランチを `main` に制限する。
2. デプロイ専用のユーザー割り当てマネージド ID を作り、OIDC の federated credential を `repo:<org>/<repo>:environment:staging` に設定する。Microsoft の手順では対象 Function App に `Website Contributor` を付与する。
3. Environment の変数に `AZURE_CLIENT_ID`、`AZURE_TENANT_ID`、`AZURE_SUBSCRIPTION_ID`、`AZURE_FUNCTIONAPP_NAME` を入れる。ランナーは Function App の staging SCM にプライベート DNS で到達でき、GitHub、Entra、Azure 管理 API、許可済みの Python パッケージ配布元に接続できる Linux x64 を用意する。Python 3.12 と pip、Azure CLI を事前に入れ、`function-deploy` ラベルを付与する。
4. Actions から **Deploy document API to staging** を手動実行する。検証用ファイルで保存・復号を行い、元ファイルと一致することを確認してから、権限のある端末で本番スワップを実行する。

```bash
az functionapp deployment slot swap \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FUNCTION_APP_NAME" \
  --slot staging \
  --target-slot production
```

カナリアを実施する場合は、検証用スロットをそのまま本番の振り分け先に使わない。本番用データと鍵を使う新版のバックエンドを用意し、旧版でも新版が保存したデータを復号できる状態で APIM のウェイトを変更する。

サンプルは一括処理のため 8 MiB 上限。HTTP 入力は Functions がバッファするため、API 入口側にもリクエストサイズ制限を設ける。POST を再送すると新しい文書 ID が発行されるため、保存の再試行を行う運用では冪等性を追加する。ワークフローはステージングへの配布までを実行する。

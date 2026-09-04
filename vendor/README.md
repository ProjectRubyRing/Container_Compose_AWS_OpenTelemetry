# vendor/

JBoss EAP 8.1 の配布物 (`jboss-eap-8.1.0.zip`) をここへ置く。

Red Hat カスタマーポータル (https://access.redhat.com/) からダウンロードする。
サブスクリプションが必要なため、リポジトリには含めない (`.gitignore` 済み)。

```
vendor/
└── jboss-eap-8.1.0.zip
```

zip を展開したときのディレクトリ名が `jboss-eap-8.1` 以外になる場合は、
ビルド時に `--build-arg EAP_ZIP_DIRNAME=<実際の名前>` を渡す。

zip を用意できないローカル検証では `./scripts/build.sh --wildfly` を使う
(WildFly 35 を取得する。EAP 8.1 のベースなので CLI / entrypoint / OTel 設定は
そのまま通る)。

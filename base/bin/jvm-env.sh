#!/bin/sh
# =============================================================================
#  base/bin/jvm-env.sh
#
#   JVM 関連の環境変数を集約する共通シェル。entrypoint.sh から source される。
#   既存構成の「JVM の環境変数は共通シェルにまとめる」という方針をそのまま踏襲し、
#   OpenTelemetry ぶんは otel-env.sh へ切り出して責務を分けている。
#
#       entrypoint.sh
#         └─ source jvm-env.sh          … ヒープ / GC / ロケール / TLS など
#              └─ source otel-env.sh    … OTEL_* と -javaagent
#
#   ---------------------------------------------------------------------------
#   JAVA_OPTS を直接設定してはいけない理由
#   ---------------------------------------------------------------------------
#   JBoss EAP の standalone.conf は「JAVA_OPTS が未設定のときだけ既定値を
#   組み立てる」作りになっている。外から JAVA_OPTS を渡すと
#     -Djava.awt.headless / -Djboss.modules.system.pkgs / ヒープ指定 / --add-opens
#   といった EAP 動作に必要な既定値がまるごと消える。
#   追記は必ず JAVA_OPTS_APPEND を使う (standalone.conf.append が連結する)。
# =============================================================================

jvm_log() { echo "[jvm-env] $*"; }

# -----------------------------------------------------------------------------
# 1. ロケール / タイムゾーン
#    ログのタイムスタンプと X-Ray のセグメント時刻をずらさないため UTC で揃える。
#    表示だけ JST にしたい場合は TZ=Asia/Tokyo を渡す (トレースは常に UTC 送信)。
# -----------------------------------------------------------------------------
: "${TZ:=Asia/Tokyo}"
: "${LANG:=ja_JP.UTF-8}"
export TZ LANG

# -----------------------------------------------------------------------------
# 2. ヒープ
#    コンテナのメモリ制限に追従させる。ECS のタスクメモリを変えても
#    JVM 側を触らなくて済むよう、絶対値ではなく割合で指定する。
#    standalone.conf の JBOSS_JAVA_SIZING を上書きする形。
# -----------------------------------------------------------------------------
: "${JVM_INITIAL_RAM_PERCENTAGE:=50.0}"
: "${JVM_MAX_RAM_PERCENTAGE:=75.0}"
: "${JBOSS_JAVA_SIZING:=-XX:InitialRAMPercentage=${JVM_INITIAL_RAM_PERCENTAGE} -XX:MaxRAMPercentage=${JVM_MAX_RAM_PERCENTAGE}}"
export JBOSS_JAVA_SIZING

# -----------------------------------------------------------------------------
# 3. 共通 JVM オプション
#    ここで JAVA_OPTS_APPEND を「初期化」する。この後 otel-env.sh が
#    -javaagent を追記するので、順序を入れ替えないこと。
# -----------------------------------------------------------------------------
_opts="${JAVA_OPTS_APPEND:-}"

# 一時領域。readonlyRootFilesystem=true でも書ける場所へ寄せる。
_opts="${_opts} -Djava.io.tmpdir=${EAP_TMP_DIR:-${EAP_RUN_DIR:-/run/eap}/tmp}"

# IPv6 が無効な VPC で名前解決に無駄な往復をしないようにする。
_opts="${_opts} -Djava.net.preferIPv4Stack=true"

# DNS キャッシュ。ALB / Aurora / ElastiCache のエンドポイントはフェイルオーバ時に
# IP が変わる。JVM 既定 (-1 = 永久キャッシュ) のままだと切り替わりに追従できず、
# 「X-Ray 上は接続タイムアウトのスパンだけが延々出る」状態になる。
: "${JVM_DNS_TTL:=30}"
: "${JVM_DNS_NEGATIVE_TTL:=5}"
_opts="${_opts} -Dnetworkaddress.cache.ttl=${JVM_DNS_TTL}"
_opts="${_opts} -Dnetworkaddress.cache.negative.ttl=${JVM_DNS_NEGATIVE_TTL}"

# 外部 SLB との HTTPS 通信で使うトラストストア。
# 別プロジェクト (Container_ExtraSLB_JVM_https_outbounds) が作った
# トラストストアをイメージに焼き込んでいる場合のみ有効化する。
if [ -n "${EXTRASLB_TRUSTSTORE_PATH:-}" ] && [ -r "${EXTRASLB_TRUSTSTORE_PATH}" ]; then
    _opts="${_opts} -Djavax.net.ssl.trustStore=${EXTRASLB_TRUSTSTORE_PATH}"
    _opts="${_opts} -Djavax.net.ssl.trustStorePassword=${EXTRASLB_TRUSTSTORE_PASSWORD:-changeit}"
    _opts="${_opts} -Djavax.net.ssl.trustStoreType=${EXTRASLB_TRUSTSTORE_TYPE:-PKCS12}"
    jvm_log "外部 SLB 用トラストストアを適用します: ${EXTRASLB_TRUSTSTORE_PATH}"
fi

# 運用からの追記フック (デバッガ接続など)
if [ -n "${APP_EXTRA_JAVA_OPTS:-}" ]; then
    _opts="${_opts} ${APP_EXTRA_JAVA_OPTS}"
fi

JAVA_OPTS_APPEND="${_opts}"
export JAVA_OPTS_APPEND
unset _opts

# -----------------------------------------------------------------------------
# 4. OpenTelemetry (OTEL_* と -javaagent)
#    ここより後で JAVA_OPTS_APPEND を組み立て直さないこと。
# -----------------------------------------------------------------------------
# shellcheck source=/dev/null
. "${APP_BIN_DIR:-/opt/app/bin}/otel-env.sh"

jvm_log "JBOSS_JAVA_SIZING = ${JBOSS_JAVA_SIZING}"

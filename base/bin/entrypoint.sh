#!/bin/sh
# =============================================================================
#  base/bin/entrypoint.sh   (ベースコンテナ共通のエントリーポイント)
#
#   front / back はこの ENTRYPOINT をそのまま継承する。ロールごとの差は
#   すべて環境変数 (APP_ROLE / HTTP_PORT ...) で吸収し、起動処理は 1 本に保つ。
#
#   処理順:
#     1. root 起動時のみ作業領域を用意して非 root へ降格
#     2. 書き込み可能な作業領域 (EAP_RUN_DIR = jboss.server.base.dir) を用意
#     3. configuration をイメージ内シードから複製
#     4. WAR (archive 方式) の実体を検証
#     5. 共通シェル (jvm-env*.sh -> otel-env.sh) を source して JVM/OTel 環境を確定
#        JVM オプションの渡し方は JVM_OPTS_MODE で 2 通りから選ぶ (下の 5. 参照)
#     6. ADOT サイドカーの待ち合わせ (任意)
#     7. standalone.sh を exec
#
#   環境変数は Containerfile の ENV に既定値を焼き込んである。
# =============================================================================
set -eu

: "${JBOSS_HOME:=/opt/eap}"
: "${APP_BIN_DIR:=/opt/app/bin}"
: "${EAP_RUN_DIR:=/run/eap}"
: "${EAP_SEED_DIR:=/opt/eap-seed}"
: "${EAP_CONFIG:=standalone.xml}"
: "${EAP_CONFIG_SEED:=always}"
: "${APP_NAME:=app.war}"
: "${APP_DEPLOY_PATH:=/opt/app/${APP_NAME}}"
: "${APP_UID:=6301}"
: "${APP_GID:=6302}"
: "${EAP_BIND:=0.0.0.0}"
: "${EAP_BIND_MANAGEMENT:=127.0.0.1}"
: "${EAP_DROP_PRIVILEGES:=auto}"
: "${JVM_OPTS_MODE:=append}"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARN: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $1" >&2; exit "${2:-1}"; }

# =============================================================================
# 1. root 起動時の権限降格
#    ECS(Fargate) の空ボリュームは root:root 0755 で現れることがあり、
#    非 root で起動すると作業領域を作れない。root なら所有者を直してから
#    自分自身を非 root で再実行する。
# =============================================================================
if [ "$(id -u)" = "0" ] && [ "${EAP_DROP_PRIVILEGES}" != "off" ]; then
    log "running as root: prepare ${EAP_RUN_DIR} and drop to ${APP_UID}:${APP_GID}"
    mkdir -p "${EAP_RUN_DIR}" || die "cannot create ${EAP_RUN_DIR}"
    chown "${APP_UID}:${APP_GID}" "${EAP_RUN_DIR}"
    chmod 0770 "${EAP_RUN_DIR}"
    if command -v setpriv >/dev/null 2>&1; then
        exec setpriv --reuid="${APP_UID}" --regid="${APP_GID}" --clear-groups "${SELF}" "$@"
    elif command -v runuser >/dev/null 2>&1; then
        exec runuser -u "#${APP_UID}" -g "#${APP_GID}" -- "${SELF}" "$@"
    else
        warn "setpriv / runuser が無いため root のまま起動します"
    fi
fi

log "start uid=$(id -u) gid=$(id -g) service=${APP_SERVICE:-未設定} role=${APP_ROLE:-未設定}"

# =============================================================================
# 2. 書き込み可能な作業領域
# =============================================================================
mkdir -p "${EAP_RUN_DIR}" 2>/dev/null || true
[ -d "${EAP_RUN_DIR}" ] || die "作業領域 ${EAP_RUN_DIR} を作成できません。readonlyRootFilesystem=true では、この場所に書き込み可能なボリュームが必要です (compose: tmpfs / ECS: volumes+mountPoints)。" 20

WTEST="${EAP_RUN_DIR}/.write-test.$$"
( : > "${WTEST}" ) 2>/dev/null || die "作業領域 ${EAP_RUN_DIR} へ uid=$(id -u) gid=$(id -g) で書き込めません。ボリュームの所有者/パーミッションを確認してください。" 21
rm -f "${WTEST}"

for d in configuration data log tmp deployments home; do
    mkdir -p "${EAP_RUN_DIR}/${d}"
done

# jboss-cli.sh が履歴ファイルを書けるよう HOME を作業領域へ向ける
HOME="${EAP_RUN_DIR}/home"
export HOME

# =============================================================================
# 3. configuration のシード
#    standalone.xml には WAR の unmanaged deployment とデータソースが
#    ビルド時に焼き込まれている。read-only なイメージ側ではなく作業領域で使う。
# =============================================================================
CONF_DST="${EAP_RUN_DIR}/configuration"
[ -d "${EAP_SEED_DIR}/configuration" ] || die "シード元がありません: ${EAP_SEED_DIR}/configuration (イメージのビルドに失敗しています)" 22

if [ "${EAP_CONFIG_SEED}" = "always" ] || [ ! -f "${CONF_DST}/${EAP_CONFIG}" ]; then
    log "seed configuration: ${EAP_SEED_DIR}/configuration -> ${CONF_DST} (mode=${EAP_CONFIG_SEED})"
    cp -R "${EAP_SEED_DIR}/configuration/." "${CONF_DST}/"
    chmod -R u+rw "${CONF_DST}"
else
    log "configuration は既に存在するため再シードしません (EAP_CONFIG_SEED=missing)"
fi
[ -f "${CONF_DST}/${EAP_CONFIG}" ] || die "${CONF_DST}/${EAP_CONFIG} がありません" 23

# =============================================================================
# 4. WAR (archive 方式) の検証
#    standalone.xml には <fs-archive path="..."/> が焼き込まれている。
#    実体がディレクトリだったり無かったりすると EAP のエラーからは原因が
#    分かりにくいので、起動前に落とす。
# =============================================================================
[ -e "${APP_DEPLOY_PATH}" ] || die "デプロイ資材がありません: ${APP_DEPLOY_PATH}" 10
[ -f "${APP_DEPLOY_PATH}" ] || die "${APP_DEPLOY_PATH} が通常ファイルではありません。archive 方式は単一の WAR ファイルを前提にしています。" 10
[ -r "${APP_DEPLOY_PATH}" ] || die "${APP_DEPLOY_PATH} を uid=$(id -u) で読めません" 10
log "payload ok: ${APP_DEPLOY_PATH} ($(wc -c < "${APP_DEPLOY_PATH}") bytes, archive)"

# =============================================================================
# 5. 共通シェルで JVM / OpenTelemetry の環境を確定する
#    ここで APP_SERVICE / APP_ROLE の規約違反があれば otel-env.sh が停止する。
#
#    JVM オプションの渡し方は 2 通り用意してあり、JVM_OPTS_MODE で選ぶ。
#    どちらのモードでも otel-env.sh は共通で、OTEL_* の導出は変わらない。
#
#      append (既定)  jvm-env.sh
#                     JAVA_OPTS_APPEND だけを組み立て、standalone.conf に
#                     連結させる。standalone.conf が持つ EAP の既定値
#                     (-Djboss.modules.system.pkgs / -Djava.awt.headless など) は
#                     そのまま残る。EAP の推奨に沿った安全側。
#
#      full           jvm-env-javaopts.sh
#                     JAVA_OPTS を直接組み立てる。JAVA_OPTS を渡すと
#                     standalone.conf は既定値を一切組み立てなくなるので、
#                     消えるぶんはすべて jvm-env-javaopts.sh が明示的に持つ。
#                     standalone.conf 経由の設定を使わない構成向け。
# =============================================================================
case "${JVM_OPTS_MODE}" in
    append) JVM_ENV_SCRIPT="jvm-env.sh" ;;
    full)   JVM_ENV_SCRIPT="jvm-env-javaopts.sh" ;;
    *)      die "JVM_OPTS_MODE は append か full です: ${JVM_OPTS_MODE}" 31 ;;
esac
log "JVM_OPTS_MODE=${JVM_OPTS_MODE} -> ${JVM_ENV_SCRIPT}"

[ -r "${APP_BIN_DIR}/${JVM_ENV_SCRIPT}" ] || die "共通シェルがありません: ${APP_BIN_DIR}/${JVM_ENV_SCRIPT}" 30
# shellcheck source=/dev/null
. "${APP_BIN_DIR}/${JVM_ENV_SCRIPT}"
otel_print_summary
# JAVA_OPTS 版だけが持つ要約 (組み立て後の JAVA_OPTS 全文)
if command -v jvm_print_summary >/dev/null 2>&1; then
    jvm_print_summary
fi

# =============================================================================
# 6. ADOT サイドカーの待ち合わせ (任意)
#
#    ECS はタスク内コンテナの起動順を dependsOn で制御できるが、
#    「プロセスが listen 済み」までは保証しない。EAP の起動は数十秒かかるので
#    実害は出にくいが、起動直後のスパンを取りこぼしたくない場合はここで待つ。
#    OTEL_WAIT_FOR_COLLECTOR=true で有効化する。
# =============================================================================
#    待ち合わせ先は OTLP の受信口 (4317/gRPC) ではなく health_check 拡張
#    (13133/HTTP) を使う。gRPC は curl で正しく叩けないうえ、TCP が開いた
#    だけでは「設定を読み終えてパイプラインが動いている」ことまでは分からない。
#    health_check なら Collector が実際に稼働しているかを確認できる。
: "${OTEL_WAIT_FOR_COLLECTOR:=false}"
: "${OTEL_WAIT_TIMEOUT_SEC:=30}"
: "${OTEL_COLLECTOR_HEALTH_URL:=http://localhost:13133}"
if [ "${OTEL_WAIT_FOR_COLLECTOR}" = "true" ]; then
    log "ADOT Collector (${OTEL_COLLECTOR_HEALTH_URL}) の待ち合わせを開始します (最大 ${OTEL_WAIT_TIMEOUT_SEC} 秒)"
    _i=0
    _ready=0
    while [ "${_i}" -lt "${OTEL_WAIT_TIMEOUT_SEC}" ]; do
        if curl -fsS --max-time 2 -o /dev/null "${OTEL_COLLECTOR_HEALTH_URL}" 2>/dev/null; then
            log "ADOT Collector が応答しました (${_i} 秒待機)"
            _ready=1
            break
        fi
        _i=$((_i + 1))
        sleep 1
    done
    if [ "${_ready}" = "0" ]; then
        warn "ADOT Collector に接続できないまま起動を継続します (起動直後のスパンは失われます)"
        warn "  -> Collector 側で health_check 拡張が 0.0.0.0:13133 で有効か確認してください"
    fi
    unset _i _ready
fi

# =============================================================================
# 7. 起動
# =============================================================================
if [ $# -gt 0 ] && [ "$1" != "run-server" ]; then
    # デバッグ用の脱出口 (docker run <image> sh など)
    log "exec (custom command): $*"
    exec "$@"
fi
if [ $# -gt 0 ]; then shift; fi   # "run-server" を捨て、残りは standalone.sh へ渡す

log "jboss.server.base.dir=${EAP_RUN_DIR}  server-config=${EAP_CONFIG}"
log "exec: ${JBOSS_HOME}/bin/standalone.sh"

exec "${JBOSS_HOME}/bin/standalone.sh" \
     -Djboss.server.base.dir="${EAP_RUN_DIR}" \
     --server-config="${EAP_CONFIG}" \
     -b "${EAP_BIND}" \
     -bmanagement "${EAP_BIND_MANAGEMENT}" \
     "$@"

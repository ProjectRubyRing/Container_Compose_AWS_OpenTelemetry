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
#     5. JBoss CLI を作業領域の standalone.xml へ適用する (apply-cli.sh)
#     6. 共通シェル (jvm-env*.sh -> otel-env.sh) を source して JVM/OTel 環境を確定
#        JVM オプションの渡し方は JVM_OPTS_MODE で 2 通りから選ぶ (下の 6. 参照)
#     7. ADOT サイドカーの待ち合わせ (任意)
#     8. standalone.sh を exec
#
#   環境変数は Containerfile の ENV に既定値を焼き込んである。
# =============================================================================
set -eu

: "${JBOSS_HOME:=/opt/eap}"
: "${APP_DIR:=/opt/app}"
: "${APP_BIN_DIR:=/opt/app/bin}"
: "${EAP_RUN_DIR:=/run/eap}"
: "${EAP_SEED_DIR:=/opt/eap-seed}"
: "${EAP_TMP_DIR:=${EAP_RUN_DIR}/tmp}"
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
: "${EAP_CLI_ENABLED:=true}"
: "${EAP_CLI_DIR:=${APP_DIR}/cli}"
: "${EAP_CLI_PATTERNS:=}"
: "${EAP_CLI_ROLE_PATTERNS:=}"
: "${EAP_CLI_STDOUT:=echo}"
: "${EAP_HTTPS_MODE:=remove}"

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
#    イメージが持っているのは素の standalone.xml (シード) だけ。WAR の
#    unmanaged deployment もデータソースも、この後の 5. で CLI が入れる。
#    read-only なイメージ側では書き換えられないので、まず作業領域へ複製する。
#    EAP_CONFIG_SEED=always (既定) なら毎起動シードからやり直すため、
#    「前回の起動が残した設定」に引きずられない。
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
#    この後の CLI が <fs-archive path="..."/> としてこのパスを登録する。
#    実体がディレクトリだったり無かったりすると EAP のエラーからは原因が
#    分かりにくいので、CLI を流す前に落とす。
# =============================================================================
[ -e "${APP_DEPLOY_PATH}" ] || die "デプロイ資材がありません: ${APP_DEPLOY_PATH}" 10
[ -f "${APP_DEPLOY_PATH}" ] || die "${APP_DEPLOY_PATH} が通常ファイルではありません。archive 方式は単一の WAR ファイルを前提にしています。" 10
[ -r "${APP_DEPLOY_PATH}" ] || die "${APP_DEPLOY_PATH} を uid=$(id -u) で読めません" 10
log "payload ok: ${APP_DEPLOY_PATH} ($(wc -c < "${APP_DEPLOY_PATH}") bytes, archive)"

# =============================================================================
# 5. JBoss CLI を作業領域の standalone.xml へ適用する
#
#    ★ ここで適用する (ビルド時ではない)
#      イメージに焼くのはシードの standalone.xml (素の状態) だけにして、
#      設定は毎起動 embed-server で組み立て直す。
#        - 同じイメージのまま、起動時の環境変数で構成を変えられる
#          (EAP_HTTPS_MODE / EAP_CLI_PATTERNS / .cli の追加投入)
#        - front / back のイメージビルドが「WAR を置くだけ」になり、
#          ビルドが速くなる & ベースの設定と食い違わない
#
#    ★ 代償: コンテナの起動が embed-server 2 回ぶん (数十秒) 遅くなる。
#      compose / ECS のヘルスチェックには start_period / startPeriod で
#      余裕を取ってある (120s / 180s)。
#
#    ★ standalone_xml_history について
#      起動時に embed-server を回すと configuration/standalone_xml_history が
#      でき、続く standalone.sh の本ブートが current の rename を試みる。
#      これがビルド時適用を選んでいた理由 (Compose では WFLYCTL0414 の警告、
#      ECS では WFLYCTL0082 でブート失敗、という環境差) だが、
#        - 書き換え先が overlayfs の下位レイヤではなく、この作業領域
#          (compose=tmpfs / ECS=volume) であること
#        - apply-cli.sh が適用直後に履歴ごと削除すること
#      の 2 点で、本ブートは「履歴の無い状態からの初回」になり rename 自体が
#      発生しない。
#
#    適用順は --pattern の並び順。00 -> 10 -> 20 -> (30) -> 31 -> ロール固有。
#      EAP_CLI_PATTERNS       指定するとこの導出を丸ごと置き換える (空白区切り)
#      EAP_CLI_ROLE_PATTERNS  ロール固有ぶん (front=5*.cli / back=6*.cli)
#      EAP_CLI_ENABLED=false  CLI 適用そのものを止める (シードのまま起動する)
# =============================================================================
if [ "${EAP_CLI_ENABLED}" = "true" ]; then
    [ -x "${APP_BIN_DIR}/apply-cli.sh" ] || die "${APP_BIN_DIR}/apply-cli.sh がありません" 24
    [ -d "${EAP_CLI_DIR}" ] || die "CLI ディレクトリがありません: ${EAP_CLI_DIR}" 24

    # --- 既定 HTTPS (8443) / application.keystore の扱い ---------------------
    #   remove   (既定) 30*.cli を適用して未使用の HTTPS 一式を削除する。
    #                   WFLYELY00023 / WFLYELY01084 は原理的に発生しない。
    #   keystore        HTTPS を残し、キーストアを作業領域に生成する。
    #                   ファイルが在るので WARN は出ない (自己署名)。
    #   keep            既定のまま。WARN は 31*.cli の filter-spec で抑制する。
    HTTPS_PATTERN=""
    case "${EAP_HTTPS_MODE}" in
        remove)
            HTTPS_PATTERN='30*.cli' ;;
        keep)
            log "EAP_HTTPS_MODE=keep: 既定 HTTPS を残します (WARN は filter-spec で抑制)" ;;
        keystore)
            KS_PATH="${CONF_DST}/application.keystore"
            if [ -f "${KS_PATH}" ]; then
                log "EAP_HTTPS_MODE=keystore: ${KS_PATH} は既にあります"
            else
                #  ★ "password" は standalone.xml の applicationKS の
                #    credential-reference と一致させるための EAP 既定値。
                #    変更する場合は elytron 側も併せて書き換えること。
                : "${EAP_KEYSTORE_PASSWORD:=password}"
                KEYTOOL="$(command -v keytool 2>/dev/null || true)"
                [ -n "${KEYTOOL}" ] || KEYTOOL="${JAVA_HOME:-/usr/lib/jvm/jre-21}/bin/keytool"
                [ -x "${KEYTOOL}" ] || die "keytool が見つかりません (${KEYTOOL})" 24
                log "EAP_HTTPS_MODE=keystore: ${KS_PATH} を生成します (自己署名)"
                "${KEYTOOL}" -genkeypair -noprompt \
                    -keystore "${KS_PATH}" \
                    -storetype JKS \
                    -storepass "${EAP_KEYSTORE_PASSWORD}" -keypass "${EAP_KEYSTORE_PASSWORD}" \
                    -alias server -keyalg RSA -keysize 2048 -validity 3650 \
                    -dname "CN=localhost, OU=container, O=local, L=local, ST=local, C=JP" \
                    -ext "SAN=dns:localhost,ip:127.0.0.1"
            fi ;;
        *)
            die "EAP_HTTPS_MODE は remove | keystore | keep のいずれかです: [${EAP_HTTPS_MODE}]" 24 ;;
    esac

    #  サブシェルで組み立てる。$@ にはコンテナのコマンド (run-server) が
    #  入っているので、ここで set -- を使っても親には影響させない。
    #  set -f はパターン (5*.cli) を作業領域のファイル名に展開させないため。
    (
        set -f
        set -- --eap-home "${JBOSS_HOME}" \
               --config   "${EAP_CONFIG}" \
               --cli-dir  "${EAP_CLI_DIR}" \
               --base-dir "${EAP_RUN_DIR}" \
               --work-dir "${EAP_TMP_DIR}" \
               --std-out  "${EAP_CLI_STDOUT}"
        if [ -n "${EAP_CLI_PATTERNS}" ]; then
            for p in ${EAP_CLI_PATTERNS}; do set -- "$@" --pattern "${p}"; done
        else
            set -- "$@" --pattern '0*.cli' --pattern '1*.cli' --pattern '2*.cli'
            [ -z "${HTTPS_PATTERN}" ] || set -- "$@" --pattern "${HTTPS_PATTERN}"
            set -- "$@" --pattern '31*.cli'
            for p in ${EAP_CLI_ROLE_PATTERNS}; do set -- "$@" --pattern "${p}"; done
        fi
        exec "${APP_BIN_DIR}/apply-cli.sh" "$@"
    ) || die "CLI の適用に失敗しました。上の [apply-cli] の出力を確認してください。" 25

    # --- 配備が焼き込まれたことの確認 ----------------------------------------
    #     ロール固有 CLI (5*/6*.cli) が WAR を <fs-archive> として登録する。
    #     ここが空のまま起動すると「200 が返らないだけ」の分かりにくい形で
    #     失敗するので、起動前に落とす。
    if [ -n "${EAP_CLI_ROLE_PATTERNS}" ] && [ -z "${EAP_CLI_PATTERNS}" ]; then
        grep -q 'fs-archive' "${CONF_DST}/${EAP_CONFIG}" \
            || die "${EAP_CONFIG} に <fs-archive> が焼き込まれていません (ロール固有 CLI: ${EAP_CLI_ROLE_PATTERNS})" 26
        log "焼き込まれた <deployments>:"
        sed -n '/<deployments>/,/<\/deployments>/p' "${CONF_DST}/${EAP_CONFIG}" \
            | sed 's/^/[entrypoint] | /'
    fi
else
    log "EAP_CLI_ENABLED=false: CLI を適用せずシードの ${EAP_CONFIG} のまま起動します"
fi

# =============================================================================
# 6. 共通シェルで JVM / OpenTelemetry の環境を確定する
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
# 7. ADOT サイドカーの待ち合わせ (任意)
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
# 8. 起動
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

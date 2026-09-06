#!/bin/sh
# =============================================================================
#  base/bin/apply-cli.sh   (コンテナ起動時に entrypoint.sh から実行される)
#
#   embed-server で standalone.xml をオフラインのまま書き換える。
#   適用対象は --pattern で指定する。ロールごとの差 (front=5*.cli /
#   back=6*.cli) はこの引数だけで吸収し、スクリプト自体は 1 本に保つ。
#
#     apply-cli.sh --eap-home /opt/eap --config standalone.xml \
#                  --cli-dir /opt/app/cli --base-dir /run/eap \
#                  --work-dir /run/eap/tmp \
#                  --pattern '0*.cli' --pattern '1*.cli'
#
#  ---------------------------------------------------------------------------
#  ★ ビルド時ではなく起動時に走る (--base-dir がその要)
#  ---------------------------------------------------------------------------
#   実行時のイメージは readonlyRootFilesystem=true で、$EAP_HOME/standalone は
#   書き込めない。書き換え先は entrypoint.sh が用意する作業領域
#   (EAP_RUN_DIR = jboss.server.base.dir) 側の configuration であり、
#   --base-dir でそこを指す。embed-server は jboss.server.base.dir を見るので、
#   CLI の JVM にこのシステムプロパティを渡せば standalone.sh の本ブートと
#   まったく同じ場所を編集できる。
#
#   ★ standalone_xml_history の扱い
#     embed-server は書き換えのたびに configuration/standalone_xml_history を
#     作る。これを残したまま standalone.sh を起動すると current ディレクトリの
#     rename が走る。ここでは CLI の直後に履歴ごと消しておくので、本ブートは
#     「履歴の無い状態からの初回」になり rename 自体が発生しない。
#     (ビルド時適用のときは overlayfs の下位レイヤに履歴が残ることが
#      WFLYCTL0414 / WFLYCTL0082 の原因だった。作業領域は通常の書き込み可能な
#      ファイルシステムなので、消してさえおけば同じ問題は起きない)
#
#  ---------------------------------------------------------------------------
#  ★ 生成されるスクリプトの形 (これが本スクリプトの目的)
#  ---------------------------------------------------------------------------
#     embed-server --server-config=standalone.xml --std-out=echo
#     batch
#         <.cli の操作をすべてここに並べる>
#     run-batch
#     stop-embedded-server
#
#   batch ～ run-batch は 1 個の composite 操作になるため、
#     - 全操作が成功したときだけ standalone.xml へ書かれる (原子性)
#     - 途中で失敗したら全部ロールバックされ、中途半端な設定が残らない
#     - 書き込みが 1 回にまとまる
#   という性質になる。CLI が通った = 設定は全部入った、が保証される。
#   途中で落ちれば entrypoint.sh がそこで停止するので、中途半端な設定の
#   サーバが起動してくることはない。
#
#  ---------------------------------------------------------------------------
#  ★ バッチモードの制約と、その解き方 (ここが本スクリプトの実装の中心)
#  ---------------------------------------------------------------------------
#   JBoss CLI のバッチに積めるのは「操作要求」だけで、
#     - if / else / end-if  … 制御構文はバッチ内で使えない
#     - echo                … バッチ非対応コマンド
#   はそのまま入れるとエラーになる。一方 .cli 側は
#   「すべて if で冪等化してある」ことが前提の作りで、これは捨てたくない
#   (SERVER_SOURCE=image の社内 EAP イメージや、front/back での再適用で
#    元から在る/無いが変わるため)。
#
#   そこで CLI 実行を 2 パスに分ける。
#
#     パス 1 (probe)  … embed-server を起動し、.cli 中の
#                       `if (...) of <アドレス>:read-resource` に出てくる
#                       アドレスの存在有無だけを一括で調べる。設定は変えない。
#     パス 2 (apply)  … パス 1 の結果で if を「CLI へ渡す前に」解決し、
#                       採用された枝の操作だけを batch ～ run-batch に並べて
#                       流し込む。echo はバッチに入れられないので、
#                       [apply-cli] のログ行に振り替える。
#
#   結果として .cli ファイルは今までどおり if / echo 付きで書けるまま、
#   実際にサーバへ渡るスクリプトは操作だけのバッチになる。
#
#   ※ embed-server の起動は 2 回になる。起動時適用ではこれがそのまま
#     コンテナの起動時間 (数十秒) に乗る。probe パスは --std-out=discard で
#     ブートログを捨てているぶん apply パスより速いが、それでもゼロではない。
#     ガードを一切使わない .cli だけを流す構成なら probe パスは自動で省かれる。
#
#  ---------------------------------------------------------------------------
#  ★ .cli を書くときの制約 (プリプロセッサの仕様)
#  ---------------------------------------------------------------------------
#   1. ガードは次の 2 形式のみ。入れ子は不可。
#        if (outcome == success) of <アドレス>:read-resource
#        if (outcome != success) of <アドレス>:read-resource
#        ... / else / ... / end-if
#   2. ガードは batch を流す前に「まとめて」評価される。したがって
#      「同じ run の中で先行する操作が作成/削除したアドレス」を
#      ガードの条件に使ってはいけない (評価時点の状態しか見ていないため)。
#      現状の .cli はすべてこの条件を満たしている。
#   3. echo は [apply-cli] のログ行になる。サーバへは渡らない。
#   4. コメント行と空行はバッチから落とされる (.cli 側が唯一の記述場所)。
#
#   --no-batch を付けるとバッチで囲まずに逐次実行する。composite が通らない
#   操作に当たったときの切り分け専用で、通常の起動では使わない。
# =============================================================================
set -eu

EAP_HOME="/opt/eap"
EAP_CONFIG="standalone.xml"
CLI_DIR="/opt/app/cli"
BASE_DIR=""                       # jboss.server.base.dir (空 = $EAP_HOME/standalone)
WORK_ROOT="${TMPDIR:-/tmp}"       # 中間ファイルの置き場 (書き込み可能であること)
STD_OUT="echo"                    # apply パスの embed-server ブートログ
PATTERNS=""
USE_BATCH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --eap-home) EAP_HOME="$2"; shift 2 ;;
        --config)   EAP_CONFIG="$2"; shift 2 ;;
        --cli-dir)  CLI_DIR="$2"; shift 2 ;;
        --base-dir) BASE_DIR="$2"; shift 2 ;;
        --work-dir) WORK_ROOT="$2"; shift 2 ;;
        --std-out)  STD_OUT="$2"; shift 2 ;;
        --pattern)  PATTERNS="${PATTERNS} $2"; shift 2 ;;
        --no-batch) USE_BATCH=0; shift ;;
        *) echo "[apply-cli] ERROR: 不明な引数: $1" >&2; exit 2 ;;
    esac
done

die() { echo "[apply-cli] ERROR: $*" >&2; exit 2; }

[ -n "${PATTERNS}" ] || die "--pattern が 1 つも指定されていません"
[ -x "${EAP_HOME}/bin/jboss-cli.sh" ] || die "${EAP_HOME}/bin/jboss-cli.sh がありません"
case "${STD_OUT}" in echo|discard) : ;; *) die "--std-out は echo か discard です: ${STD_OUT}" ;; esac

# 書き換え対象の configuration。--base-dir を渡した場合はそちら (実行時)。
if [ -n "${BASE_DIR}" ]; then
    CONF_DIR="${BASE_DIR}/configuration"
else
    CONF_DIR="${EAP_HOME}/standalone/configuration"
fi
[ -f "${CONF_DIR}/${EAP_CONFIG}" ] || die "${CONF_DIR}/${EAP_CONFIG} がありません"
[ -w "${CONF_DIR}/${EAP_CONFIG}" ] || die "${CONF_DIR}/${EAP_CONFIG} へ uid=$(id -u) で書き込めません"

# -----------------------------------------------------------------------------
#  jboss-cli.sh の起動 (JAVA_OPTS はここで作り直す)
#
#   ★ 実行時に呼ぶうえで外せない処理
#     jboss-cli.sh は JAVA_OPTS をそのまま CLI の JVM へ渡す。起動時に走る
#     以上、アプリ用の JAVA_OPTS (JVM_OPTS_MODE=full では -javaagent を含む) が
#     そのまま効いてしまい、CLI まで計装されて遅くなるうえ無意味なスパンが出る。
#     JAVA_TOOL_OPTIONS も同じ理由で落とす (README「JBoss EAP 固有の注意点」)。
#     ここで CLI に必要なぶんだけを組み立て直す。
#
#       -Djboss.server.base.dir  embed-server の編集対象を作業領域へ向ける
#       -Djava.io.tmpdir         readonlyRootFilesystem=true では /tmp が無い
# -----------------------------------------------------------------------------
run_cli() {
    _opts="-Djava.io.tmpdir=${WORK_DIR}"
    if [ -n "${BASE_DIR}" ]; then
        _opts="${_opts} -Djboss.server.base.dir=${BASE_DIR}"
    fi
    JAVA_OPTS="${_opts}" JAVA_OPTS_APPEND= JAVA_TOOL_OPTIONS= \
        "${EAP_HOME}/bin/jboss-cli.sh" "$@"
}

# 適用対象を列挙する。パターン順 = 適用順 (00 -> 10 -> 20 ...)。
FILES=""
for p in ${PATTERNS}; do
    for f in "${CLI_DIR}"/${p}; do
        [ -f "$f" ] || continue
        FILES="${FILES} ${f}"
    done
done
[ -n "${FILES}" ] || die "${CLI_DIR} に対象の .cli がありません (${PATTERNS})"

mkdir -p "${WORK_ROOT}" 2>/dev/null || true
WORK_DIR="$(mktemp -d "${WORK_ROOT}/apply-cli.XXXXXX")" \
    || die "作業ディレクトリを ${WORK_ROOT} に作れません (--work-dir で書き込み可能な場所を指定してください)"
trap 'rm -rf "${WORK_DIR}"' EXIT

PROBE_CLI="${WORK_DIR}/probe.cli"
PROBE_OUT="${WORK_DIR}/probe.out"
PROBE_ADDRS="${WORK_DIR}/probe-addrs.txt"
STATE="${WORK_DIR}/probe-state.txt"
RUN_CLI="${WORK_DIR}/apply.cli"

TAB="$(printf '\t')"

# -----------------------------------------------------------------------------
#  小道具
# -----------------------------------------------------------------------------

# 先頭の空白を落とす (サブシェルを起こさないよう戻り値はグローバル変数)。
LINE_T=""
lead_trim() {
    _ws="${1%%[![:space:]]*}"
    LINE_T="${1#"${_ws}"}"
}

# 末尾の空白を落とす。
RTRIM=""
rtrim() {
    _s="$1"
    while : ; do
        case "$_s" in
            *' '|*"${TAB}") _s="${_s%?}" ;;
            *) break ;;
        esac
    done
    RTRIM="$_s"
}

# `if (outcome == success) of <アドレス>:read-resource` を分解する。
GUARD_OP=""
GUARD_ADDR=""
parse_guard() {
    rtrim "$1"; _g="${RTRIM}"; _where="$2"

    case "${_g}" in
        *'('*')'*' of '*':read-resource') : ;;
        *) die "${_where}: 未対応の if 構文です (対応形式は 'if (outcome ==|!= success) of <アドレス>:read-resource'): ${_g}" ;;
    esac

    _rest="${_g#*(}"          # outcome != success) of <アドレス>:read-resource
    _cond="${_rest%%)*}"      # outcome != success
    _tail="${_rest#*\)}"      #  of <アドレス>:read-resource

    lead_trim "${_tail}"; _tail="${LINE_T}"
    _tail="${_tail#of }"
    lead_trim "${_tail}"; _tail="${LINE_T}"
    rtrim "${_tail}";     _tail="${RTRIM}"
    GUARD_ADDR="${_tail%:read-resource}"
    [ -n "${GUARD_ADDR}" ] || die "${_where}: アドレスを読み取れません: ${_g}"

    case "$(printf '%s' "${_cond}" | tr -d '[:space:]')" in
        outcome==success) GUARD_OP="exists" ;;
        outcome!=success) GUARD_OP="absent" ;;
        *) die "${_where}: 未対応の条件式です (== / != のみ): (${_cond})" ;;
    esac
}

# probe 結果の参照。
PROBE_RESULT=""
probe_lookup() {
    PROBE_RESULT=""
    if   grep -Fxq "exists ${1}" "${STATE}" 2>/dev/null; then PROBE_RESULT="exists"
    elif grep -Fxq "absent ${1}" "${STATE}" 2>/dev/null; then PROBE_RESULT="absent"
    fi
}

# CRLF を落とした作業用コピーを作る。
SANITIZED=""
sanitize() {
    SANITIZED="${WORK_DIR}/src-$(basename "$1")"
    sed 's/\r$//' "$1" > "${SANITIZED}"
}

emit() { printf '%s\n' "$1" >> "${RUN_CLI}"; }

# -----------------------------------------------------------------------------
#  パス 1: .cli からガードのアドレスを集め、embed-server で存在有無を調べる
# -----------------------------------------------------------------------------
: > "${PROBE_ADDRS}"
for f in ${FILES}; do
    sanitize "$f"
    _lineno=0
    while IFS= read -r _raw || [ -n "${_raw}" ]; do
        _lineno=$((_lineno + 1))
        lead_trim "${_raw}"; rtrim "${LINE_T}"; _line="${RTRIM}"
        case "${_line}" in
            'if '*|'if('*)
                parse_guard "${_line}" "$(basename "$f"):${_lineno}"
                printf '%s\n' "${GUARD_ADDR}" >> "${PROBE_ADDRS}"
                ;;
        esac
    done < "${SANITIZED}"
done
sort -u "${PROBE_ADDRS}" -o "${PROBE_ADDRS}"

: > "${STATE}"
if [ -s "${PROBE_ADDRS}" ]; then
    _want="$(wc -l < "${PROBE_ADDRS}" | tr -d ' ')"
    echo "[apply-cli] パス 1 (probe): ${_want} 個のアドレスの存在有無を確認します"
    {
        # 設定は変えないので --std-out=discard (ブートログでマーカーを埋もれさせない)。
        echo "embed-server --server-config=${EAP_CONFIG} --std-out=discard"
        while IFS= read -r addr; do
            [ -n "${addr}" ] || continue
            echo "if (outcome == success) of ${addr}:read-resource"
            echo "    echo \"@@PROBE@@ exists ${addr}\""
            echo "else"
            echo "    echo \"@@PROBE@@ absent ${addr}\""
            echo "end-if"
        done < "${PROBE_ADDRS}"
        echo "stop-embedded-server"
    } > "${PROBE_CLI}"

    if ! run_cli --file="${PROBE_CLI}" > "${PROBE_OUT}" 2>&1; then
        echo "[apply-cli] ERROR: probe パスが失敗しました" >&2
        cat "${PROBE_OUT}" >&2
        exit 1
    fi
    sed -n 's/.*@@PROBE@@ //p' "${PROBE_OUT}" | sed 's/[[:space:]]*$//' > "${STATE}"

    # 調べたアドレスの数だけ結果が返っていること (取りこぼしを黙って進めない)。
    _got="$(wc -l < "${STATE}" | tr -d ' ')"
    [ "${_want}" = "${_got}" ] || {
        echo "[apply-cli] ERROR: probe の結果が不足しています (期待 ${_want} / 取得 ${_got})" >&2
        cat "${PROBE_OUT}" >&2
        exit 1
    }
else
    echo "[apply-cli] パス 1 (probe): ガードが無いため省略します"
fi

# -----------------------------------------------------------------------------
#  パス 2: if を解決し、batch ～ run-batch に操作を並べたスクリプトを組み立てる
# -----------------------------------------------------------------------------
: > "${RUN_CLI}"
emit "embed-server --server-config=${EAP_CONFIG} --std-out=${STD_OUT}"
if [ "${USE_BATCH}" -eq 1 ]; then
    emit "batch"
fi

OPS=0
for f in ${FILES}; do
    _name="$(basename "$f")"
    echo "[apply-cli] ${_name}"
    emit "# ---- ${_name} ----"
    sanitize "$f"

    _in_if=0            # 0=if の外 / 1=if 節の中 / 2=else 節の中
    _taken=1            # 直近の if の条件が成立したか
    _lineno=0
    while IFS= read -r _raw || [ -n "${_raw}" ]; do
        _lineno=$((_lineno + 1))
        _where="${_name}:${_lineno}"
        lead_trim "${_raw}"; rtrim "${LINE_T}"; _line="${RTRIM}"

        case "${_line}" in
            ''|'#'*)
                continue ;;
            'if '*|'if('*)
                [ "${_in_if}" -eq 0 ] || die "${_where}: if の入れ子は未対応です"
                parse_guard "${_line}" "${_where}"
                probe_lookup "${GUARD_ADDR}"
                [ -n "${PROBE_RESULT}" ] || die "${_where}: probe 結果がありません: ${GUARD_ADDR}"
                if [ "${GUARD_OP}" = "${PROBE_RESULT}" ]; then _taken=1; else _taken=0; fi
                _in_if=1
                continue ;;
            'else')
                [ "${_in_if}" -eq 1 ] || die "${_where}: 対応する if の無い else です"
                _in_if=2
                continue ;;
            'end-if')
                [ "${_in_if}" -ne 0 ] || die "${_where}: 対応する if の無い end-if です"
                _in_if=0; _taken=1
                continue ;;
        esac

        # 採用されなかった枝は捨てる。
        if [ "${_in_if}" -eq 1 ] && [ "${_taken}" -eq 0 ]; then continue; fi
        if [ "${_in_if}" -eq 2 ] && [ "${_taken}" -eq 1 ]; then continue; fi

        # echo はバッチに積めない。[apply-cli] のログ行へ振り替える。
        case "${_line}" in
            'echo '*|'echo"'*)
                _msg="${_line#echo}"
                lead_trim "${_msg}"; _msg="${LINE_T}"
                rtrim "${_msg}";     _msg="${RTRIM}"
                case "${_msg}" in '"'*'"') _msg="${_msg#\"}"; _msg="${_msg%\"}" ;; esac
                printf '[apply-cli]     %s\n' "${_msg}"
                continue ;;
        esac

        emit "${_raw}"
        # 継続行 (末尾が \) はまだ 1 操作の途中なので数えない。
        case "${_line}" in
            *\\) : ;;
            *) OPS=$((OPS + 1)) ;;
        esac
    done < "${SANITIZED}"

    [ "${_in_if}" -eq 0 ] || die "${_name}: end-if で閉じていない if があります"
done

if [ "${USE_BATCH}" -eq 1 ]; then
    emit "run-batch"
fi
emit "stop-embedded-server"

[ "${OPS}" -gt 0 ] || die "バッチに入れる操作が 1 つもありません (すべてのガードが不成立)"

# -----------------------------------------------------------------------------
#  パス 2 の実行
# -----------------------------------------------------------------------------
if [ "${USE_BATCH}" -eq 1 ]; then
    echo "[apply-cli] パス 2 (apply): ${OPS} 操作を batch ～ run-batch で適用します"
else
    echo "[apply-cli] パス 2 (apply): ${OPS} 操作を逐次適用します (--no-batch)"
fi
echo "[apply-cli] --- 生成された CLI スクリプト ---"
sed 's/^/[apply-cli] | /' "${RUN_CLI}"
echo "[apply-cli] --------------------------------"

run_cli --file="${RUN_CLI}"

# embed-server が作った履歴は残さない。
#   - 起動時適用: 履歴が残っていると続く standalone.sh の本ブートが
#                 standalone_xml_history/current の rename を試みる。消して
#                 おけば「履歴の無い状態からの初回ブート」になり発生しない。
#   - ビルド時に使う場合: 残すと overlayfs の下位レイヤになり、起動時の rename が
#                 原理的に通らなくなる (WFLYCTL0056 / WFLYCTL0414 が毎起動出続ける)。
rm -rf "${CONF_DIR}/standalone_xml_history"

echo "[apply-cli] 完了"

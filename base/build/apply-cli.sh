#!/bin/sh
# =============================================================================
#  base/build/apply-cli.sh   (ビルド時のみ実行)
#
#   embed-server で standalone.xml をオフラインのまま書き換える。
#   front / back の Containerfile からも同じスクリプトを呼べるよう、
#   適用対象を --pattern で指定する形にしてある。
#
#     apply-cli.sh --eap-home /opt/eap --config standalone.xml \
#                  --cli-dir /opt/app/cli --pattern '0*.cli' --pattern '1*.cli'
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
#   という性質になる。ビルドが通った = 設定は全部入った、が保証される。
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
#     パス 2 (apply)  … パス 1 の結果で if を「ビルド時に」解決し、
#                       採用された枝の操作だけを batch ～ run-batch に並べて
#                       流し込む。echo はバッチに入れられないので、
#                       ビルドログへの出力に振り替える。
#
#   結果として .cli ファイルは今までどおり if / echo 付きで書けるまま、
#   実際にサーバへ渡るスクリプトは操作だけのバッチになる。
#
#   ※ embed-server の起動はビルド時に 2 回になるが、これはイメージビルドの
#     中だけの話で、実行時 (standalone.sh) のブート回数は 1 回のまま変わらない。
#     base/Containerfile が CLI をビルド時に適用している理由
#     (standalone_xml_history の rename 問題) には一切影響しない。
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
#   3. echo はビルドログ行になる。サーバへは渡らない。
#   4. コメント行と空行はバッチから落とされる (.cli 側が唯一の記述場所)。
#
#   --no-batch を付けるとバッチで囲まずに逐次実行する。composite が通らない
#   操作に当たったときの切り分け専用で、通常のビルドでは使わない。
# =============================================================================
set -eu

EAP_HOME="/opt/eap"
EAP_CONFIG="standalone.xml"
CLI_DIR="/opt/app/cli"
PATTERNS=""
USE_BATCH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --eap-home) EAP_HOME="$2"; shift 2 ;;
        --config)   EAP_CONFIG="$2"; shift 2 ;;
        --cli-dir)  CLI_DIR="$2"; shift 2 ;;
        --pattern)  PATTERNS="${PATTERNS} $2"; shift 2 ;;
        --no-batch) USE_BATCH=0; shift ;;
        *) echo "[apply-cli] ERROR: 不明な引数: $1" >&2; exit 2 ;;
    esac
done

die() { echo "[apply-cli] ERROR: $*" >&2; exit 2; }

[ -n "${PATTERNS}" ] || die "--pattern が 1 つも指定されていません"
[ -x "${EAP_HOME}/bin/jboss-cli.sh" ] || die "${EAP_HOME}/bin/jboss-cli.sh がありません"

# 適用対象を列挙する。パターン順 = 適用順 (00 -> 10 -> 20 ...)。
FILES=""
for p in ${PATTERNS}; do
    for f in "${CLI_DIR}"/${p}; do
        [ -f "$f" ] || continue
        FILES="${FILES} ${f}"
    done
done
[ -n "${FILES}" ] || die "${CLI_DIR} に対象の .cli がありません (${PATTERNS})"

WORK_DIR="$(mktemp -d /tmp/apply-cli.XXXXXX)"
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

    if ! "${EAP_HOME}/bin/jboss-cli.sh" --file="${PROBE_CLI}" > "${PROBE_OUT}" 2>&1; then
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
emit "embed-server --server-config=${EAP_CONFIG} --std-out=echo"
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

        # echo はバッチに積めない。ビルドログへ振り替える。
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

"${EAP_HOME}/bin/jboss-cli.sh" --file="${RUN_CLI}"

# ビルド時に作られた履歴はイメージに残さない。
# 残すと overlayfs の下位レイヤになり、起動時の rename が原理的に通らなくなる
# (WFLYCTL0056 / WFLYCTL0414 が毎起動出続ける)。
rm -rf "${EAP_HOME}/standalone/configuration/standalone_xml_history"

echo "[apply-cli] 完了"

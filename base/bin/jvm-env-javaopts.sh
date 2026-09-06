#!/bin/sh
# =============================================================================
#  base/bin/jvm-env-javaopts.sh
#
#   JVM 関連の環境変数を集約する共通シェル ―― JAVA_OPTS を直接組み立てる版。
#   jvm-env.sh (JAVA_OPTS_APPEND 版) と 1 対 1 の代替関係にあり、
#   entrypoint.sh が JVM_OPTS_MODE を見てどちらか一方だけを source する。
#
#       JVM_OPTS_MODE=append (既定)  entrypoint.sh -> jvm-env.sh
#       JVM_OPTS_MODE=full           entrypoint.sh -> jvm-env-javaopts.sh (このファイル)
#
#   どちらのモードでも OpenTelemetry ぶんは otel-env.sh をそのまま使う。
#   OTEL_* の導出と命名規約はモードによって一切変わらない。
#
#       entrypoint.sh
#         └─ source jvm-env-javaopts.sh   … ヒープ / GC / ロケール / TLS など
#              └─ source otel-env.sh      … OTEL_* と -javaagent
#
#   ---------------------------------------------------------------------------
#   このファイルが背負う責務 = 「消える既定値を全部自分で持つ」
#   ---------------------------------------------------------------------------
#   standalone.conf は JAVA_OPTS をこうとしか組み立てない。
#
#       if [ "x$JAVA_OPTS" = "x" ]; then
#           JAVA_OPTS="$JBOSS_JAVA_SIZING -Djava.net.preferIPv4Stack=true"
#           JAVA_OPTS="$JAVA_OPTS -Djboss.modules.system.pkgs=$JBOSS_MODULES_SYSTEM_PKGS -Djava.awt.headless=true"
#       else
#           echo "JAVA_OPTS already set in environment; overriding default settings with values: $JAVA_OPTS"
#       fi
#
#   つまり外から JAVA_OPTS を渡した瞬間に else 側へ落ち、EAP が前提にしている
#   既定値は 1 つも付かない。JAVA_OPTS 版を採るなら、消えた既定値を
#   こちら側で漏れなく再現するのが必須条件になる (下の 4. と 5.)。
#
#   ★ 最も危険なのは -Djboss.modules.system.pkgs が落ちること。
#     JBOSS_MODULES_SYSTEM_PKGS 環境変数そのものは guard の外で既定値が入るので
#     「変数はある」。しかし -D に変換しているのは guard の中だけなので、
#     JAVA_OPTS を渡すとこの 1 行だけが静かに消える。
#     こうなると JBoss Modules のクラスローダ隔離から
#     io.opentelemetry.javaagent が外れず、計装対象クラスから
#     エージェントのクラスが見えなくなる。
#     「起動はするのに X-Ray に何も出ない」という一番気づきにくい壊れ方をする。
#
#   ---------------------------------------------------------------------------
#   standalone.conf 側に設定を置かない
#   ---------------------------------------------------------------------------
#   このモードでは standalone.conf 経由の設定を一切使わない。
#   イメージに焼いてある standalone.conf.append (JAVA_OPTS_APPEND を JAVA_OPTS へ
#   連結するフック) も、最後に JAVA_OPTS_APPEND を空にすることで確実に no-op にする
#   (9. 参照)。JVM に渡る値はこのファイルだけを読めば全部わかる、という状態を保つ。
#
#   ---------------------------------------------------------------------------
#   単体確認
#   ---------------------------------------------------------------------------
#       sh base/bin/jvm-env-javaopts.sh --print
#         → otel-env.sh の要約 + 組み立て後の JAVA_OPTS を表示して終わる。
#           append 版との差分を見たいときは JVM_OPTS_MODE を変えて起動し、
#           起動ログの "JAVA_OPTS (final)" 行と、append 版の
#           "JAVA_OPTS_APPEND" 行を突き合わせる。
# =============================================================================

#  致命的エラーは jvm_die() 経由で明示的に落とす (otel-env.sh と同じ流儀)。
#  終了コードは共通シェルの帯 (30 番台) を使う。40 番台は otel-env.sh の担当。
jvm_log() { echo "[jvm-env:javaopts] $*"; }
jvm_die() { echo "[jvm-env:javaopts] ERROR: $1" >&2; exit "${2:-30}"; }

# -----------------------------------------------------------------------------
# 0. 外から渡された JAVA_OPTS の退避
#
#    このモードでは JAVA_OPTS をこのファイルが組み立てる。とはいえ
#    タスク定義側で JAVA_OPTS を渡してくる運用もあり得るので、捨てずに
#    最後尾へ回して「運用の指定が既定値に勝つ」形にしておく
#    (JVM は同じオプションが複数あれば後勝ち)。
# -----------------------------------------------------------------------------
_inherited_java_opts="${JAVA_OPTS:-}"
if [ -n "${_inherited_java_opts}" ]; then
    jvm_log "外から渡された JAVA_OPTS を検出しました。既定値の後ろへ連結します: ${_inherited_java_opts}"
fi
JAVA_OPTS=""

# -----------------------------------------------------------------------------
# 1. ロケール / タイムゾーン
#    ログのタイムスタンプと X-Ray のセグメント時刻をずらさないため揃える。
#    (append 版と同じ。モードで挙動を変えない)
# -----------------------------------------------------------------------------
: "${TZ:=Asia/Tokyo}"
: "${LANG:=ja_JP.UTF-8}"
export TZ LANG

# -----------------------------------------------------------------------------
# 2. ヒープ / Metaspace  (standalone.conf の JBOSS_JAVA_SIZING 相当)
#
#    EAP の既定は
#      -Xms1303m -Xmx1303m -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m
#    という絶対値。コンテナではタスクメモリを変えるたびに追随させる必要があるので
#    ヒープだけ割合指定へ置き換える。Metaspace は EAP 既定値をそのまま踏襲する
#    (割合指定の対象外。落とすと Metaspace が事実上無制限になる)。
# -----------------------------------------------------------------------------
: "${JVM_INITIAL_RAM_PERCENTAGE:=50.0}"
: "${JVM_MAX_RAM_PERCENTAGE:=75.0}"
: "${JVM_METASPACE_SIZE:=96M}"
: "${JVM_MAX_METASPACE_SIZE:=256M}"
: "${JBOSS_JAVA_SIZING:=-XX:InitialRAMPercentage=${JVM_INITIAL_RAM_PERCENTAGE} -XX:MaxRAMPercentage=${JVM_MAX_RAM_PERCENTAGE} -XX:MetaspaceSize=${JVM_METASPACE_SIZE} -XX:MaxMetaspaceSize=${JVM_MAX_METASPACE_SIZE}}"
#    ※ このモードでは standalone.conf が JBOSS_JAVA_SIZING を読まない
#      (guard の中でしか参照されない) ため、export は起動ログ表示のためだけ。
#      実際に効かせているのは 4-1. で JAVA_OPTS へ入れているぶん。
export JBOSS_JAVA_SIZING

# -----------------------------------------------------------------------------
# 3. OpenTelemetry (OTEL_* と -javaagent) を先に確定させる
#
#    ★ 順序が重要。otel-env.sh は
#        - JBOSS_MODULES_SYSTEM_PKGS へ io.opentelemetry.javaagent を追加する
#        - JAVA_OPTS_APPEND へ -javaagent とエージェントログ抑制の -D を積む
#      という 2 つをやる。どちらも後で JAVA_OPTS に取り込む必要があるため、
#      JAVA_OPTS を組み立てる前に source しておく。
#
#    APP_SERVICE / APP_ROLE の規約違反はここで停止する (append 版と同じ)。
# -----------------------------------------------------------------------------
# shellcheck source=/dev/null
. "${APP_BIN_DIR:-/opt/app/bin}/otel-env.sh"

# -----------------------------------------------------------------------------
# 4. standalone.conf の既定値の再現
#
#    ここが JAVA_OPTS 版の本体。standalone.conf の
#    「JAVA_OPTS が空のときだけ」ブロックと同じものを、同じ順序で組み立てる。
# -----------------------------------------------------------------------------

# 4-1. ヒープ / Metaspace
JAVA_OPTS="${JBOSS_JAVA_SIZING}"

# 4-2. IPv6 が無効な VPC で名前解決に無駄な往復をしないようにする。
#      (standalone.conf 既定。append 版でも同じ値を付けている)
JAVA_OPTS="${JAVA_OPTS} -Djava.net.preferIPv4Stack=true"

# 4-3. ★ JBoss Modules のシステムパッケージ。ADOT Java Agent を動かすための必須指定。
#      3. で otel-env.sh が org.jboss.byteman (EAP 既定) に
#      io.opentelemetry.javaagent を足した結果をそのまま -D に変換する。
JAVA_OPTS="${JAVA_OPTS} -Djboss.modules.system.pkgs=${JBOSS_MODULES_SYSTEM_PKGS:-org.jboss.byteman}"

# 4-4. ヘッドレス。X サーバの無いコンテナで AWT を初期化させない。
JAVA_OPTS="${JAVA_OPTS} -Djava.awt.headless=true"

# -----------------------------------------------------------------------------
# 5. modular JDK 用の --add-exports / --add-opens
#
#    これは standalone.conf ではなく standalone.sh (bin/common.sh の
#    setDefaultModularJvmOptions) が付けている既定値で、
#    「JAVA_OPTS に --add-modules が含まれていなければ既定一式を足す」
#    という作りになっている。つまり JAVA_OPTS を渡しただけでは消えない。
#
#    それでもこのモードでは既定で明示する (explicit)。
#    「JVM に渡る値はこのファイルを読めば全部わかる」を優先するため。
#    一覧の最後に --add-modules=java.se を含めるので standalone.sh 側は
#    何も足さなくなり、二重に付くこともない。
#
#      JVM_MODULAR_OPTS_MODE=explicit (既定) … 下の一覧を JAVA_OPTS に入れる
#      JVM_MODULAR_OPTS_MODE=delegate        … 入れない。standalone.sh に任せる
#
#    ★ delegate は「使っている EAP の版が、ここに書いていない --add-opens を
#      必要としていた」場合の逃げ道。起動直後に IllegalAccessError や
#      InaccessibleObjectException が出たらまず delegate を試すこと。
#      一覧は EAP 8.1 / WildFly 35 系の setDefaultModularJvmOptions に合わせてある。
#      個別に足したいだけなら JVM_MODULAR_OPTS を丸ごと差し替えてもよい。
# -----------------------------------------------------------------------------
: "${JVM_MODULAR_OPTS_MODE:=explicit}"

if [ -z "${JVM_MODULAR_OPTS:-}" ]; then
    # iiop-openjdk サブシステムが要求する
    JVM_MODULAR_OPTS="--add-exports=java.desktop/sun.awt=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-exports=jdk.unsupported/sun.misc=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-exports=jdk.unsupported/sun.reflect=ALL-UNNAMED"
    # Hibernate / Javassist などがリフレクションで触る
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.base/java.lang=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.base/java.lang.invoke=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.base/java.lang.reflect=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.base/java.io=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.base/java.security=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.base/java.util=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.base/java.util.concurrent=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.management/javax.management=ALL-UNNAMED"
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-opens=java.naming/javax.naming=ALL-UNNAMED"
    # ★ この 1 つがあると standalone.sh 側は既定一式を足さなくなる (= 二重防止)
    JVM_MODULAR_OPTS="${JVM_MODULAR_OPTS} --add-modules=java.se"
fi

case "${JVM_MODULAR_OPTS_MODE}" in
    explicit)
        JAVA_OPTS="${JAVA_OPTS} ${JVM_MODULAR_OPTS}"
        ;;
    delegate)
        jvm_log "JVM_MODULAR_OPTS_MODE=delegate: --add-opens 一式は standalone.sh に任せます"
        ;;
    *)
        jvm_die "JVM_MODULAR_OPTS_MODE は explicit か delegate です: ${JVM_MODULAR_OPTS_MODE}" 32
        ;;
esac

# -----------------------------------------------------------------------------
# 6. 本構成の共通 JVM オプション
#    (append 版 jvm-env.sh の 3. と同じ内容。片方だけ直さないこと)
# -----------------------------------------------------------------------------

# 一時領域。readonlyRootFilesystem=true でも書ける場所へ寄せる。
JAVA_OPTS="${JAVA_OPTS} -Djava.io.tmpdir=${EAP_TMP_DIR:-${EAP_RUN_DIR:-/run/eap}/tmp}"

# DNS キャッシュ。ALB / Aurora / ElastiCache のエンドポイントはフェイルオーバ時に
# IP が変わる。JVM 既定 (-1 = 永久キャッシュ) のままだと切り替わりに追従できず、
# 「X-Ray 上は接続タイムアウトのスパンだけが延々出る」状態になる。
: "${JVM_DNS_TTL:=30}"
: "${JVM_DNS_NEGATIVE_TTL:=5}"
JAVA_OPTS="${JAVA_OPTS} -Dnetworkaddress.cache.ttl=${JVM_DNS_TTL}"
JAVA_OPTS="${JAVA_OPTS} -Dnetworkaddress.cache.negative.ttl=${JVM_DNS_NEGATIVE_TTL}"

# 外部 SLB との HTTPS 通信で使うトラストストア。
# 別プロジェクト (Container_ExtraSLB_JVM_https_outbounds) が作った
# トラストストアをイメージに焼き込んでいる場合のみ有効化する。
if [ -n "${EXTRASLB_TRUSTSTORE_PATH:-}" ] && [ -r "${EXTRASLB_TRUSTSTORE_PATH}" ]; then
    JAVA_OPTS="${JAVA_OPTS} -Djavax.net.ssl.trustStore=${EXTRASLB_TRUSTSTORE_PATH}"
    JAVA_OPTS="${JAVA_OPTS} -Djavax.net.ssl.trustStorePassword=${EXTRASLB_TRUSTSTORE_PASSWORD:-changeit}"
    JAVA_OPTS="${JAVA_OPTS} -Djavax.net.ssl.trustStoreType=${EXTRASLB_TRUSTSTORE_TYPE:-PKCS12}"
    jvm_log "外部 SLB 用トラストストアを適用します: ${EXTRASLB_TRUSTSTORE_PATH}"
fi

# -----------------------------------------------------------------------------
# 7. otel-env.sh が積んだぶんを取り込む
#
#      -javaagent:/opt/aws/aws-opentelemetry-agent.jar
#      -Dio.opentelemetry.javaagent.slf4j.simpleLogger.log.<...>=error  など
#
#    otel-env.sh は append 版と共有しているので JAVA_OPTS_APPEND に積んでくる。
#    このモードではそれをここで JAVA_OPTS へ移し、9. で空にする。
# -----------------------------------------------------------------------------
if [ -n "${JAVA_OPTS_APPEND:-}" ]; then
    JAVA_OPTS="${JAVA_OPTS} ${JAVA_OPTS_APPEND}"
fi

# -----------------------------------------------------------------------------
# 8. 運用からの追記フック (デバッガ接続など) と、外から来た JAVA_OPTS
#    後ろに置くことで、同じオプションがぶつかったときに運用側の指定が勝つ。
# -----------------------------------------------------------------------------
if [ -n "${APP_EXTRA_JAVA_OPTS:-}" ]; then
    JAVA_OPTS="${JAVA_OPTS} ${APP_EXTRA_JAVA_OPTS}"
fi
if [ -n "${_inherited_java_opts}" ]; then
    JAVA_OPTS="${JAVA_OPTS} ${_inherited_java_opts}"
fi

export JAVA_OPTS
unset _inherited_java_opts

# -----------------------------------------------------------------------------
# 9. standalone.conf 側のフックを無効化する
#
#    イメージには standalone.conf.append (JAVA_OPTS_APPEND を JAVA_OPTS へ連結する
#    フック) が焼き込まれている。7. で取り込み済みなので、空にしておかないと
#    同じ -javaagent が 2 回入る。-javaagent の重複はエージェントの二重ロード
#    = スパンの二重計上に直結するため、ここは必ず空にする。
#    (unset ではなく空文字。標準の "x${JAVA_OPTS_APPEND:-}" != "x" 判定は
#     どちらでも false になるが、export したまま空にしておく方が
#     「意図的に空」だと読める)
# -----------------------------------------------------------------------------
JAVA_OPTS_APPEND=""
export JAVA_OPTS_APPEND

# -----------------------------------------------------------------------------
# 10. PRESERVE_JAVA_OPTS (任意)
#
#     true にすると standalone.conf / standalone.sh は JAVA_OPTS に一切触らなくなる。
#     このファイルが組み立てた値をそのまま JVM へ渡したい場合に使う。
#     ★ JVM_MODULAR_OPTS_MODE=delegate と併用してはいけない。
#       delegate は standalone.sh の補完が前提なので、両方入れると
#       --add-opens が 1 つも付かなくなる。ここで落として気づけるようにする。
# -----------------------------------------------------------------------------
: "${JVM_PRESERVE_JAVA_OPTS:=false}"
if [ "${JVM_PRESERVE_JAVA_OPTS}" = "true" ]; then
    if [ "${JVM_MODULAR_OPTS_MODE}" = "delegate" ]; then
        jvm_die "JVM_PRESERVE_JAVA_OPTS=true と JVM_MODULAR_OPTS_MODE=delegate は併用できません (--add-opens が一切付かなくなります)" 33
    fi
    PRESERVE_JAVA_OPTS=true
    export PRESERVE_JAVA_OPTS
    jvm_log "PRESERVE_JAVA_OPTS=true: standalone.sh による JAVA_OPTS の加工を止めます"
fi

# -----------------------------------------------------------------------------
# 11. 起動ログ
#     ECS では stdout (awslogs) だけが手掛かりになる。JAVA_OPTS 版は
#     「何が付いていて何が付いていないか」がそのまま事故に直結するので、
#     組み立て結果は必ず全文を出す。
# -----------------------------------------------------------------------------
jvm_print_summary() {
    jvm_log "--------------- JVM configuration (JAVA_OPTS mode) ---------------"
    jvm_log "  JVM_OPTS_MODE          = full (このファイルが JAVA_OPTS を全部組み立てる)"
    jvm_log "  JBOSS_JAVA_SIZING      = ${JBOSS_JAVA_SIZING}"
    jvm_log "  JVM_MODULAR_OPTS_MODE  = ${JVM_MODULAR_OPTS_MODE}"
    jvm_log "  PRESERVE_JAVA_OPTS     = ${PRESERVE_JAVA_OPTS:-false}"
    jvm_log "  JAVA_OPTS_APPEND       = (意図的に空。standalone.conf のフックは no-op)"
    jvm_log "  JAVA_OPTS (final)      = ${JAVA_OPTS}"
    jvm_log "------------------------------------------------------------------"
}

# 単体実行時 (sh jvm-env-javaopts.sh --print) は内容を表示して終わる。
# source されたときは何も出さず、呼び出し元が jvm_print_summary を呼ぶ。
case "${1:-}" in
    --print) jvm_print_summary ;;
esac

#!/bin/sh
# =============================================================================
#  scripts/gen-taskdefs.sh — 4 サービスぶんの ECS タスク定義を生成する
#
#    ./scripts/gen-taskdefs.sh prd shopdemo
#    -> ecs/generated/intra-api-prd.json
#       ecs/generated/intra-web-prd.json
#       ecs/generated/inter-api-prd.json
#       ecs/generated/sf-api-prd.json
#
#  ★ テンプレートを 1 本に保つ理由
#    タスク定義を 4 本手書きすると、必ずどこかで APP_SERVICE と
#    ECS サービス名がずれる。ずれると X-Ray のサービスマップ上で
#    ノードが分裂し、しかも「間違っているように見えない」ため気づけない。
#    テンプレート置換にしておけば、ずれようがない。
#
#  生成後、<...> のプレースホルダを環境の値に置換してから
#  aws ecs register-task-definition --cli-input-json file://... する。
# =============================================================================
set -eu

cd "$(dirname "$0")/.."

ENV_NAME="${1:-dev}"
NAMESPACE="${2:-shopdemo}"

case "${ENV_NAME}" in
    local|dev|stg|prd) ;;
    *) echo "ERROR: 環境名は local|dev|stg|prd のいずれか (指定値: ${ENV_NAME})" >&2; exit 2 ;;
esac

TEMPLATE="ecs/taskdef.template.json"
OUT_DIR="ecs/generated"
[ -f "${TEMPLATE}" ] || { echo "ERROR: ${TEMPLATE} がありません" >&2; exit 2; }
mkdir -p "${OUT_DIR}"

# ★ ここが唯一の許可リスト。base/bin/otel-env.sh の case 文と必ず一致させること。
SERVICES="intra-api intra-web inter-api sf-api"

for svc in ${SERVICES}; do
    out="${OUT_DIR}/${svc}-${ENV_NAME}.json"
    sed -e "s/__SERVICE__/${svc}/g" \
        -e "s/__ENV__/${ENV_NAME}/g" \
        -e "s/__NAMESPACE__/${NAMESPACE}/g" \
        "${TEMPLATE}" > "${out}"
    echo "generated: ${out}   (service.name = ${svc}-front / ${svc}-back)"
done

cat <<MSG

---------------------------------------------------------------------
 次の手順
---------------------------------------------------------------------
 1. 生成された JSON の <...> を環境の値に置換する
      <account-id> <region> <tag> <aurora-cluster> <valkey-cluster> ...

 2. ADOT Collector の設定を Secrets Manager に登録する
      aws secretsmanager create-secret \\
        --name /adot/collector-config/${ENV_NAME} \\
        --secret-string file://otel/collector-xray.yaml
    その ARN を各 JSON の <adot-collector-config-secret> に入れる。

 3. タスクロールに X-Ray への書き込み権限を付ける
      AWSXRayDaemonWriteAccess (PutTraceSegments / PutTelemetryRecords /
      GetSamplingRules / GetSamplingTargets / GetSamplingStatisticSummaries)
    ※ executionRoleArn ではなく taskRoleArn に付けること。
    ※ GetSampling* が無いと OTEL_TRACES_SAMPLER=xray が動かず
      全量送信にフォールバックする (料金が跳ねる形で表面化する)。

 4. 登録
      aws ecs register-task-definition --cli-input-json file://${OUT_DIR}/intra-api-${ENV_NAME}.json

 5. ECS サービス名は必ず APP_SERVICE と同じ名前にする
      intra-api / intra-web / inter-api / sf-api
---------------------------------------------------------------------
MSG

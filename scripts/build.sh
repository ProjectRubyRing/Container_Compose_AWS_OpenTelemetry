#!/bin/sh
# =============================================================================
#  scripts/build.sh — WAR とコンテナイメージをビルドする
#
#    ./scripts/build.sh                 # WAR -> base -> front/back
#    ./scripts/build.sh --wildfly       # EAP zip が無い環境 (ローカル検証)
#    ./scripts/build.sh --skip-war      # WAR は既にある
#
#  ★ ビルド順序に意味がある
#    front/back は base イメージを FROM に指定するため、base を先に作る。
#    base に ADOT Agent / 共通シェル / データソース定義が入るので、
#    front/back 側は WAR と固有 CLI だけを足せばよい。
# =============================================================================
set -eu

cd "$(dirname "$0")/.."

SERVER_SOURCE=zip
SKIP_WAR=0
BASE_TAG="${BASE_IMAGE_TAG:-app-eap-base:1.0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --wildfly)  SERVER_SOURCE=wildfly; shift ;;
        --image)    SERVER_SOURCE=image; shift ;;
        --skip-war) SKIP_WAR=1; shift ;;
        *) echo "usage: $0 [--wildfly|--image] [--skip-war]" >&2; exit 2 ;;
    esac
done

# -----------------------------------------------------------------------------
# 1. WAR のビルド
#    ホストに Maven が無くてもよいよう、コンテナ内でビルドする。
# -----------------------------------------------------------------------------
if [ "${SKIP_WAR}" = "0" ]; then
    echo "==> [1/3] WAR をビルドします"
    mkdir -p dist
    docker run --rm \
        -v "$(pwd)/sample-app:/src:ro" \
        -v "$(pwd)/dist:/out" \
        -v "eap-otel-m2:/root/.m2" \
        -w /work \
        docker.io/library/maven:3.9.9-eclipse-temurin-21 \
        sh -c 'cp -r /src/. /work/ && mvn -B -q clean package && cp target/app.war /out/app.war'
    ls -l dist/app.war
fi

# -----------------------------------------------------------------------------
# 2. ベースイメージ
# -----------------------------------------------------------------------------
echo "==> [2/3] ベースイメージをビルドします (SERVER_SOURCE=${SERVER_SOURCE})"
if [ "${SERVER_SOURCE}" = "zip" ] && [ ! -f vendor/jboss-eap-8.1.0.zip ]; then
    echo "ERROR: vendor/jboss-eap-8.1.0.zip がありません。" >&2
    echo "       EAP 8.1 の zip は Red Hat カスタマーポータルから取得して vendor/ に置いてください。" >&2
    echo "       ローカル検証だけなら --wildfly を指定してください。" >&2
    exit 2
fi

docker build \
    -f base/Containerfile \
    -t "${BASE_TAG}" \
    --build-arg "SERVER_SOURCE=${SERVER_SOURCE}" \
    ${ADOT_JAVA_AGENT_VERSION:+--build-arg ADOT_JAVA_AGENT_VERSION=${ADOT_JAVA_AGENT_VERSION}} \
    .

# -----------------------------------------------------------------------------
# 3. front / back
# -----------------------------------------------------------------------------
echo "==> [3/3] front / back イメージをビルドします"
docker build -f front/Containerfile -t "${IMAGE_PREFIX:-local}/eap-front:${IMAGE_TAG:-dev}" \
    --build-arg "BASE_IMAGE=${BASE_TAG}" \
    --build-arg "APP_SOURCE=${FRONT_WAR:-dist/app.war}" .
docker build -f back/Containerfile -t "${IMAGE_PREFIX:-local}/eap-back:${IMAGE_TAG:-dev}" \
    --build-arg "BASE_IMAGE=${BASE_TAG}" \
    --build-arg "APP_SOURCE=${BACK_WAR:-dist/app.war}" .

echo "==> 完了"
docker images | grep -E "eap-(front|back)|app-eap-base" || true

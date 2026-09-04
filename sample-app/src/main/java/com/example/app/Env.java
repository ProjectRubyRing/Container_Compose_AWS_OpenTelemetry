package com.example.app;

/**
 * 環境変数の読み出しヘルパー。
 *
 * <p>接続先はすべて環境変数で与える。これは単なる設定の外出しではなく、
 * <b>X-Ray のサービスマップのノード名を決める仕組みの一部</b>である。
 *
 * <p>{@code base/bin/otel-env.sh} は DB_HOST / VALKEY_HOST / REPORT_ALB_HOST /
 * EXTERNAL_SLB_HOST / BACKEND_HOST を読み取り、
 * {@code OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING} を組み立てる。
 * アプリが接続に使うホスト名と、peer.service マッピングのキーが
 * 同じ環境変数から来るため、両者がずれることが構造的に起きない。
 *
 * <p>逆に言えば、アプリ側でホスト名をハードコードしたり別の変数から取ったりすると
 * マッピングが外れ、X-Ray のノード名が FQDN のまま出るようになる。
 */
final class Env {
    private Env() {
    }

    static String get(String name, String defaultValue) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? defaultValue : v;
    }

    static int getInt(String name, int defaultValue) {
        try {
            return Integer.parseInt(get(name, Integer.toString(defaultValue)));
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }

    /** front / back のどちらとして動いているか。 */
    static String role() {
        return get("APP_ROLE", "front");
    }

    /** intra-api / intra-web / inter-api / sf-api。 */
    static String service() {
        return get("APP_SERVICE", "unknown");
    }

    /** X-Ray / Jaeger 上の自分の名前。otel-env.sh が決めた値と一致する。 */
    static String serviceName() {
        return get("OTEL_SERVICE_NAME", service() + "-" + role());
    }
}

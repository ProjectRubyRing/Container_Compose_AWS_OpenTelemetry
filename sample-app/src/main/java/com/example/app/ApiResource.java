package com.example.app;

import jakarta.annotation.Resource;
import jakarta.enterprise.context.RequestScoped;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import javax.sql.DataSource;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.SqsClientBuilder;
import software.amazon.awssdk.services.sqs.model.SendMessageRequest;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;

/**
 * 検証対象の全通信経路を叩くエンドポイント群。
 *
 * <p><b>ここに OpenTelemetry の API は 1 行も出てこない。</b>
 * スパンの生成・親子付け・コンテキスト伝播はすべて ADOT Java Agent が
 * バイトコード計装で行う。アプリ側がやるべきことは
 * 「エージェントが計装できるクライアントを普通に使う」ことだけ。
 *
 * <p>経路とスパンの対応:
 * <pre>
 *   GET  /api/health    ヘルスチェック            … Collector 側で捨てる
 *   GET  /api/db        Aurora Serverless v2      … JDBC スパン (db.system=mysql)
 *   GET  /api/cache     ElastiCache for Valkey    … Redis スパン (db.system=redis)
 *   GET  /api/back      front -> back             … HTTP クライアント + サーバスパン
 *   GET  /api/report    ALB -> 帳票 EC2           … HTTP クライアントスパン
 *   GET  /api/external  外部 SLB (VPC 外)         … HTTP クライアントスパン
 *   POST /api/sqs       SQS -> Lambda -> ALB -> back … PRODUCER スパン
 *   POST /api/from-lambda  Lambda からの受信      … サーバスパン (back のみ)
 *   GET  /api/all       上記をまとめて実行         … 1 トレースに全経路が入る
 * </pre>
 */
@Path("/")
@Produces(MediaType.APPLICATION_JSON)
// CDI の管理下に置いて @Resource (DataSource) の注入を確実にする。
// スコープを付けないと bean-discovery-mode によっては CDI Bean として
// 検出されず、dataSource が null のまま NPE になる。
@RequestScoped
public class ApiResource {

    /**
     * JBoss のデータソース。20-datasource-aurora.cli が登録した AppDS。
     *
     * <p>DataSource 経由にすることで、ADOT Java Agent の
     * {@code OTEL_INSTRUMENTATION_JDBC_DATASOURCE_ENABLED=true} が効き、
     * 「プールから接続を取るのにかかった時間」のスパンが別に出る。
     * Aurora Serverless v2 が 0 ACU から立ち上がるときの待ちを
     * X-Ray 上で SQL 実行時間と切り分けられる。
     */
    @Resource(lookup = "java:jboss/datasources/AppDS")
    private DataSource dataSource;

    /**
     * HTTP クライアント。JDK 標準の HttpClient を使う。
     *
     * <p>ADOT Java Agent が java.net.http.HttpClient を計装し、
     * 送信時に traceparent と X-Amzn-Trace-Id の両方を自動で注入する
     * (OTEL_PROPAGATORS=xray,tracecontext,baggage の設定に従う)。
     * アプリがヘッダを手で足す必要は無い。
     */
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(3))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();

    // ------------------------------------------------------------------
    //  ヘルスチェック
    // ------------------------------------------------------------------
    @GET
    @Path("/health")
    public Response health() {
        return Response.ok(json(Map.of(
                "status", "UP",
                "service", Env.serviceName(),
                "role", Env.role()))).build();
    }

    // ------------------------------------------------------------------
    //  1. Aurora Serverless v2 (MySQL 8.4)
    // ------------------------------------------------------------------
    @GET
    @Path("/db")
    public Response db() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("peer", "aurora-mysql");
        try (Connection c = dataSource.getConnection();
             Statement st = c.createStatement();
             // SELECT のリテラルは db-statement-sanitizer が ? に伏せるため、
             // X-Ray の annotation に値が漏れることはない。
             ResultSet rs = st.executeQuery("SELECT 1 AS ok, NOW() AS now_at, VERSION() AS ver")) {
            if (rs.next()) {
                out.put("ok", rs.getInt("ok"));
                out.put("now", String.valueOf(rs.getObject("now_at")));
                out.put("version", rs.getString("ver"));
            }
            return Response.ok(json(out)).build();
        } catch (Exception e) {
            // 例外はエージェントがスパンに記録し、X-Ray 上では
            // そのサブセグメントが赤 (fault) になる。ここで握り潰しても
            // トレース上の情報は失われない。
            return fail(out, e);
        }
    }

    // ------------------------------------------------------------------
    //  2. ElastiCache for Valkey
    // ------------------------------------------------------------------
    @GET
    @Path("/cache")
    public Response cache() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("peer", "elasticache-valkey");
        String host = Env.get("VALKEY_HOST", "valkey");
        int port = Env.getInt("VALKEY_PORT", 6379);
        // JedisPool は本来アプリスコープで保持するが、検証用なので都度生成する。
        try (JedisPool pool = new JedisPool(new JedisPoolConfig(), host, port, 3000);
             var jedis = pool.getResource()) {
            String key = "otel:" + Env.serviceName();
            jedis.setex(key, 60, String.valueOf(System.currentTimeMillis()));
            out.put("ok", true);
            out.put("value", jedis.get(key));
            return Response.ok(json(out)).build();
        } catch (Exception e) {
            return fail(out, e);
        }
    }

    // ------------------------------------------------------------------
    //  3. front -> back (ECS タスク内 / Compose ではサービス名解決)
    // ------------------------------------------------------------------
    @GET
    @Path("/back")
    public Response back() {
        // ECS  : http://localhost:18080  (タスク内は同一ネットワーク名前空間)
        // Compose: http://back:18080
        String url = Env.get("BACKEND_URL", "http://localhost:18080") + "/back/api/db";
        return proxy("intra-back", url, "front-to-back");
    }

    // ------------------------------------------------------------------
    //  4. ALB -> 帳票 EC2 サーバ
    // ------------------------------------------------------------------
    @GET
    @Path("/report")
    public Response report() {
        String url = Env.get("REPORT_ALB_URL", "http://alb:80/report/daily");
        return proxy("report-ec2", url, "container-to-report");
    }

    // ------------------------------------------------------------------
    //  5. 外部ロードバランサー経由の VPC 外通信
    // ------------------------------------------------------------------
    @GET
    @Path("/external")
    public Response external() {
        String url = Env.get("EXTERNAL_SLB_URL", "http://external-slb:80/outside/api");
        return proxy("external-slb", url, "container-to-external");
    }

    // ------------------------------------------------------------------
    //  6. SQS へ送信 (この先 Lambda -> ALB -> back)
    // ------------------------------------------------------------------
    @POST
    @Path("/sqs")
    public Response sqs() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("peer", "sqs");
        String queueUrl = Env.get("SQS_QUEUE_URL", "");
        if (queueUrl.isBlank()) {
            out.put("ok", false);
            out.put("error", "SQS_QUEUE_URL が未設定です");
            return Response.status(503).entity(json(out)).build();
        }
        try (SqsClient sqs = buildSqsClient()) {
            // ★ トレースコンテキストの注入はここでは書かない。
            //   AWS SDK v2 の計装が SendMessage 呼び出しに割り込み、
            //   otel-env.sh の
            //     OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING=true
            //   に従って設定済みの propagator (xray を含む) で
            //   メッセージ属性へ書き込む。Lambda 側はそれを読んで親子を繋ぐ。
            var resp = sqs.sendMessage(SendMessageRequest.builder()
                    .queueUrl(queueUrl)
                    .messageBody("{\"from\":\"" + Env.serviceName() + "\",\"ts\":" + System.currentTimeMillis() + "}")
                    .build());
            out.put("ok", true);
            out.put("messageId", resp.messageId());
            return Response.ok(json(out)).build();
        } catch (Exception e) {
            return fail(out, e);
        }
    }

    /**
     * SQS -> Lambda -> ALB と流れてきた呼び出しの受け口 (back 側)。
     *
     * <p>Lambda が付けた X-Amzn-Trace-Id を xray propagator が拾い、
     * front の SendMessage スパンの続きとして親子が繋がる。
     */
    @POST
    @Path("/from-lambda")
    public Response fromLambda(@Context HttpHeaders headers) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("ok", true);
        out.put("received_by", Env.serviceName());
        // 「トレースが繋がらない」ときにヘッダが来ているかを即座に確認できるよう
        // 受信したヘッダをそのまま返す。
        out.put("x_amzn_trace_id", headers.getHeaderString("X-Amzn-Trace-Id"));
        out.put("traceparent", headers.getHeaderString("traceparent"));
        out.put("x_app_caller", headers.getHeaderString("X-App-Caller"));
        return Response.ok(json(out)).build();
    }

    // ------------------------------------------------------------------
    //  7. まとめて実行 (1 トレースに全経路を入れる)
    //     X-Ray のサービスマップを一発で埋めたいときに使う。
    // ------------------------------------------------------------------
    @GET
    @Path("/all")
    public Response all() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("service", Env.serviceName());
        out.put("db", statusOf(this::db));
        out.put("cache", statusOf(this::cache));
        if ("front".equals(Env.role())) {
            out.put("back", statusOf(this::back));
            out.put("report", statusOf(this::report));
            out.put("external", statusOf(this::external));
            out.put("sqs", statusOf(this::sqs));
        }
        return Response.ok(json(out)).build();
    }

    // ==================================================================
    //  ヘルパー
    // ==================================================================

    private SqsClient buildSqsClient() {
        SqsClientBuilder b = SqsClient.builder()
                .region(Region.of(Env.get("AWS_REGION", "ap-northeast-1")))
                // JBoss のクラスローダ下でも素直に動く URLConnection ベースの
                // HTTP クライアントを使う (Netty を避ける)。
                .httpClient(UrlConnectionHttpClient.builder().build());
        // ローカル (LocalStack / ElasticMQ) 向け。本番では未設定にして
        // 既定のエンドポイントと IAM タスクロールを使う。
        String endpoint = Env.get("SQS_ENDPOINT", "");
        if (!endpoint.isBlank()) {
            b = b.endpointOverride(URI.create(endpoint));
        }
        return b.build();
    }

    /**
     * 下流の HTTP 呼び出し。
     *
     * <p>{@code X-App-Caller} には「自分が誰か」を入れる。受け側では
     * capture-request-headers でスパン属性に取り込まれ、Collector が
     * annotation {@code app_caller} に昇格させる。これにより X-Ray 上で
     * 「この back を叩いたのは front か Lambda かバッチか」を
     * ALB を挟んでいても即座に絞り込める。
     */
    private Response proxy(String peer, String url, String caller) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("peer", peer);
        out.put("url", url);
        try {
            HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(10))
                    .header("X-App-Caller", Env.get("APP_CALLER", caller))
                    .GET()
                    .build();
            HttpResponse<String> res = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
            out.put("ok", res.statusCode() < 400);
            out.put("status", res.statusCode());
            out.put("body", abbreviate(res.body()));
            return Response.ok(json(out)).build();
        } catch (Exception e) {
            return fail(out, e);
        }
    }

    private Object statusOf(java.util.function.Supplier<Response> call) {
        try {
            Response r = call.get();
            return r.getStatus() < 400 ? "ok" : ("ng(" + r.getStatus() + ")");
        } catch (Exception e) {
            return "ng(" + e.getClass().getSimpleName() + ")";
        }
    }

    private Response fail(Map<String, Object> out, Exception e) {
        out.put("ok", false);
        out.put("error", e.getClass().getSimpleName() + ": " + e.getMessage());
        return Response.status(503).entity(json(out)).build();
    }

    private static String abbreviate(String s) {
        if (s == null) {
            return null;
        }
        return s.length() <= 200 ? s : s.substring(0, 200) + "...";
    }

    /** 依存を増やさないための最小 JSON 生成。 */
    private static String json(Map<String, ?> map) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, ?> e : map.entrySet()) {
            if (!first) {
                sb.append(',');
            }
            first = false;
            sb.append('"').append(e.getKey()).append("\":");
            Object v = e.getValue();
            if (v == null) {
                sb.append("null");
            } else if (v instanceof Number || v instanceof Boolean) {
                sb.append(v);
            } else {
                sb.append('"').append(String.valueOf(v)
                        .replace("\\", "\\\\").replace("\"", "\\\"")
                        .replace("\n", " ").replace("\r", " ")).append('"');
            }
        }
        return sb.append('}').toString();
    }
}

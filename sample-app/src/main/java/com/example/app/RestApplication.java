package com.example.app;

import jakarta.ws.rs.ApplicationPath;
import jakarta.ws.rs.core.Application;

/**
 * JAX-RS のルート。すべてのエンドポイントは /api/* になる。
 *
 * <p>OpenTelemetry の観点では、このクラスに手を入れる必要は一切ない。
 * ADOT Java Agent が Undertow (サーブレット) と JAX-RS を自動計装し、
 * {@code GET /api/db} のようなサーバスパンを作る。スパン名は
 * 「HTTPメソッド + ルートテンプレート」になるため、X-Ray のサービスマップ上でも
 * URL のパラメータ違いでノードが分裂しない。
 */
@ApplicationPath("/api")
public class RestApplication extends Application {
}

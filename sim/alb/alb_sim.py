#!/usr/bin/env python3
"""
sim/alb/alb_sim.py — ALB のトレース関連の振る舞いだけを再現する簡易リバースプロキシ。

===============================================================================
 なぜ Compose に ALB のスタブが要るのか
===============================================================================
本構成でトレースが繋がる仕組みは、経路によって 2 通りある。

  (A) 自前の Java 同士 (front -> back)
      ADOT Java Agent が W3C traceparent を注入し、受け側が読む。
      ALB が居ようが居まいが関係なく繋がる。

  (B) 計装されていない相手が入口になる経路
      - EC2 バッチサーバ -> ALB -> コンテナ
      - Lambda -> ALB -> back
      - 利用者ブラウザ -> ALB -> front
      これらは traceparent を送ってこない。にもかかわらず X-Ray 上で
      1 本のトレースになるのは、**ALB が X-Amzn-Trace-Id を採番して
      付与するから**である。コンテナ側は xray propagator でそれを拾う。

つまり (B) は「ALB が居ること」に依存した経路であり、素の nginx を置いた
Compose では再現できない。ここで X-Amzn-Trace-Id を実物と同じ書式で
付与することで、ローカルでも xray propagator の経路を検証できるようにする。

===============================================================================
 実 ALB の挙動 (再現している部分)
===============================================================================
  - リクエストに X-Amzn-Trace-Id が無ければ Root=1-<epoch hex 8>-<random hex 24>
    を採番して付与する
  - 既にあればそのまま透過する (Self= を足す挙動は再現しない)
  - X-Forwarded-For / X-Forwarded-Proto / X-Forwarded-Port を付ける
  - パスに応じてターゲットグループへ転送する

  ※ 実 ALB は traceparent を「素通し」する。ここでも触らない。
     この素通しがあるため、front -> ALB -> back のように ALB を挟んでも
     自前の Java 同士は W3C で繋がったままになる。

===============================================================================
 実 ALB がやらないこと (トレース上の限界。ここも忠実に再現する)
===============================================================================
  - **X-Ray にセグメントを送らない。**
    API Gateway や AppSync と違い、ALB のノードが AWS 側から
    サービスマップに生えてくることは無い。マップに出るのは
    「呼び出し側のクライアントスパンが作った推定ノード」だけ。
    したがって ALB とターゲットの内訳 (ALB で待たされたのか、EC2 が
    遅いのか) は X-Ray だけでは分離できない。
  - **どのターゲットへ振ったかをレスポンスで教えてくれない。**
    X-Target-Group のようなヘッダは付かない。実サーバを知りたければ
    ターゲット側が名乗るしかない (sim/report-ec2/stub.py の X-Server-Id)。

  一方で **ターゲットが返したレスポンスヘッダは素通しする**。
  ここもそれに合わせてあり、X-Server-Id はそのまま呼び出し側へ届く。
  これが「ALB の裏の実サーバを自動計装だけで追う」唯一の足がかりになる。
  詳細と実機での設定例は docs/alb-tracing.md。
"""

import http.client
import os
import re
import secrets
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "80"))

# ルーティング表。 "<正規表現>=<転送先ホスト:ポート>" をカンマ区切りで与える。
#   例: ROUTES=^/report=report-ec2:8000,^/back=back:18080,^/=front:8080
DEFAULT_ROUTES = "^/report=report-ec2:8000,^/back=back:18080,^/front=front:8080,^/=front:8080"
ROUTES = [
    (re.compile(p), t)
    for p, t in (r.split("=", 1) for r in os.environ.get("ROUTES", DEFAULT_ROUTES).split(",") if r)
]

# 実 ALB と同じで、ヘッダ名の大文字小文字は区別されない
TRACE_HEADER = "X-Amzn-Trace-Id"

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host",
}


def new_trace_id() -> str:
    """
    ALB と同じ書式のトレース ID を採番する。

        Root=1-5759e988-bd862e3fe1be46a994272793
              ^        ^
              |        +-- 96bit のランダム値 (16進 24 桁)
              +----------- 先頭 4 バイト = リクエスト時刻の UNIX epoch 秒 (16進 8 桁)

    ★ この「先頭にタイムスタンプを埋める」形式が X-Ray の必須要件。
      X-Ray は現在時刻から大きく外れた ID のセグメントを
      InvalidTraceId として捨てる (既定で概ね 30 日以上前のものは不可)。

      OpenTelemetry 標準の Java Agent は完全ランダムな 128bit を採番するため、
      これをそのまま X-Ray へ送ると大半が捨てられる。しかもコンソールには
      何も出ず Collector のログにだけエラーが残るので極めて気づきにくい。
      ADOT Java Agent はこの形式の ID ジェネレータを既定で組み込んでいる。
      これが「標準エージェントではなく ADOT エージェントを使う」最大の理由。
    """
    return "Root=1-%08x-%s" % (int(time.time()), secrets.token_hex(12))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "alb-sim/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[alb] %s\n" % (fmt % args))

    def _target(self, path: str):
        for pattern, target in ROUTES:
            if pattern.search(path):
                return target
        return None

    def _proxy(self, method: str):
        target = self._target(self.path)
        if target is None:
            self.send_error(404, "no matching target group")
            return

        # --- ALB が付与/透過するヘッダを組み立てる ---------------------------
        headers = {}
        for k, v in self.headers.items():
            if k.lower() in HOP_BY_HOP:
                continue
            headers[k] = v

        incoming_trace = self.headers.get(TRACE_HEADER)
        if incoming_trace:
            # 既に付いていればそのまま透過する。
            # front -> ALB -> back の場合はここを通り、front が採番した
            # トレース ID が back まで届く。
            trace_id = incoming_trace
            origin = "passthrough"
        else:
            # 計装されていない呼び出し元 (EC2 バッチ / Lambda / ブラウザ)。
            # ALB が採番する。これが X-Ray 上でのトレースの起点になる。
            trace_id = new_trace_id()
            origin = "generated"
        headers[TRACE_HEADER] = trace_id

        client_ip = self.client_address[0]
        xff = self.headers.get("X-Forwarded-For")
        headers["X-Forwarded-For"] = f"{xff}, {client_ip}" if xff else client_ip
        headers["X-Forwarded-Proto"] = "http"
        headers["X-Forwarded-Port"] = str(LISTEN_PORT)

        body = None
        length = self.headers.get("Content-Length")
        if length:
            body = self.rfile.read(int(length))

        self.log_message("%s %s -> %s  trace=%s (%s) caller=%s xff=%s",
                         method, self.path, target, trace_id, origin,
                         self.headers.get("X-App-Caller", "-"),
                         headers.get("X-Forwarded-For", "-"))

        try:
            host, _, port = target.partition(":")
            conn = http.client.HTTPConnection(host, int(port or 80), timeout=30)
            conn.request(method, self.path, body=body, headers=headers)
            res = conn.getresponse()
            payload = res.read()
        except Exception as e:  # noqa: BLE001
            self.log_message("upstream error: %s", e)
            self.send_error(502, "upstream unreachable")
            return

        # ターゲットが名乗った実サーバをログにも残す。
        # 実 ALB は教えてくれないので、これが取れるかどうかは
        # 「ターゲット側が X-Server-Id を返す実装になっているか」で決まる。
        self.log_message("   <- %s server_id=%s", res.status,
                         res.getheader("X-Server-Id", "-"))

        self.send_response(res.status)
        for k, v in res.getheaders():
            if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                continue
            # ★ ターゲットのレスポンスヘッダは素通しする (実 ALB と同じ)。
            #   X-Server-Id がここを通って呼び出し側のスパンに載る。
            self.send_header(k, v)
        # 実 ALB もレスポンスに X-Amzn-Trace-Id を返す
        self.send_header(TRACE_HEADER, trace_id)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        conn.close()

    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_PUT(self):
        self._proxy("PUT")

    def do_DELETE(self):
        self._proxy("DELETE")


def main():
    sys.stderr.write("[alb] listening on :%d\n" % LISTEN_PORT)
    for pattern, target in ROUTES:
        sys.stderr.write("[alb]   %s -> %s\n" % (pattern.pattern, target))
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()

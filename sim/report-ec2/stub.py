#!/usr/bin/env python3
"""
sim/report-ec2/stub.py — 「帳票 EC2 サーバ」および「外部 SLB 先」のスタブ。

STUB_NAME 環境変数で名前を変えて 2 用途に使い回す。

===============================================================================
 あえて計装していない
===============================================================================
帳票 EC2 サーバと VPC 外の外部サービスは、多くの場合こちらから計装できない。
その状態が X-Ray でどう見えるかを、そのまま再現している。

  - X-Ray のサービスマップには「呼び出し先ノード」として現れる
  - ただしノードの中身 (そのサーバ内で何に時間がかかったか) は見えない
  - ノード名は呼び出し側のクライアントスパンから決まる。既定では接続先の
    ホスト名 (FQDN) がそのまま出てしまうため、otel-env.sh の
    peer-service-mapping で "report-ec2" / "external-slb" に寄せている

受信したトレースヘッダをレスポンスとログに出すので、
「ヘッダはちゃんと届いているのか」をローカルで確認できる。
帳票 EC2 を後から計装する (同じ ADOT Java Agent を入れる) 場合は、
このヘッダを読ませれば 1 本のトレースとして繋がる。
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8000"))
STUB_NAME = os.environ.get("STUB_NAME", "report-ec2")
DELAY_MS = int(os.environ.get("DELAY_MS", "0"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "%s-stub/1.0" % STUB_NAME

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (STUB_NAME, fmt % args))

    def _handle(self):
        if DELAY_MS:
            import time
            time.sleep(DELAY_MS / 1000.0)

        payload = {
            "stub": STUB_NAME,
            "path": self.path,
            # 受け取ったトレースヘッダをそのまま返す。
            # 「X-Ray に下流ノードが出ない」ときの一次切り分けに使う。
            "received": {
                "X-Amzn-Trace-Id": self.headers.get("X-Amzn-Trace-Id"),
                "traceparent": self.headers.get("traceparent"),
                "tracestate": self.headers.get("tracestate"),
                "X-App-Caller": self.headers.get("X-App-Caller"),
            },
        }
        self.log_message("%s xray=%s traceparent=%s caller=%s",
                         self.path,
                         payload["received"]["X-Amzn-Trace-Id"],
                         payload["received"]["traceparent"],
                         payload["received"]["X-App-Caller"])

        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()


if __name__ == "__main__":
    sys.stderr.write("[%s] listening on :%d\n" % (STUB_NAME, PORT))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

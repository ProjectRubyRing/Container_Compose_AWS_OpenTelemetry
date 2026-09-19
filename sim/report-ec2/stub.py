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

===============================================================================
 X-Server-Id を返す理由 (ALB の裏の「実サーバ」を追えるようにする)
===============================================================================
ALB を挟むと、呼び出し側のクライアントスパンからは ALB しか見えない。
ALB 自身は X-Ray にセグメントを送らないし、「どのターゲットが応答したか」も
レスポンスヘッダで教えてはくれない。つまり **ALB が何もしてくれない以上、
ターゲット側が名乗るしかない**。

そこでこのスタブは自分の識別子を

    X-Server-Id: <STUB_NAME>@<hostname>

として返す。ALB (実物も sim/alb も) はターゲットのレスポンスヘッダを
素通しするので、呼び出し側の HTTP クライアント計装が
    http.response.header.x-server-id
として拾える (otel-env.sh の APP_CAPTURE_CLIENT_RESPONSE_HEADERS に
入れてある)。Collector がこれを app_upstream に写すため、

    front -> report-ec2 というエッジ 1 本しか無くても
    annotation.app_upstream = "report-ec2@ip-10-0-1-23"

で「どの EC2 が遅いのか」まで絞り込める。
実機の帳票 EC2 でも、Apache/nginx なら 1 行の設定で同じヘッダを返せる。
アプリの改修は要らない。詳細は docs/alb-tracing.md。
"""

import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT = int(os.environ.get("PORT", "8000"))
STUB_NAME = os.environ.get("STUB_NAME", "report-ec2")
DELAY_MS = int(os.environ.get("DELAY_MS", "0"))

# 実 EC2 ならインスタンス ID を入れる想定。ここではコンテナのホスト名。
SERVER_ID = os.environ.get("SERVER_ID", "%s@%s" % (STUB_NAME, socket.gethostname()))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "%s-stub/1.0" % STUB_NAME

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (STUB_NAME, fmt % args))

    def _handle(self):
        if DELAY_MS:
            import time
            time.sleep(DELAY_MS / 1000.0)

        query = parse_qs(urlsplit(self.path).query)
        payload = {
            "stub": STUB_NAME,
            "server_id": SERVER_ID,
            "path": self.path,
            # クエリをそのまま返す。呼び出し側のスパンに載る url.query と
            # 突き合わせれば「Collector の伏せ字が効いているか」が分かる。
            "query": query,
            # 受け取ったトレースヘッダをそのまま返す。
            # 「X-Ray に下流ノードが出ない」ときの一次切り分けに使う。
            "received": {
                "X-Amzn-Trace-Id": self.headers.get("X-Amzn-Trace-Id"),
                "traceparent": self.headers.get("traceparent"),
                "tracestate": self.headers.get("tracestate"),
                "X-App-Caller": self.headers.get("X-App-Caller"),
                # ALB が付けるヘッダ。ここに値が入っていれば
                # 「ALB を通ってきた」ことがターゲット側からも確認できる。
                "X-Forwarded-For": self.headers.get("X-Forwarded-For"),
                "X-Forwarded-Proto": self.headers.get("X-Forwarded-Proto"),
                "X-Forwarded-Port": self.headers.get("X-Forwarded-Port"),
            },
        }
        self.log_message("%s xray=%s traceparent=%s caller=%s xff=%s",
                         self.path,
                         payload["received"]["X-Amzn-Trace-Id"],
                         payload["received"]["traceparent"],
                         payload["received"]["X-App-Caller"],
                         payload["received"]["X-Forwarded-For"])

        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        # ★ ALB の裏で実際に応答したサーバを呼び出し側へ伝える。
        #   ALB はレスポンスヘッダを素通しするので、そのまま
        #   http.response.header.x-server-id として相手のスパンに載る。
        self.send_header("X-Server-Id", SERVER_ID)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()


if __name__ == "__main__":
    sys.stderr.write("[%s] listening on :%d (X-Server-Id: %s)\n"
                     % (STUB_NAME, PORT, SERVER_ID))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

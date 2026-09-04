#!/usr/bin/env python3
"""
sim/lambda/sqs_to_alb.py — 「SQS をトリガーに起動し ALB 経由で back を呼ぶ Lambda」の
Compose 用スタブ。

===============================================================================
 このスタブが検証している「契約」
===============================================================================
SQS を挟むとトレースは必ず一度切れる。HTTP と違い、キューには
「呼び出し元のスレッド」が存在しないためである。繋ぐには次の 3 つが揃う必要がある。

  (1) 送信側 (front/back の Java) がメッセージにトレースコンテキストを書き込む
      -> otel-env.sh の
           OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING=true
         により、AWS SDK v2 の計装が設定済み propagator (xray を含む) で
         メッセージ属性へ書き込む。
      -> X-Ray 方式では SQS の **システム属性** AWSTraceHeader が使われる。
         これは通常のメッセージ属性 10 個の上限に含まれない (重要)。

  (2) Lambda がそれを読み取り、自分のトレースの親にする
      -> 本番では ADOT Lambda レイヤー + AWS_LAMBDA_EXEC_WRAPPER=/opt/otel-handler
         が自動で行う。Lambda の「アクティブトレース」を有効にした場合は
         Lambda サービス自身も AWSTraceHeader を見て親子を繋ぐ。

  (3) Lambda が下流 (ALB -> back) の呼び出しに X-Amzn-Trace-Id を付ける
      -> ADOT レイヤーが自動注入する。ALB は既にヘッダがあれば透過するので、
         back まで同じトレース ID が届く。

このスタブは (2)(3) を素の Python で明示的に実装している。
本番の Lambda コードでこれを手書きする必要は無いが、
「何が起きていれば繋がるのか」をローカルで目に見える形にしておくと、
本番で繋がらなかったときにどの段が壊れているかを切り分けられる。

===============================================================================
 環境変数
===============================================================================
  SQS_ENDPOINT     LocalStack のエンドポイント (例: http://localstack:4566)
  SQS_QUEUE_URL    ポーリング対象のキュー URL
  TARGET_URL       転送先 (例: http://alb:80/back/api/from-lambda)
  POLL_INTERVAL    ポーリング間隔 (秒)
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SQS_ENDPOINT = os.environ.get("SQS_ENDPOINT", "http://localstack:4566")
QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
TARGET_URL = os.environ.get("TARGET_URL", "http://alb:80/back/api/from-lambda")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "2"))


def log(msg):
    sys.stderr.write("[lambda] %s\n" % msg)
    sys.stderr.flush()


def sqs_call(action, params):
    """LocalStack の SQS へ Query プロトコルで問い合わせる (依存を増やさないため)。"""
    body = {"Action": action, "Version": "2012-11-05", **params}
    data = urllib.parse.urlencode(body).encode()
    req = urllib.request.Request(
        SQS_ENDPOINT,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            # LocalStack は署名を検証しないのでダミーで通る
            "Authorization": "AWS4-HMAC-SHA256 Credential=test/20250101/ap-northeast-1/sqs/aws4_request",
        },
    )
    with urllib.request.urlopen(req, timeout=25) as res:
        return res.read().decode()


def extract_trace_context(xml_text):
    """
    受信したメッセージから、下流へ渡すべきトレースコンテキストを取り出す。

    優先順位は本番の ADOT Lambda レイヤーと同じ:
      1. システム属性 AWSTraceHeader  (X-Ray 方式。SQS -> Lambda の標準経路)
      2. メッセージ属性 traceparent   (W3C 方式)

    ★ ここが「SQS を挟むと繋がらない」の主戦場。
      送信側が (1) も (2) も書いていなければ、Lambda 側で何をしても
      親子は繋がらない。X-Ray 上では「front の SendMessage で終わるトレース」と
      「back から始まるトレース」の 2 本に割れる。
      その状態を見分けるために、ここでは取れた/取れなかったを必ずログに出す。
    """
    import re

    ctx = {}
    m = re.search(
        r"<Name>AWSTraceHeader</Name>\s*<Value>([^<]+)</Value>", xml_text
    )
    if m:
        ctx["X-Amzn-Trace-Id"] = m.group(1)

    m = re.search(
        r"<Name>traceparent</Name>.*?<StringValue>([^<]+)</StringValue>",
        xml_text,
        re.S,
    )
    if m:
        ctx["traceparent"] = m.group(1)

    return ctx


def main():
    if not QUEUE_URL:
        log("SQS_QUEUE_URL が未設定です。終了します。")
        return

    log("polling %s -> %s" % (QUEUE_URL, TARGET_URL))
    while True:
        try:
            xml_text = sqs_call(
                "ReceiveMessage",
                {
                    "QueueUrl": QUEUE_URL,
                    "MaxNumberOfMessages": "10",
                    "WaitTimeSeconds": "5",
                    # ★ AWSTraceHeader を受け取るには明示的に要求する必要がある。
                    #   本番の Lambda イベントソースマッピングは自動で含めるが、
                    #   自前でポーリングする場合は指定を忘れると
                    #   「送信側は正しいのに Lambda 側で拾えない」状態になる。
                    "AttributeName.1": "AWSTraceHeader",
                    "MessageAttributeName.1": "All",
                },
            )
        except Exception as e:  # noqa: BLE001
            log("receive error: %s" % e)
            time.sleep(POLL_INTERVAL)
            continue

        import re

        bodies = re.findall(r"<Body>(.*?)</Body>", xml_text, re.S)
        receipts = re.findall(r"<ReceiptHandle>(.*?)</ReceiptHandle>", xml_text, re.S)
        if not bodies:
            time.sleep(POLL_INTERVAL)
            continue

        ctx = extract_trace_context(xml_text)
        if ctx:
            log("trace context found in message: %s" % ", ".join(ctx.keys()))
        else:
            log("WARN: メッセージにトレースコンテキストがありません。"
                "X-Ray 上でトレースが 2 本に割れます。"
                "送信側の OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING を確認してください。")

        for body in bodies:
            headers = {
                "Content-Type": "application/json",
                # 呼び出し元の識別。back 側で annotation app_caller になる。
                "X-App-Caller": "lambda-sqs",
            }
            headers.update(ctx)
            req = urllib.request.Request(
                TARGET_URL, data=body.encode(), headers=headers, method="POST"
            )
            try:
                with urllib.request.urlopen(req, timeout=20) as res:
                    log("forwarded -> %s (%d)" % (TARGET_URL, res.status))
            except urllib.error.HTTPError as e:
                log("forward failed: HTTP %s" % e.code)
            except Exception as e:  # noqa: BLE001
                log("forward failed: %s" % e)

        for rh in receipts:
            try:
                sqs_call("DeleteMessage", {"QueueUrl": QUEUE_URL, "ReceiptHandle": rh})
            except Exception as e:  # noqa: BLE001
                log("delete failed: %s" % e)


if __name__ == "__main__":
    main()

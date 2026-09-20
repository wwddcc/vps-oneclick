# -*- coding: utf-8 -*-
"""本地校验 xray-server 模板渲染后的 JSON 合法性。"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "templates", "xray-server.json.tmpl")

UUID = "11111111-2222-3333-4444-555555555555"

CDN_BLOCK = (
    ",{\"tag\":\"cdn\",\"listen\":\"0.0.0.0\",\"port\":2053,"
    "\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"" + UUID + "\"}],"
    "\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"xhttp\","
    "\"security\":\"tls\",\"tlsSettings\":{\"certificates\":[{"
    "\"certificateFile\":\"/etc/vps-oneclick/cdn/cert.pem\","
    "\"keyFile\":\"/etc/vps-oneclick/cdn/key.pem\"}]},"
    "\"xhttpSettings\":{\"mode\":\"auto\"}},"
    "\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}}"
)


def render(cdn_block: str) -> dict:
    with open(TEMPLATE, encoding="utf-8") as f:
        s = f.read()
    for k, v in {
        "__REALITY_PORT__": "443",
        "__UUID__": UUID,
        "__REALITY_SNI__": "www.samsung.com",
        "__PRIVATE_KEY__": "DUMMY-PRIVATE-KEY",
        "__SHORT_ID__": "0123abcd",
        "__CDN_BLOCK__": cdn_block,
    }.items():
        s = s.replace(k, v)
    return json.loads(s)


def main() -> None:
    base = render("")
    assert base["inbounds"][0]["port"] == 443
    assert base["inbounds"][0]["streamSettings"]["network"] == "xhttp"
    assert base["routing"]["rules"][0]["outboundTag"] == "warp"

    with_cdn = render(CDN_BLOCK)
    assert len(with_cdn["inbounds"]) == 2
    assert with_cdn["inbounds"][1]["port"] == 2053
    assert with_cdn["inbounds"][1]["streamSettings"]["security"] == "tls"

    print("JSON render OK: no-CDN / with-CDN both valid")


if __name__ == "__main__":
    main()

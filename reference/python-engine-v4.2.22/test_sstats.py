import os, socket, urllib.request
from urllib.parse import urlparse
from dotenv import load_dotenv
load_dotenv()
base=os.getenv("SSTATS_BASE_URL","https://api.sstats.net").rstrip("/")
key=os.getenv("SSTATS_API_KEY","")
host=urlparse(base).hostname or "api.sstats.net"
print("SStats diagnostic 4.2.19")
print("BASE:", base)
try:
    infos=socket.getaddrinfo(host,443,type=socket.SOCK_STREAM)
    print("DNS: OK", sorted(set("IPv4" if x[0]==socket.AF_INET else "IPv6" for x in infos)))
except Exception as e:
    print("DNS: ERROR",type(e).__name__,e)
try:
    url=base+"/Account/Info"
    req=urllib.request.Request(url,headers={"Accept":"application/json","User-Agent":"SYNDICATE-QUANT/4.2.19"})
    if key: req.add_header("apikey",key)
    with urllib.request.urlopen(req,timeout=15) as r:
        print("HTTP: OK",r.status,r.geturl())
        raw=r.read(2000).decode("utf-8","replace")
        try:
            import json
            body=json.loads(raw)
            if isinstance(body,dict):
                for k in list(body.keys()):
                    if str(k).lower() in ("apikey","api_key","token","access_token","authorization"):
                        body[k]="***REDACTED***"
            print("BODY:",json.dumps(body,ensure_ascii=False)[:1200])
        except Exception:
            print("BODY: [non-JSON response redacted]")
except Exception as e:
    print("HTTP: ERROR",type(e).__name__,e)
print("\nIf DNS is OK but HTTP fails, check firewall/VPN/antivirus/proxy. If browser opens sstats.net but api.sstats.net fails, test the API host specifically.")

#!/bin/sh
# Manual camera check: tries the same requests CameraBridge makes (ONVIF with WS-UsernameToken, ONVIF with HTTP
# Digest, Hikvision ISAPI) so we can see which ones a camera accepts. The password is read silently, never printed
# or saved. Usage: sh Tools/camera_check.sh 192.0.2.41 [username]
set -u
IP="${1:?usage: camera_check.sh <camera-ip> [username]}"
USER_NAME="${2:-}"
[ -z "$USER_NAME" ] && { printf "Camera username: "; read -r USER_NAME; }
printf "Camera password (hidden): "; stty -echo; read -r CAM_PASS; stty echo; echo
export IP USER_NAME CAM_PASS

python3 - <<'PY'
import os, base64, hashlib, datetime, re, urllib.request, urllib.error, subprocess
ip, user, pw = os.environ["IP"], os.environ["USER_NAME"], os.environ["CAM_PASS"]
dev = f"http://{ip}/onvif/device_service"

def post(url, body, extra_header=""):
    env = f'<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Header>{extra_header}</s:Header><s:Body>{body}</s:Body></s:Envelope>'
    req = urllib.request.Request(url, env.encode(), {"Content-Type": "application/soap+xml"})
    try:
        r = urllib.request.urlopen(req, timeout=6); return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode(errors="replace")
    except Exception as e: return 0, str(e)

def fault(text):
    m = re.search(r"<[^>]*Text[^>]*>([^<]*)", text) or re.search(r"<p>([^<]*)</p>", text)
    return (m.group(1) if m else text[:120]).strip()

# Camera clock (unauthenticated), used for the token's Created time, like CameraBridge does.
code, t = post(dev, '<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>')
g = lambda k: int(re.search(rf"<[^>]*{k}>(\d+)<", t[t.find("UTCDateTime"):]).group(1))
try:
    cam = datetime.datetime(g("Year"), g("Month"), g("Day"), g("Hour"), g("Minute"), g("Second"), tzinfo=datetime.timezone.utc)
    offset = cam - datetime.datetime.now(datetime.timezone.utc)
    print(f"1. ONVIF clock (no login): OK, camera is {offset.total_seconds():+.0f}s from this Mac")
except Exception:
    offset = datetime.timedelta(0); print(f"1. ONVIF clock (no login): FAILED (HTTP {code})")

def token():
    nonce = os.urandom(16)
    created = (datetime.datetime.now(datetime.timezone.utc) + offset).strftime("%Y-%m-%dT%H:%M:%SZ")
    digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + pw.encode()).digest()).decode()
    return ('<Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><UsernameToken>'
            f'<Username>{user}</Username><Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</Password>'
            f'<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{base64.b64encode(nonce).decode()}</Nonce>'
            f'<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">{created}</Created></UsernameToken></Security>')

info = '<GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>'
code, t = post(dev, info, token())
if code == 200:
    model = re.search(r"Model>([^<]*)<", t); print(f"2. ONVIF login (WS-UsernameToken, what CameraBridge sends): OK, model {model.group(1) if model else '?'}")
else:
    print(f"2. ONVIF login (WS-UsernameToken, what CameraBridge sends): REJECTED (HTTP {code}: {fault(t)})")

def curl(args, data=None):
    cmd = ["curl", "-s", "-m", "6", "--digest", "-u", f"{user}:{pw}", "-o", "/dev/stderr", "-w", "%{http_code}"] + args
    p = subprocess.run(cmd, input=data, capture_output=True, text=True)
    return p.stdout.strip(), p.stderr

env = f'<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>{info}</s:Body></s:Envelope>'
code, t = curl(["-H", "Content-Type: application/soap+xml", "--data-binary", "@-", dev], env)
print(f"3. ONVIF login (HTTP Digest only): {'OK' if code == '200' else 'REJECTED (HTTP ' + code + ': ' + fault(t) + ')'}")

code, t = post(f"http://{ip}/onvif/Media", '<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>', token())
if code == 200:
    names = re.findall(r"<[^>]*:Name>([^<]*)<", t)
    res = re.findall(r"Width>(\d+)<[^W]*?Height>(\d+)<", t)
    print(f"4. ONVIF video profiles: OK, {len(re.findall('<[^>]*Profiles ', t))} profiles, resolutions {sorted(set(res))}")
else:
    print(f"4. ONVIF video profiles: FAILED (HTTP {code}: {fault(t)})")

code, t = curl([f"http://{ip}/ISAPI/System/deviceInfo"])
model = re.search(r"<model>([^<]*)<", t)
print(f"5. Hikvision ISAPI login (web account): {'OK, model ' + model.group(1) if code == '200' and model else 'HTTP ' + code}")
code, t = curl([f"http://{ip}/ISAPI/Streaming/channels/101"])
if code == "200":
    sc = re.search(r"<SmartCodec>.*?<enabled>(\w+)</enabled>", t, re.S)
    gov = re.search(r"<GovLength>(\d+)<", t); fps = re.search(r"<maxFrameRate>(\d+)<", t); codec = re.search(r"<videoCodecType>([^<]*)<", t)
    print(f"6. Main stream (ISAPI): codec {codec.group(1) if codec else '?'}, smart codec {'ON' if sc and sc.group(1)=='true' else 'off' if sc else 'not offered'}, "
          f"GOP {gov.group(1) if gov else '?'} frames, fps {int(fps.group(1))/100 if fps else '?'}")
else:
    print(f"6. Main stream (ISAPI): HTTP {code}")
code, t = curl([f"http://{ip}/ISAPI/Streaming/channels/102"])
print(f"7. Sub stream (ISAPI channel 102): {'present' if code == '200' else 'HTTP ' + code}")
PY

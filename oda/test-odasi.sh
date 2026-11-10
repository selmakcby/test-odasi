#!/usr/bin/env bash
# test-odasi.sh — güvenmediğin bir repoyu kullan-at bir konteynerde aç.
#
#   ./test-odasi.sh <dizin | git-url | ->        ağsız (--network none) oda
#   ./test-odasi.sh --sink <dizin | git-url | -> izole ağ + test-odasi-sink (DNS/HTTP denemelerini kaydeder)
#   ./test-odasi.sh --dogrula [--sink]           odanın dışarı çıkamadığını kanıtlar
#   ./test-odasi.sh --internetli <repo> ["komut"] temiz çıkan repoyu internetli (ama yine sırsız,
#                                                komşusuz) odada gerçekten kur + komutu dene
#
# "-" = repo stdin'den tar olarak gelir:  git archive HEAD | ssh sunucu ./test-odasi.sh -
# Oda: salt-okunur kök, yetkisiz kullanıcı (1000), tüm capability'ler düşük, host'tan hiçbir
# klasör bağlanmaz. Repo içeri tar ile kopyalanır. Biter bitmez konteyner/ağ silinir.
set -euo pipefail

KOK="$(cd "$(dirname "$0")" && pwd)"
IMAGE="node:22-slim"
TS="$(date +%Y%m%d-%H%M%S)-$$"
AD="test-odasi-$TS"
NET="test-odasi-net-$TS"
SINK="test-odasi-sink-$TS"
GELEN="$KOK/gelen/$TS"
KAYIT="$KOK/kayit"
mkdir -p "$KAYIT"

SINK_MOD=0; DOGRULA=0; INTERNETLI=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --sink) SINK_MOD=1 ;;
    --dogrula) DOGRULA=1 ;;
    --internetli) INTERNETLI=1 ;;
    *) echo "bilinmeyen seçenek: $1" >&2; exit 2 ;;
  esac
  shift
done
KAYNAK="${1:-}"
DENE="${2:-}"

temizle() {
  docker rm -f "$AD" "$SINK" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$GELEN"
  rmdir "$KOK/gelen" 2>/dev/null || true
}
trap temizle EXIT

# --- 1) repo -> tar akışı (host'ta hiçbir şey ÇALIŞTIRILMAZ) ---
repo_tar() {
  if [[ "$KAYNAK" == "-" ]]; then
    cat
  elif [[ -d "$KAYNAK" ]]; then
    tar -C "$KAYNAK" --exclude .git -c .
  else
    mkdir -p "$GELEN"
    # hook yok, submodule yok, sadece son commit
    GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null clone -q --depth 1 \
      --no-recurse-submodules "$KAYNAK" "$GELEN/repo" >&2
    tar -C "$GELEN/repo" --exclude .git -c .
  fi
}

# --- 2) odanın içinde koşan betik ---
read -r -d '' ICERDE <<'ICERI' || true
set -e
mkdir -p /work/repo "$HOME/.ssh"
tar -x -C /work/repo -f - 2>/dev/null
# SAHTE yem sırlar: sadece bu konteynerin RAM'inde
printf 'SAHTE-ANAHTAR-ed25519-0000\n' > "$HOME/.ssh/id_ed25519"
printf 'OPENAI_API_KEY=sk-SAHTE-0000\nSTRIPE_SECRET_KEY=sk_live_SAHTE-1111\n' > "$HOME/.env"
cd /work/repo
echo "== test odası ==   kullanıcı: $(id -un 2>/dev/null || id -u)   ağ: $(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | tr '\n' ' ')"
echo "== kurulum betikleri (package.json) =="
node -e '
const s = require("./package.json").scripts || {};
const tehlikeli = ["preinstall", "install", "postinstall", "prepare"];
const k = Object.keys(s);
if (!k.length) console.log("   (script yok)");
k.forEach((n) => console.log(`   ${tehlikeli.includes(n) ? "!!" : "  "} ${n.padEnd(12)} ${s[n]}`));
if (!k.some((n) => tehlikeli.includes(n))) console.log("   -> kurulumda kendiliğinden çalışan betik YOK");
' 2>/dev/null || echo "   (package.json yok)"
echo "== npm install =="
npm install --foreground-scripts --no-audit --no-fund --omit=dev $NPM_EK 2>&1 | grep -v '^npm notice' || true
if [ -n "$DENE" ]; then echo "== deneme (repo kodu çalıştırılıyor) =="; bash -c "$DENE" 2>&1 || true; fi
echo "== bitti =="
ICERI

read -r -d '' DOGRULAMA <<'DOG' || true
echo "kullanıcı        : uid=$(id -u)  (root değil)"
echo "ağ arayüzleri    : $(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | tr '\n' ' ')"
echo "docker.sock      : $( [ -e /var/run/docker.sock ] && echo VAR || echo yok )"
echo "görülen süreçler : $(ls /proc | grep -c '^[0-9]*$')  (sadece kendi süreçleri)"
echo "kök dosya sistemi: $(touch /deneme 2>/dev/null && echo YAZILABİLİR || echo salt-okunur)"
node -e '
const net = require("net"); const dns = require("dns");
const dene = (ad, host, port) => new Promise((ok) => {
  const s = net.connect({ host, port, timeout: 3000 });
  const bitir = (sonuc) => { s.destroy(); console.log(`${ad.padEnd(17)}: ${sonuc}`); ok(); };
  s.on("connect", () => bitir("AÇIK  <-- dikkat"));
  s.on("timeout", () => bitir("ulaşılamadı (zaman aşımı)"));
  s.on("error", (e) => bitir(`ulaşılamadı (${e.code})`));
});
(async () => {
  await new Promise((ok) => dns.lookup("google.com", (e, a) => { console.log(`DNS google.com    : ${e ? "çözülemedi (" + e.code + ")" : a === process.env.SINK_IP ? "sadece sink cevapladı (" + a + "), internete gitmedi" : "ÇÖZÜLDÜ " + a}`); ok(); }));
  await dene("internet 1.1.1.1", "1.1.1.1", 443);
  await dene("sunucu dış IP SSH", process.env.DIS_IP, 22);
  await dene("docker köprüsü", "172.17.0.1", 22);
  await dene("komşu konteyner", "172.18.0.2", 80);
})();
'
DOG

docker_run() {
  local ag=(--network none) npm_ek="--fetch-retries=0 --fetch-timeout=5000"
  [[ $SINK_MOD -eq 1 ]] && ag=(--network "$NET" --dns "$SINK_IP")
  [[ $INTERNETLI -eq 1 ]] && { ag=(--network "$NET"); npm_ek=""; }
  docker run --rm -i --name "$AD" "${ag[@]}" \
    --read-only --tmpfs /tmp --tmpfs /work:exec,size=512m,mode=1777 \
    --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory 1g --cpus 1 --user 1000:1000 \
    -e HOME=/work/home -e GITHUB_TOKEN=ghp_SAHTE-2222 \
    -e NPM_EK="$npm_ek" -e DENE="$DENE" -e SINK_IP="$SINK_IP" -e DIS_IP="$DIS_IP" \
    "$IMAGE" bash -c "$1"
}

SINK_IP=""
DIS_IP="$(hostname -I | cut -d' ' -f1)"
if [[ $INTERNETLI -eq 1 ]]; then
  docker network create "$NET" >/dev/null
fi
if [[ $SINK_MOD -eq 1 ]]; then
  # --internal: dışarı rota yok. inhibit_ipv4: köprüye host IP'si verilmez -> oda sunucunun
  # kendi servislerine (sshd vb.) de ulaşamaz.
  docker network create --internal -o com.docker.network.bridge.inhibit_ipv4=true "$NET" >/dev/null
  docker run -d --rm --name "$SINK" --network "$NET" --read-only \
    --cap-drop ALL --security-opt no-new-privileges --pids-limit 32 \
    --memory 128m --cpus 0.5 --user 1000:1000 \
    "$IMAGE" node -e "$(cat "$KOK/sink.js")" >/dev/null
  SINK_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SINK")"
  sleep 1
fi

# ekran için renk (kayıt dosyası düz kalır)
renk() {
  sed -u -E \
    -e 's/^(== .*)$/\x1b[1;36m\1\x1b[0m/' \
    -e 's/^( *!! .*)$/\x1b[1;31m\1\x1b[0m/' \
    -e 's/(collect\.example\.invalid)/\x1b[1;31m\1\x1b[0m/' \
    -e 's/(gonderilemedi.*|ENGELLEND.*|ulaşılamadı.*|çözülemedi.*|yok$|salt-okunur$|internete gitmedi$)/\x1b[1;32m\1\x1b[0m/' \
    -e 's/([A-Za-z_-]*SAHT[^*]*\*\*\*|sk_live_\*\*\*)/\x1b[1;33m\1\x1b[0m/' \
    -e 's/(POST https[^ ]*|AÇIK.*)/\x1b[1;31m\1\x1b[0m/'
}

LOG="$KAYIT/$TS.log"
if [[ $DOGRULA -eq 1 ]]; then
  docker_run "$DOGRULAMA" </dev/null 2>&1 | tee "$LOG" | renk
else
  [[ -z "$KAYNAK" ]] && { echo "kullanım: $0 [--sink] <dizin|git-url|->" >&2; exit 2; }
  repo_tar | docker_run "$ICERDE" 2>&1 | tee "$LOG" | renk
fi

if [[ $SINK_MOD -eq 1 ]]; then
  echo "== test-odasi-sink kaydı ==" | tee -a "$LOG" | renk
  docker logs "$SINK" 2>&1 | tee -a "$LOG" | renk
fi
echo "== oda yıkılıyor: $AD ==" | tee -a "$LOG" | renk

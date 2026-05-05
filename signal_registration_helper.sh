#!/bin/bash
# ============================================================
# signal_registration_helper.sh Ver.1.0.0 
# MIT License
# 2027 by Michael Ionescu
# https://github.com/bongosmurf/signal-landline-registration/
# ============================================================
# Signal Festnetz-Registrierung für Home Assistant
# Kompatibel mit signal-cli-rest-api v0.98.0 (JSON-RPC Mode)
# ============================================================
# Verwendung:
#   1. Datei nach /config/scripts/signal_registration_helper.sh kopieren
#   2. Im HA-Terminal: bash /config/scripts/signal_registration_helper.sh
# ============================================================
DEBUG=false
# ── Konfiguration ────────────────────────────────────────
HA_IP="homeassistant"    # hostname oder IP deines HA-Hosts – anpassen falls nötig
API_PORT="8516"          # TCP-Port von Add-on „Signal Messenger" (vorrübergehend) in Mode normal
# ── Konfiguration (optional) ─────────────────────────────
PHONE=""                 # kann auch vorab konfiguriert werden
# ─────────────────────────────────────────────────────────
API_BASE=""
CAPTCHA=""
SKIP_VOICE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

hr()   { echo -e "${CYAN}──────────────────────────────────────────────${NC}"; }
ok()   { echo -e "${GREEN}✔  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
err()  { echo -e "${RED}✖  $1${NC}"; }
info() { echo -e "   $1"; }

strip_captcha() {
    # Entfernt führende "signalcaptcha://" falls vorhanden
    echo "${1#signalcaptcha://}"
}

get_captcha() {
    local step="$1"
    echo ""
    warn "Captcha erforderlich (Versuch ${step})"
    info "1. Öffne in Chrome: https://signalcaptchas.org/registration/generate.html"
    info "2. Löse das Captcha"
    info "3. Klicke 'Abbrechen' wenn Chrome Signal öffnen will"
    info "4. Rechtsklick auf 'Open Signal' → 'Link-Adresse kopieren'"
    info "5. Füge den kompletten kopierten Link hier ein"
    echo ""
    read -rp "   Captcha-Link: " raw_captcha
    CAPTCHA=$(strip_captcha "$raw_captcha")
    if [[ -z "$CAPTCHA" ]]; then
        err "Kein Captcha eingegeben. Abbruch."
        exit 1
    fi
    $DEBUG && echo "[DEBUG] Captcha (Anfang): ${CAPTCHA:0:60}..."
}

# Temporäre Datei für curl-Ausgabe (vermeidet Subshell-Problem mit LAST_HTTP_CODE)
CURL_TMPFILE=$(mktemp)

do_curl() {
    local method="$1"
    local url="$2"
    local data="$3"
    local http_code
    if [[ -n "$data" ]]; then
        curl -s --max-time 60 -w "\n__HTTP_%{http_code}__" -X "$method" \
             -H "Content-Type: application/json" \
             -d "$data" \
             "$url" > "$CURL_TMPFILE" 2>&1
    else
        curl -s --max-time 60 -w "\n__HTTP_%{http_code}__" -X "$method" \
             -H "Content-Type: application/json" \
             "$url" > "$CURL_TMPFILE" 2>&1
    fi
    http_code=$(grep -o '__HTTP_[0-9]*__' "$CURL_TMPFILE" | grep -o '[0-9]*')
    sed -i 's/__HTTP_[0-9]*__//' "$CURL_TMPFILE"
    # curl gibt "000" bei Verbindungsfehlern zurück → auf "0" normalisieren
    [[ "$http_code" =~ ^0+$ ]] && http_code="0"
    LAST_HTTP_CODE="${http_code:-0}"
    $DEBUG && echo "[DEBUG] HTTP-Statuscode: ${LAST_HTTP_CODE}" >&2
    # Kein echo/cat hier - Aufrufer liest CURL_TMPFILE direkt
}

curl_body() {
    # Liefert den Body des letzten do_curl-Aufrufs
    cat "$CURL_TMPFILE"
}

# Aufräumen beim Beenden
trap 'rm -f "$CURL_TMPFILE"' EXIT

check_status() {
    local context="$1"   # "sms" | "voice" | "verify"
    case "${LAST_HTTP_CODE}" in
        200|"")
            # OK oder leere Antwort – normal
            ;;
        400)
            if [[ "$context" == "sms" ]]; then
                warn "HTTP 400 bei SMS-Versuch – bei Festnetz erwartet (InvalidTransportMode)."
                ok  "Weiter mit Voice-Verifikation."
            else
                err "HTTP 400 – Ungültiger Captcha-Token oder falsches Nummernformat."
                info "Captcha möglicherweise abgelaufen oder falsche IP beim Lösen."
                exit 1
            fi
            ;;
        429)
            echo ""
            err "HTTP 429 – Signal hat diese Nummer temporär gesperrt (Rate Limit)."
            warn "Ursache: Zu viele Registrierungsversuche in kurzer Zeit."
            warn "Lösung:  48–72 Stunden warten, dann erneut versuchen."
            warn "Wichtig: Jeder weitere Versuch verlängert die Sperre."
            exit 1
            ;;
        502)
            err "HTTP 502 – Signal-Server nicht erreichbar (ExternalServiceFailure)."
            warn "Das ist ein temporärer Fehler auf Signal-Seite. Einige Minuten warten und erneut versuchen."
            exit 1
            ;;
        0)
            err "Keine Antwort – curl-Timeout oder API nicht erreichbar."
            exit 1
            ;;
        *)
            warn "Unbekannter HTTP-Statuscode: ${LAST_HTTP_CODE}"
            warn "API-Antwort oben prüfen."
            ;;
    esac
}

# ════════════════════════════════════════════════════════
# Schritt 0: Konfiguration & Eingabe
# ════════════════════════════════════════════════════════
hr
echo -e "${CYAN}  Signal Festnetz-Registrierung – Schritt-für-Schritt${NC}"
echo -e "${CYAN}  signal-cli-rest-api v0.98.0 / JSON-RPC${NC}"
hr
echo ""
info "Konfiguration: HA=${HA_IP}, Port=${API_PORT}"
echo ""
if [[ -n "$PHONE" ]]; then
    PHONE="${PHONE// /}"    # Leerzeichen entfernen
    info "Festnetznummer aus Variable: ${PHONE}"
else
    read -rp "   Festnetznummer im Format +49... : " PHONE
    PHONE="${PHONE// /}"    # Leerzeichen entfernen
fi

if [[ ! "$PHONE" =~ ^\+[0-9]{6,15}$ ]]; then
    err "Ungültiges Format. Bitte +49XXXXXXXXX verwenden (mit führendem +)."
    exit 1
fi

API_BASE="http://${HA_IP}:${API_PORT}"
echo ""
ok "Nummer : ${PHONE}"
ok "API-URL: ${API_BASE}"
echo ""

# Prüfen ob API erreichbar und Mode korrekt
info "Prüfe Verbindung zur Signal API (${API_BASE})..."
do_curl GET "${API_BASE}/v1/about" ""
ABOUT=$(curl_body)

case "${LAST_HTTP_CODE}" in
    200) ;;
    0)
        err "API nicht erreichbar (Timeout oder keine Verbindung)."
        info "  – Signal Messenger Add-on läuft nicht"
        info "  – Hostname '${HA_IP}' nicht auflösbar → stattdessen IP eintragen"
        info "  – Falscher Port (eingestellt: ${API_PORT})"
        exit 1
        ;;
    *)
        err "Unerwarteter HTTP-Statuscode beim About-Check: ${LAST_HTTP_CODE}"
        exit 1
        ;;
esac

API_MODE=$(echo "$ABOUT" | grep -o '"mode":"[^"]*"' | grep -o ':[^}]*' | tr -d ':"')
$DEBUG && echo "[DEBUG] Add-on Mode: ${API_MODE}" >&2

if [[ "$API_MODE" != "normal" && "$API_MODE" != "native" ]]; then
    echo ""
    err "Add-on läuft im Mode '${API_MODE:-unbekannt}' – Registrierung nicht möglich!"
    warn "Die Registrierung funktioniert nur im Mode 'normal' oder 'native'."
    info "So umstellen:"
    info "  1. HA → Einstellungen → Add-ons → Signal Messenger → Konfiguration"
    info "  2. Mode auf 'normal' ändern und Add-on neu starten"
    info "  3. Dieses Skript erneut ausführen"
    info "  4. Nach erfolgreicher Registrierung Mode zurück auf 'json-rpc' stellen"
    echo ""
    exit 1
fi
ok "Add-on Mode: ${API_MODE} ✔"

do_curl GET "${API_BASE}/v1/accounts" ""
ACCOUNTS=$(curl_body)

if [[ "${LAST_HTTP_CODE}" == "200" ]]; then
    if echo "$ACCOUNTS" | grep -q "$PHONE"; then
        warn "Nummer ${PHONE} ist in diesem Add-on bereits registriert."
        warn "Eine Neu-Registrierung überschreibt den bestehenden Account."
        read -rp "   Trotzdem neu registrieren? [j/N]: " redo
        if [[ ! "$redo" =~ ^[jJyY]$ ]]; then
            info "Abbruch auf Wunsch."
            exit 0
        fi
    else
        ok "Nummer ${PHONE} noch nicht registriert – Registrierung wird gestartet."
    fi
else
    # Im normal-Mode ohne registrierte Nummer liefert /v1/accounts HTTP 500 – das ist normal
    $DEBUG && echo "[DEBUG] Accounts-Abfrage HTTP ${LAST_HTTP_CODE}: noch keine Nummer im Add-on registriert" >&2
    ok "Noch keine Nummer registriert – Registrierung wird gestartet."
fi
echo ""

# ════════════════════════════════════════════════════════
# Schritt 1: Erster Versuch (SMS) – schlägt bei Festnetz fehl
# ════════════════════════════════════════════════════════
hr
echo -e "  ${CYAN}Schritt 1/5:${NC} Erster Registrierungsversuch (SMS)"
echo -e "  ${YELLOW}Bei Festnetz erwartet: Signal kann keine SMS senden → Fehler ist normal${NC}"
hr
get_captcha 1

echo ""
info "Sende Anfrage mit use_voice=false..."
do_curl POST "${API_BASE}/v1/register/${PHONE}" \
    "{\"captcha\":\"${CAPTCHA}\", \"use_voice\": false}"
RESULT=$(curl_body)
echo ""
info "Antwort der API: ${RESULT:-<leer – vermutlich OK>}"
check_status "sms"
echo ""

if [[ "${LAST_HTTP_CODE}" != "400" ]] && echo "$RESULT" | grep -qi '"error"'; then
    warn "Fehlerantwort erhalten – bei Festnetz erwartet (keine SMS möglich)."
    ok  "Fortfahren mit Voice-Verifikation (Schritt 2+3)."
else
    ok "Anfrage ohne Fehler akzeptiert."
    read -rp "   Hast du eine SMS mit Verifikationscode empfangen? [j/N]: " got_sms
    if [[ "$got_sms" =~ ^[jJyY]$ ]]; then
        SKIP_VOICE=true
        ok "Überspringe Voice-Schritt, gehe direkt zu Schritt 4."
    fi
fi

# ════════════════════════════════════════════════════════
# Schritt 2: 60 Sekunden Wartezeit (Signal-Pflicht)
# ════════════════════════════════════════════════════════
if [[ "$SKIP_VOICE" != "true" ]]; then
    hr
    echo -e "  ${CYAN}Schritt 2/5:${NC} 60 Sekunden warten"
    echo -e "  ${YELLOW}Signal verlangt diese Pause vor einem Voice-Versuch${NC}"
    hr
    echo ""
    for i in $(seq 60 -1 1); do
        printf "\r   Warte noch: %2d Sekunden..." "$i"
        sleep 1
    done
    printf "\r   Wartezeit abgelaufen.              \n"
    echo ""
    ok "Bereit für Voice-Versuch."

    # ════════════════════════════════════════════════════
    # Schritt 3: Zweiter Versuch (Voice-Anruf)
    # ════════════════════════════════════════════════════
    hr
    echo -e "  ${CYAN}Schritt 3/5:${NC} Zweiter Versuch – Voice-Anruf"
    echo -e "  ${YELLOW}Signal ruft jetzt deine Festnetznummer an${NC}"
    hr
    get_captcha 2

    echo ""
    info "Sende Anfrage mit use_voice=true..."
    do_curl POST "${API_BASE}/v1/register/${PHONE}" \
        "{\"captcha\":\"${CAPTCHA}\", \"use_voice\": true}"
    RESULT=$(curl_body)
    echo ""
    info "Antwort der API: ${RESULT:-<leer – vermutlich OK>}"
    check_status "voice"
    echo ""

    if echo "$RESULT" | grep -qi '"error"'; then
        err "Fehler beim Voice-Versuch."
        err "Antwort: $RESULT"
        echo ""
        info "Mögliche Ursachen:"
        info "  – Captcha-Token abgelaufen (zu langsam eingegeben)"
        info "  – Captcha vom Browser einer anderen IP gelöst als HA-Host-IP"
        exit 1
    fi
    ok "Voice-Anfrage erfolgreich gesendet. Telefon sollte jetzt klingeln."
fi

# ════════════════════════════════════════════════════════
# Schritt 4: Verifikationscode eingeben
# ════════════════════════════════════════════════════════
hr
echo -e "  ${CYAN}Schritt 4/5:${NC} Verifikationscode eingeben"
hr
echo ""
warn "Nimm den Anruf entgegen und notiere den angesagten 6-stelligen Code."
warn "Kein Bindestrich eingeben (aus '123-456' wird '123456')."
echo ""
read -rp "   Verifikationscode: " VCODE
VCODE="${VCODE//[^0-9]/}"    # Nur Ziffern behalten

if [[ ${#VCODE} -lt 6 ]]; then
    err "Code zu kurz (${#VCODE} Stellen). Abbruch."
    exit 1
fi

echo ""
info "Sende Verifikationscode ${VCODE}..."
do_curl POST "${API_BASE}/v1/register/${PHONE}/verify/${VCODE}" ""
RESULT=$(curl_body)
echo ""
info "Antwort der API: ${RESULT:-<leer – das ist OK>}"
echo ""

if echo "$RESULT" | grep -qi '"error"'; then
    err "Verifikation fehlgeschlagen."
    err "Antwort: $RESULT"
    info "Hinweis: Bei falschem Code einfach Skript neu starten."
    exit 1
fi
ok "Verifikation erfolgreich!"

# ════════════════════════════════════════════════════════
# Schritt 5: Account-Status prüfen
# ════════════════════════════════════════════════════════
hr
echo -e "  ${CYAN}Schritt 5/5:${NC} Account-Status prüfen"
hr
echo ""
info "Frage registrierte Accounts ab..."
do_curl GET "${API_BASE}/v1/accounts" ""
RESULT=$(curl_body)
echo ""
info "Registrierte Accounts: ${RESULT}"
echo ""

if echo "$RESULT" | grep -q "$PHONE"; then
    ok "Nummer ${PHONE} ist erfolgreich registriert!"
else
    warn "Nummer nicht in der Account-Liste. Antwort oben prüfen."
    warn "Manchmal erscheint die Nummer erst nach einem Neustart des Add-ons."
fi

# ════════════════════════════════════════════════════════
# Abschluss: Hinweise für HA
# ════════════════════════════════════════════════════════
hr
echo -e "  ${CYAN}Fertig! Nächste Schritte:${NC}"
hr
echo ""
info "── Testnachricht senden ────────────────────────────"
echo ""
cat << TESTMSG
  curl -X POST -H 'Content-Type: application/json' \\
    '${API_BASE}/v2/send' \\
    -d '{
      "message": "Testmeldung von Home Assistant",
      "number": "${PHONE}",
      "recipients": ["+49EMPFAENGERNUMMER"]
    }'
TESTMSG
echo ""
info "── Mode zurückstellen für Betrieb ─────────────────"
echo ""
echo -e "   ${YELLOW}Wichtig: Add-on jetzt zurück auf JSON-RPC stellen:${NC}"
info "  1. HA → Einstellungen → Add-ons → Signal Messenger → Konfiguration"
info "  2. Mode auf 'json-rpc' ändern und Add-on neu starten"
info "  3. Dann configuration.yaml eintragen und HA neu starten"
echo ""
info "── configuration.yaml Eintrag ──────────────────────"
echo ""
cat << YAML
  notify:
    - name: signal
      platform: signal_messenger
      url: "${API_BASE}"
      number: "${PHONE}"
      recipients:
        - "+49EMPFAENGERNUMMER"
YAML
echo ""
hr

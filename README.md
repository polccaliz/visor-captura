# Visor Captura

App nativa de macOS (Swift) per veure en pantalla el senyal d'una capturadora de vídeo (USB/HDMI) amb àudio.

## Requisits
- macOS 12 o superior
- Eines de desenvolupament (`xcode-select --install`)

## Compilar
```bash
./build.sh
```
Compila l'app, la signa en local (ad-hoc) i crea `Visor Captura.dmg` a l'Escriptori.

## Instal·lar sense compilar
Baixa el `.dmg` de la pàgina de [Releases](../../releases), obre'l i arrossega l'app a Aplicacions.
Com que no està signada amb Apple Developer, el primer cop: clic dret a l'app > Obrir > Obrir.
Si macOS la bloqueja: Ajustos del Sistema > Privacitat i seguretat > "Obrir igualment".

## Permisos
Al primer ús, macOS demanarà accés a la càmera (senyal de la capturadora) i al micròfon (àudio).

## Llicència
MIT

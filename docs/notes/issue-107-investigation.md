# Onderzoek issue #107 — OpenCode v2

Onderzocht op 2 oktober 2026, op branch
`fix/opencode-v2-session-tracker`, vanaf `origin/main`
`c3895253bf3445548c8d007eb961ab8926de6226`.
Tmux- en Codex-naam:
`timvw/tmux-assistant-resurrect - issue-107 - opencode-v2`.

## Resultaat

De bug is met de echte OpenCode 2.0.22-binary gereproduceerd. De fix
voegt `@assistant-resurrect-opencode 'off'` toe en voorkomt automatische
installatie van de v1-hook bij niet-ondersteunde OpenCode-versies. Een bestaande
herkenbare tracker-symlink wordt daarbij verwijderd, ook na een upgrade of bij
een verouderd checkoutpad. Gewone bestanden en symlinks naar andere plugins
blijven behouden. Claude- en Cursor-installatie blijven onafhankelijk werken,
met hun eigen `@assistant-resurrect-claude` en `@assistant-resurrect-cursor`
opt-outs. Alle drie installers blijven standaard ingeschakeld.

Native v1-tracking blijft behouden. Deze wijziging implementeert **geen native
v2-sessietracking**: de geverifieerde v2-serverinterface identificeert niet de
geselecteerde conversatie van één TUI-proces in een tmux-pane.

Het [actuele issue](https://github.com/timvw/tmux-assistant-resurrect/issues/107)
was bij de controle open en zonder reacties. De gecontroleerde recente open en
gesloten PR's bevatten geen oplossing voor dit probleem; remote `main` kwam
overeen met de worktreebasis.

## Oorzaak en upstreambewijs

De bestaande hook exporteert uitsluitend de async functie `SessionTracker`.
Dat is de v1-interface: initialisatie ontvangt `client` en `directory`, en
retourneert een object met een `event`-callback.

De officiële v2-loader decodeert daarentegen een module met een default-export
met `id` en `effect` of `setup`. Als die ontbreekt, produceert hij letterlijk
de gemelde fout. Dit staat in
[plugin/module.ts op v2-commit dbe08d2](https://github.com/anomalyco/opencode/blob/dbe08d2ac3fbee752ed143ea15ffe502649e6164/packages/core/src/plugin/module.ts).
De [Promise-plugininterface](https://github.com/anomalyco/opencode/blob/dbe08d2ac3fbee752ed143ea15ffe502649e6164/packages/plugin/src/promise/plugin.ts)
bevestigt `setup(context)` en een teruggegeven cleanupfunctie.

De [officiële migratiehandleiding](https://github.com/anomalyco/opencode/blob/dbe08d2ac3fbee752ed143ea15ffe502649e6164/services/www/src/docs/content/build/plugins/migrate-v1.mdx)
vervangt de v1-eventcallback door `ctx.event.subscribe()` en `directory` door
`ctx.location.directory`. Hij waarschuwt dat de pluginlocatie niet noodzakelijk
de locatie is van alle waargenomen sessies. Een gecombineerde default-export
met v1 `server()` en v2 `setup()` werkt pas vanaf v1.18.29; oudere v1-loaders
kunnen zo'n object niet laden. Een universele exportwijziging zou dus bestaande
v1-installaties kunnen breken.

Daarnaast start de
[v2 CLI standaard een achtergrondserver](https://github.com/anomalyco/opencode/blob/dbe08d2ac3fbee752ed143ea15ffe502649e6164/packages/cli/src/commands/handlers/default.ts).
De serverplugin draait daarmee niet vanzelf onder de PID van de TUI in de pane.
De conclusie voor onze architectuur is dat alleen de export en eventvorm
aanpassen onvoldoende is: `opencode-<process.pid>.json` zou een server kunnen
identificeren, terwijl save de TUI zoekt. Serverevents geven ook geen bewijs
welke sessie de gebruiker in een bepaalde TUI heeft geselecteerd.

De v2-package levert bovendien zowel `opencode` als `opencode2`.
Beide ontdekken dezelfde globale plugins. De installer controleert daarom
beide beschikbare executables: een v1 `opencode` naast een v2 `opencode2` mag
niet alsnog de gedeelde v1-hook installeren.

## Lokale wijziging

- `off` wordt vóór iedere versieprobe en installatie verwerkt. Herhaald
  opstarten hermaakt de link niet; `on` of een ontbrekende optie activeert
  installatie alleen als alle gevonden OpenCode-commando's herkenbare v1
  melden.
- De versiecontrole gebeurt vóór de bestaande “al correct gelinkt”-guard.
  Daardoor wordt een reeds geïnstalleerde hook na een v2-upgrade verwijderd.
- V2, toekomstige majors, dev/onbekende uitvoer, ontbrekende binaries en
  mislukte probes krijgen geen hook. Meerregelige diagnostiek telt niet als
  geldige versie, ook niet als één regel op v1 lijkt.
- Opruimen raakt alleen `session-tracker.js` wanneer die een symlink is naar
  `*/hooks/opencode-session-track.js`. Het volgt geen linkdoel. De bestaande
  v1-installguards voor gewone bestanden en symlinks naar directories blijven
  intact.
- Hookcode, veilige atomische statewrites, permissies en het state-directory-
  contract zijn ongewijzigd. Er zijn geen wrappers toegevoegd.
- Claude/Cursor-opt-outs verwijderen huidige en stale native hooks, zonder
  andere hooks of instellingen te verwijderen. JSON-updates behouden
  dotfile-symlinkketens en targetmodi, weigeren te diepe/cyclische ketens en
  schrijven atomisch naast het opgeloste target. Ontbrekende configuratie
  wordt bij `off` niet aangemaakt; ongeldige JSON blijft staan.

De optie regelt uitsluitend automatische **plugininstallatie**. De bestaande
argv/SQLite-fallbacks en save/restore-hooks blijven actief. Dat is geen belofte
van volledige v2-restore. De binary moet op tmux's `PATH` staan voor automatische
v1-installatie; een niet-zichtbare alternatieve v2-binary kan niet worden ontdekt.

## Verificatie

Alle tests gebruiken tijdelijke homes/config/state en eigen subprocessen of
Docker. De binarycontracttest gebruikt `serve` met een eigen lokale poort en
procesgroep, zonder login, prompts of modelverzoeken. Er wordt geen gedeelde
OpenCode-service gestart of gestopt.

- De uitgebreide installer/hardening-suite: **123 geslaagd**, geen fouten of
  skips op macOS en onder Bash 3.2 in Linux/Docker. De nieuwe regressies falen
  aantoonbaar tegen de oorspronkelijke installer uit `HEAD`.
- De nieuwe `test/opencode-plugin-contract-test.py`: echte v1.18.34 laadt de
  native plugin, registreert twee `session.created`-events en `session.updated`,
  bewaart geconfigureerde env en private JSON, en ruimt state op bij stoppen.
  Echte v2.0.22 meldt vóór de fix exact de issuefout; na twee installer-runs
  bevat de plugininventaris geen falende tracker. Claude blijft geïnstalleerd.
  De combinatie v1 `opencode` / v2 `opencode2` is eveneens gecontroleerd.
- State-directory-suite: **63 geslaagd**; save-hardening: **95 geslaagd**;
  restore-suite: **185 geslaagd**, inclusief de gedeelde replay-policy-suite.
- De volledige Linux/Docker-suite onder Bash 5 eindigde met **518 geslaagd,
  1 fout**. Die fout was de Python-compilatiecheck: mijn read-only bind-mount
  verhindert dat `py_compile` een `__pycache__` naast de broncode schrijft.
  Dezelfde helpers compileren allemaal succesvol vanuit een tijdelijke
  schrijfbare kopie in hetzelfde image. Op dat moment is de volledige suite niet opnieuw
  gedraaid; de gerichte herhaling bevestigt de oorzaak in de testopstelling.
  De echte install/save/restore-scenario's slaagden. Het image bevat tmux 3.4;
  de contractcases die tmux >= 3.7 vereisen worden daar bewust overgeslagen.
- ShellCheck, Ruff op de nieuwe Python-test, `node --check` op de bestaande
  hook, YAML-parsing van de aangepaste workflow en `git diff --check` slagen.

De echte v1/v2-contracttest is toegevoegd aan de macOS-CI-job met afzonderlijke,
gepinde npm-prefixes. De installerregressies draaien mee in de bestaande
hermetische suites; er is geen GitHub-workflow herstart.

De eerste macOS-CI-run bevestigde het echte OpenCode-contract, maar faalde op
een bestaande Copilot-aanname: een lege sessie in 1.0.91 maakt nog geen globale
`session-store.db` aan. De [officiële configuratiereferentie](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
beschrijft die als gedeelde index en vermeldt dat bestanden op aanvraag ontstaan.
De contracttest controleert nu expliciet dat de bestaande productie-resolver
zonder die index werkt; de PID-lock en per-sessie `session.db` blijven vereist.
De echte Copilot-contracttest slaagt lokaal met **18 checks**.

De Linux-runs onthulden daarnaast twee fouten bij Copilot 1.0.91: de contracttest
koos soms de interne `.session-operation-locks`-map in plaats van de map met de
native PID-lock, en de help-warmup stopte onder `set -e` als de oude variadic-regex
niets vond. De test selecteert nu de map via de echte PID-lock. De gedeelde
replayhelper bereikt weer de bestaande statische fallback wanneer de nieuwe
`<tools>...`-notatie geen match oplevert. Een regressie in een nieuwe shell met
`errexit` en `pipefail` controleert warmup en fallback. De sessie-ID-lookup is
ongewijzigd. De integratietest gebruikt voor tekstasserties een here-string,
zodat een succesvolle `grep -q` geen SIGPIPE-fout van de producent veroorzaakt.

## Grenzen en vervolg

Voor volledige v2-tracking moet een native TUI-plugin de geselecteerde route/
sessie aan de TUI-PID en pane koppelen. De publieke TUI-context biedt
`ctx.ui.router.current()` en lokale sessiedata, maar die aanpak is hier niet
als sessieherstel getest of geïmplementeerd. Nodige vervolgtests omvatten
session switching, meerdere TUI's op één server, gelijke cwd's, afsluiten/
pluginreload, en daadwerkelijke tmux-save/restart/restore met v2.

Er is geen geauthenticeerde v2-conversatiehersteltest gedaan. De fix neemt de
pluginlaadfout weg en behoudt geverifieerde native v1-tracking; hij claimt geen
volledige v2-ondersteuning. De melder kan de opt-out en automatische v2-skip
testen zodra deze lokale wijziging langs de normale reviewroute beschikbaar is.

Het onderzoek en de tests hebben geen live gebruikersdotfiles, hooks,
tmux-configuratie of gedeelde triagenotes aangepast.

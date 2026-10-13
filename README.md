# Homey Self-Hosted Server – backup & restore voor Proxmox

Bash-script om de map `/root/.homey-shs` van de Homey Self-Hosted Server
(LXC-container, standaard ID `100`) op Proxmox te back-uppen, te controleren en te herstellen.
Het script draait op de **Proxmox-host** en gebruikt `pct`. Er is geen extra software nodig.

## Snel starten

Als root op de Proxmox-host:

```bash
# Direct draaien vanaf GitHub
bash <(curl -fsSL https://raw.githubusercontent.com/charlesderidder/HomeySHS-Backup/refs/heads/main/Homey-backup.sh) backup

# Of eerst downloaden (aanbevolen, zodat je het eerst kunt lezen)
curl -fsSL https://raw.githubusercontent.com/charlesderidder/HomeySHS-Backup/refs/heads/main/Homey-backup.sh -o Homey-backup.sh
chmod +x Homey-backup.sh
./Homey-backup.sh backup
```

Met `bash <(curl ...)` blijft de terminal beschikbaar, zodat de bevestiging bij een restore werkt.
Gebruik dus niet `curl ... | bash`.

## Commando's

| Commando | Doel |
|---|---|
| `./Homey-backup.sh backup` | Backup maken |
| `./Homey-backup.sh list` | Beschikbare backups tonen |
| `./Homey-backup.sh verify <bestand>` | Backup controleren zonder te herstellen |
| `./Homey-backup.sh restore <bestand>` | Backup herstellen |
| `./Homey-backup.sh help` | Hulp tonen |

```bash
./Homey-backup.sh restore /var/lib/vz/dump/homey/homey-shs-ct100-<datum>.tar.gz
```

## Instellingen

Bovenaan `Homey-backup.sh` staan de variabelen die je kunt aanpassen. De belangrijkste:

| Variabele | Standaard | Betekenis |
|---|---|---|
| `CTID` | `100` | ID van de Homey-container |
| `SRC_DIR` | `/root/.homey-shs` | Map met Homey-data in de container |
| `BACKUP_DIR` | `/var/lib/vz/dump/homey` | Opslagmap op de host |
| `KEEP` | `14` | Aantal backups bewaren (`0` = alles) |
| `MOUNT_CHECK` | leeg | Pad dat gemount moet zijn, bijv. `/mnt/nas` |
| `ASSUME_YES` | `0` | `1` = restore zonder bevestiging (voor cron) |

Je kunt ze ook per keer overschrijven:

```bash
KEEP=5 BACKUP_DIR=/mnt/nas/homey ./Homey-backup.sh backup
```

## Automatisch backuppen (cron)

Elke nacht om 03:00:

```bash
crontab -e
# regel toevoegen:
0 3 * * * bash <(curl -fsSL https://raw.githubusercontent.com/charlesderidder/HomeySHS-Backup/refs/heads/main/Homey-backup.sh) backup >/dev/null 2>&1
```

Het logbestand staat in `/var/log/homey-backup.log`.

## Downloaden naar je computer

```bash
scp root@<proxmox-ip>:/var/lib/vz/dump/homey/homey-shs-ct100-*.tar.gz .
```

Of gebruik WinSCP / FileZilla (SFTP) op Windows, of Cyberduck op macOS.

## Belangrijk

- Tijdens backup en restore wordt de container **gestopt**. Homey ligt er dus even uit.
- De container wordt na afloop altijd weer gestart, ook bij een fout.
- Bij een restore wordt de bestaande map eerst hernoemd naar `.voor-restore-<datum>`.
- Controleer eerst of het pad `/var/lib/lxc/100/rootfs` klopt met `pct mount 100`.
- Een backup bevat geheimen (tokens, wachtwoorden). Deel hem dus niet publiek.
- Test een restore liefst eerst op een testcontainer.

## Licentie

MIT

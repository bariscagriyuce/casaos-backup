# CasaOS → Google Drive Automatic Backup

**Languages:** [English](#english) · [Türkçe](#türkçe)

---

## English

A Docker Compose based system running on CasaOS that backs up your entire CasaOS setup (app data, app definitions, system settings) to Google Drive on a schedule — **encrypted and incremental**.

- **restic**: encryption, deduplication (only changed chunks are uploaded), snapshots and retention policy
- **rclone**: Google Drive connection
- **crond**: scheduling
- Stops containers during the backup and restarts them afterwards, so databases (SQLite, Postgres, etc.) are captured consistently
- ntfy / Telegram notification on failure (or on every run)

### What gets backed up?

| Host path | Contents |
|---|---|
| `/DATA/AppData` | Settings and data of all CasaOS apps |
| `/var/lib/casaos` | App docker-compose definitions (`apps/`), CasaOS database |
| `/etc/casaos` | CasaOS service configuration |
| (automatic) | Container, image, network and volume lists (`/backup-meta`) |

To add more folders (for example apps that keep data outside `/DATA/AppData`, like `/srv/...`), create `docker-compose.override.yml` next to `docker-compose.yml`. Docker Compose merges it automatically and `git pull` never touches it:

```yaml
services:
  casaos-backup:
    volumes:
      - /srv/lsio:/source/srv/lsio:ro
      - /DATA/Media:/source/DATA/Media:ro
      - /etc:/source/etc:ro
      - /root:/source/root:ro
```

Apply with `sudo docker compose up -d`. To find folders that are not backed up yet:

```bash
docker inspect -f '{{.Name}}{{range .Mounts}} {{.Source}}{{end}}' $(docker ps -aq) | tr ' ' '\n' | grep '^/' | grep -vE '^/(DATA/AppData|var/lib/casaos|etc/casaos|var/lib/docker|var/run|run|dev|proc|sys)' | sort -u
```

(Lines that are just container names, like `/nextcloud`, can be ignored.)

**Self-built Docker images** (an image you built with `docker build` that is not on a registry) are not in the backup. Save them into a backed-up folder, and repeat after every rebuild:

```bash
mkdir -p /DATA/AppData/docker-images && docker save IMAGE_NAME | gzip > /DATA/AppData/docker-images/IMAGE_NAME.tar.gz
```

Exclusions live in `config/excludes.txt`.

### Installation

#### 1. Copy the files to your CasaOS server

```bash
git clone https://github.com/bariscagriyuce/casaos-backup.git /tmp/casaos-backup
```

```bash
sudo mv /tmp/casaos-backup /DATA/AppData/casaos-backup
```

```bash
cd /DATA/AppData/casaos-backup && sudo cp .env.example .env
```

Edit `.env` and change **at least `RESTIC_PASSWORD`**. To generate a random password:

```bash
openssl rand -base64 32
```

> ⚠️ Store this password in your password manager. Without it, backups **cannot be decrypted**.

#### 2. Start the container

```bash
sudo docker compose up -d --build
```

The container waits until rclone is configured (check with `docker logs casaos-backup`).

#### 3. Configure the Google Drive connection (rclone)

rclone's shared Google client ID is being retired in 2026, so you need **your own (free) client ID**. You also do the Google sign-in on your own computer, so nothing waits on the server (web terminals like CasaOS's tend to disconnect).

**3a. Create a client ID** at [console.cloud.google.com](https://console.cloud.google.com):

1. Create a new project (e.g. `casaos-backup`).
2. **APIs & Services → Library → Google Drive API → Enable**.
3. **Google Auth Platform** (or **OAuth consent screen**): enter an app name and your e-mail, user type **External**.
4. **Audience → Publish app**. Otherwise the token expires every 7 days and backups stop. The `drive.file` scope needs no Google review.
5. **Clients → Create client → Desktop app**. Copy the **Client ID** and **Client secret**.

**3b. Create the rclone config on your computer** ([install rclone](https://rclone.org/install/) there; a browser opens, sign in and allow):

```bash
rclone config create gdrive drive client_id=YOUR_CLIENT_ID client_secret=YOUR_SECRET scope=drive.file --config ~/gdrive-rclone.conf
```

> `scope=drive.file` lets rclone see only the files it created itself; the rest of your Drive stays out of reach. Files are tied to the client ID: if you change the client ID later, rclone can no longer see the existing backups.

**3c. Copy it to the server:**

```bash
scp ~/gdrive-rclone.conf root@SERVER-IP:/DATA/AppData/casaos-backup/config/rclone/rclone.conf
```

No SSH? Open `nano config/rclone/rclone.conf` on the server and paste **all** lines of the file (`[gdrive]`, `type`, `client_id`, `client_secret`, `scope`, `token`).

**3d. Test and start:**

```bash
sudo docker compose run --rm --entrypoint rclone casaos-backup lsd gdrive:
```

```bash
sudo docker compose up -d
```

Within a minute the container creates the `casaos-backup` folder and the restic repository on Drive (`docker logs casaos-backup` shows `created restic repository`).

> If the connection fails (missing or expired token), the container does not crash; it logs the error and retries every 5 minutes, so you can fix the config while it is running.

<details><summary>Alternative: interactive wizard on the server</summary>

```bash
sudo docker compose exec casaos-backup rclone config
```

`n` → name `gdrive` → storage `drive` → enter your client ID/secret → scope `3` → `Use web browser?` `n` → run the shown `rclone authorize "drive" "..."` command on a computer with a browser and paste the result → Shared drive `n` → `y` → `q`. Answer quickly: the wizard is lost if the terminal disconnects.
</details>

#### 4. Run the first backup manually (recommended)

The first backup uploads everything and may take hours; later runs upload only changes. Start it in the background so it keeps running if your terminal disconnects:

```bash
sudo docker exec -d casaos-backup sh -c 'backup > /proc/1/fd/1 2>&1'
```

Containers are **not** stopped during this first backup (`FIRST_BACKUP_NO_STOP=true`). Progress appears in `docker logs casaos-backup` once a minute.

From then on it runs automatically at `BACKUP_CRON` from `.env` (default: every night at 03:00).

### Daily usage

Follow logs:

```bash
sudo docker logs -f casaos-backup
```

List snapshots:

```bash
sudo docker compose exec casaos-backup restore
```

Check repository integrity manually:

```bash
sudo docker compose exec casaos-backup backup --check-only
```

Space used on Drive:

```bash
sudo docker compose exec casaos-backup restic stats --mode raw-data
```

Stop a running backup (containers are restarted automatically):

```bash
sudo docker exec casaos-backup pkill restic
```

> Don't use `docker stop casaos-backup` for this: the script can't restart your apps then. (If it happens anyway, they are started again the next time the backup container starts.)

### Performance

The backup runs with low CPU/disk priority and is limited to `BACKUP_CPUS` (default 1) and `BACKUP_MEM_LIMIT` (default 1536m). If the server becomes slow or unreachable during backups, lower these in `.env`; if uploads are slow and you have spare RAM, raise `DRIVE_CHUNK_SIZE` (e.g. `64M`). Apply with `sudo docker compose up -d`.

### Container stop behaviour

`STOP_MODE=all` (default): all running containers are stopped during the backup and restarted right after the files are read (before pruning). For incremental backups this is usually a few minutes. The first backup is taken without stopping anything (`FIRST_BACKUP_NO_STOP`). If a backup is interrupted while apps are stopped (e.g. the server reboots), they are started again when the backup container starts.

> Containers you need to reach the server (Cloudflare Tunnel, Tailscale, VPN, reverse proxy, Pi-hole/AdGuard DNS) must not be stopped, otherwise you lose access during backups. List their names in `.env` (find them with `docker ps --format '{{.Names}}'`), then apply with `sudo docker compose up -d`:
>
> ```bash
> STOP_EXCLUDE=cloudflared,tailscale
> ```
>
> This is the recommended way on CasaOS. The label below also works, but CasaOS sometimes recreates apps from its own stored settings and the label you added to the compose file is lost.

To never stop a specific app, add this label to its compose file (in CasaOS: app → Settings → edit compose):

```yaml
labels:
  casaos-backup.stop: "false"
```

With `STOP_MODE=labeled` it works the other way around: only containers labelled `casaos-backup.stop: "true"` are stopped.

### Restore

#### Restore a single app

Example: restore Jellyfin settings from the latest backup:

```bash
sudo docker compose exec casaos-backup restore latest --include /source/DATA/AppData/jellyfin
```

Files are extracted on the host under `/DATA/AppData/casaos-backup/restore/source/DATA/AppData/jellyfin`. Stop the app and copy the folder back:

```bash
sudo rsync -a --delete /DATA/AppData/casaos-backup/restore/source/DATA/AppData/jellyfin/ /DATA/AppData/jellyfin/
```

#### Full restore from scratch (disk failure / new server / reinstall)

**Keep these outside the server, you can't restore without them:**

- `RESTIC_PASSWORD` from `.env`. Without it the backups cannot be decrypted.
- `config/rclone/rclone.conf`, **and** the Google Cloud project with your client ID. With `scope=drive.file` only that client ID can see the backups, so never delete that project. If you lose `rclone.conf`, create a new one with the same client ID (step 3b above).

**Steps:**

1. Install Debian and CasaOS.
2. Install this tool again, but **don't start a backup**:
   ```bash
   sudo git clone https://github.com/bariscagriyuce/casaos-backup.git /DATA/AppData/casaos-backup
   ```
   Create `.env` with **the same `RESTIC_PASSWORD`** and `RESTIC_REPOSITORY`, and copy `rclone.conf` to `config/rclone/`. Then:
   ```bash
   cd /DATA/AppData/casaos-backup && sudo docker compose up -d --build
   ```
3. Extract the latest snapshot (all files go into `restore/`, nothing is overwritten yet):
   ```bash
   sudo docker exec casaos-backup restore latest
   ```
4. Stop CasaOS so no app starts with empty data:
   ```bash
   sudo systemctl stop casaos casaos-app-management
   ```
5. Copy the data back. `--numeric-ids` keeps the file owners the containers expect:
   ```bash
   R=/DATA/AppData/casaos-backup/restore/source
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/DATA/AppData/ /DATA/AppData/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/var/lib/casaos/ /var/lib/casaos/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/etc/casaos/ /etc/casaos/
   ```
   Folders you added with `docker-compose.override.yml` (skip the ones you don't have):
   ```bash
   sudo mkdir -p /srv/lsio && sudo rsync -a --numeric-ids $R/srv/lsio/ /srv/lsio/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/DATA/Media/ /DATA/Media/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/root/ /root/
   ```
6. **Don't copy the whole `/etc`** over the new system: disk IDs, network settings and the machine ID differ, and the server may not boot. Take only what you need from `$R/etc`, for example:
   - `/etc/ssh/` (keeps the server's SSH keys, so clients don't warn about a changed host)
   - extra disk lines from `/etc/fstab` (copy the lines by hand, check the UUIDs with `blkid`)
   - configs of other services you installed (e.g. `/etc/apache2/`)

   To see what differs: `sudo diff -rq $R/etc /etc | less`
7. Load self-built images (e.g. from `/DATA/AppData/docker-images`):
   ```bash
   for f in /DATA/AppData/docker-images/*.tar.gz; do sudo docker load < "$f"; done
   ```
8. Start CasaOS. Apps are recreated from the compose files in `/var/lib/casaos/apps`:
   ```bash
   sudo systemctl start casaos casaos-app-management
   ```
   If an app does not come up, start it from the CasaOS dashboard, or:
   ```bash
   cd /var/lib/casaos/apps/APP_NAME && sudo docker compose up -d
   ```
9. Restart the backup container, so it picks up the restored `docker-compose.override.yml`, then delete the extracted copy:
   ```bash
   cd /DATA/AppData/casaos-backup && sudo docker compose up -d
   ```
   ```bash
   sudo rm -rf /DATA/AppData/casaos-backup/restore/source /DATA/AppData/casaos-backup/restore/backup-meta
   ```
   The next nightly backup continues in the same repository and uploads only the changes.

The old container, image and network lists are in `restore/backup-meta/` if you need to look something up (before step 9).

> **Test it once before you need it:** restore a small folder (`restore latest --include /source/DATA/AppData/SOME_APP`) and check the files in `restore/`.

### Security notes

- The container has access to the Docker socket (to stop and start containers) — this is equivalent to root on the host. Restrict the folder to root: `sudo chmod 700 /DATA/AppData/casaos-backup`.
- Keep a copy of `.env` (password) and `config/rclone/rclone.conf` (Drive token) **outside** the server; if the server is lost entirely you'll need them to restore.
- Data on Drive is encrypted by restic with AES-256; Google cannot read the contents.

### File layout

```
casaos-backup/
├── docker-compose.yml
├── Dockerfile
├── .env.example        → copy to .env
├── config/
│   ├── excludes.txt    exclusion patterns
│   └── rclone/         rclone.conf is created here
├── scripts/
│   ├── entrypoint.sh   scheduling + repository init
│   ├── backup.sh       backup, stop/start, retention, notifications
│   └── restore.sh      snapshot list / restore
├── cache/              restic cache (automatic)
└── restore/            restored files (automatic)
```

---

## Türkçe

CasaOS üzerinde Docker Compose ile çalışan, tüm CasaOS sistemini (uygulama verileri, uygulama tanımları, sistem ayarları) zamanlanmış olarak **şifreli ve artımlı** şekilde Google Drive'a yedekleyen sistem.

- **restic**: şifreleme, tekilleştirme (sadece değişen parçalar yüklenir), snapshot ve saklama politikası
- **rclone**: Google Drive bağlantısı
- **crond**: zamanlama
- Yedek sırasında konteynerleri durdurup sonra tekrar başlatır, böylece veritabanları (SQLite, Postgres vb.) tutarlı yedeklenir
- Hata olursa (veya her seferinde) ntfy / Telegram bildirimi

### Neler yedekleniyor?

| Host yolu | İçerik |
|---|---|
| `/DATA/AppData` | Tüm CasaOS uygulamalarının ayarları ve verileri |
| `/var/lib/casaos` | Uygulama docker-compose tanımları (`apps/`), CasaOS veritabanı |
| `/etc/casaos` | CasaOS servis yapılandırmaları |
| (otomatik) | Konteyner, imaj, ağ ve volume listesi (`/backup-meta`) |

Başka klasör eklemek için (ör. verisini `/DATA/AppData` dışında, `/srv/...` gibi yerlerde tutan uygulamalar) `docker-compose.yml` dosyasının yanına `docker-compose.override.yml` oluşturun. Docker Compose bu dosyayı otomatik birleştirir ve `git pull` ona dokunmaz:

```yaml
services:
  casaos-backup:
    volumes:
      - /srv/lsio:/source/srv/lsio:ro
      - /DATA/Media:/source/DATA/Media:ro
      - /etc:/source/etc:ro
      - /root:/source/root:ro
```

`sudo docker compose up -d` ile uygulayın. Henüz yedeklenmeyen klasörleri bulmak için:

```bash
docker inspect -f '{{.Name}}{{range .Mounts}} {{.Source}}{{end}}' $(docker ps -aq) | tr ' ' '\n' | grep '^/' | grep -vE '^/(DATA/AppData|var/lib/casaos|etc/casaos|var/lib/docker|var/run|run|dev|proc|sys)' | sort -u
```

(`/nextcloud` gibi sadece konteyner adı olan satırları yok sayın.)

**Kendi oluşturduğunuz Docker imajları** (`docker build` ile yaptığınız, hiçbir registry'de olmayan imajlar) yedekte yoktur. Yedeklenen bir klasöre kaydedin ve her yeniden derlemeden sonra tekrarlayın:

```bash
mkdir -p /DATA/AppData/docker-images && docker save IMAJ_ADI | gzip > /DATA/AppData/docker-images/IMAJ_ADI.tar.gz
```

Hariç tutmalar `config/excludes.txt` dosyasında.

### Kurulum

#### 1. Dosyaları CasaOS sunucusuna kopyalayın

```bash
git clone https://github.com/bariscagriyuce/casaos-backup.git /tmp/casaos-backup
```

```bash
sudo mv /tmp/casaos-backup /DATA/AppData/casaos-backup
```

```bash
cd /DATA/AppData/casaos-backup && sudo cp .env.example .env
```

`.env` dosyasını düzenleyip **en azından `RESTIC_PASSWORD`** değerini değiştirin. Rastgele parola üretmek için:

```bash
openssl rand -base64 32
```

> ⚠️ Bu parolayı şifre yöneticinize kaydedin. Parola olmadan yedekler **açılamaz**.

#### 2. Konteyneri başlatın

```bash
sudo docker compose up -d --build
```

Konteyner, rclone ayarlanana kadar bekleme modunda kalır (`docker logs casaos-backup` ile görebilirsiniz).

#### 3. Google Drive bağlantısını (rclone) yapın

rclone'un herkesin ortak kullandığı Google client ID'si 2026'da kapatılıyor; bu yüzden **size ait (ücretsiz) bir client ID** gerekiyor. Google girişini de kendi bilgisayarınızda yapacaksınız; böylece sunucuda hiçbir şey beklemez (CasaOS'unki gibi web terminalleri sık kopar).

**3a. Client ID oluşturun** — [console.cloud.google.com](https://console.cloud.google.com):

1. Yeni bir proje oluşturun (ör. `casaos-backup`).
2. **APIs & Services → Library → Google Drive API → Enable**.
3. **Google Auth Platform** (veya **OAuth consent screen**): uygulama adı ve e-postanızı girin, kullanıcı tipi **External**.
4. **Audience → Publish app**. Yapmazsanız token 7 günde bir geçersiz olur ve yedekler durur. `drive.file` izni Google incelemesi gerektirmez.
5. **Clients → Create client → Desktop app**. **Client ID** ve **Client secret** değerlerini kopyalayın.

**3b. rclone ayarını kendi bilgisayarınızda oluşturun** (orada [rclone kurulu](https://rclone.org/install/) olmalı; tarayıcı açılır, giriş yapıp izin verin):

```bash
rclone config create gdrive drive client_id=CLIENT_ID_NIZ client_secret=SECRET_INIZ scope=drive.file --config ~/gdrive-rclone.conf
```

> `scope=drive.file` ile rclone sadece kendi oluşturduğu dosyaları görür; Drive'ınızın geri kalanına erişemez. Dosyalar client ID'ye bağlıdır: ileride client ID'yi değiştirirseniz rclone mevcut yedekleri göremez.

**3c. Sunucuya kopyalayın:**

```bash
scp ~/gdrive-rclone.conf root@SUNUCU-IP:/DATA/AppData/casaos-backup/config/rclone/rclone.conf
```

SSH yoksa sunucuda `nano config/rclone/rclone.conf` açıp dosyanın **tüm** satırlarını (`[gdrive]`, `type`, `client_id`, `client_secret`, `scope`, `token`) yapıştırın.

**3d. Test edip başlatın:**

```bash
sudo docker compose run --rm --entrypoint rclone casaos-backup lsd gdrive:
```

```bash
sudo docker compose up -d
```

Bir dakika içinde konteyner Drive'da `casaos-backup` klasörünü ve restic deposunu oluşturur (`docker logs casaos-backup` çıktısında `created restic repository` görünür).

> Bağlantı kurulamazsa (eksik veya süresi dolmuş token) konteyner çökmez; hatayı loga yazar ve 5 dakikada bir tekrar dener. Böylece ayarı konteyner çalışırken düzeltebilirsiniz.

<details><summary>Alternatif: sunucuda etkileşimli sihirbaz</summary>

```bash
sudo docker compose exec casaos-backup rclone config
```

`n` → isim `gdrive` → storage `drive` → client ID/secret'ınızı girin → scope `3` → `Use web browser?` `n` → ekrandaki `rclone authorize "drive" "..."` komutunu tarayıcılı bir bilgisayarda çalıştırıp sonucu yapıştırın → Shared drive `n` → `y` → `q`. Hızlı olun: terminal koparsa sihirbaz yarıda kalır.
</details>

#### 4. İlk yedeği elle alın (önerilir)

İlk yedek tüm veriyi yükler ve saatler sürebilir; sonrakiler sadece değişiklikleri yükler. Terminal kopsa bile devam etmesi için arka planda başlatın:

```bash
sudo docker exec -d casaos-backup sh -c 'backup > /proc/1/fd/1 2>&1'
```

Bu ilk yedekte konteynerler **durdurulmaz** (`FIRST_BACKUP_NO_STOP=true`). İlerleme dakikada bir `docker logs casaos-backup` çıktısında görünür.

Bundan sonra `.env` içindeki `BACKUP_CRON` zamanında (varsayılan her gece 03:00) otomatik çalışır.

### Günlük kullanım

Logları izleme:

```bash
sudo docker logs -f casaos-backup
```

Snapshot listesi:

```bash
sudo docker compose exec casaos-backup restore
```

Depo bütünlüğünü elle kontrol etme:

```bash
sudo docker compose exec casaos-backup backup --check-only
```

Drive'da ne kadar yer kaplıyor:

```bash
sudo docker compose exec casaos-backup restic stats --mode raw-data
```

Çalışan bir yedeği durdurma (konteynerler otomatik tekrar başlatılır):

```bash
sudo docker exec casaos-backup pkill restic
```

> Bunun için `docker stop casaos-backup` kullanmayın: script uygulamalarınızı tekrar başlatamaz. (Yine de olursa, yedek konteyneri bir sonraki açılışında onları başlatır.)

### Performans

Yedek düşük CPU/disk önceliğiyle çalışır ve `BACKUP_CPUS` (varsayılan 1) ile `BACKUP_MEM_LIMIT` (varsayılan 1536m) ile sınırlıdır. Yedek sırasında sunucu yavaşlıyor veya erişilemez oluyorsa bunları `.env` içinde düşürün; yükleme yavaşsa ve boş RAM varsa `DRIVE_CHUNK_SIZE` değerini artırın (ör. `64M`). `sudo docker compose up -d` ile uygulayın.

### Konteyner durdurma davranışı

`STOP_MODE=all` (varsayılan): yedek alınırken çalışan tüm konteynerler durdurulur, dosyalar okunduktan hemen sonra (prune'dan önce) tekrar başlatılır. Artımlı yedeklerde bu genelde birkaç dakikadır. İlk yedek hiçbir şey durdurulmadan alınır (`FIRST_BACKUP_NO_STOP`). Uygulamalar durdurulmuşken yedek yarıda kesilirse (ör. sunucu yeniden başlarsa), yedek konteyneri açılışta onları tekrar başlatır.

> Sunucuya erişmenizi sağlayan konteynerler (Cloudflare Tunnel, Tailscale, VPN, reverse proxy, Pi-hole/AdGuard DNS) durdurulmamalı; yoksa yedek sırasında erişiminiz kesilir. Adlarını `.env` dosyasına yazın (`docker ps --format '{{.Names}}'` ile bulabilirsiniz), sonra `sudo docker compose up -d` ile uygulayın:
>
> ```bash
> STOP_EXCLUDE=cloudflared,tailscale
> ```
>
> CasaOS'ta önerilen yol budur. Aşağıdaki etiket de çalışır, ama CasaOS bazen uygulamaları kendi kayıtlı ayarlarından yeniden oluşturur ve compose dosyasına eklediğiniz etiket kaybolur.

Belirli bir uygulamanın hiç durdurulmamasını istiyorsanız o uygulamanın compose dosyasına (CasaOS'ta uygulama → Ayarlar → compose düzenle) etiket ekleyin:

```yaml
labels:
  casaos-backup.stop: "false"
```

`STOP_MODE=labeled` seçerseniz tersine, sadece `casaos-backup.stop: "true"` etiketli konteynerler durdurulur.

### Geri yükleme

#### Tek bir uygulamayı geri yükleme

Örnek: Jellyfin ayarlarını son yedekten geri almak:

```bash
sudo docker compose exec casaos-backup restore latest --include /source/DATA/AppData/jellyfin
```

Dosyalar hostta `/DATA/AppData/casaos-backup/restore/source/DATA/AppData/jellyfin` altına açılır. Uygulamayı durdurup klasörü yerine kopyalayın:

```bash
sudo rsync -a --delete /DATA/AppData/casaos-backup/restore/source/DATA/AppData/jellyfin/ /DATA/AppData/jellyfin/
```

#### Sıfırdan tüm sistemi geri yükleme (disk çöktü / yeni sunucu / format)

**Bunları sunucunun dışında saklayın, onlar olmadan geri yükleyemezsiniz:**

- `.env` içindeki `RESTIC_PASSWORD`. Bu olmadan yedekler açılamaz.
- `config/rclone/rclone.conf` **ve** client ID'nizin bulunduğu Google Cloud projesi. `scope=drive.file` ile yedekleri sadece o client ID görebilir; o projeyi asla silmeyin. `rclone.conf` kaybolursa aynı client ID ile yenisini oluşturun (yukarıdaki 3b adımı).

**Adımlar:**

1. Debian ve CasaOS'u kurun.
2. Bu aracı tekrar kurun ama **yedek başlatmayın**:
   ```bash
   sudo git clone https://github.com/bariscagriyuce/casaos-backup.git /DATA/AppData/casaos-backup
   ```
   **Aynı `RESTIC_PASSWORD`** ve `RESTIC_REPOSITORY` ile `.env` oluşturun, `rclone.conf` dosyasını `config/rclone/` içine kopyalayın. Sonra:
   ```bash
   cd /DATA/AppData/casaos-backup && sudo docker compose up -d --build
   ```
3. Son snapshot'ı açın (tüm dosyalar `restore/` altına gelir, henüz hiçbir şeyin üzerine yazılmaz):
   ```bash
   sudo docker exec casaos-backup restore latest
   ```
4. Hiçbir uygulama boş veriyle başlamasın diye CasaOS'u durdurun:
   ```bash
   sudo systemctl stop casaos casaos-app-management
   ```
5. Verileri geri kopyalayın. `--numeric-ids`, konteynerlerin beklediği dosya sahipliğini korur:
   ```bash
   R=/DATA/AppData/casaos-backup/restore/source
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/DATA/AppData/ /DATA/AppData/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/var/lib/casaos/ /var/lib/casaos/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/etc/casaos/ /etc/casaos/
   ```
   `docker-compose.override.yml` ile eklediğiniz klasörler (sizde olmayanları atlayın):
   ```bash
   sudo mkdir -p /srv/lsio && sudo rsync -a --numeric-ids $R/srv/lsio/ /srv/lsio/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/DATA/Media/ /DATA/Media/
   ```
   ```bash
   sudo rsync -a --numeric-ids $R/root/ /root/
   ```
6. **`/etc` klasörünün tamamını** yeni sistemin üzerine kopyalamayın: disk kimlikleri, ağ ayarları ve makine kimliği farklıdır; sunucu açılmayabilir. `$R/etc` içinden sadece ihtiyacınız olanları alın, örneğin:
   - `/etc/ssh/` (sunucunun SSH anahtarları korunur, istemciler "anahtar değişti" uyarısı vermez)
   - `/etc/fstab` içindeki ek disk satırları (satırları elle kopyalayın, UUID'leri `blkid` ile kontrol edin)
   - kurduğunuz diğer servislerin ayarları (ör. `/etc/apache2/`)

   Farkları görmek için: `sudo diff -rq $R/etc /etc | less`
7. Kendi oluşturduğunuz imajları yükleyin (ör. `/DATA/AppData/docker-images` içinden):
   ```bash
   for f in /DATA/AppData/docker-images/*.tar.gz; do sudo docker load < "$f"; done
   ```
8. CasaOS'u başlatın; uygulamalar `/var/lib/casaos/apps` altındaki compose dosyalarından yeniden oluşturulur:
   ```bash
   sudo systemctl start casaos casaos-app-management
   ```
   Bir uygulama ayağa kalkmazsa CasaOS panelinden başlatın ya da:
   ```bash
   cd /var/lib/casaos/apps/UYGULAMA_ADI && sudo docker compose up -d
   ```
9. Yedek konteynerini geri yüklenen `docker-compose.override.yml` ile yeniden başlatın, sonra açılan kopyayı silin:
   ```bash
   cd /DATA/AppData/casaos-backup && sudo docker compose up -d
   ```
   ```bash
   sudo rm -rf /DATA/AppData/casaos-backup/restore/source /DATA/AppData/casaos-backup/restore/backup-meta
   ```
   Bir sonraki gece yedeği aynı depoda devam eder ve sadece değişiklikleri yükler.

Eski konteyner, imaj ve ağ listeleri, bir şeye bakmanız gerekirse `restore/backup-meta/` altındadır (9. adımdan önce).

> **İhtiyacınız olmadan önce bir kez deneyin:** küçük bir klasörü geri yükleyin (`restore latest --include /source/DATA/AppData/BIR_UYGULAMA`) ve `restore/` altındaki dosyaları kontrol edin.

### Güvenlik notları

- Konteyner Docker soketine erişir (konteynerleri durdurup başlatabilmek için) — bu, host üzerinde root yetkisine eşdeğerdir. Klasörün izinlerini root'a kısıtlayın: `sudo chmod 700 /DATA/AppData/casaos-backup`.
- `.env` (parola) ve `config/rclone/rclone.conf` (Drive token'ı) dosyalarının bir kopyasını sunucu **dışında** saklayın; sunucu tamamen giderse geri yükleme için bunlara ihtiyacınız olacak.
- Drive'daki veriler restic tarafından AES-256 ile şifrelenir; Google içeriği göremez.

### Dosya yapısı

```
casaos-backup/
├── docker-compose.yml
├── Dockerfile
├── .env.example        → .env olarak kopyalanır
├── config/
│   ├── excludes.txt    hariç tutma desenleri
│   └── rclone/         rclone.conf burada oluşur
├── scripts/
│   ├── entrypoint.sh   zamanlama + depo oluşturma
│   ├── backup.sh       yedekleme, durdur/başlat, saklama, bildirim
│   └── restore.sh      snapshot listesi / geri yükleme
├── cache/              restic önbelleği (otomatik)
└── restore/            geri yüklenen dosyalar (otomatik)
```

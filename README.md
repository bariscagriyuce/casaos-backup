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

To add more folders, uncomment the lines in `docker-compose.yml` or add `- /host/path:/source/host/path:ro`. Exclusions live in `config/excludes.txt`.

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

```bash
sudo docker compose exec casaos-backup rclone config
```

In the wizard:

1. `n` (new remote) → name: **`gdrive`**
2. Storage: **`drive`** (Google Drive)
3. `client_id` / `client_secret`: can be left empty (with lots of data, [your own client ID](https://rclone.org/drive/#making-your-own-client-id) avoids rate limits)
4. scope: **`1`** (full access) or **`3`** (drive.file — only files created by rclone, safer)
5. `Use web browser to automatically authenticate?` → **`n`** (the server has no browser)
6. Run the shown `rclone authorize "drive" "..."` command **on a computer with a browser** (rclone must be installed there), sign in with Google and paste the resulting token into the wizard on the server
7. Shared drive → `n`, then `y` to save and `q` to quit

Within a minute the container detects the config and creates the `casaos-backup` folder and the restic repository on Drive.

#### 4. Run the first backup manually (recommended)

The first backup uploads everything and may take a long time; later runs upload only changes.

```bash
sudo docker compose exec casaos-backup backup
```

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

### Container stop behaviour

`STOP_MODE=all` (default): all running containers are stopped during the backup and restarted right after the files are read (before pruning). For incremental backups this is usually a few minutes.

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

#### Full restore from scratch (disk failure / new server)

1. Install CasaOS on the new server.
2. Put this folder back under `/DATA/AppData/casaos-backup`, create `.env` with **the same `RESTIC_PASSWORD`**, and configure rclone again with the same `gdrive` name (or copy your old `config/rclone/rclone.conf`).
3. Start the container and extract the latest snapshot:
   ```bash
   sudo docker compose up -d --build
   ```
   ```bash
   sudo docker compose exec casaos-backup restore latest
   ```
4. Stop CasaOS and copy the files into place:
   ```bash
   sudo systemctl stop casaos casaos-app-management
   ```
   ```bash
   sudo rsync -a /DATA/AppData/casaos-backup/restore/source/DATA/AppData/ /DATA/AppData/
   ```
   ```bash
   sudo rsync -a /DATA/AppData/casaos-backup/restore/source/var/lib/casaos/ /var/lib/casaos/
   ```
   ```bash
   sudo rsync -a /DATA/AppData/casaos-backup/restore/source/etc/casaos/ /etc/casaos/
   ```
5. Start CasaOS; apps are recreated from the compose files in `/var/lib/casaos/apps`:
   ```bash
   sudo systemctl start casaos casaos-app-management
   ```
   If apps don't come up automatically, for each one:
   ```bash
   cd /var/lib/casaos/apps/APP_NAME && sudo docker compose up -d
   ```
6. The old container/image lists are kept for reference under `restore/backup-meta/`.

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

Başka klasör eklemek için `docker-compose.yml` içindeki yorumlu satırları açın veya `- /host/yol:/source/host/yol:ro` şeklinde ekleyin. Hariç tutmalar `config/excludes.txt` dosyasında.

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

```bash
sudo docker compose exec casaos-backup rclone config
```

Sihirbazda:

1. `n` (new remote) → isim: **`gdrive`**
2. Storage: **`drive`** (Google Drive)
3. `client_id` / `client_secret`: boş bırakabilirsiniz (çok veri varsa [kendi client ID'nizi](https://rclone.org/drive/#making-your-own-client-id) oluşturmanız hız limitlerini önler)
4. scope: **`1`** (full access) veya **`3`** (drive.file — sadece rclone'un oluşturduğu dosyalar, daha güvenli)
5. `Use web browser to automatically authenticate?` → **`n`** (sunucuda tarayıcı yok)
6. Ekranda verilen `rclone authorize "drive" "..."` komutunu **tarayıcısı olan bilgisayarınızda** çalıştırın (o bilgisayarda rclone kurulu olmalı), Google ile giriş yapın, çıkan token'ı sunucudaki sihirbaza yapıştırın
7. Shared drive sorusu → `n`, sonra `y` ile kaydedin, `q` ile çıkın

Konteyner bir dakika içinde yapılandırmayı fark eder, Drive'da `casaos-backup` klasörünü ve restic deposunu oluşturur.

#### 4. İlk yedeği elle alın (önerilir)

İlk yedek tüm veriyi yükleyeceği için uzun sürebilir; sonrakiler sadece değişiklikleri yükler.

```bash
sudo docker compose exec casaos-backup backup
```

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

### Konteyner durdurma davranışı

`STOP_MODE=all` (varsayılan): yedek alınırken çalışan tüm konteynerler durdurulur, dosyalar okunduktan hemen sonra (prune'dan önce) tekrar başlatılır. Artımlı yedeklerde bu genelde birkaç dakikadır.

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

#### Sıfırdan tüm sistemi geri yükleme (disk çöktü / yeni sunucu)

1. Yeni sunucuya CasaOS'u kurun.
2. Bu klasörü tekrar `/DATA/AppData/casaos-backup` altına koyun, **aynı `RESTIC_PASSWORD`** ile `.env` oluşturun, rclone'u aynı `gdrive` adıyla tekrar yapılandırın (veya eski `config/rclone/rclone.conf` dosyasını kopyalayın).
3. Konteyneri başlatıp tüm son snapshot'ı açın:
   ```bash
   sudo docker compose up -d --build
   ```
   ```bash
   sudo docker compose exec casaos-backup restore latest
   ```
4. CasaOS'u durdurun ve dosyaları yerlerine kopyalayın:
   ```bash
   sudo systemctl stop casaos casaos-app-management
   ```
   ```bash
   sudo rsync -a /DATA/AppData/casaos-backup/restore/source/DATA/AppData/ /DATA/AppData/
   ```
   ```bash
   sudo rsync -a /DATA/AppData/casaos-backup/restore/source/var/lib/casaos/ /var/lib/casaos/
   ```
   ```bash
   sudo rsync -a /DATA/AppData/casaos-backup/restore/source/etc/casaos/ /etc/casaos/
   ```
5. CasaOS'u başlatın; uygulamalar `/var/lib/casaos/apps` altındaki compose dosyalarından tekrar oluşturulur:
   ```bash
   sudo systemctl start casaos casaos-app-management
   ```
   Uygulamalar otomatik ayağa kalkmazsa her biri için:
   ```bash
   cd /var/lib/casaos/apps/UYGULAMA_ADI && sudo docker compose up -d
   ```
6. Eski konteyner/imaj listesi referans için `restore/backup-meta/` altında durur.

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

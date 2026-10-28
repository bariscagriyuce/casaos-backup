# Privacy Policy / Gizlilik Politikası

## English

casaos-backup is a self-hosted backup tool. It runs entirely on the user's own server.

- It uses the Google Drive API only to upload, list, download and delete the backup files **it created itself** (`drive.file` scope). It cannot see or access any other files in your Google Drive.
- Backup data is encrypted on your server with restic (AES-256) before it is uploaded. Google cannot read its contents.
- No data is sent to the author of this project or to any third party other than Google Drive. There is no analytics, telemetry or tracking.
- OAuth tokens are stored only in the `rclone.conf` file on your own server.
- You can revoke access at any time at https://myaccount.google.com/permissions.

## Türkçe

casaos-backup, kullanıcının kendi sunucusunda çalışan bir yedekleme aracıdır.

- Google Drive API'yi sadece **kendi oluşturduğu** yedek dosyalarını yüklemek, listelemek, indirmek ve silmek için kullanır (`drive.file` izni). Google Drive'ınızdaki diğer dosyaları göremez ve erişemez.
- Yedek verileri yüklenmeden önce sunucunuzda restic ile (AES-256) şifrelenir. Google içeriği okuyamaz.
- Google Drive dışında hiçbir veri bu projenin yazarına ya da üçüncü taraflara gönderilmez. Analitik, telemetri veya takip yoktur.
- OAuth token'ları sadece kendi sunucunuzdaki `rclone.conf` dosyasında saklanır.
- Erişimi istediğiniz zaman https://myaccount.google.com/permissions adresinden iptal edebilirsiniz.
